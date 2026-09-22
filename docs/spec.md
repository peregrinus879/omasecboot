# OmaSecBoot design

This document owns the design. The upstream behaviour it relies on is recorded, with sources, in [upstream-contracts.md](upstream-contracts.md); references such as [C3] point to sections there. Every behaviour of the tool traces to a decision in section 2, a row of the failure table in section 7 or an upstream contract. A change that can cite none of them does not belong in the tool.

## 1. Purpose

OmaSecBoot is the opt-in way to run an installed Omarchy system with Secure Boot on, using the user's own keys. It fills the gaps that sbctl, the Limine tools and pacman leave between them, verifies what they did, and tells the user the truth about the result.

What it promises:

- It is opt-in. On a machine where `setup` never ran, its hook exits on its first line.
- It never blocks pacman and never fails a Limine operation; its budget inside a kernel update is two seconds per installed kernel (section 5).
- It delegates to sbctl and the stock Limine tools. It patches no package and pins no version.
- `status` states the limits.
- The tool can undo itself: `remove` returns the boot files and settings to stock, and the firmware's own key menu restores the firmware's keys.
- It is one small package; what Omarchy adds to deliver it is in [omarchy-integration.md](omarchy-integration.md).

## 2. Decisions

### D1. The user's certificate goes into the firmware, not into a shim

Limine's seal is written into the loader itself, and Omarchy's kernel images are built on the machine, so both are signed on the machine with a key that lives there. A shim does not change that: it only moves that key's certificate from the firmware's db to shim's Machine Owner Key list. The certificate goes into db because that route is complete today. Limine documents it and no other [C1], upstream's enroll hook and sbctl's mkinitcpio hook sign for it [C2], and the firmware itself checks every image Limine chainloads, which on this stack is every UKI [C1]. The shim route is not complete: no repository of Arch or Omarchy ships a shim that Microsoft signed [C6], shim demands an `.sbat` section of its second stage, which the Limine executable does not have [C1], and no record shows Limine starting a kernel image behind a shim. A shim also puts Microsoft's third-party certificate into the Linux boot path.

The cost of own keys is D9: one round trip through a key menu that differs from firmware to firmware, a PK that is the user's to look after [C9], and beside an encrypted Windows a PCR 7 that changes when the PK is deleted and again when the keys are written [C8]. A shim spares all three, because it leaves PK, KEK, db and dbx as they are, and it is the route Omarchy's maintainers plan for consumer installs [C6]. The decision flips when Omarchy ships its own Microsoft-signed shim and a Limine that shim accepts. Signing, sealing, the proof, the hook and the watchers stay as they are then, and the firmware step of `setup` becomes an import of the same certificate into shim's list.

### D2. Converge and verify, no journal

State is derived from observation on every run, every command is idempotent, and an interrupted operation is finished by running the same command again. A journal is a second account of the machine that can be wrong: `/var/lib` rolls back with a snapshot restore while the ESP and the firmware do not, and power loss separates a record from what it records. An observation can go stale while a command waits, for pacman, for the lock or for a person, so the pass looks again once it holds the lock, and what it finds then decides. The cost: the tool can say what is true now, never what it did last, and the files it keeps are only what observation cannot recover: consent, the settings' originals, the keys' backup, and one note that a pass could not finish, which the next clean pass removes.

### D3. The loader is sealed over `limine.conf`, and OS entries carry no path hashes

Sealing the loader over `limine.conf` (upstream calls it config enrollment) is required, not optional: Omarchy's UKIs carry no embedded command line when sbctl and Snapper are present [C2], so without a sealed `limine.conf` the menu entries themselves are unprotected. The tool manages two settings, written to `/etc/default/limine` only, the one layer that honours `ENABLE_ENROLL_LIMINE_CONFIG` [C3]:

- `ENABLE_ENROLL_LIMINE_CONFIG=yes`.
- `ENABLE_VERIFICATION=no`, which takes path hashes off the OS entries. A UKI is started through the firmware's LoadImage, which checks its signature against db, and Limine itself waives the hash for such a chainload under Secure Boot [C1]; upstream's own warning hook exempts `ENABLE_UKI=yes` [C2]. A hash would add nothing to that: whoever can replace the UKI on the ESP can replace the loader beside it, and both answer to the same db. What it would add is a way to fail: under Secure Boot a mismatch is a panic [C1], so every signature written in place, by this tool's repair or after `sbctl rotate-keys`, would stop the entry until it is regenerated. The cost: the setting differs from upstream's default, and upstream's hook advises against it during a snapshot restore [C2].

`setup` requires an effective `ENABLE_UKI=yes`, because entries without a UKI need hashes under Secure Boot. After writing the settings it regenerates the OS entries through `limine-mkinitcpio` when they still carry hashes, and goes on only when the hashes are gone: `limine-mkinitcpio` reports success after a failed build [C2], and signing a hashed UKI in place would make its entry stale. An entry that `limine-mkinitcpio` does not write keeps its hash, so `setup` lists the hashed paths that remain and says to take the hash off such an entry.

### D4. Every EFI program on the ESP is signed, with five exceptions

The pass signs every `.efi` file on the ESP that arrived unsigned, not only Omarchy's kernel images and loader. A machine with Secure Boot on refuses whatever is unsigned, so a narrower rule would stop a memory tester or a second system's loader, and leave the user to sign each by hand after every update. fwupd's helper is not among them: with Secure Boot on fwupd takes only a `fwupdx64.efi.signed` beside its own executable and copies it over the file on the ESP (section 7). `status` names every file the pass signs.

The exceptions, each with its reason:

- Microsoft's files. They carry Microsoft's signature, which db trusts already, and a second signature written in place would change files that Windows services and measures.
- Snapshot images (D5).
- The fallback loader (D6).
- `BOOTIA32.EFI`, Limine's loader for 32-bit firmware. An installer built on archinstall copies it to `EFI/BOOT` beside `BOOTX64.EFI` [C2], 64-bit firmware looks for `BOOTX64.EFI` alone, and upstream never touches it again, so signing it would protect nothing and only change a file that is the package's byte for byte.
- A file that `limine.conf` names with a path hash, whoever wrote the hash, because the signature would make that entry stale.

The cost: a file is signed in place, without staging, as a kernel image is, and one that sbctl cannot sign fails every pass until it is signed or removed.

### D5. Snapshot images are never touched

limine-snapper-sync stores a hash of every snapshot image it keeps (a history file under `limine_history/`) and never rewrites it [C2]. Signing such an image in place makes its menu entry stale for good [C10]. OmaSecBoot therefore never modifies, signs or registers a history file. Nor does it write a new hash into `snapshots.json`: the file is upstream's, and its copy on the root filesystem comes back with a restore [C2]. Images from before setup stay unsigned with valid hashes: with Secure Boot on the firmware refuses that one entry, which Limine reports as a panic before it halts [C10], and with Secure Boot off it boots normally. `status` counts them, and Omarchy's snapshot rotation (five to six entries) retires them.

