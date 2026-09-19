# OmaSecBoot design

This document owns the design. The upstream behaviour it relies on is recorded, with sources, in [upstream-contracts.md](upstream-contracts.md); references such as [C3] point to sections there. Every behaviour of the tool traces to a row of the failure table in section 8 or to an upstream contract. A change that can cite neither does not belong in the tool.

## 1. Purpose

OmaSecBoot is the opt-in way to run an installed Omarchy system with Secure Boot on, using the user's own keys. It fills the gaps that sbctl, the Limine tools and pacman leave between them, verifies what they did, and tells the user the truth about the result.

What it promises:

- It is opt-in. On a machine where `setup` never ran, its hook exits on its first line.
- It never blocks pacman and never fails a Limine operation. A kernel update costs a couple of seconds at most.
- It delegates to sbctl and the stock Limine tools. It patches no package and pins no version.
- `status` states the limits honestly, and the tool can undo itself: `remove` returns the boot files and settings to stock, and the firmware's own key menu restores the firmware's keys.
- It is one small package. Omarchy's side is a pair of thin wrappers and a menu row ([omarchy-integration.md](omarchy-integration.md)).

## 2. Decisions

### D1. Snapshot images are never touched

limine-snapper-sync stores a hash of every snapshot image it keeps and never rewrites it [C2]. Signing such an image in place makes its menu entry stale for good [C6]. OmaSecBoot therefore never modifies, signs or registers a history file. Images from before setup stay unsigned with valid hashes: with Secure Boot on the firmware refuses that one entry, with Secure Boot off it boots normally. `status` counts them, and Omarchy's snapshot rotation (five to six entries) retires them.

### D2. The fallback loader stays raw

Limine checks an enrolled config checksum unconditionally and refuses to start on a mismatch, with Secure Boot on or off [C1]. The fallback loader `EFI/BOOT/BOOTX64.EFI` is therefore left exactly as upstream deploys it, unsealed and unsigned, which makes it the rescue that needs no rescue media: turn Secure Boot off, pick it in the firmware's boot menu, run `sign`. With Secure Boot on the firmware refuses it, so it costs no security, and upstream re-copies it raw on every Limine upgrade anyway [C2]. A fallback that is signed but not sealed would boot under Secure Boot without enforcing `limine.conf`; `status` reports one and `sign` restores the raw copy. The accepted cost: a firmware that loses its Limine boot entry but keeps the keys needs one Secure Boot toggle to recover.

### D3. A watcher re-seals the loader when `limine.conf` changes

An edit of `limine.conf` without re-enrollment stops Limine from booting (D2). The package ships a systemd path unit template. `setup` enables one instance for the machine's `limine.conf`, `remove` disables it, and on a change it checks the seal and re-enrolls only on a mismatch. Nothing is generated and nothing stays resident. systemd merges changes that arrive while the triggered service runs [C5], so the check looks at the file's current state and repeats, three rounds at most, until the file held still across a round; the service's start rate limit is off, so a burst of saves cannot disable the watcher.

### D4. Keys are enrolled by appending

After the user deletes only the Platform Key, the tool writes db, then KEK, then PK, one variable per `sbctl enroll-keys --append --partial <variable> --ignore-immutable` call, and reads each one back. Nothing the machine trusted is removed: the manufacturer's and Microsoft's entries, including certificates that Windows servicing added, survive by construction, and dbx is never written.

- sbctl's append adds the local certificate again on every run [C4], so a variable that already holds it is skipped. That also makes a run that was interrupted between db, KEK and PK safe to finish.
- Append skips sbctl's option-ROM check [C4], so the tool proves beforehand, against the backup taken while a PK was in place, that KEK and db still hold every entry and that dbx is unchanged. A machine that reached Setup Mode before its first `setup` has no such backup and is told that the tool cannot know what was removed.
- Appending to an empty KEK or db would enroll the local keys alone, without the certificates option ROMs and Windows need, so empty never means append. Only when the firmware's key menu cleared KEK and db together with the PK (each is empty, or already what an interrupted rebuild wrote) does the tool rebuild them with `--microsoft --firmware-builtin`, or `--microsoft` alone on firmware that does not expose both `KEKDefault` and `dbDefault`. That path has a confirmation of its own, which lists every backup entry the rebuild cannot bring back and names a changed dbx. Anything in between is refused.
- Per-variable writes over the immutable variables with `--ignore-immutable`, read back exactly, are recorded on hardware [C6]; the append payload is proved in stage 2 of acceptance.

