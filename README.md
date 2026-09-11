# OmaSecBoot

**[Omarchy](https://omarchy.com) Secure Boot: sbctl signing, Limine enrollment, pacman hooks, and Windows BootNext handoff.**

OmaSecBoot provisions signing keys, signs every EFI artifact Omarchy boots, enrolls the current Limine configuration checksum into both Limine executables, backs up and replaces firmware trust under explicit confirmation, and adds a validated Windows firmware handoff for dual-boot systems. Every mutation runs as a durable transaction that can be resumed or rolled back, and every firmware instruction is printed only after a direct read-back proof.

> [!CAUTION]
> **Development status, 2026-09-07:** the source implementation, hermetic test suites, and Arch package layout are complete. No tagged release or published package exists, CI covers only the hermetic suites and a container package check, and the current code has no recorded real-machine firmware validation. Do not install this over an existing Secure Boot setup, and do not treat the hermetic tests as proof of firmware behavior. The release gates are in the [release checklist](docs/release-checklist.md).

## Why This Tool

[Omarchy Quattro](https://github.com/omacom/omarchy/releases/tag/v4.0.0) installs alongside Windows and documents `limine-scan` for adding Windows to Limine. Its boot stack is Limine with Unified Kernel Images (UKIs) and Snapper snapshot entries. That stack has Secure Boot gaps that no single upstream tool closes:

- **sbctl** creates keys and signs EFI binaries, but does not enroll the Limine configuration checksum, discover snapshot UKIs, or manage a Windows firmware handoff.
- **shim and MOK** target the GRUB and systemd-boot chains. Limine on Omarchy uses direct UEFI verification with user-owned keys.
- **Windows dual boot** under Secure Boot interacts with BitLocker and Device Encryption, so the order of operations and the preparation steps matter.

OmaSecBoot fills those gaps for this exact stack and delegates everything else to the tools Omarchy already ships.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Lifecycle](#lifecycle)
- [Setting Up Secure Boot](#setting-up-secure-boot)
- [Adopting an Existing Configuration](#adopting-an-existing-configuration)
- [Windows Dual Boot](#windows-dual-boot)
- [Day-to-Day Operation](#day-to-day-operation)
- [Commands](#commands)
- [Recovery](#recovery)
- [Undoing OmaSecBoot](#undoing-omasecboot)
- [Troubleshooting](#troubleshooting)
- [Boundaries](#boundaries)
- [How It Works](#how-it-works)
- [License](#license)
- [Credits](#credits)

<details>
<summary>Glossary</summary>

| Term | Definition |
|------|------------|
| **ESP** | EFI System Partition. The FAT partition firmware reads boot loaders from. Mounted at `/boot` on Omarchy. |
| **PK, KEK, db, dbx** | The UEFI trust hierarchy: Platform Key, Key Exchange Keys, the allowed-signature database, and the forbidden-signature database. |
| **Setup Mode** | The firmware state with no PK enrolled. OmaSecBoot supports only a PK-only delete that leaves KEK, db, and dbx unchanged. |
| **UKI** | Unified Kernel Image. One EFI file containing kernel, initramfs, and command line. Built by `mkinitcpio` through limine-mkinitcpio-hook on Omarchy. |
| **Config enrollment** | Embedding the checksum of `limine.conf` into the Limine EFI binary so Limine can verify its configuration at boot. |
| **BootNext** | A UEFI variable that selects the boot entry for the next boot only. Used by Limine's `efi_boot_entry` protocol and by `efibootmgr -n` to hand off to Windows. |
| **Lifecycle** | OmaSecBoot's durable record of whether it manages this system, separate from the firmware's Secure Boot state. |

</details>

## Requirements

- [Omarchy](https://omarchy.com) 4.x with the Limine bootloader, UKIs, and btrfs with Snapper.
- UEFI firmware that can delete only the PK from its Secure Boot menu without clearing KEK, db, and dbx. Firmware that offers only "clear all keys" is not supported.
- The ESP mounted at `/boot`.
- For dual boot: Windows Boot Manager present in the firmware boot entries, and the Windows recovery keys backed up before any firmware change.

OmaSecBoot drives three boot-artifact producers whose hook protocol it audits per version, so lifecycle activation and the package guard pin them exactly; anything else fails closed until a new OmaSecBoot release audits it. efibootmgr only needs to be new enough.

| Package | Supported version | Source |
|---|---|---|
| `limine-mkinitcpio-hook` | 1.38.0-1.1 | Omarchy Package Repository |
| `limine-snapper-sync` | 1.31.0-1.1 | Omarchy Package Repository |
| `sbctl` | 0.18-2 | Arch `extra` |
| `efibootmgr` | 18 or newer | Arch `core` |

The package also depends on bash, coreutils, util-linux, diffutils, findutils, gawk, grep, jq, OpenSSL, gum, limine, pacman, and systemd.

## Installation

`OmaSecBoot` is the product name; `omasecboot` is the command, package, and namespace.

The supported deployment is the Arch package built from `PKGBUILD`. Build it from a git clone of the commit you want to install:

```bash
git clone https://github.com/peregrinus879/omasecboot.git
cd omasecboot
make package                                  # writes omasecboot-1.0.0-1-any.pkg.tar.zst here
sudo pacman -U omasecboot-1.0.0-1-any.pkg.tar.zst
omasecboot version                            # omasecboot 1.0.0
```

`make package` needs `base-devel` and git. It packs the tracked files into the archive layout the recipe expects and runs makepkg without a dependency check, so the package can be built on any Arch machine; pacman checks the dependencies when it installs. `bash tests/package.sh` runs the same build with payload and lifecycle checks and discards it.

`make install` refuses to write to a live root; it exists only for package staging. A same-named hook in `/etc/pacman.d/hooks/` takes precedence over the packaged one, and the lifecycle refuses to activate while any hook is shadowed or targets a command other than `/usr/bin/omasecboot`; `status` reports both conditions.

## Lifecycle

OmaSecBoot keeps a durable record under `/var/lib/omasecboot` that says whether it manages this system. That record is separate from whether firmware Secure Boot is on.

| State | Meaning |
|---|---|
| `unmanaged` | No record. Existing settings need explicit adoption or a fresh setup. |
| `active` | OmaSecBoot manages the Limine settings and repairs boot artifacts after package and Limine changes. It does not mean keys are enrolled or Secure Boot is on. |
| `disabled` | Settings were restored by `unconfigure`. Package removal is permitted. |
| `transition` | A transaction is running. Other boot mutations are refused until it finishes. |
| `recovery-required` | A transaction or its rollback failed. Only `repair` and the recovery built into every command may proceed. |

Every mutating command first writes a transaction manifest and backups, then mutates, then commits the stable state last. If a command finds an interrupted transaction, it completes that recovery and returns without starting new work; run the command again afterwards.

A recovery-only mutation returns **3**, so a caller cannot mistake recovery for completion of the requested operation. `repair` itself returns 0 when recovery completes or none is required. Waiting for a busy boot lock returns **75** after the bounded wait; wait for the current operation to finish and retry. An unsafe lock path or failed proof is an error, not ordinary contention.

## Setting Up Secure Boot

Run these steps in order. Each command prints the next instruction only after it has proved the current state by direct read-back.

1. **Prepare Windows first** if Windows is installed: `sudo omasecboot windows preflight`. See [Windows Dual Boot](#windows-dual-boot). Nothing below prints a firmware instruction until this gate passes.
2. **Set up**: `sudo omasecboot setup`. On a machine without local keys this backs up the raw PK, KEK, db, dbx, and mode variables, creates the sbctl keys, builds the planned trust set (`sbctl enroll-keys -m -f --export esl`), compares it entry by entry with the current firmware trust, shows the current and planned PK fingerprints, and asks you to confirm the PK replacement, the firmware's PK-only delete capability, and the review of retained trust entries and recovery preparation. It then repairs and signs every boot artifact and prints exactly one firmware instruction: delete only the PK.
3. **In firmware settings**, delete only the PK to enter Setup Mode. Do not clear KEK, db, or dbx. Reboot into Linux.
4. **Enroll**: `sudo omasecboot enroll`. This verifies that KEK, db, and dbx are unchanged from the backup, proves every boot artifact again, writes db, then KEK, then PK, reads each back, proves the artifacts once more, and prints the enablement instruction.
5. **In firmware settings**, enable Secure Boot. Boot Linux.
6. **Verify**: `sudo omasecboot status` should report Secure Boot enabled, the lifecycle `active`, both Limine executables carrying the current configuration checksum, and every artifact signed and tracked.
7. **Windows**: boot Windows directly once, verify its Secure Boot and encryption state, then set up the handoff as described below.

Between `setup` and `enroll`, do not boot Windows or update the firmware: either can change db or dbx, and enrollment refuses a set that differs from the backup. After enrollment, Microsoft's certificate servicing through Windows Update can still add to db and dbx; the OmaSecBoot-signed Linux boot path keeps working, and `setup` then observes state 3, refuses at the instruction boundary, and names the difference.

`setup` is idempotent and classifies the machine into one of five states each time it runs:

| State | Observation | What `setup` does |
|---|---|---|
| 1 | No local keys | Backup, key creation, plan comparison, artifact proof, PK-delete instruction |
| 2 | Keys exist, firmware in Setup Mode, plan not enrolled | Tells you to run `enroll` |
| 3 | Keys exist, firmware in user mode, plan not enrolled | Backup, plan comparison, artifact proof, PK-delete instruction |
| 4 | Plan enrolled, Secure Boot off | Artifact proof, enablement instruction |
| 5 | Plan enrolled, Secure Boot on | Artifact repair and verification |

Contradictory or indeterminate observations fail closed with a message instead of being assigned to a state. Plan comparison accepts a firmware that holds none of the planned trust set, and one that already holds all of it, which is observed as state 4 or 5 and receives no firmware write; a firmware that holds only part of it is refused with `The firmware already holds part of the planned trust set` before any plan is recorded.

What blocks setup before any firmware instruction:

- A current KEK or db entry that the plan would drop, an unknown organizational certificate, or an unsupported signature-list type. OmaSecBoot never preserves trust by subject name and never repairs with `--append`.
- A non-zero AuditMode or DeployedMode value, one of those variables without the other, or either appearing or disappearing after the backup was taken. Firmware that predates UEFI 2.5 and exposes neither variable is accepted, and their absence is recorded in the backup.
- Firmware already in Setup Mode without a validated backup from this tool.
- A Windows preflight that did not pass.

## Adopting an Existing Configuration

If Limine is already configured with `ENABLE_VERIFICATION`, `ENABLE_ENROLL_LIMINE_CONFIG`, or the enrollment commands in `/etc/default/limine`, the lifecycle is `unmanaged` and `setup` refuses to guess the original values. Run `sudo omasecboot adopt` instead. It shows the current managed settings and asks for the original value of each one (`yes`, `no`, or `unset` for the two switches; `present` or `absent` for the two command tokens). The originals can also be passed as `--verification-original`, `--enrollment-original`, `--before-save-original`, and `--after-save-original`.

Adoption refuses `unknown` for any value, because `unconfigure` must always be able to restore them. Adoption also requires the supported package versions and all five installed hooks, and it does not claim anything about firmware enrollment; it only activates guarded repair for the recorded configuration.

## Windows Dual Boot

### Preflight

`sudo omasecboot windows preflight` is a read-only preparation gate. It inspects three independent signals: a Windows entry in the firmware boot options, a BitLocker filesystem signature on any internal partition, and a Microsoft boot manager on an internal GPT ESP. It never mounts or modifies NTFS. It may mount an internal FAT ESP read-only under a private path and reads only the boot manager's header to confirm it is present.

Exit status:

| Status | Meaning |
|---|---|
| 0 | Either all three signals are absent (a bounded observation, not proof that Windows is absent), or Windows was detected and you confirmed that the encryption state was checked and every recovery key was backed up |
| 1 | You declined a confirmation |
| 2 | A technical uncertainty: a missing tool, an ambiguous probe, an external ESP, or an unsafe mount. There is no override; resolve the cause and rerun |

If Windows uses BitLocker or Device Encryption:

1. Back up and verify the recovery key before starting. Find it at [aka.ms/myrecoverykey](https://aka.ms/myrecoverykey) or in its existing USB, print, Active Directory, or Microsoft Entra ID backup.
2. On Windows Home, use Microsoft's documented [Device Encryption Settings](https://support.microsoft.com/en-us/windows/device-encryption-in-windows-cf7e2b6f-3e70-4882-9532-18633605b7df) to turn Device Encryption off and wait for decryption to finish. Microsoft documents no Home suspension workflow, so OmaSecBoot does not offer one.
3. On Pro, Enterprise, or Education, inspect protection in an administrator PowerShell and use Microsoft's documented BitLocker suspension when appropriate. Managed devices require administrator approval.
4. After enrollment, boot Windows directly, verify Secure Boot and protection state, then resume protection if it was suspended.
5. Keep the recovery key available. Secure Boot changes can trigger recovery; a firmware handoff does not guarantee a quiet boot or stable measurements.

A present boot manager is a signal that Windows is installed. It is not proof that the firmware db and dbx accept that boot manager.

### Handoff

`sudo omasecboot windows setup` records the Windows target and writes a managed Limine entry that uses `protocol: efi_boot_entry`. Selecting Windows in the Limine menu then sets the firmware BootNext variable and reboots, so firmware loads `bootmgfw.efi` directly instead of Limine chainloading it. `sudo omasecboot windows bootnext` requests the same one-boot handoff from Linux without the menu. The menu reboots only when that command exits 0; when it first had to complete lifecycle recovery it exits 3 without a request.

The target is validated structurally, not by matching text: the command parses `BootOrder` and each boot option's device path, requires the exact `\EFI\Microsoft\Boot\bootmgfw.efi` file node, maps the partition node to exactly one FAT ESP by PARTUUID and geometry, reads the loader's header without writing, and requires one active Windows target whose label resolves identically under Limine's rules. Duplicate labels, multiple Windows installations, entries outside `BootOrder`, localized labels, and ambiguous mounts fail closed. OmaSecBoot never creates or relabels firmware entries. If a recorded target stops resolving, `sudo omasecboot windows suppress` removes the managed Limine block while keeping the opt-in.

Quattro's own `limine-scan` writes a `protocol: efi` chainload entry for Windows. `status` reports such entries but never removes them.

The tracked `omarchy/omarchy-menu.jsonc` file is the reference fragment for a Quattro menu entry, "Reboot to Windows", owned by the Omarchy integration. If the reboot is cancelled after BootNext is armed, firmware keeps the one-boot request.

## Day-to-Day Operation

Once the lifecycle is `active`, package and Limine hooks keep the boot artifacts signed and the configuration checksum enrolled:

| Hook | When | Purpose |
|---|---|---|
| `00-omasecboot-removal-guard.hook` | Before removing a recovery dependency or `omasecboot` | Refuses unless the lifecycle is verified `disabled` or pristine |
| `00-omasecboot-transition-guard.hook` | Before a transaction that touches boot paths or producer packages | Refuses during `transition` or `recovery-required`; refuses changes to the three pinned producer packages while `active`; otherwise records the producer lease |
| `zz-sbctl.hook` (from sbctl) | After the transaction | Re-signs files sbctl already tracks |
| `zzz-omasecboot.hook` | After `zz-sbctl.hook` | Repairs and re-enrolls Limine, signs and tracks new artifacts, and proves the result |
| `000-omasecboot-guard` | Limine pre-hook | Validates ownership and locking before a Limine or snapshot mutation |
| `zzz-omasecboot-sign` | Limine post-hook | Completes the matching Limine, snapshot, or restore repair |

Kernel, Limine, and snapshot updates therefore need no manual action. Two situations do:

- **A supported package update.** While the lifecycle is `active`, a pacman transaction that changes `limine-mkinitcpio-hook`, `limine-snapper-sync`, or `sbctl` is refused with `disable lifecycle before changing pinned producers`. Wait for an OmaSecBoot release that supports the new version, install it, and if the refusal persists, disable Secure Boot in firmware, run `sudo omasecboot unconfigure`, update, and run `setup` again. This is a known cost of the exact-version model.
- **`limine-install` refusals.** `limine-install` is not a recognized producer, so while the lifecycle is `active` the Limine pre-hook refuses it with exit status 100 when `limine-update`, `omarchy refresh limine`, or the `limine` package's install hook runs it; the rest of those commands continues and the package repair rebuilds the primary loader from the new package source. That message is expected noise, not a failure.
- **Template resets.** `omarchy refresh limine`, config reinstalls, and factory resets can replace `limine.conf` and drop the Windows entry. Run `sudo omasecboot sign` afterwards; it re-enrolls the checksum, and `status` reports a missing Windows block.

Updating `omasecboot` itself is not a boot mutation and is allowed in any lifecycle state; during `recovery-required` it is the way to receive a recovery fix.

## Commands

All mutating commands require root, refuse unknown arguments, and complete any pending recovery before doing new work.

Use `omasecboot <command> --help` or `-h`, including `omasecboot windows <command> --help`, without root or operational dependencies. The global `--quiet` option precedes the command and suppresses optional progress while preserving warnings and required instructions. Diagnostics go to stderr. Redirected output is plain text; `NO_COLOR` and a dumb terminal also disable color. Interactive confirmation needs a terminal attached to stdin and stderr; there is no noninteractive confirmation bypass.

| Command | Purpose |
|---|---|
| `setup` | Prepare or reuse a validated plan, confirm PK fingerprints, prove artifacts, and print the next firmware instruction |
| `enroll` | Write the confirmed db, KEK, and PK plan from Setup Mode with per-write read-back |
| `adopt [--...-original VALUE]` | Record an existing configuration as `active` with its original values |
| `status` | Show lifecycle, firmware, hooks, managed Limine checksums, path-hash readiness, Windows targets, and EFI tracking/signatures. Run with sudo for protected observations; exit 0 means verification passed, and exit 1 means failed or incomplete |
| `sign` | Repair `/etc/default/limine`, re-enroll the checksum into both Limine executables, clean stale tracking, sign and track every artifact, and prove the result. Never rebuilds UKIs or runs `limine-update` |
| `cleanup` | Remove stale sbctl tracking entries |
| `windows available` | Exit 0 silently if the durable Windows opt-in exists and still matches one valid firmware target; no root required |
| `windows preflight` | The read-only encryption preparation gate |
| `windows setup` | Record the validated target and write the managed Limine entry |
| `windows suppress` | Remove the managed Limine entry, keep the opt-in |
| `windows bootnext` | Request one firmware handoff to Windows; as with other mutations, exit 3 means recovery ran and the request was not made |
| `unconfigure` | Restore recorded settings and stock boot state, commit `disabled` |
| `repair` | Resume the interrupted operation recorded in the lifecycle |
| `version` | Print `omasecboot 1.0.0` |
| `help` | List commands |

## Recovery

An interrupted or failed mutation leaves the lifecycle in `transition` (the owning process may still be running) or `recovery-required` (it failed, its owner is gone, or its rollback failed). `status` reports which, with the transaction ID. Every mutating command, and `sudo omasecboot repair` on its own, resumes the recovery that the immutable incident record selects; the command you typed does not choose it.

| Incident root | Recovery | What it does |
|---|---|---|
| Package, Limine, snapshot, or restore producer | Producer recovery | Reruns the interrupted producer's own build (`limine-mkinitcpio` or `limine-snapper-sync`), repairs and proves artifacts, completes or fails the lease |
| Firmware enrollment | Firmware recovery | Resolves the pending write by direct read-back, proves artifacts, then continues only the remaining db, KEK, or PK writes |
| Windows BootNext | Windows recovery | Restores the recorded prior BootNext value, or records `consumed-unknown` when the variable is absent after a later boot |
| Software mutation before its preservation point | Software rollback | Restores backed-up files and settings |
| Unconfiguration after its preservation point | Unconfigure recovery | Resumes the idempotent restoration phases to a proved `disabled` state |

Bounds and outcomes you may see:

- Each incident allows 32 recovery attempts. After that, automatic recovery stops and the state stays `recovery-required` for expert review.
- Firmware recovery allows six write attempts per incident and two per hierarchy. A firmware state outside the expected before and after values is recorded as failed. One narrowly defined historical outcome can be reconciled: a terminal PK command with exit status 0 whose readback was recorded `failed`, preceded by proved db and KEK writes. Fresh readback must prove the complete planned trust set, unchanged dbx, and the supported clear firmware modes, including SetupMode 0 and Secure Boot 0. Recovery records that resolution in a new attempt, performs no further firmware write, and preserves the original sealed evidence. Other failed writes remain refused.
- Windows recovery classifies a BootNext value that is neither the recorded prior nor the recorded target as unrelated state and leaves it alone.
- Uncertain read-back keeps evidence pending rather than resolving it.

Do not edit files under `/var/lib/omasecboot`, run `sbctl reset`, clear firmware keys, or hand-edit `limine.conf` to escape a recovery state. Record the `status` output and seek review. Keep Secure Boot disabled in firmware if the system will not boot.

If the PK command succeeded but SetupMode still read 1, keep Secure Boot off, reboot normally, and run `sudo omasecboot repair`. A changed mode alone does not authorize completion: repair revalidates the exact trust set and boot artifacts. Only after recovery succeeds should `sudo omasecboot setup` be used to obtain a freshly proved enablement instruction.

## Undoing OmaSecBoot

These are four different operations. None of them is a factory reset.

| Operation | Command | Effect |
|---|---|---|
| Software unconfiguration | `sudo omasecboot unconfigure` | Requires Secure Boot off. Restores the recorded Limine settings by three-way merge (a conflicting manual edit stops it), removes the managed Windows entry, removes owned sbctl tracking, resets config enrollment, rebuilds stock Limine executables from the package, proves them, and commits `disabled`. Keys and firmware trust are untouched. |
| Package removal | `sudo pacman -R omasecboot` | Allowed only from verified `disabled` or pristine state. Removes the command, library, and hooks. Preserves `/var/lib/omasecboot` (lifecycle history, transactions, firmware backups, Windows opt-in, repair lock) and `/var/lib/sbctl`. Does not remove sbctl. |
| PK reset | `sbctl reset` (not run by OmaSecBoot) | Removes the PK and enters Setup Mode. KEK, db, and dbx stay as they are. |
| Factory restoration | Firmware vendor procedure | Restores the vendor trust set. The raw pre-change backup under `/var/lib/omasecboot` is what the firmware had before OmaSecBoot, which is not necessarily the factory set. |

## Troubleshooting

| Message or symptom | Meaning | Action |
|---|---|---|
| `Lifecycle: unmanaged (explicit setup or adoption required)` | No lifecycle record | Run `setup`, or `adopt` if Limine was already configured |
| `Lifecycle activation requires the exact supported producer packages` or `Lifecycle activation requires efibootmgr 18 or newer` | One of the three pinned producer packages is not at its supported version, or efibootmgr is older than 18 | Update or downgrade from disabled or pristine state; see Requirements |
| `Limine path hashes are stale; Limine refuses these entries once Secure Boot is on` | A present hash is malformed, unresolved, or does not match its file | For the current OS entry, run `sudo limine-mkinitcpio` and verify again. A normal `limine-snapper-sync` does not migrate historical hashes. Preserve snapshot data and report the affected entries; historical migration remains release-blocking work |
| `Limine requires BLAKE2B hashes for these non-EFI resources under Secure Boot` | A resource lacks a hash required by its loading protocol | Restore the supported UKI configuration or regenerate the resource through its owning producer with the required hash. Only EFI chainloading waives a missing hash |
| `Limine fallback loader is missing at /boot/EFI/BOOT/BOOTX64.EFI while ENABLE_LIMINE_FALLBACK is yes` (or `unset`) | Limine's configuration deploys the fallback loader but none is on the ESP | Run Omarchy's `limine-update` to deploy it and rerun; a configuration that sets `ENABLE_LIMINE_FALLBACK=no` in `/etc/default/limine` needs no fallback, and `status` then reports the primary loader alone |
| `sign` or `status` reports that `/EFI/BOOT/BOOTX64.EFI` carries no Limine config checksum | On a shared ESP, Windows repair or a Windows installer rewrote the fallback loader with its own copy | Rerun Omarchy's `limine-update` to restore Limine's fallback copy, then `sudo omasecboot sign` |
| `Lifecycle activation requires the current installed ... hook` | A hook is missing, altered, or targets a command other than `/usr/bin/omasecboot` | Reinstall the package; remove any `/usr/local` copy |
| `... blocked while full snapshot restore is running` | The `limine-snapper-restore` marker under `/run/lock` exists: a full restore is running, or one crashed and left it behind | Wait for the restore to finish; a reboot clears a stale marker. After confirming no restore is running you may remove `/run/lock/limine-snapper-restore.lock` yourself |
| `Boot-mutating package transaction blocked: ... disable lifecycle before changing pinned producers` | A pacman transaction would change a supported package while active | See Day-to-Day Operation |
| `Boot-mutating package transaction blocked: lifecycle is transition ...` | Another OmaSecBoot transaction is running or was interrupted | Wait, then `sudo omasecboot repair` |
| `Boot state is busy` (exit 75) | Another operation holds a required boot lock | Wait for that operation to finish, then retry. Do not delete the lock file or infer that recovery failed |
| `Package removal requires verified disabled or pristine lifecycle state` | The removal guard refused | Run `unconfigure` first |
| `Lifecycle: recovery-required (...)` | A mutation or rollback failed | `sudo omasecboot repair`; do not intervene manually |
| `Enrollment requires validated Setup Mode; current setup state is N` | `enroll` was run outside state 2 | Follow the instruction `setup` prints for that state |
| `The firmware already holds part of the planned trust set` | Some but not all of PK, KEK, and db already equal the planned set, so no supported enrollment sequence exists | If the message came from plan comparison during `setup` and no plan is recorded yet, restore the factory Secure Boot keys in firmware settings and run `setup` again. If a plan is already recorded, treat it as the invalid-plan row below |
| `The current Secure Boot enrollment plan is invalid` or `... failed validation; setup will not replace it` | The recorded backup or plan no longer validates; setup never replaces recorded evidence and no supported reset exists yet | Keep Secure Boot off, leave `/var/lib/omasecboot` untouched, and report the message with `sudo omasecboot status` output |
| `windows preflight` exits 2 | Technical uncertainty | Read the printed guidance, fix the cause, rerun; there is no override |
| `Setup cancelled ...`, `Enrollment cancelled ...`, or `Unconfigure cancelled ...` | You answered no, or pressed Esc or Ctrl-C, at a confirmation; the message says what remains recorded | Run the command again and confirm with Enter or `y` |
| `Local sbctl key directories exist without keys: ...` | `/var/lib/sbctl/keys` holds `PK`, `KEK`, or `db` directories but none of sbctl's key files, as an interrupted key creation can leave them; sbctl would report them as created keys and write nothing | Move the named directories away, or remove them if they hold nothing you need, then run `setup` again |
| `Operation ... preflight failed; no transaction was started` | A read-only check refused the command before any change; the lines above it name the cause when the check has one | Fix the named cause and rerun |
| `Firmware and plan observation does not match a supported setup state`, `The state N instruction boundary could not be proved`, or `... did not complete`, followed by `Observed:` lines | A read-only predicate refused, or a transaction failed. The lines show modes, local keys, lifecycle, and trust comparisons. Exact trust entries alone do not establish completion; mode observations, plan validation, artifacts, and Windows preparation must also pass | Follow the lifecycle line first. For a terminal successful PK command with delayed SetupMode observation, use the guarded recovery procedure above. Changed KEK, db, or dbx after a PK-only delete is unsupported; preserve the evidence and report it. Legitimate post-enrollment servicing changes need the plan-refresh design in the ledger |
| System will not boot with Secure Boot on | Artifact or trust mismatch | Disable Secure Boot in firmware, boot Linux, run `sudo omasecboot status`, and keep Secure Boot off until the proof passes |
| A snapshot older than `setup` was restored with `limine-snapper-restore` | The root subvolume, including OmaSecBoot, its hooks, the sbctl keys, and `/var/lib/omasecboot`, went back to before setup while the ESP and firmware keep the signed state; the system boots, but the next kernel or Limine update produces unsigned artifacts | Keep Secure Boot off until the proof passes: disable Secure Boot in firmware, restore the factory keys there, reinstall the package, and run `setup` again. A snapshot taken after setup carries the records it held at that time |

Read-only helpers: `sbctl status`, `sbctl list-files`, `sbctl verify`, `efibootmgr -v`, and `findmnt`. They report state; they do not authorize a firmware change.

## Boundaries

- Lifecycle `active` means OmaSecBoot manages this system. It does not mean keys are enrolled or Secure Boot is on.
- BootNext is a one-boot request. It does not prove Windows booted, keep BitLocker quiet, or preserve PCR7 measurements. Secure Boot changes can trigger BitLocker recovery; they do not always do so.
- A negative Windows preflight is a bounded observation, not firmware clearance.
- A full snapshot restore replaces the root subvolume. A snapshot older than `setup` takes OmaSecBoot, its keys, and its records with it while the ESP and firmware keep the signed state; see Troubleshooting.
- The raw pre-change firmware backup is not a factory key set. OmaSecBoot has no dbx writer and does not promise OEM PK, dbx, or factory-state restoration.
- After the OEM PK is replaced, Microsoft's Secure Boot certificate servicing is the user's responsibility.
- Hermetic tests prove the software contract, not firmware behavior. See the [release checklist](docs/release-checklist.md) for the hardware evidence a release requires.
- The Omarchy installer ISO is not Secure Boot bootable; OmaSecBoot applies to installed systems only.
- Eligible Windows 11 devices may enable Device Encryption after qualifying; this is not universal. Intune policy can mark a device noncompliant; this does not imply universal loss of access.

## How It Works

### Proof sequence

`setup` and `sign` repair the managed `/etc/default/limine` settings (`ENABLE_VERIFICATION=no`, `ENABLE_ENROLL_LIMINE_CONFIG=yes`), enroll the current `/boot/limine.conf` checksum into the managed loaders, verify that checksum directly, clean stale tracking, and sign and track discovered non-Microsoft EFI artifacts. Activation also invokes `limine-mkinitcpio` and a snapshot sync when hashed paths are present; historical snapshot migration remains limited as described below.

The primary `/EFI/limine/limine_x64.efi` is always managed. The fallback `/EFI/BOOT/BOOTX64.EFI` is also managed when it exists or the effective `ENABLE_LIMINE_FALLBACK` policy is `yes` or unset. Each target is rebuilt from the unsigned package executable in a staging file, enrolled, signed, verified, and synced before atomic replacement. Higher-priority `limine.conf` candidates on the ESP that could shadow `/boot/limine.conf` are rejected.

Snapshot UKIs created by limine-snapper-sync end in `.efi_sha256_<hash>` or a similar suffix; that is part of the filename, not a Limine path hash. Limine path hashes are never written by this tool: Limine only waives a missing hash for `protocol: efi`, and checks any hash that is present, so setup regenerates hashed entries once and `status` reports a hash that no longer matches its file.

**Current snapshot limitation:** the snapshot producer retains historical hashes and checks the content hash embedded in history filenames. In-place signing of an unsigned history UKI breaks that identity, and the activation-time sync does not repair it. Existing unsigned snapshot history therefore needs a producer-compatible migration before this workflow is release-ready. A warning or deletion of the underlying Btrfs snapshots is not a migration.

Arch's sbctl 0.18 ignores `--save` for an already-signed file, so a copied snapshot UKI can be signed but untracked. OmaSecBoot writes the tracking entry directly in that case, which is why `sign` may report a snapshot UKI as `registered`.

### Locking and ownership

Limine, limine-entry-tool, and limine-snapper-sync share `/run/lock/boot-partition.lock`. OmaSecBoot validates an inherited descriptor's identity and locks it, or acquires the lock itself, before any boot mutation, and holds its own repair lock under `/var/lib/omasecboot`. Hooks decide whether a mutation is theirs by the transaction token, boot ID, owner process identity, ancestry, and the durable manifest, never by an environment variable. A full snapshot restore is admitted only in stable state, because upstream runs it without a parent lock.

### Firmware

Before any Setup Mode instruction, the raw PK, KEK, db, and dbx payloads, their attributes and hashes, absence records, the SetupMode and SecureBoot values, the AuditMode and DeployedMode values or their absence, and the DMI identity fields (product UUID plus the vendor, product, board, and BIOS identifiers, including the board serial) are saved root-only. The planned set is compared entry by entry; every current KEK and db entry must appear byte-for-byte in the plan. Only a single X.509 OEM PK may be replaced, after fingerprint confirmation. Enrollment writes db, KEK, and PK in that order, records each attempt before invoking sbctl, and treats command success as insufficient: the read-back governs.

### Contributing

`AGENTS.md` is the contributor contract: module ownership, invariants, terminology, and verification. Sources and compatibility findings are in [docs/maintenance.md](docs/maintenance.md).

### Design philosophy

Handle the parts of Secure Boot that Omarchy does not automate for this dual-boot flow: one-time key creation and enrollment, config checksum enrollment and verification in both Limine executables, signing of new and snapshot artifacts, and the Windows handoff. Delegate everything else: re-signing of tracked files to `zz-sbctl.hook`, UKI building to `mkinitcpio`, kernel entries to `limine-entry-tool`, snapshot entries to `limine-snapper-sync`. Automate only what nothing else automates.

## License

[MIT](LICENSE)

## Credits

Created by [peregrinus879](https://github.com/peregrinus879).