### D6. The fallback loader stays raw

Limine checks a sealed loader's checksum unconditionally and refuses to start on a mismatch, with Secure Boot on or off [C1]. The fallback loader `EFI/BOOT/BOOTX64.EFI` is therefore left exactly as upstream deploys it, unsealed and unsigned, which makes it the rescue that needs no rescue media: turn Secure Boot off, pick it in the firmware's boot menu, run `sign`. With Secure Boot on the firmware refuses it, so it costs no security, and where `ENABLE_LIMINE_FALLBACK` is yes, Omarchy's default, upstream re-copies it raw on every Limine upgrade anyway [C2].

A machine that Omarchy installed beside another system starts without a fallback [C6], so `setup` offers to add one through `limine-install --fallback`, and only while nothing stands at that path, because upstream's step copies over whatever does [C2]. A fallback that is signed but not sealed, which the comments in upstream's configuration file suggest [C2], would boot under Secure Boot without enforcing `limine.conf`; `status` reports one and `sign` restores the raw copy. The cost: a firmware that loses its Limine boot entry but keeps the keys needs one Secure Boot toggle to recover.

Two limits are stated rather than hidden. `remove` returns the boot files to stock through upstream's install, which deploys the fallback by the user's `ENABLE_LIMINE_FALLBACK` setting as every Limine upgrade does [C2]: with `no`, Omarchy's setting beside another system [C6], another system's loader at that path stays; with `yes` it is replaced by upstream's, on `remove` as on any upgrade, and `remove` says so before its question where another system's loader stands there. And "raw" is what sbctl can tell, no seal and no signature by the current local key: a signature by another key that db still trusts is not seen, so `status` calls the fallback upstream's copy only when its bytes are, and says otherwise what sbctl could tell.

### D7. Nothing is registered in sbctl's file list

Nothing is registered in sbctl's file list, because nothing in this stack needs it and one row can do damage. Upstream's tools sign with plain `sbctl sign`: the mkinitcpio hook signs each UKI while it is built, and `90-limine-enroll-config` signs the loader after sealing it [C2], so on a stock machine the list is empty and `sbctl sign-all` has nothing to do. A row for the loader would have sbctl's pacman hook sign the raw executable that Omarchy's installer hook leaves after a Limine upgrade [C6]: a loader that starts under Secure Boot and enforces nothing, until the next pass replaces it. A row for a history file or the fallback is the damage D5 and D6 exist to prevent. And the list lives on the root filesystem, which a snapshot restore rolls back while the ESP stays as it is. The pass finds its files by looking at the ESP. The cost: `sbctl list-files` shows nothing of this tool's, though `sbctl verify` does, because it scans the ESP; and `sbctl sign-all` and `sbctl rotate-keys` pass its files by, so `sign` runs after a key rotation. The list stays the user's for files outside the ESP, such as the signed helper fwupd needs.

### D8. Watchers re-seal the loader when `limine.conf` or the loader changes

The seal holds two files together, and either can change where no Limine hook runs: `limine.conf` under an editor, which stops Limine from booting [C1], and the primary loader under a plain copy. The pacman hook that Omarchy's installer leaves makes such a copy after every Limine upgrade [C6], and the firmware refuses a raw loader once Secure Boot is on. One path unit template, enabled by the pass for each of the two files and disabled by `remove`, starts `sign --seal-only` (section 5); nothing is generated and nothing stays resident. That pass:

- waits for a running pacman, five minutes at most, so it judges what the transaction's last hook left behind; a lock file without a pacman process is a crashed pacman's and is not waited for. The lock is a plain file with no owner to ask, so a package front end that runs no process named pacman looks the same and is not waited for either; the result is still right, because every later change of the loader or of `limine.conf` starts the pass again;
- rebuilds the loader only when the proof fails, and repeats until `limine.conf` held still across a round, because systemd merges changes that arrive while the service runs [C5]. Three rounds are the bound: a later change starts the pass again by systemd's merge rule [C5], which no hardware row has exercised yet. The service's start rate limit is off, so a burst of saves cannot disable the service; the path unit keeps its own limit, 200 triggers in two seconds [C5], beyond any editor, and a watcher that stopped is enabled again by the next full pass;
- ignores the stop signal of a shutdown, which `KillMode=mixed` sends to it alone, because a pass cut off before the rename leaves the loader the firmware refuses, or the one sealed over the old `limine.conf`; the unit's stop budget of eight minutes covers the waits above before systemd would kill every process of the service, the pass included [C5];
- looks again once it holds the lock: a machine that was removed, a restore that began or an ESP that went away while it waited ends the pass with nothing written (D2).

systemd does not replay a change that lands after the pass's last proof and before it exits [C5]; the next change of either file starts the pass again, and `status` reports the seal in between.

The watchers need a running systemd, so a Limine upgrade from a chroot leaves the raw loader until the next pass; and if Omarchy drops its installer hook, the loader's watcher guards only copies by hand, and stays, because it is cheap.

A pacman hook sorted after the installer's would re-seal that one copy inside the transaction, but not a copy by hand or an edit, so the watchers would stay; and pacman does not notice a post-transaction hook that fails [C6].

### D9. Keys are enrolled by appending

Only the firmware's own key menu can take a manufacturer's Platform Key away: from the running system a PK write must be signed by the PK in place, and the manufacturer holds that key [C4]. The user deletes the PK and nothing else, because whatever else goes is a loss nobody in this stack repairs: sbctl writes PK, KEK and db and has no writer for dbx [C4], and `--microsoft` puts back the certificates sbctl ships, not the ones this machine held. The usual sbctl route, clear every key and enroll with `-m`, is the rebuild path below, taken only when the firmware leaves no choice. It is better in one respect: sbctl 0.18 writes Microsoft's 2023 certificates from its own copies, while append writes none of Microsoft's, so a KEK that lacks the 2023 certificate keeps lacking it (section 7).

After the user deletes only the Platform Key, the tool writes db, then KEK, then PK (the PK last, because it ends Setup Mode), one variable per `sbctl enroll-keys --append --partial <variable> --ignore-immutable` call, and reads each one back. Nothing the machine trusted is removed: the manufacturer's and Microsoft's entries, including certificates that Windows servicing added, survive by construction, and dbx is never written. The lists are read by the tool's own parser, because the proof compares every entry of every type by owner and content, while sbctl's listing names certificates only, and efitools would be a dependency for one reader. The record of this path is in [C10].