## 3. Non-goals and claim limits

- No transaction journal, state machine, recovery chain, ownership proof, version pin or patched upstream package. An interrupted operation is finished by running the same command again.
- No pacman hook of any kind, and no write to sbctl's file list beyond removing rows that would cause damage.
- No crash-atomic publication of several files. A single file is replaced through a staging file in the same directory, a sync and a rename; FAT rename is not claimed to be atomic.
- No dbx writer, no restoration of factory keys, no `sbctl reset`, no access to NTFS, no enforcement of module signatures.
- Threat model. Secure Boot's own threat is the offline modification of boot files; signing and config enrollment address it as far as the upstream tools' design allows. One limit is upstream's: the raw loader that every Limine operation seals and signs comes from an unauthenticated backup file on the ESP [C2], and OmaSecBoot rebuilds from the same file, so it adds no exposure and removes none. At runtime the only adversary considered is a non-root user; root, and physical access with the firmware's credentials, are trusted.
- Never claimed: that a BootNext request keeps BitLocker quiet or preserves PCR7, that a signature proves the firmware will boot a file, that a clean Windows preflight clears the firmware, that firmware keys are restored automatically, that the installer ISO becomes Secure Boot capable, or anything beyond the machines recorded in acceptance.

## 4. Architecture

One command, `omasecboot`: a dispatcher and modules under `/usr/lib/omasecboot`, in Bash, in one style (`#!/bin/bash`, two-space indentation, `[[ ]]` and `(( ))`, comments that say why). State is derived from observation on every run. The tool keeps only these files under `/var/lib/omasecboot`, which the first command that records something creates and package removal leaves alone:

| File | Purpose |
| --- | --- |
| `enabled` | Written by `setup` as soon as the managed settings are in place, before it regenerates and signs, so the hook and the watcher keep the boot files converged even when that run is interrupted. The hook tests this file first and exits when it is absent. |
| `settings-originals` | What `/etc/default/limine` said about the two managed keys before the first change, for `remove`. |
| `firmware-backup/<utc>/` | PK, KEK, db and dbx byte for byte, with their attributes and the mode variables, taken before any firmware instruction. It is the set this machine trusted before the change, never called "factory keys". |
| `windows-enabled` | Zero-byte opt-in for the Windows entry, so the entry can be put back after Omarchy replaces `limine.conf` from its template. |
| `needs-attention` | Written when a pass could not finish, removed by the next one that does. Read by `status` and by Omarchy's wrapper. A busy lock (exit 75) never writes it. |

The Windows target is never recorded. It is derived from the firmware on every use, which also survives a firmware that renumbers its boot entries.

### Managed settings

Config enrollment is required, not optional: Omarchy's UKIs carry no embedded command line when sbctl and Snapper are present [C2], so without an enrolled `limine.conf` the boot entries themselves are unprotected. The tool manages two settings, written to `/etc/default/limine` only, the one layer that honours enrollment [C3]:

- `ENABLE_ENROLL_LIMINE_CONFIG=yes`.
- `ENABLE_VERIFICATION=no`, which takes path hashes off the OS entries. Under Secure Boot the firmware already verifies the UKI's signature, while a hash turns any later signature repair in place into a boot failure [C1].

`setup` requires an effective `ENABLE_UKI=yes`, because entries without a UKI need hashes under Secure Boot. After writing the settings it regenerates the OS entries through `limine-mkinitcpio` when they still carry hashes, and goes on only when the hashes are gone: the tool reports success after a failed build [C2], and signing a hashed UKI in place would make its entry stale.

### Who owns what

Upstream owns the primary loader cycle (raw in the pre-hook, enrolled and signed by `90-limine-enroll-config`), the fallback loader, `snapshots.json`, the history files and `limine.conf`. The one exception in `limine.conf` is the marked Windows block, written only under the lock inside a pass that seals the loader afterwards, or while the loader carries no checksum. sbctl owns its file list and signs rebuilt UKIs through its mkinitcpio hook.