- sbctl's append adds the local certificate again on every run [C4], so a variable that already holds it is skipped. That also makes a run that was interrupted between db, KEK and PK safe to finish.
- Append skips sbctl's option-ROM check [C4], so the tool proves beforehand, against the backup taken while a PK was in place, that KEK and db still hold every entry and that dbx is unchanged. A machine that reached Setup Mode before its first `setup` has no such backup and is told that the tool cannot know what was removed.
- Appending to an empty KEK or db would enroll the local keys alone, without the certificates option ROMs and Windows need, so empty never means append. Only when the firmware's key menu cleared KEK and db together with the PK (each is empty, or already what an interrupted rebuild wrote) does the tool rebuild them with `--microsoft --firmware-builtin`, or `--microsoft` alone on firmware that does not expose both `KEKDefault` and `dbDefault` as volatile variables, which is all sbctl accepts [C4]. That path has a confirmation of its own, which lists every backup entry the rebuild cannot bring back and names a changed dbx. Anything in between is refused.

### D10. One firmware step per run

`setup` is run several times, and each run takes one step towards the firmware and stops: it asks for the PK to be deleted, or it writes the keys, or it asks for Secure Boot to be turned on. The run that first changes the boot files never also writes keys, even on a machine it finds in Setup Mode: what it did to the boot files `remove` takes back, while keys in the firmware are taken back only in the firmware's own key menu. So the step that cannot be undone from Linux gets a run of its own, behind a question the user has just read; on a machine that had a Platform Key, the restart into the firmware has by then shown that the machine starts on the sealed loader.

### D11. Windows starts through the firmware, never through a chainload

The Windows entry uses Limine's `efi_boot_entry` protocol, which reboots into the firmware's boot entry of that name, and `windows bootnext` asks the firmware for the same entry, once, at the next start. Either way the firmware itself starts its Windows Boot Manager entry after a restart [C7]. The other way, a `protocol: efi` chainload of `bootmgfw.efi` as `limine-scan` writes it [C2], puts Limine into what BitLocker measures [C8]:

- With Secure Boot on, BitLocker seals its key to PCR 7 only when a single db entry, Microsoft's, verified the boot path. The firmware verifies Limine with the user's certificate first, so a chainload rules that binding out.
- Without that binding BitLocker seals to PCR 0, 2, 4 and 11, and PCR 4 then holds the Limine loader, which is sealed again whenever `limine.conf` changes, by upstream's hook or this tool's watchers (D8). Every re-seal would change what Windows measures.

After the restart the firmware starts Windows as it does from its own boot menu, and by the sources of C8 neither measurement holds anything of Limine's. On the recorded machine BitLocker did not tell the firmware's boot menu, the tool's entry and a BootNext request apart, through every re-seal of the loader in between, and asked for its recovery key at each change between them and a chainload entry, in both directions [C10]. The decision makes a stable binding possible and promises none (section 3).

A chainload entry is upstream's or the user's: Limine starts it under Secure Boot, because a chainload needs no path hash [C1] and `bootmgfw.efi` carries Microsoft's signature, and without BitLocker it does no harm. So the tool neither writes nor removes one. Where one stands beside a BitLocker volume, `status`, `windows setup` and `windows status` say that the two ways of starting Windows do not mix, advise the firmware's way, the only one with a record of staying quiet while the loader is sealed again, and print upstream's command that takes the entry out [C2].

## 3. Threat model, non-goals and claim limits

### Threat model

Secure Boot's own threat is the offline modification of boot files; signing and sealing address it as far as the upstream tools' design allows. One limit is upstream's: the raw loader that every Limine operation seals and signs comes from an unauthenticated backup file on the ESP [C2], and OmaSecBoot rebuilds from the same file, so it adds no source of trust and removes none. A pass authorises what it finds: a full pass signs every EFI program on the ESP that arrived unsigned (D4) and seals whatever `limine.conf` holds, without knowing where either came from, so a file placed on the ESP while the system was off is signed by the next full pass. Four checks stand in a row: the firmware verifies each image against db, Limine checks `limine.conf` against its embedded checksum, OmaSecBoot checks that the boot files agree and were signed with the current local key, and its signing rule takes what stands on the ESP for the user's. An older file that db still trusts is not refused for being older. At runtime the only adversary considered is a non-root user; root, and physical access with the firmware's credentials, are trusted. db keeps Microsoft's certificates (D9), so the firmware still starts any loader that Microsoft signed and dbx does not revoke, another distribution's shim included: signing and sealing keep Omarchy's own boot chain from being changed unnoticed, and do not keep another signed system from being started on the machine.

### Non-goals

- No transaction journal, state machine, version pin or patched upstream package (D2).
- No pacman hook of any kind, and no write to sbctl's file list beyond removing rows that would cause damage.
- No crash-atomic publication of several files. A single file is replaced through a staging file in the same directory, a sync and a rename; FAT rename is not claimed to be atomic.
- No dbx writer, no restoration of factory keys, no `sbctl reset`, no access to NTFS, no enforcement of module signatures. The firmware's key menu restores its factory keys, dbx among them, on the recorded machine [C10], and a firmware update, fwupd or Windows also writes dbx [C4]; a key menu without that option is a firmware this tool has no record of; a restore by this tool would need a writer of signed variables of its own, the one job the design leaves to sbctl. The backup is the reference for D9's proof and a record for a person; no command reads it back. `remove` leaves sbctl's keys, because the firmware may still hold their certificates, and a PK whose private key is gone can sign no KEK update [C9].

### Never claimed

Neither this tool nor the Omarchy pages about it claim that a BootNext request keeps BitLocker quiet or preserves PCR 7, that a signature proves the firmware will boot a file, that a clean Windows preflight clears the firmware, that firmware keys are restored automatically, that enrolled keys mean Secure Boot is on, that the hook and the watchers make every later action unnecessary, that the installer ISO becomes Secure Boot capable, or anything beyond the machines recorded in acceptance.

## 4. Architecture

One command, `omasecboot`: a dispatcher and modules under `/usr/lib/omasecboot`, in Bash. State is derived from observation on every run. The tool keeps only these files under `/var/lib/omasecboot`, which the first command that records something creates and package removal leaves alone:

| File | Purpose |
| --- | --- |
| `settings-originals` | What `/etc/default/limine` said about the two managed keys before the first change, for `remove`. |
| `enabled` | Written by `setup` as soon as the managed settings are in place, before it regenerates and signs, so the Limine hook converges the boot files, and enables the watchers, even when that run is interrupted. The hook tests this file first and exits when it is absent. |
| `firmware-backup/<utc>/` | PK, KEK, db and dbx byte for byte, with their attributes and the mode variables, taken before any firmware instruction. It is the set this machine trusted before the change, never called "factory keys". |
| `windows-enabled` | Zero-byte opt-in for the Windows entry, so the entry can be put back after Omarchy replaces `limine.conf` from its template. |
| `needs-attention` | Written when a pass could not finish, removed by the next one that does. Read by `status`; `remove` clears it. A busy lock (exit 75) never writes it. |

The Windows target is never recorded. It is derived from the firmware on every use, which also survives a firmware that renumbers its boot entries.

### Observed states

Derived on every run:

- Not set up.
- Boot files ready and the firmware untouched.
- Setup Mode, ready to enroll.
- Enrolled, reboot to confirm.
- Enrolled with Secure Boot off.
- Enrolled with Secure Boot on.
- Attention needed, with the reason.

"Enrolled" means PK, KEK and db hold the local certificates, however they got there. Entries that Microsoft or firmware servicing add later are never refused. A missing local certificate is an error while Secure Boot is on and the pending firmware step while it is off.

### Who owns what

Upstream owns the primary loader cycle (raw in the pre-hook, sealed and signed by `90-limine-enroll-config`), the fallback loader, `snapshots.json`, the history files and `limine.conf`. The one exception in `limine.conf` is the Windows entry, written only under the lock inside a pass that seals the loader afterwards, or while the loader carries no checksum. Upstream's rewrites keep a foreign entry and drop comment lines beside it [C7], so the entry carries no markers: it is this tool's when its header is `/Windows` and its body holds nothing but this tool's three keys, its comment among them. sbctl owns its file list and signs rebuilt UKIs through its mkinitcpio hook.

OmaSecBoot verifies the primary loader after every Limine operation: the checksum embedded in it must equal `b2sum limine.conf`, and it must carry the local signature. Only when that proof fails, because upstream masks enroll and sign failures [C2], does it rebuild the loader:

1. The source is the raw executable upstream deployed: its backup beside the primary loader, because upstream holds back a Limine it does not know [C2] and the package's file would then be newer than the loader it deployed; else the package's file.
2. 2 MiB must be free on the ESP, because FAT has no journal to survive a write that ran out of space, and a loader is well under a megabyte.
3. In a staging file beside the target: seal, sign, sync, verify, rename, sync.

It signs, with plain `sbctl sign`, only the files D4 names.

### The boot lock

Every path that changes boot files takes `/run/lock/boot-partition.lock` on descriptor 200, the mutex of limine-entry-tool and limine-snapper-sync [C2].

- Inside a Limine hook the calling tool already holds the lock on the descriptor the hook inherits; the tool locks that same descriptor, because a fresh open would deadlock against its own parent.
- An inherited descriptor that cannot be locked at once means the calling tool timed out and someone else is at work on the boot files. The hook waits five seconds at most, because that time is spent inside a package transaction, then returns 75 and leaves the proof to the next Limine operation, `sign` or `status`.
- Otherwise the tool opens the lock, waits up to 90 seconds, longer than the minute a kernel install holds it [C10], then exits 75 and names the lock. It never proceeds unlocked.
- While `/run/lock/limine-snapper-restore.lock` exists the pass does nothing, and `setup`, `remove`, `windows setup` and `windows remove` refuse, because a full snapshot restore works on the boot files without the lock [C2]. Nothing starts a pass when the restore ends: an accepted cost, because upstream removes its lock when the restore command returns and offers a reboot [C2], and `sign` after a restore is the documented step.
- The Limine tools that `setup` and `remove` run as children take the lock themselves and carry on unlocked after their own timeout, so the lock is released around them and taken again afterwards, with a fresh proof.

## 5. Integration points

Two, and neither is a pacman hook.

| Piece | When it runs | What it does |
| --- | --- | --- |
| `/etc/boot/hooks/post.d/90-omasecboot-sign` | At the end of every Limine operation that uses the hook chain: kernel install and removal, Limine upgrade, `limine-update`, snapshot sync [C2]; inside a snapshot restore it runs too, and does nothing (section 4). The name follows upstream's scheme: it sorts after `90-limine-enroll-config`, whose work it checks, and before upstream's optional `91` hook that remounts the ESP read-only. | A script that sources nothing: `[[ -e /var/lib/omasecboot/enabled ]] || exit 0`, then `omasecboot sign --quiet || :` and `exit 0`, with no `exec` and no `set -e`. The last hook's status becomes the Limine tool's, and `limine-mkinitcpio-install` treats non-zero as a failed kernel install [C2], so even a broken OmaSecBoot never fails an update. On failure `sign` leaves `needs-attention` and one red line that names `omasecboot status`. |
| `omasecboot-watch@.path` and `omasecboot-watch@.service` | When `limine.conf` or the primary loader changes. `setup` enables one instance for each resolved path (`systemd-escape --template`); the path unit uses `PathChanged=%f`, the service `StartLimitIntervalSec=0` and `KillMode=mixed`; systemd orders an instance after the ESP's mount by itself [C5]. | `omasecboot sign --quiet --seal-only`. No `needs-attention` on exit 75; quiet while a restore runs or the ESP is not mounted. |

Every upstream operation that changes the boot chain (UKIs, the primary loader, `limine.conf`, snapshot entries) runs the Limine hook chain, including the firmware, microcode, dkms and systemd updates that rebuild the initramfs [C2]. The two changes that bypass it, an edit of `limine.conf` and the installer hook's copy over the loader [C6], belong to the watchers (D8). A pacman hook would only repeat that work later in the same transaction, and sbctl's own `zz-sbctl` hook has nothing to do, because OmaSecBoot registers nothing in sbctl's file list.

The cost is time: the budget for what OmaSecBoot adds to one kernel transaction is two seconds per installed kernel; stage 1 of acceptance times it, because a breach would change the design, and the recorded machine took 1.1 seconds with two kernels [C10]. A full pass reads every current UKI once to check its signature; it never copies or re-signs one and never reads a history file. Hooks never prompt.

Omarchy's update sequence has no step that can hold its restart prompt [C6]. `needs-attention` and the red line are the visible signal; the update step proposed in [omarchy-integration.md](omarchy-integration.md) would run `omasecboot status --quiet`.

Nothing here can stop an update in time. A Limine post-hook and a pacman post-transaction hook both run after the boot files have changed, pacman has no rollback, and only a pre-transaction hook can abort a transaction [C6]; a non-zero status from the hook would only turn a finished kernel install into a reported failure [C2]. A pre-transaction hook runs before anything has changed: it could refuse an update only because the boot files are wrong already. That would hold back security updates over a state the refusal does not improve, and the transaction it refuses is the one whose Limine operations run the pass that repairs. So the tool repairs, and where it cannot it says so. Removal is the same: the scriptlet warns and cannot stop pacman, and the hook that could is ruled out in section 3. The cost: a machine can be left set up without its tool, which the warning names.

## 6. Commands