OmaSecBoot verifies the primary after every Limine operation: the checksum embedded in it must equal `b2sum limine.conf`, and it must carry the local signature. Only when that proof fails, because upstream masks enroll and sign failures [C2], does it rebuild the loader: from the raw executable upstream deployed (its backup beside the primary, else the package's file), in a staging file beside the target, enroll, sign, verify, sync, rename, with a free-space check first. It signs, with plain `sbctl sign`, only files that arrive unsigned and are neither Microsoft's, history files nor the fallback.

### The boot lock

Every path that changes boot files takes `/run/lock/boot-partition.lock` on descriptor 200, the mutex of limine-entry-tool and limine-snapper-sync [C2].

- Inside a Limine hook the calling tool already holds the lock on the descriptor the hook inherits; the tool locks that same descriptor, because a fresh open would deadlock against its own parent.
- An inherited descriptor that cannot be locked at once means the calling tool timed out and someone else is at work on the boot files. The hook waits five seconds at most, because that time is spent inside a package transaction, then returns 75 and leaves the proof to the next Limine operation, `sign` or `status`.
- Otherwise the tool opens the lock, waits up to 90 seconds, then exits 75 and names the lock. It never proceeds unlocked.
- It does nothing while `/run/lock/limine-snapper-restore.lock` exists, because a full snapshot restore runs without the lock [C2].
- The Limine tools that `setup` and `remove` run as children take the lock themselves and carry on unlocked after their own timeout, so the lock is released around them and taken again afterwards, with a fresh proof.

## 5. Commands

Subcommands carry no `--` prefix. Exit status: 0 success, 1 failure or attention needed, 2 usage, 75 boot files busy.

### `setup`

The one command a user needs; it is run again after each step it asks for. It is interactive, needs a terminal, and says what was cancelled at every declined prompt. One firmware step per run, chosen from what the firmware holds (section 6).

Boot files, on every run:

1. Preflight: UEFI, a vfat ESP resolved through the four configuration layers, `ENABLE_UKI=yes`, the tools present, no `limine.conf` in a place Limine reads first, no leftovers of a pre-package install (with the removal command printed), and readable `SecureBoot` and `SetupMode` variables, because `remove` would refuse without them.
2. `sbctl create-keys` only when there are no keys, without creating anything under `/var/lib/sbctl` itself [C4]; `pacman -D --asexplicit sbctl`, so orphan cleanup never offers to remove it.
3. The managed settings, with the originals saved first. Whatever `/etc/default/limine` said before is the user's and comes back with `remove`, including values equal to the managed ones.
4. Rows that would make sbctl sign a history file or the fallback in place are removed from its file list.
5. Regeneration of the OS entries when they carry hashes, then the `sign` pass, which also enables the watcher.
6. A warning when the machine has no fallback loader, and the advice to take a snapshot now.

Then the firmware step:

- **A Platform Key is in place and it is not the user's.** The keys are backed up, and the user is told to delete only the PK in the firmware.
- **Setup Mode.** Never in the run that created `enabled`, which ends with an instruction instead. The local certificates are identified first: they are the entries sbctl owns in an export that does not read the firmware [C4], so they are known before, during and after an enrollment and beside an older certificate that rotated keys left behind. Then the proofs of D4, one confirmation (default No) that says the PK is replaced, how many KEK and db entries are kept and where the backup is, and the writes. The result is judged by reading the variables back, never by `SetupMode`, which keeps reading 1 in the boot that wrote the PK [C6].
- **The user's keys are enrolled.** "Reboot" while `SetupMode` still reads 1; "turn Secure Boot on" after that; "complete" once it is on.

Where Windows or a BitLocker volume is found, or cannot be ruled out, the delete instruction and the enrollment are each preceded by the encryption guidance and one acknowledgment (default No), and the instruction to turn Secure Boot on by a reminder, because each of them changes what Windows measures at boot. A machine without Windows is asked nothing.

### `sign`

The converge-and-verify pass that people, the hook and the watcher all run. It is idempotent and cheap when nothing changed.

- Sweeps staging files a killed pass left on the ESP, and ensures the managed settings.
- Keeps the Windows block in step with `windows-enabled`: written or replaced while the flag exists, taken out when it does not. Whatever keeps the block from being written is said and left to `status`, never made the pass's failure.
- Proves the primary loader or rebuilds it (section 4).
- Restores a fallback that is Limine's (it contains the checksum marker) and is signed or sealed to the raw copy, and never touches any other `BOOTX64.EFI`.
- Signs EFI files that arrived unsigned (D1 and D2 apply) and proves each signable file with one read.
- Fails on a stale path hash of an OS entry, re-enables the watcher when it is inactive, and clears or writes `needs-attention`.
- Writes nothing to an ESP with less than 2 MiB free.
- Never asks sbctl for its file list, which would make sbctl read every tracked file [C4].

`--config-only` stops after the loader proof; the watcher uses it. A loader that could not be sealed is reported as "do not reboot, with Secure Boot on or off"; every other failure as "do not reboot with Secure Boot on".

### `status`

Read-only. It reports the firmware state and whether the user's keys are enrolled, the managed settings, the loader proof, the fallback, the signing keys, every signable file, harmful sbctl rows, stale path hashes of OS entries, unsigned history files as a count, the Windows entry, the hook, the watcher, leftovers and `needs-attention`. It ends with one next step, chosen by what repairs the worst problem seen: `sign`, `setup`, or nothing this tool runs. Anything that could not be read belongs to the last kind. `--quiet` only sets the exit status.

### `windows preflight | setup | remove | status | bootnext | available`

- The target comes from the firmware alone [C8]: the file node of an entry's first device path must be exactly `\EFI\Microsoft\Boot\bootmgfw.efi`, exactly one such entry may be active among every `Boot####` variable, and no other entry may share its label. The tool never creates or renames firmware entries and never mounts or reads a foreign filesystem.
- `preflight` looks for a Windows Boot Manager entry and for BitLocker volumes and prints what to do in Windows before Secure Boot changes. A clean result is an observation, not a clearance.
- `setup` writes the flag and runs the pass, which writes the block, using Limine's `efi_boot_entry` protocol, and seals the loader over it. `remove` deletes the flag and runs the pass the same way; on a machine that is not set up it takes the block out only while the loader carries no checksum. Both refuse during a snapshot restore and report what `limine.conf` holds afterwards.
- `bootnext` asks the firmware for one boot of the target and reads `BootNext` back. Exit 0 means the firmware holds the request, nothing more; a request for a loader that has gone missing falls through to the next boot entry [C8].
- `available` is the silent, unprivileged guard of the menu row: the flag exists and the firmware still has one clear target.

### `remove`

The way back to stock, named as Omarchy names the counterpart of a `setup` [C7]. It refuses unless `SecureBoot` reads 0, because the stock boot files are unsigned. It is driven by `settings-originals`, which it deletes last, so it can be run again after an interruption: it takes the lock, deletes `enabled` so the hook goes quiet, disables the watcher, restores the settings, runs upstream's install, entry generation and reset (their post-hooks sign the primary while keys exist, so the reset comes last), verifies that the primary is upstream's raw executable again, and only then takes the Windows block and flag out, because `limine.conf` must not change under a sealed loader. Keys and firmware backups stay.

## 6. Observed states

Derived on every run: not set up; boot files ready and the firmware untouched; Setup Mode, ready to enroll; enrolled, reboot to confirm; enrolled with Secure Boot off; enrolled with Secure Boot on; attention needed, with the reason. "Enrolled" means PK, KEK and db hold the local certificates, however they got there. Entries that Microsoft or firmware servicing add later are never refused. A missing local certificate is an error while Secure Boot is on and the pending firmware step while it is off.

## 7. Integration points

Two, and neither is a pacman hook.

| Piece | When it runs | What it does |
| --- | --- | --- |
| `/etc/boot/hooks/post.d/90-omasecboot-sign` | At the end of every Limine operation that uses the hook chain: kernel install and removal, Limine upgrade, `limine-update`, snapshot sync, restore [C2]. The name follows upstream's scheme: it sorts after `90-limine-enroll-config`, whose work it checks, and before upstream's optional `91` hook that remounts the ESP read-only. | A script that sources nothing: `[[ -e /var/lib/omasecboot/enabled ]] || exit 0`, then `omasecboot sign --quiet || :` and `exit 0`, with no `exec` and no `set -e`. The last hook's status becomes the Limine tool's, and `limine-mkinitcpio-install` treats non-zero as a failed kernel install [C2], so even a broken OmaSecBoot never fails an update. On failure `sign` leaves the marker and one red line that names `omasecboot status`. |
| `omasecboot-watch@.path` and `omasecboot-watch@.service` | When the watched `limine.conf` changes. `setup` enables the instance for the resolved path (`systemd-escape --template`); the path unit uses `PathChanged=%f`, the service `StartLimitIntervalSec=0`; systemd orders the instance after the ESP's mount by itself [C5]. | `omasecboot sign --quiet --config-only`. No marker on exit 75; quiet while a restore runs or the ESP is not mounted. |

Everything that changes the boot chain on Omarchy (UKIs, the primary loader, `limine.conf`, snapshot entries) runs the Limine hook chain, including the firmware, microcode, dkms and systemd updates that rebuild the initramfs [C2]. A pacman hook would only repeat that work later in the same transaction, and sbctl's own `zz-sbctl` hook has nothing to do, because OmaSecBoot registers nothing in sbctl's file list.

Cost. The work OmaSecBoot adds to one kernel transaction stays within two seconds per installed kernel on 267 MB UKIs, measured in stage 1 of acceptance, because a breach would change the design. A full pass reads every current UKI once to check its signature; it never copies or re-signs one and never reads a history file. Hooks never prompt.

Omarchy's update sequence has no step that can hold its restart prompt [C7]. The marker and the red line are the visible signal; Omarchy's wrapper and update step read `omasecboot status --quiet` ([omarchy-integration.md](omarchy-integration.md)).

## 8. Failure table

Any later finding or feature cites a row here or adds one with its evidence.

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| A new UKI arrives unsigned, or a Limine tool masks a failed build | The new default entry is refused | Boots | Boot a snapshot entry or turn Secure Boot off, run `sign` | The pass in the Limine hook signs it; otherwise marker, red line, `status` exit 1 |
| `limine.conf` edited without re-enrollment, or `omarchy-refresh-limine` interrupted | The primary refuses to start | The primary refuses to start [C1] | Secure Boot off, pick the fallback loader in the firmware's boot menu, run `sign`; rescue media on a machine without a fallback | The watcher (D3), the Limine hook, the raw fallback (D2); `setup` warns when there is no fallback |
| The firmware loses its Limine boot entry but keeps the keys (a firmware or Windows update) | The raw fallback is refused; the firmware boots Windows or stops | The fallback boots | Secure Boot off, boot, `limine-install`, Secure Boot on | Documented; the accepted cost of D2 |
| A history file or the fallback has a row in sbctl's file list | sbctl's hook signs it in place: a stale snapshot hash, or a signed but unsealed fallback | Same | `setup` | `setup` removes the rows, `sign` restores the fallback, `status` reports both; OmaSecBoot never adds rows |
| Power is lost while upstream rewrites the primary in place | The primary may be raw or torn | A raw primary boots; a torn one does not | The fallback loader or rescue media, then `sign` | Upstream's window, which a post-hook cannot close |
| Power is lost during the staged rebuild | The old primary or the new one | Same | `sign` | Stage, sync, rename |
| Power is lost while the pass signs an unsigned UKI in place (rare: sbctl's build hook normally signs it first) | That entry is torn | Same | Boot a snapshot entry, rebuild with `limine-mkinitcpio` | In place by choice: a staged copy of a 267 MB image can exhaust a small ESP |
| Power is lost while the tool replaces `limine.conf` or a loader on the FAT ESP | The file may be missing or torn, and the primary refuses a `limine.conf` it is not sealed over | Same | Secure Boot off, the fallback loader, `sign`; rescue media without a fallback | Staging in the same directory, a sync before and after the rename, staging files swept by the next pass; FAT cannot do better |
| Omarchy replaces `limine.conf` from its template (`omarchy-refresh-limine`, `omarchy-reinstall-configs`) | The Windows entry disappears | Same | `sign` | The `windows-enabled` flag; the pass puts the block back |
| A line of the tool's Windows markers lost its partner, `limine.conf` is not root's alone, or it changed while the entry was being written | Omarchy boots; the Windows entry may be missing or doubled | Same | Fix what `status` names, then `sign` | The pass says so and goes on; `status` error; a refused write never touches `limine.conf` |
| Windows is removed, or a second Windows Boot Manager entry appears, while the entry is enabled | Omarchy boots; the menu entry may point nowhere | Same | `windows remove`, or fix the firmware's entries | The pass goes on quietly; `status` error that names `windows remove`; the menu guard hides the row |
| An Omarchy factory reset rebuilds the ESP from a root without keys | Boot files unsigned while the firmware still holds the local PK | Boots | Secure Boot off, `setup` with new keys | Documented |
| `sbctl rotate-keys` | Files signed with the old key are refused once the new keys are enrolled | Boots | `sign` after rotating, before rebooting | `status` verifies signatures against the current key. Append never removes the old certificate: it stays trusted until the firmware's keys are reset |
| A snapshot taken before setup is restored | Its boot entry is unsigned and cannot be booted | Boots and restores; the root then has no tool, keys or settings, and the next Limine operation returns the loader to stock | Stay on Secure Boot off, or install and run `setup` again with new keys and another firmware round trip | Documentation only: nothing can run in a root that predates the package |
| A snapshot taken after setup is restored | Boots | Boots | `sign` | Converge |
| sbctl's file list is lost | Boots | Boots | None needed | The boot chain does not depend on it |
| sbctl's keys are lost | Boots until the next update | Boots | New keys and another Setup Mode round trip | `status` error: no signing keys, which no command of this tool repairs |
| An upgrade of Limine or its tools changes behaviour | Possibly unsigned files or stale hashes | Boots | `status`, `sign`, Secure Boot off if needed | Version floors, not pins; the contract suites of section 11 |
| The package is removed while set up | sbctl and upstream keep signing the UKI and the primary; gaps are no longer repaired or reported | Harmless | Reinstall, or `remove` first | The documented removal order; Omarchy's remove wrapper runs `remove`; `setup` marks sbctl as explicitly installed |
| Leftovers of a pre-package install (a `/usr/local` copy with hooks under `/etc/pacman.d/hooks` and `/etc/boot/hooks/post.d`) | The old hooks keep running the old tool, or fail the Limine tools once it is gone | Same | The printed removal command | `setup` preflight and `status` |
| A configuration without UKIs | Entries without hashes are refused | Boots | Enable UKIs | `setup` preflight |
| A firmware update or CMOS reset restores the factory keys | Limine is refused; Windows boots | Boots | Secure Boot off, `setup` again | `status` error while Secure Boot is on without the local keys; with it off, `status` names the firmware step again |
| Microsoft or firmware servicing changes db or dbx | Unaffected | Unaffected | None | Never refused |
| BitLocker asks for its recovery key | Windows side only | n/a | Enter the key | Guidance and an acknowledgment before the two steps that cannot be taken back, deleting the PK and writing keys; a reminder before Secure Boot is turned on |
| Snapshot entries older than setup | Those entries do not boot | Boot | They age out, or delete them | D1; `status` counts them |
| The ESP is full | A Limine tool's failure is masked upstream | Same | Free space, `sign` | A free-space check before every write to the ESP; the proof after every Limine operation |
| Another tool holds the lock | The command waits, then exits 75 | Same | Run it again | The lock is named, no marker; the hook waits five seconds at most |
| `SetupMode` still reads 1 after the PK write | n/a | n/a | Reboot, `setup` | Judged by the variables [C6] |
| The enrollment is interrupted between db, KEK and PK | Secure Boot cannot be turned on yet | Boots | `setup` again | A variable that already holds the local certificate is skipped |
| No terminal, or a declined prompt | n/a | n/a | Run it again in a terminal | The refusal says what was cancelled |

## 9. Rules learned on hardware

Recorded with their evidence in [C6]:

- Accept firmware without `AuditMode` and `DeployedMode`, and a key menu that is reachable only while Secure Boot is set to enabled.
- Judge enrollment by the variables, never by `SetupMode` in the boot that wrote the PK.
- Back up before any firmware instruction.
- Never create sbctl's directories for it, and accept its 755 mode.
- Always pass `--ignore-immutable`. Read the mode variables directly.
- Enroll the config checksum before signing a loader.
- Never trust the exit status of a Limine tool or of pacman. The Limine hook exits 0.
- A hash suffix in a snapshot image's filename is not a path hash. Parse trimmed lines.
- Prompts need a terminal and say what was cancelled.
- A busy lock is "busy", not "failed".

## 10. Code layout

| Module | Content |
| --- | --- |
| `bin/omasecboot` | The dispatcher and the commands |
| `lib/common.sh` | Output, file safety, atomic write, the settings lookup as upstream parses it, the boot lock, the marker |
| `lib/checks.sh` | Root, UEFI, ESP, tools, terminal and prompts |
| `lib/files.sh` | The EFI files on the ESP, history and fallback classification, signature state, sbctl's file list |
| `lib/firmware.sh` | Mode variables, the signature-list reader, the backup, the enrollment plan with its proofs, the per-variable enrollment |
| `lib/limine.sh` | Managed settings and originals, `limine.conf` facts, the loader proof and staged rebuild, the fallback, the watcher, the way back to stock |
| `lib/windows.sh` | The target from the firmware's boot entries, the managed block, the BootNext request, the encryption acknowledgment |
| `lib/sign.sh` | The converge-and-verify pass |
| `lib/status.sh` | The report and its next step |

The package also holds the Limine hook, the two unit templates, the menu fragment for Omarchy and its documentation. It carries version floors only, ships no state directory and no tmpfiles declaration, and has no install scriptlet.

A pre-package install, copied into place from this repository, left `/usr/local/bin/omasecboot`, `/usr/local/lib/omasecboot`, files in `/etc/pacman.d/hooks` and `/etc/boot/hooks/post.d/zzz-omasecboot-sign`. They keep running the old tool, and the old Limine hook fails the Limine tools once the old command is gone, so `setup` refuses until they are removed and prints the command that removes them.

## 11. Tests

- Hermetic suites against a fixture machine with stub tools, with a case for every failure-table row that software can simulate. The commands run as processes of their own, so errexit behaves as installed. Every stub behaviour cites the section of upstream-contracts.md that records it; anything else is marked as an assumption in the stub. The whole run takes about a minute.
- A mutation probe per safety predicate: disabling it must fail a named case.
- Real-tool contract suites: real sbctl in a sandbox with fixture keys and a fixture firmware directory (the export against the forms D4 relies on, what a write produces, `--partial` with `--append`, the owner GUID, the list shapes); upstream's Limine shell functions from the installed package (the configuration layers, hook order and exit semantics); a templated `PathChanged` unit on vfat. A weekly CI job runs them against Omarchy's current packages, and drift opens an issue instead of blocking users.
- CI: lint, the hermetic suites, the package build, and installation, upgrade and removal in a container.
- Outside any software test: Limine's behaviour at boot, firmware writes, and sbctl's signing step inside mkinitcpio. Stages 1 and 2 of acceptance are their evidence.

## 12. Acceptance on hardware

Staged, on a dedicated machine, recorded with `tests/acceptance-record.sh`; every stage has a STOP condition ([release-checklist.md](release-checklist.md)), and no claim exceeds the machines recorded.

0. Baseline: factory keys, Secure Boot off, stock Limine settings, no earlier install.
1. Boot files, no firmware write: `setup` to the firmware instruction; hook timing on real UKIs; proof that a rebuilt UKI was already signed before the pass touched it; the stale-checksum drill with Secure Boot off and rescue media at hand, with and without the watcher.
2. Enrollment: delete only the PK, `setup`, reboot, `setup`, Secure Boot on, `status`.
3. Secure Boot on: kernel reinstall, snapshot, a snapshot entry older than setup, `omarchy refresh limine`, a `limine` reinstall, an interrupted pass followed by `sign`.
4. Restore of a snapshot taken after setup, `sign`, update.
5. Windows: preflight, `windows setup`, the menu entry, `bootnext`, upstream's rewrites afterwards.
6. Secure Boot off, `remove`, package removal.