Subcommands carry no `--` prefix. Exit status: 0 success, 1 failure or attention needed, 2 usage, 75 boot files busy (sysexits' `EX_TEMPFAIL`: try again). A command that fails says why, a usage error by naming what it did not understand; only `status --quiet` and `windows available` are silent.

### `setup`

The one command a user needs; it is run again after each step it asks for. It is interactive, needs a terminal, and says what was cancelled at every declined prompt. One firmware step per run, chosen from what the firmware holds (section 4).

Boot files, on every run:

1. Preflight: x86_64, UEFI, a vfat ESP resolved through the four configuration layers, `ENABLE_UKI=yes`, the tools present, no `limine.conf` in a place Limine reads first, and readable `SecureBoot` and `SetupMode` variables, because `remove` refuses without a readable `SecureBoot` and the firmware step needs `SetupMode`.
2. With `SecureBoot` reading 1, the keys must exist and db must hold their certificate before anything is written, or `setup` refuses and names the way, Secure Boot off: a loader signed with keys the firmware does not trust stops the machine, and the step that would enroll them comes later (D10). Then `sbctl create-keys` only when there are no keys, without creating anything under `/var/lib/sbctl` itself [C4]; `pacman -D --asexplicit sbctl`, so orphan cleanup never offers to remove it.
3. Rows that would make sbctl sign a history file or the fallback in place are removed from its file list.
4. Under the lock, as `remove` deletes them under it: the originals of the two managed settings, which are the user's and come back with `remove`, values equal to the managed ones included; then the managed settings, then `enabled`, then regeneration of the OS entries when they carry hashes.
5. The offer of D6 when there is no fallback loader, through `limine-install --fallback --no-efi-register`.
6. The pass, which enables the watchers.
7. A warning while the machine has no Limine fallback, because there is none or because a loader that is not Limine's stands at its path, and on the first run the advice to take a snapshot.

Then the firmware step:

- **A Platform Key is in place and it is not the user's.** The keys are backed up. When KEK lacks Microsoft's 2023 KEK certificate the user is warned and asked, because after this step only the user can add it [C9]. Then the user is told to delete only the PK in the firmware and to leave Secure Boot disabled when saving: a key menu that shows only while Secure Boot is set to enabled [C10] would otherwise leave it on, and Secure Boot would come on by itself with the enrollment, before the boot-entry check and the Windows reminder that precede the instruction to turn it on.
- **Setup Mode.** Never in the run that created `enabled`, which ends with an instruction instead.
  - The local certificates are identified first: they are the entries sbctl owns in an export that does not read the firmware [C4], so they are known before, during and after an enrollment and beside an older certificate that rotated keys left behind.
  - Then the proofs of D9, one confirmation (default No) that says the PK is replaced, how many KEK and db entries are kept and where the backup is, and the writes.
  - The result is judged by reading the variables back, never by `SetupMode`, which keeps reading 1 in the boot that wrote the PK [C10].
- **The user's keys are enrolled.**
  - `SetupMode` still reads 1: restart, and run `setup` again.
  - Secure Boot is off: the instruction to turn it on, given only when the firmware holds an active boot entry for the primary loader, because a machine that starts through the fallback path would stop (D6). The entry is known by its path alone: which partition it names and which entry the firmware picks first are not compared ([maintenance.md](maintenance.md) lists that).
  - Secure Boot is on: complete.

Where Windows or a BitLocker volume is found, or cannot be ruled out, the delete instruction and the enrollment are each preceded by the encryption guidance and one acknowledgement (default No), and the instruction to turn Secure Boot on by a reminder, because each of them changes what Windows measures at boot [C8]. The acknowledgement asks for the recovery key: with it a BitLocker prompt is an inconvenience, without it a lockout. Disabling BitLocker's protectors with `manage-bde` before the change, and enabling them once Windows has started with Secure Boot on, only avoids the prompt [C8]; the guidance offers it, as Microsoft documents it without naming an edition and as Windows Home accepted it on the recorded machine [C10], and the tool needs neither. `status` sends an enrolled machine to `setup` for the last step, so that one surface owns the reminder. A machine without Windows is asked nothing.

### `sign`

The converge-and-verify pass that people, the hook and the watchers all run. It is idempotent and cheap when nothing changed.

- Looks again once it holds the lock, since the wait for pacman can be long: a machine that was removed, a restore that began or an ESP that went away ends the pass with nothing written (D2).
- Sweeps staging files a killed pass left on the ESP, and ensures the managed settings.
- Keeps the Windows entry in step with `windows-enabled`: written or replaced while the flag exists, taken out when it does not. Whatever keeps the entry from being written is said and left to `status`, never made the pass's failure.
- Proves the primary loader or rebuilds it (section 4).
- Restores the raw copy over a fallback that is Limine's (it contains the checksum marker) and has been signed or sealed, and never touches any other `BOOTX64.EFI`.
- Signs EFI files that arrived unsigned (D4, D5 and D6 apply), never one that `limine.conf` names with a path hash, under any spelling of the path and whatever resource the entry names, because which volume the firmware resolves `guid()` or `fslabel()` to is not known here [C1], and none while a `limine.conf` that exists cannot be read; it proves each signable file with one read.
- Fails on a stale path hash of an OS entry, re-enables the watchers when either is inactive, and clears or writes `needs-attention`.
- Writes nothing to an ESP with less than 2 MiB free.
- Never asks sbctl for its file list, which would make sbctl read every tracked file [C4].

`--seal-only` is the watchers' pass: it waits for a running pacman to finish and stops after the loader proof. A loader that could not be sealed is reported as "do not reboot, with Secure Boot on or off"; every other failure as "do not reboot with Secure Boot on".

### `status`

Read-only, as root: whether the firmware's keys are the user's is judged against sbctl's export of the local certificates, which needs root and the keys [C4], and one report with one exit status serves the menu row and the update check alike.

- It reports the firmware state and whether the user's keys are enrolled, whether the firmware has an active boot entry for the primary loader, which of Microsoft's 2023 certificates KEK and db lack [C9], the managed settings, the loader proof, the fallback and whether it is the Limine build of the primary loader, the signing keys, every signable file, an ESP with less free space than its largest boot file, a `limine.conf` that shadows the real one, harmful sbctl rows, stale path hashes of OS entries, unsigned history files as a count, the Windows entry, a chainload entry for Windows beside a BitLocker volume (a note, D11), the hook, the watchers, the restore lock while it stands, and `needs-attention`.
- On a machine that is not set up it reports a `setup` or `remove` that stopped half way, which `settings-originals` without `enabled` shows, and names the two commands that finish it.
- On a machine that is set up it ends with one next step, chosen by what repairs the worst problem seen: `sign`, `setup`, or nothing this tool runs; before `setup`, a problem's own line says what to do.
- Anything that could not be read belongs to the last kind.
- `--quiet` only sets the exit status.

### `remove`

The way back to stock, named as Omarchy names the counterpart of a `setup` [C6]. On a machine that is not set up it says that there is nothing to remove and exits 0, as every command is idempotent, so a wrapper that goes on to remove the package does not stop there.

- It refuses unless `SecureBoot` reads 0, because the stock boot files are unsigned, and asks once. Beside Windows the refusal comes with the reminder of the recovery key (section 7.7).
- It stops at an ESP with less room than the next boot file needs before it changes anything (section 7.4), and says before its question when upstream's install will replace another system's fallback loader (D6).
- It is driven by `settings-originals`, which it deletes last, so it can be run again after an interruption:
  1. It takes the lock and deletes `enabled`, so the hook goes quiet.
  2. It disables the watchers and restores the settings.
  3. It runs upstream's install, entry generation and reset; their post-hooks sign the primary loader while keys exist, so the reset comes last. The OS entries limine-entry-tool writes, marked by their order-priority comment [C2], are judged against the restored settings: each of their paths must carry a hash, and a hash on an entry of the user's own proves nothing, because `limine-mkinitcpio` reports success after a failed build [C2]; a run that cannot prove them keeps `settings-originals` and fails, and the next run finishes.
  4. It verifies that the primary loader is upstream's raw executable again.
  5. Only then does it take the Windows entry and the flag out, because `limine.conf` must not change under a sealed loader, clear `needs-attention`, and delete `settings-originals`, still under the lock.
- Keys and firmware backups stay, and so does a fallback loader that `setup` added: it is upstream's raw copy.

### `windows preflight | setup | remove | status | bootnext | available`

- Boot entries are the firmware's, Windows' and `limine-install`'s. A second writer is how a dual-boot machine gets duplicate entries or another boot order, so the tool creates and renames none: its own `limine-install` calls pass `--no-efi-register` [C2], a missing Limine entry is reported with the command that adds it, and the only boot variable the tool writes is `BootNext`, read back.
- The target comes from the firmware alone [C7]: the file node of an entry's first device path must be `\EFI\Microsoft\Boot\bootmgfw.efi`, compared without case, exactly one such entry may be active among every `Boot####` variable, its number must stand in `BootOrder`, where alone Limine looks for it, and no other entry may share its label. The tool never mounts or reads a foreign filesystem.
- `preflight` looks for a Windows Boot Manager entry and for BitLocker volumes and prints what to do in Windows before Secure Boot changes. A clean result means that none was found, not that there is none.
- `setup`, on a machine that is set up with one clear target, writes the flag and runs the pass, which writes the entry, using Limine's `efi_boot_entry` protocol, and seals the loader over it. The entry stands after the entries upstream orders, those that carry `order-priority` [C2], because Omarchy's `default_entry` counts the menu from the top [C6]: the pass writes nothing into a `limine.conf` without menu entries, Omarchy's template on its way to `limine-update`, and the pass after `limine-update` appends the entry; one that stands before upstream's is reported and moved behind them. An entry of the user's after it is left alone. `remove` deletes the flag and runs the pass the same way; on a machine that is not set up it takes the entry out only while the loader carries no checksum. Both refuse during a snapshot restore and report what `limine.conf` holds afterwards.
- `status` shows the target and the entry's state in words: none, the entry for this target once, that entry before upstream's (displaced), an entry for another target or several (stale), this tool's comment in an entry it did not write (misplaced), or a `limine.conf` that could not be read.
- `setup` and `status` end with the note of D11 where a chainload entry for Windows, any entry with a path that ends in `bootmgfw.efi`, stands beside a BitLocker volume, also without a target in the firmware; where the volumes cannot be listed, the note names the condition. The printed command quotes the entry's name for the shell and carries its position where an earlier entry shares the name [C2]. The main `status` says it on a machine that is set up.
- `bootnext` asks the firmware for one boot of the target and reads `BootNext` back. Exit 0 means the firmware holds the request, nothing more; a request for a loader that has gone missing falls through to the next boot entry [C7].
- `available` is the silent, unprivileged guard of the menu row: the flag exists and the firmware still has one clear target.

## 7. Failure table

A finding or a feature cites a row here, or adds one with its evidence.

### 7.1 Boot files and the seal

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| A new UKI arrives unsigned, or a Limine tool masks a failed build | The new default entry is refused | Boots | Boot a snapshot entry or turn Secure Boot off, run `sign` | The pass in the Limine hook signs it; otherwise `needs-attention`, red line, `status` exit 1 |
| The primary loader is replaced outside the Limine tools: Omarchy's installer hook after a Limine upgrade [C6], or a copy by hand | The firmware refuses the raw loader | Boots, the loader is raw | Secure Boot off, run `sign` | The loader's watcher rebuilds it once pacman is done; `status` error until then |
| `limine.conf` edited without a re-seal, or `omarchy-refresh-limine` interrupted | The primary loader refuses to start | The primary loader refuses to start [C1] | Secure Boot off, pick the fallback loader in the firmware's boot menu, run `sign`; rescue media on a machine without a fallback | The watcher (D8), the Limine hook, the raw fallback (D6); `setup` offers to add a fallback and warns while there is none |
| A `limine.conf` stands where Limine reads first [C1], or an OS entry still carries a path hash | The loader is sealed over a file Limine does not read, or the entry is stale | Same, or a warning that waits for a key | Remove the stray file; `setup` regenerates the entries, and the user takes the hash off an entry written by hand that starts an EFI application (an entry of another protocol needs its hash under Secure Boot [C1] and is not served) | `setup` refuses beside a shadowing file, goes on only when the hashes are gone and lists the ones that remain; `status` reports both. A hashed path under a resource other than `boot():/` names a volume only the firmware resolves [C1]: `sign` and `status` say it cannot be checked and do not fail on it, and the pass signs no file of that path |
| A managed setting is changed, by hand or on the advice of upstream's hook 89 [C2] | Boots | Boots | None needed | Every pass writes the two settings back; `status` reports one that is not in effect |
| A configuration without UKIs | Entries without hashes are refused | Boots | Enable UKIs | `setup` preflight |
| An upgrade of Limine, its tools or sbctl changes behaviour | Possibly unsigned files or stale hashes; an sbctl whose enrollment plan or export no longer reads as C4 says | Boots | `status`, `sign`, Secure Boot off if needed | Version floors, not pins; the contract suites (Tests); `setup` checks sbctl's export of the local certificates before the user is asked to delete anything, and its plan before any write, and refuses; an unsound plan is refused with "nothing was written" |

### 7.2 The fallback loader and the firmware's boot entries

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| The firmware never had a boot entry for the Limine loader: a board upstream installs with `--skip-uefi`, or a registration that failed [C2] | The machine starts through the fallback path, which is raw (D6) and refused | Boots | Secure Boot off, `limine-install`, check with `efibootmgr`, `setup` again | `status` blocks, and `setup` holds back the instruction to turn Secure Boot on, without an active firmware entry for the primary loader |
| The firmware loses its Limine boot entry but keeps the keys (a firmware or Windows update) | The raw fallback is refused; the firmware boots Windows or stops | The fallback boots | Secure Boot off, boot, `limine-install`, Secure Boot on | Documented; the accepted cost of D6 |
| `remove` on a machine with `ENABLE_LIMINE_FALLBACK=yes` and another system's loader at the fallback path | n/a | Upstream's install replaces that loader, as every Limine upgrade does [C2] | Put the other loader back from its own media | Documented (D6); `status` names a foreign fallback while the machine is set up, and the setting decides [C3] |
| The signing keys are missing or their certificate is not in db while Secure Boot is on (a snapshot restore from before `setup`, lost keys) | Boots on the files as they are | n/a | Secure Boot off, then `setup` | `setup` refuses before it creates keys or writes a file (section 6) |
| Upstream never refreshes the fallback (`ENABLE_LIMINE_FALLBACK` is no, as Omarchy's installer writes beside another system [C6], or unset [C3]) | The fallback is refused, as always | The rescue loader is an older Limine, which a later major's `limine.conf` may not suit | `limine-install --fallback` | `status` notes a fallback that is another build than the primary loader, unless upstream holds the packaged Limine back, when its step would refresh nothing [C2] |

### 7.3 Power loss

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| Power is lost while upstream rewrites the primary loader in place | The primary loader may be raw or torn | A raw primary boots; a torn one does not | The fallback loader or rescue media, then `sign` | Upstream's window, which a post-hook cannot close |
| Power is lost during the staged rebuild | The old primary loader or the new one | Same | `sign` | Stage, sync, rename |
| Power is lost while the pass signs an unsigned UKI in place (rare: sbctl's build hook normally signs it first) | That entry is torn | Same | Boot a snapshot entry, rebuild with `limine-mkinitcpio` | In place by choice: a staged copy of an image of a few hundred megabytes can exhaust a small ESP |
| Power is lost while the tool replaces `limine.conf` or a loader on the FAT ESP | The file may be missing or torn, and the primary loader refuses a `limine.conf` it is not sealed over | Same | Secure Boot off, the fallback loader, `sign`; rescue media without a fallback | Staging in the same directory, a sync before and after the rename, staging files swept by the next pass; FAT cannot do better |

### 7.4 Snapshots and the ESP

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| Snapshot entries older than setup | Those entries do not boot: Limine panics on the firmware's refusal and halts [C10] | Boot | Power cycle and pick another entry; they age out, or delete them | D5; `status` counts them |
| A snapshot taken before setup is restored | Its menu entry is unsigned and cannot be booted | Boots and restores; the root then has no tool, keys or settings, and the next Limine operation returns the loader to stock | Stay on Secure Boot off, or install and run `setup` again with new keys and another firmware round trip | Documentation only: nothing can run in a root that predates the package |
| A snapshot taken after setup is restored | Boots, unless upstream's masked enroll failed inside the restore [C2]: then the loader refuses `limine.conf` | Same | `sign` after the restore; the fallback loader if the machine is already down | The pass does nothing beside a restore (section 4); `status` names a restore lock that stays; the commands that change boot files refuse beside it |
| The ESP is full, sooner than before setup: an image that is rebuilt and signed again never deduplicates against its predecessor in the snapshot history [C2] | The next kernel image does not fit and a Limine tool's failure is masked upstream [C2] | Same | Delete old snapshots, rebuild with `limine-mkinitcpio`, `sign` | `status` notes an ESP with less free space than its largest boot file needs; a free-space check before every write this tool makes to the ESP, and before upstream's fallback step; the proof after every Limine operation |
| The ESP is not mounted, or the state directory is unsafe | Nothing is checked | Same | Mount the ESP; look at the directory's owner and mode | Without the ESP the pass and `status` say so and change nothing; `setup` and `windows setup` refuse an unsafe state directory before they record anything, and say what makes it unsafe |

### 7.5 sbctl and its keys

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| A history file or the fallback has a row in sbctl's file list | sbctl's hook signs it in place: a stale snapshot hash, which Limine refuses, or a signed but unsealed fallback | Same, except that the stale entry starts once Limine's warning is answered with Y [C1] | `setup` | `setup` removes the rows, `sign` restores the fallback, `status` reports both; OmaSecBoot never adds rows |
| sbctl's file list is lost | Boots | Boots | None needed | The boot chain does not depend on it |
| sbctl's keys are lost | Boots until the next update | Boots | New keys and another Setup Mode round trip | `status` error: no signing keys, which no command of this tool repairs |
| `sbctl rotate-keys` | Files signed with the old key are refused once the new keys are enrolled | Boots | `sign` after rotating, before rebooting | `status` verifies signatures against the current key. Append never removes the old certificate: it stays trusted until the firmware's keys are reset |
| fwupd schedules a firmware update | fwupd refuses without `/usr/lib/fwupd/efi/fwupdx64.efi.signed` | Works | Sign the helper where fwupd looks for it: `sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi`, set `DisableShimForSecureBoot=true` in fwupd's configuration and restart fwupd | Documentation only: the file is outside the ESP, and sbctl's file list stays the user's for it |

### 7.6 Firmware keys and enrollment

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| KEK lacks Microsoft's 2023 KEK certificate when the Platform Key becomes the user's [C9] | Boots | Boots | Install the pending Windows and firmware updates before the PK is deleted; afterwards only the user's own keys can add it | `setup` warns and asks before it tells the user to delete the PK; `status` notes every missing 2023 certificate |
| The firmware's key menu cleared KEK and db with the PK, or left something in between | n/a: Setup Mode | Boots | Restore the factory keys in the firmware, then delete only the PK | D9: rebuild only from lists that are empty or what an interrupted rebuild wrote, behind a confirmation that names what cannot come back; anything else is refused with the list |
| The firmware has no Platform Key and does not report Setup Mode | n/a | Boots | Look at the firmware's key menu; restore the factory keys | `setup` writes nothing and says so |
| The firmware reports Audit Mode (UEFI 2.5), which writing the PK would leave for Deployed Mode | n/a | Boots | Leave Audit Mode in the firmware's own menu | `setup` writes nothing and says so; no machine has a record of that firmware |
| dbx changed between the backup and the PK delete, as after a dbx update Windows applied, while KEK and db are whole | Unaffected | Boots | Restore the factory keys, `setup`, delete the PK again | `setup` refuses before it writes and names dbx as the only difference: a key menu that cleared dbx with the PK would look the same |
| A firmware stores a written list otherwise than sbctl exported it, a duplicate entry dropped | n/a | Boots | Report it, with the read-back's words | The read-back after every write refuses, and `setup` stops with the variables it wrote; no machine has a record of that firmware |
| `SetupMode` still reads 1 after the PK write | n/a | n/a | Reboot, `setup` | Judged by the variables [C10] |
| A mode variable cannot be read during the firmware step | n/a | n/a | Look at efivarfs, `setup` again | `setup` refuses before anything is written; an empty value never passes for "off" |
| A backup carries a name later than the clock reads now (a clock that ran ahead, C10) | n/a | n/a | Set the clock right, `setup` again | `setup` refuses to take a new backup beside it, because the names order the backups and the reference is the newest complete one; the backups and their directory are root's alone whatever the caller's umask |
| The enrollment is interrupted between db, KEK and PK | Secure Boot cannot be turned on yet | Boots | `setup` again | A variable that already holds the local certificate is skipped |
| A firmware update or CMOS reset restores the factory keys | Limine is refused; Windows boots | Boots | Secure Boot off, `setup` again | `status` error while Secure Boot is on without the local keys; with it off, `status` names the firmware step again |
| Microsoft or firmware servicing changes db or dbx after enrollment | Unaffected | Unaffected | None | Never refused; a dbx changed before the PK delete is the row above |

### 7.7 Windows

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| Omarchy replaces `limine.conf` from its template (`omarchy-refresh-limine`, `omarchy-reinstall-configs`) | The Windows entry disappears; an entry written into the bare template would stand first and shift Omarchy's `default_entry` [C6, C10] | Same | `sign` | The `windows-enabled` flag; the pass writes nothing into a `limine.conf` without menu entries and puts the entry back behind Omarchy's once `limine-update` has filled it; `status` reports an entry that stands before them. A write that finds `limine.conf` changed right before its rename gives up, so a newer file of upstream's is not lost; the instant between that check and the rename stays, and the next pass converges |
| The tool's Windows comment stands in an entry that is not as the tool writes it, `limine.conf` is not root's alone, or it changed while the entry was being written | Omarchy boots; the Windows entry may be missing or out of date | Same | Fix what the pass or `status` names, then `sign` | The pass says so and goes on; `status` error; a refused write never touches `limine.conf` |
| Windows is removed, or a second Windows Boot Manager entry appears, while the entry is enabled | Omarchy boots; the menu entry may point nowhere | Same | `windows remove`, or fix the firmware's entries | The pass goes on quietly; `status` error that names `windows remove`; the menu guard hides the row |
| A chainload entry for Windows stands beside a BitLocker volume | Windows starts; on the recorded machine BitLocker asked for its recovery key at each change between that entry and the firmware's way [C10], and by C8 a chainload start is asked again after the loader is sealed anew, which has no record | No record | Start Windows through the firmware only and take the chainload entry out with `limine-remove-entry` [C2] | A note in `status`, `windows setup` and `windows status`; the entry is never written or removed (D11) |
| BitLocker asks for its recovery key | Windows side only | n/a | Enter the key | Guidance and an acknowledgement before the two steps that cannot be taken back, deleting the PK and writing keys; a reminder before Secure Boot is turned on, and where `remove` asks for it to be turned off, the change at which BitLocker asked on the recorded machine [C10] |

### 7.8 The tool's state, the lock and the package

| Event | Secure Boot on | Secure Boot off | Recovery | Handling |
| --- | --- | --- | --- | --- |
| Another tool holds the lock | The command waits, then exits 75 | Same | Run it again | The lock is named, no `needs-attention`; the hook waits five seconds at most |
| The boot lock cannot be opened | Nothing is changed | Same | Look at `/run/lock` | The command fails and names the lock; it never proceeds unlocked |
| `setup` or `remove` stops half way, for example when a Limine tool fails | Depends on where it stopped; `status` exit 1 | Same | `remove`, or `setup` | `settings-originals` without `enabled`; `status` names both commands |
| `limine-mkinitcpio` reports success without rebuilding the entries during `remove` [C2] | Boots | Boots | `remove` again | `remove` judges the entries against the restored settings, keeps `settings-originals` and fails; the next run finishes |
| A watcher's pass waits for pacman while `remove` finishes | Boots | Boots | None needed | The pass looks again under the lock and does nothing on a removed machine (D2) |
| `enabled` exists without the settings' originals | Boots | Boots | `setup` again, which records the settings as they stand now, then `remove`; the two managed settings then stay in `/etc/default/limine` and are deleted by hand | `remove` refuses, says that what the settings were before is gone, and names `setup`; nothing is guessed |
| No terminal, or a declined prompt | n/a | n/a | Run it again in a terminal | The refusal says what was cancelled |
| The package is removed while set up | sbctl and upstream keep signing the UKI and the primary loader, but nothing repairs a change that bypasses them: after the next Limine upgrade the installer hook's raw loader [C6] is refused | Boots until `limine.conf` is edited by hand: upstream keeps sealing the loader, and nothing re-seals it after an edit [C1] | Reinstall, or `remove` first | The package warns before it goes, and never blocks the removal; the documented removal order; the remove wrapper proposed for Omarchy would run `remove`; `setup` marks sbctl as explicitly installed |

## 8. The package

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the layout of the code. The package also holds the Limine hook, the two unit templates, the menu fragment for Omarchy and its documentation. It carries version floors only, capability floors and not tested versions: `limine` 11.0.0 brought the `efi_boot_entry` protocol, `sbctl` 0.18 and `limine-mkinitcpio-hook` 1.38.0 are the versions the contracts were read at, and the machine of C10 ran Limine 12.8.0 and 12.9.0. It ships no state directory and no tmpfiles declaration. Its one install scriptlet prints a warning before the package is removed from a machine that is still set up; it never fails and changes nothing.

## 9. Tests

- Hermetic suites against a fixture machine with stub tools, with a case for every failure-table row that software can simulate. The commands run as processes of their own, so errexit behaves as installed, through the tool's own prompt code, and a command that fails without a line that says why fails its case (section 6). Every stub behaviour cites the section of upstream-contracts.md that records it; anything else is marked as an assumption in the stub. The whole run takes about a minute.
- Every safety predicate has a named case that fails when the predicate is disabled.
- One suite reads the documents: every decision, contract and section cited by number exists, every link and anchor resolves, a section or form field named in quotation marks exists, and the messages that the README's troubleshooting table and the field guide's "Expected" lines quote are ones the tool prints.
- Real-tool contract suites, in a sandbox that hides the machine's own keys, firmware, settings and ESP.
  - One runs the real sbctl with keys made for the run and a fixture firmware directory: the export in the forms D9 relies on, what a write produces, `--partial` with `--append`, the owner GUID, the signature and file-list answers.
  - The other runs upstream's own Limine shell code from the installed package on fixture settings, hooks and an ESP: the configuration layers, hook order and exit statuses, the lock, the loader backup, the `limine-install` options, its fallback step with the policy that decides it, and the hooks this tool relies on by name, and one loader through the whole exchange: enrolled and signed by upstream's code and proved by this tool, rebuilt by this tool after `limine.conf` changed, and still proved after upstream's next operation over it.
  - A scheduled CI job reads the versions of sbctl, Limine and Omarchy's Limine tools every day and runs both suites when one of them or the contract code has changed, and at least once a week; a failure opens an issue instead of blocking users.
  - The watchers' `PathChanged` units on vfat are left to stage 1 of acceptance, where systemd and the ESP are the real ones.
- CI: lint, the hermetic suites, the package build, and installation, upgrade and removal in a container.
- Outside any software test: Limine's behaviour at boot, firmware writes, and sbctl's signing step inside mkinitcpio. Stages 1 to 3 and 7 of acceptance are their evidence.

## 10. Acceptance on hardware

The stages of [release-checklist.md](release-checklist.md), 0 Baseline to 7 Rebuild, run on a dedicated machine, each with a STOP condition and recorded with `tests/acceptance-record.sh`; that page owns the rows. No claim exceeds the machines recorded.
