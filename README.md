# OmaSecBoot

**[Omarchy](https://omarchy.com) Secure Boot: sbctl signing, Limine enrollment, pacman hook, and Windows BootNext handoff.**

The target release provisions signing keys, proves Limine and EFI artifacts, enrolls firmware trust, and adds a validated Windows BootNext handoff. The current implementation provides the durable lifecycle boundary, tested artifact proof, bounded producer, firmware, Windows, software, and unconfiguration recovery, dormant mutations with immutable evidence and direct readback, validated Windows firmware target identity, a read-only Windows encryption preflight, raw firmware backup, strict trust planning, five-state observation, enrollment failure proof, and gated command integration. Public boot, firmware, signing, cleanup, unconfiguration, and Windows mutations plus active producer automation remain blocked until the T-6.8 activation unit lands.

> [!CAUTION]
> **Development status, 2026-09-04:** lifecycle manifests, file rollback and post-write preservation, stale-owner handling, validated hook ownership, shared-lock enforcement, producer quiescing, transition guards, explicit adoption, bounded package/Limine/snapshot/restore, firmware, Windows BootNext, software, and unconfiguration recovery, immutable expected-EFI proof, dormant mutations, validated Windows targeting and preflight, raw firmware backup, strict trust planning, enrollment proof, and public-command routing are implemented. Production activation, producer activation, packaging, and uninstall remain release gates. Public adoption, boot, firmware, signing, cleanup, unconfiguration, recovery, and Windows mutation commands still fail closed. Do not use this branch to enter Setup Mode, enroll or reset keys, configure Windows, unconfigure managed state, or remove an existing Secure Boot setup. The remaining release gates are defined in the [implementation contract](docs/implementation-contract.md).

## Why This Tool

[Omarchy Quattro](https://github.com/omacom/omarchy/releases/tag/v4.0.0) supports installation into free space alongside Windows, and its [dual-boot guide](https://omarchy.org/manual/dual-boot-install/) documents `limine-scan` for adding Windows to Limine. The current scanner creates a generic `protocol: efi` chainload entry. OmaSecBoot builds on that native dual-boot foundation with a firmware BootNext path designed for Secure Boot and BitLocker-sensitive systems.

Omarchy uses Limine with Unified Kernel Images (UKIs) and Snapper snapshots. That stack still has Secure Boot lifecycle gaps:

- **sbctl** manages keys and signs EFI binaries, but does not handle Limine config enrollment, snapshot UKI discovery, or durable Windows BootNext entries.
- **shim/MOK** is designed for the GRUB and systemd-boot chains. Limine uses direct UEFI Secure Boot verification with custom keys enrolled via sbctl.
- **systemd-boot** is not Omarchy's bootloader. This tool is specific to the Limine + UKI + Snapper stack that Omarchy ships.

The target release is intended to fill those gaps with verified Limine enrollment, snapshot UKI discovery, a fail-closed Windows firmware handoff, durable recovery, and guarded package and Limine repair.

## Table of Contents

- [Why This Tool](#why-this-tool)
- [Development Status](#development-status)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Planned Release Workflow](#planned-release-workflow)
- [Commands](#commands)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)
- [Recovery / Rollback](#recovery--rollback)
- [Design Philosophy](#design-philosophy)
- [License](#license)
- [Credits](#credits)

<details>
<summary>Glossary</summary>

| Term | Definition |
|------|------------|
| **ESP** | EFI System Partition. FAT32 partition used by UEFI firmware to find boot loaders. Mounted at `/boot` on Omarchy. |
| **Setup Mode** | UEFI firmware state with no enrolled PK. OmaSecBoot v1 supports only a separately confirmed firmware-local PK deletion that leaves KEK, db, and dbx unchanged. |
| **UKI** | Unified Kernel Image. Single EFI file containing kernel, initramfs, and command line. Built by `mkinitcpio` on Omarchy. |
| **BootNext** | UEFI firmware variable that overrides the boot order for one boot only. Used by `efi_boot_entry` and `efibootmgr -n` to boot Windows directly from firmware. |
| **Config enrollment** | Embedding `limine.conf`'s checksum into the Limine EFI binary so it can verify config integrity at boot. |
| **Signing** | Attaching a cryptographic signature to an EFI binary so UEFI firmware can verify it has not been tampered with. |

</details>

## Development Status

The package-first release uses five durable lifecycle states: `unmanaged`, `disabled`, `active`, `transition`, and `recovery-required`. Root-owned manifests and backups precede mutation; stable state is committed last. Consolidated recovery selects only producer, firmware, Windows BootNext, supported software rollback, or preserved unconfiguration from immutable incident evidence. Producer completion requires schema-2 proof with immutable expected-EFI obligations. Firmware recovery follows hash-bound setup lineage, inherits one cumulative write ledger, and completes only after direct F0-F3 and EFI proof. Windows recovery restores only the recorded prior BootNext state or classifies later-boot absence as `consumed-unknown`. Unconfiguration restores owned state, executes intent-bound Limine tool inodes, and commits `disabled` only after direct proof. Command handlers route through that registry and return after recovery, but the production capability remains closed until T-6.8 activation.

The consolidated registry handles its supported producer, firmware, Windows, software, and unconfiguration boundaries, but every public mutation and firmware instruction remains closed until lifecycle activation. Firmware factory restoration and package removal remain separate unfinished paths. Until those gates and their tests land, this README is a development reference rather than an operational setup guide.

## Prerequisites

- **[Omarchy](https://omarchy.com)** with Limine bootloader, UKI, and btrfs/Snapper
- [sbctl](https://github.com/Foxboron/sbctl) - Secure Boot key manager
- [jq](https://jqlang.github.io/jq/) - JSON parser
- [OpenSSL](https://www.openssl.org/) - strict X.509 DER and local key-pair validation
- [gum](https://github.com/charmbracelet/gum) - interactive adoption and Windows preflight prompts
- [efibootmgr](https://github.com/rhboot/efibootmgr) and util-linux - firmware, block-device, filesystem, lock, mount, and privilege-drop inspection
- [sbsigntools](https://git.kernel.org/pub/scm/linux/kernel/git/jejb/sbsigntools.git/) - advisory Windows boot-manager signer metadata
- UEFI firmware with Secure Boot support
- EFI System Partition mounted at `/boot`
- For dual-boot: Windows Boot Manager present in the firmware boot entries

```bash
sudo pacman -S --needed sbctl jq openssl gum efibootmgr sbsigntools util-linux
```

### Windows Preflight

`sudo omasecboot windows preflight` is the implemented read-only preparation gate. It independently inspects Windows firmware options, direct BitLocker filesystem signatures, and Microsoft boot-manager files on internal GPT ESPs. It never mounts a Windows volume. It may temporarily mount an internal FAT ESP read-only under a private runtime path, request `O_NOATIME` while copying the boot manager, and inspect the copy as the unprivileged `nobody` identity.

A complete three-detector negative returns success only as a bounded observation; it is not proof that Windows is absent and is not firmware clearance. Any positive or unknown signal requires confirmation that the Windows encryption state was checked and every available recovery key was backed up. A user decline returns 1. Missing tools, ambiguous probes, external ESPs, unsafe mounts, or unknown signer metadata print the applicable preparation guidance and return 2 without an override. Recognized signer names are embedded metadata only, not proof of firmware db/dbx acceptance or bootability.

These preparations remain required before any future firmware mutation. Do not change Windows solely for the current development branch.

If Windows uses BitLocker or Device Encryption:

1. **Back up and verify the recovery key** before starting. Find it at [aka.ms/myrecoverykey](https://aka.ms/myrecoverykey) or in its existing USB, print, Active Directory, or Microsoft Entra ID backup.
2. On Windows Home, use Microsoft's documented [Device Encryption Settings](https://support.microsoft.com/en-us/windows/device-encryption-in-windows-cf7e2b6f-3e70-4882-9532-18633605b7df) to turn Device Encryption off and wait for decryption to finish. Microsoft does not document Home suspension, so OmaSecBoot must not improvise one.
3. On Pro, Enterprise, or Education, inspect protection in an administrator PowerShell and use Microsoft's documented BitLocker suspension workflow when appropriate. Managed-device users must obtain administrator approval.
4. Boot Windows directly after enrollment, verify Secure Boot and protection state, then resume protection if it was suspended.
5. Keep the recovery key available. Secure Boot changes can trigger recovery; BootNext and direct firmware handoff do not guarantee a quiet boot or stable PCR measurements.

OmaSecBoot does not mount or modify NTFS and does not diagnose Windows hibernation from a failed Linux mount.

## Installation

`OmaSecBoot` is the product name; `omasecboot` is the command, repository slug, and machine-facing namespace.

There is no supported installation from the current branch. Do not run `make install`: the guards are intentionally fail-closed and consolidated recovery is not yet available.

For source review only:

```bash
git clone https://github.com/peregrinus879/omasecboot.git
cd omasecboot
```

The first supported installation will be the tagged package from the Omarchy Package Repository, installed through the planned Omarchy setup wrapper after all read-only prechecks pass.

## Planned Release Workflow

The audited workflow is not publicly available. Its backup, planning, classification, and enrollment-proof machinery remains dormant behind the interrupted-recovery gate:

1. Classify durable lifecycle state and require explicit adoption of an existing unrecorded configuration.
2. Complete Windows edition, recovery-key, management, firmware inventory, and raw PK/KEK/db/dbx backup gates before printing any Setup Mode instruction.
3. Provision keys and boot state in a durable transaction, enroll and directly verify the current Limine config checksum in both bootable executables, sign last, and verify signatures plus sbctl tracking.
4. Enter Setup Mode only after the planned trust set has been compared with the recorded firmware trust; enroll and compare the resulting PK, KEK, db, and dbx state.
5. Enable Secure Boot only after the final read-only proof passes. Verify Linux directly, then request one direct Windows firmware handoff and complete Windows-side Secure Boot and protection checks.
6. Use guarded repair for later package, Limine, and snapshot mutations. A failed rollback enters `recovery-required` and blocks other mutation producers.

## Commands

The current implementation exposes `version`, read-only status, and Windows discovery and encryption preflight. Mutation handlers are integrated with operation-selected recovery but fail closed until T-6.8 activation; uninstall remains unavailable until packaging lands.

### `setup`

Integrated behind the closed production gate. The handler prepares or finds a validated plan, confirms exact PK fingerprints, repairs and proves EFI artifacts, and revalidates every instruction boundary. No firmware instruction is currently reachable.

### `enroll`

Integrated behind the closed production gate. The dormant path binds raw PK/KEK/db/dbx backup, the confirmed plan, each firmware-write attempt, and direct readback.

### `adopt`

Integrated behind the closed production gate. The transaction records an existing untracked configuration as an `active` lifecycle after displaying managed Limine settings and collecting confirmed original values or `unknown`. It revalidates the observations under the shared boot lock and lifecycle lock before committing. Adoption does not claim firmware enrollment or activate producer repair.

### `windows`

Provides explicit Windows firmware handoff operations:

- `windows available` silently parses BootOrder and raw EFI device-path nodes without root. It requires one active, structurally unambiguous Windows target and Limine-equivalent label resolution, but does not inspect the block-device mapping or loader file.
- `windows preflight` requires root and runs the read-only three-signal encryption preparation gate. It prints edition-specific Home decryption or Pro/Enterprise/Education suspension and resume guidance, requires administrator approval for managed devices, and fails closed on technical uncertainty.
- `windows setup`, `windows suppress`, and `windows bootnext` are integrated behind the closed production gate.

The dormant setup transaction parses BootOrder and raw UEFI device-path nodes, maps the GPT HD node by PARTUUID and geometry to one FAT ESP, validates the exact loader read-only, persists strict target identity, and composes the managed Limine block with artifact repair in one lifecycle transaction. Standard HD short-form paths rely on point-in-time uniqueness across the current Linux block inventory, and every dormant write revalidates that mapping. A reusable ESP mount must be unique, identity-matched, free of same-device subroot aliases, and reached through a controlled path. One controlled root mount may be reused without writing even when writable; the descriptor-bound loader read applies `O_NOATIME` and fails closed if that flag cannot be set. An uncontrolled read-only root mount is not read directly, and the mapped ESP is instead mounted `ro,noatime` under the owned runtime path. Uncontrolled writable, multiple, and subroot mounts fail closed. The opened loader descriptor must remain on the selected kernel mount ID and mapped filesystem before and after its `MZ` header is read. The transaction also rejects efibootmgr diagnostics, malformed paths, duplicate installations or labels, unsupported localized labels, missing BootOrder records, and geometry or loader changes. Selecting Windows from the Limine boot menu requests a one-boot firmware handoff; it does not prove that Windows booted successfully. Requires `efibootmgr`, `jq`, GNU coreutils, and util-linux.

### `status`

Shows Secure Boot state, ESP mount state, hook status, direct current-checksum proof in both Limine binaries, Limine 12 readiness diagnostics, Windows entry, Omarchy Direct Boot firmware entries, stale sbctl tracking entries, and enrolled file verification. Works without root for basic info; stale tracking diagnostics and file verification require root.

### `sign`

Integrated behind the closed production gate. It repairs configuration enrollment and signs last without rebuilding UKIs.

### `cleanup`

Integrated behind the closed production gate and routed through consolidated recovery before fresh cleanup.

### `unconfigure`

Integrated behind the closed production gate. Pre-preservation failures use software rollback; preserved failures resume through dedicated recovery to directly proved `disabled` state.

### `repair`

Integrated behind the closed production gate. Recovery selection comes from the immutable incident root, never from the command used to request repair.

### `version`

Prints the machine-readable release contract, currently `omasecboot 1.0.0`.

### `help`

Prints the current fail-closed command boundary. It does not print firmware-key mutation instructions.

## How It Works

### EFI File Discovery

Finds all `.efi`/`.EFI` files under `/boot`, plus snapshot UKIs with hash suffixes such as `*.efi_sha256_*`, `*.efi_sha1_*`, `*.efi_b3_*`, and `*.efi_xxh_*` (created by limine-snapper-sync with a content hash in the filename). Excludes:

| Pattern | Reason |
|---|---|
| `*/Microsoft/*` | Excluded from local signing; the path alone does not prove signer identity, db acceptance, or dbx status |
| `BOOTIA32.EFI` | 32-bit bootloader; irrelevant on x86_64 |
| `*.bak` | Backup files; not loaded by firmware |

### Signing and Database Registration

The artifact transaction remains unreachable from public mutation commands until interrupted recovery is available.

This repo treats **signature state** and **tracking state** as separate concerns:

- A file can be correctly signed but still missing from sbctl's tracked-file database.
- `zz-sbctl.hook` only re-signs files that are tracked by sbctl.

For normal unsigned files, `sbctl sign -s` both signs and tracks the file.

Each Limine target is rebuilt from the package's unsigned executable in a same-directory staging file. OmaSecBoot enrolls the current config checksum, signs and verifies the staged executable, then atomically replaces the target. A repair never durably publishes an unsigned Limine target. Proof also rejects higher-priority `limine.conf` candidates on the ESP that could shadow `/boot/limine.conf` at boot.

For already-signed files, Arch's current `sbctl` (0.18) has an upstream bug where `--save` may be ignored. Snapshot UKIs can hit exactly that case, because limine-snapper-sync may copy already-signed EFI files into snapshot history. When that happens, this repo writes the expected sbctl file entry directly so the file becomes truly tracked and future `zz-sbctl.hook` runs include it.

This is why `sign` may report a snapshot UKI as `registered` instead of `signed`.

Tracking reads use `sbctl list-files` first, then fall back to the on-disk sbctl file database only when needed. Stale-entry cleanup also merges in readable database entries so deleted snapshot UKIs do not remain hidden from cleanup if sbctl's CLI view is incomplete. The database path comes from one explicit plain top-level `files_db` scalar in `/etc/sbctl/sbctl.conf`; without that file, resolution follows sbctl 0.18's legacy-directory or default-path selection and rejects unsupported config syntax rather than guessing.

### Lifecycle Guards

Package and Limine hooks implement producer admission and completion behind the closed consolidated-recovery gate:

| Trigger | Scope | Purpose |
|---|---|---|
| `00-omasecboot-removal-guard.hook` (ours) | Recovery dependencies | Blocks removal unless lifecycle state is verified `disabled` or pristine |
| `00-omasecboot-transition-guard.hook` (ours) | Boot paths and producer packages | Consumes `NeedsTargets`, validates lifecycle state, and publishes an immutable package-producer lease when automation is available |
| `zz-omasecboot-cleanup.hook` (ours) | Boot paths and producer packages | Validates the owned package lease and records the pre-sbctl checkpoint |
| `zz-sbctl.hook` (sbctl built-in) | Boot/EFI path changes | Re-signs files already in sbctl's database |
| `zzz-omasecboot.hook` (ours) | Boot paths and producer packages | Completes fixed-registry reconstruction, artifact repair, and final producer proof |
| `000-omasecboot-guard` (ours) | Limine pre-hook | Resolves the fixed producer class and validates lifecycle ownership, ancestry, FD 200, and the durable lease |
| `zzz-omasecboot-sign` (ours) | Limine post-hook | Suppresses matching nested work or completes the matching Limine, snapshot, or restore producer lease |

Pacman hook ordering remains `zz-omasecboot-cleanup` < `zz-sbctl` < `zzz-omasecboot`. The three producer hooks use the same exact boot-path and producer-package registry without dependency-based skip conditions; only the transition guard consumes `NeedsTargets`, while both post hooks rely on the durable target set. The separate removal guard evaluates verified `disabled` or pristine state under both boot locks, while generic lifecycle mutation checks pacman's database lock before publication so concurrent activation cannot cross an allowed removal. Active lifecycle rejects direct changes to the four pinned producer packages: `limine-mkinitcpio-hook`, `limine-snapper-sync`, `efibootmgr`, and `coreutils`; disabled or pristine state is the upgrade path after the exact package pins are revalidated. Nested hooks under an OmaSecBoot top-level transition validate the root-owned token, boot ID, owner process start time, ancestry, manifest, parent descriptor, and current lock-path inode. Independent producer hooks validate the external coordinator's immutable producer record, exact identity, boot ID, process start time, and current ancestry. Full snapshot restore binds its root-owned runtime marker inode into the producer record to close the admission race; stale recovery removes the marker pathname only while it still matches that inode under both locks and no exact restore wrapper or native worker remains. The upstream mutation window remains lockless and is admitted only through the specialized stable-state path.

**Why this matters:** The current Omarchy stack works with three separate pieces:

- UEFI firmware verifies EFI binaries, so Omarchy UKIs, Limine EFI binaries, and the fallback loader must be signed.
- Limine config enrollment embeds the current `limine.conf` checksum into the Limine EFI binary.
- Limine path-hash generation is kept disabled with `ENABLE_VERIFICATION=no` for Omarchy's current UKI flow. Limine 12 and newer can still enforce BLAKE2B path hashes when Secure Boot and config checksum enrollment are both active; `status` reports this without changing current Omarchy behavior.

**Why config enrollment is required:** Limine protects Secure Boot systems by embedding the checksum of `limine.conf` into the Limine EFI binary. Any time `limine.conf` changes, the checksum must be re-enrolled with `limine-enroll-config`. The audited release verifies the current checksum directly in both `/EFI/limine/limine_x64.efi` and `/EFI/BOOT/BOOTX64.EFI` before final signing. Windows uses firmware BootNext rather than a managed Limine chainload, but this choice does not guarantee PCR7 binding or prevent BitLocker recovery.

**Why path hashes are not managed here:** Limine also supports `path: ...#<blake2b>` suffixes, but Omarchy's current working state uses `ENABLE_VERIFICATION=no` and boots UKIs through EFI paths, which Limine 12 exempts from path-hash enforcement. Snapshot filenames such as `omarchy_linux.efi_sha256_<hex>` come from `limine-snapper-sync`; that SHA256 is part of the filename, not a Limine `path:` hash suffix. If future Omarchy entries load non-EFI paths under Limine 12 Secure Boot enforcement, `status` flags the missing BLAKE2B suffixes.

**Why the repo does not rely only on sbctl internals:** sbctl deployments may store tracking state in either `files.json` or `files.db`, while the public `sbctl list-files` CLI is the normal read path for tracking state. This repo reads tracking state from the CLI first, and only falls back to or merges the database for cleanup and compatibility logic.

### Windows Boot Path

Quattro's documented `limine-scan` path adds Windows through `protocol: efi`, which chainloads `bootmgfw.efi` from Limine. OmaSecBoot instead uses Limine's `efi_boot_entry` protocol. When you select Windows from the Limine menu, Limine sets the firmware BootNext variable and triggers a reboot. On that reboot, firmware loads `bootmgfw.efi` directly, bypassing `limine_x64.efi` entirely.

This requests a direct firmware handoff instead of a Limine-managed chainload. `limine-snapper-sync` can mutate `limine_x64.efi` as snapshot state changes. The design avoids relying on that mutable binary as the Windows launcher, but no collected evidence proves stable PCR measurements, successful Windows boot, or absence of BitLocker recovery.

Windows mutation handlers and recovery are integrated but remain blocked until T-6.8 production activation.

Current `limine-update` and `limine-snapper-sync` update the existing configuration tree. Template-reset paths such as `omarchy refresh limine`, config reinstall, factory reset, or owner provisioning can replace `limine.conf` and remove the Windows entry. Durable target identity and stale-target suppression are implemented behind the recovery gate. `status` validates the recorded identity schema and bounded managed block without mounting the Windows ESP, and warns about Windows EFI chainload entries (`protocol: efi`, `efi_chainload`, or `uefi`) that may still need manual cleanup.

### Quattro Menu Integration

The tracked `omarchy/omarchy-menu.jsonc` fragment is a pre-contract reference for `Reboot to Windows`; do not merge it into the user-owned `~/.config/omarchy/extensions/omarchy-menu.jsonc`. The audited Omarchy integration will ship a package-aware guard and durable opt-in contract. Quattro's user file remains relevant evidence because its parser strips only whole-line `//` comments and silently drops every user entry on parse failure.

Do not install or invoke the current menu fragment. The audited action first revalidates the recorded target, requests BootNext in a visible terminal, then returns to user context for `omarchy system reboot`. If reboot is cancelled after BootNext is armed, firmware retains a one-attempt request; that does not guarantee the target will boot successfully.

### Current Producer Flow

```
Boot-mutating package transaction
  -> dependency removal guard requires verified disabled or pristine state
  -> 00-omasecboot-transition-guard consumes targets and checks lifecycle
  -> unmanaged or disabled: automation remains inactive
  -> active: transaction currently aborts while production activation is unavailable
  -> transition or recovery-required: transaction aborts
  -> after activation: publish ancestor-bound lease and immutable target/baseline records
  -> cleanup checkpoint runs before sbctl
  -> final hook reconstructs expected outputs, repairs artifacts, and proves obligations

Hook-aware Limine or snapshot mutation
  -> 000-omasecboot-guard resolves a fixed producer and validates FD 200 plus FD 201 policy
  -> active: mutation currently aborts while production activation is unavailable
  -> after activation: publish an ancestor-bound Limine, snapshot, or restore lease
  -> owned nested transition: mutation may proceed and nested post-repair is suppressed
  -> external transition or recovery-required: mutation aborts fatally
  -> matching post-hook completes fixed-registry repair and schema-2 proof
```

### Code Structure

Single dispatcher (`bin/omasecboot`) sources modular libraries:

- `common.sh` -- output helpers, quiet mode, backup/restore
- `lifecycle.sh` -- versioned lifecycle state, manifests, locks, hook ownership, and transaction guards
- `producers.sh` -- ancestor-bound producer leases, fixed recovery registry, and expected-EFI obligations
- `checks.sh` -- prerequisite validation (root, deps, EFI mount)
- `discover.sh` -- EFI file discovery and sbctl database queries
- `sign.sh` -- key creation, signing, Limine config management
- `enroll.sh` -- raw firmware backup, strict trust planning, setup-state observation, and guarded enrollment
- `windows.sh` -- Windows encryption preflight, firmware BootNext handoff, and Limine `efi_boot_entry` management
- `status.sh` -- status display and file verification

Maintainer-facing reference sources, versioned compatibility findings, workaround removal triggers, and deferred work live in [docs/maintenance.md](docs/maintenance.md). Remaining implementation and release gates live in [docs/implementation-contract.md](docs/implementation-contract.md), with operational invariants in `AGENTS.md`.

## Troubleshooting

The current branch has no supported mutation-based troubleshooting procedure. Do not clear firmware keys, reinstall hooks, edit `limine.conf`, run enrollment or signing repair, arm BootNext, remove a Windows entry, or re-enable Secure Boot based on the current status checks.

Read-only observations remain useful for an expert-led recovery:

- `omasecboot status` reports the current branch's view but does not implement the approved release proof.
- `sbctl status`, `sbctl list-files`, and `sbctl verify` report local state; they do not prove complete firmware trust or dbx acceptance.
- `efibootmgr -v` is diagnostic input. Do not select a target by the first label or `bootmgfw.efi` text match.
- `sudo omasecboot windows preflight` reports its bounded Windows and BitLocker observations without authorizing firmware changes. Exit 2 means a technical uncertainty must be resolved rather than overridden.
- `findmnt` can show whether Windows volumes or ESPs are mounted. Dormant target proof can reuse a controlled `ro` or `rw` ESP mount, applying `O_NOATIME` for a writable-mount loader read, or create an owned `ro,noatime` mount; OmaSecBoot never mounts or modifies NTFS.
- Windows disk-check prompts and BitLocker recovery are separate. Diagnose Windows volume state from Windows, not from a failed Linux mount.

Record the exact state and seek machine-specific recovery review before any write. The audited release will replace this section with tested lifecycle-state recovery procedures.

## Recovery / Rollback

### Emergency boot recovery

If the system will not boot with Secure Boot enabled:

1. Enter BIOS/UEFI firmware settings
2. Disable Secure Boot temporarily
3. Boot into Linux normally
4. Diagnose with `sudo omasecboot status`
5. Keep Secure Boot disabled and avoid current mutation commands until the state and available backups have been reviewed

Do not re-enable Secure Boot from the current branch's status result alone. The approved gate requires direct Limine checksum proof in both binaries plus final signature and tracking verification.

### Full rollback

The current branch has no public verified full rollback. `make uninstall` fails closed until command-integrated unconfiguration, concurrency-safe package removal, and package removal tests land. Do not remove installed files manually or treat package removal as unconfiguration.

The dormant implementation provides a separate `unconfigure` transaction. It requires Secure Boot off, restores only settings whose current values still match OmaSecBoot's recorded values, removes the managed Windows block, resets config enrollment, rebuilds and verifies stock boot state, and commits `disabled` last. The audited release allows package removal only from verified `disabled` or pristine state; it removes package trigger hooks and only the `omasecboot` package while preserving lifecycle, transaction, recovery, firmware-backup, Windows-opt-in, lock-path, and local-key state.

Software unconfiguration, PK reset, recovery from raw pre-change variables, and firmware factory restoration are distinct procedures. A pre-change backup is not necessarily a factory-key set.

### Re-enrollment after key reset

Do not equate clearing keys, entering Setup Mode, resetting the PK, or restoring firmware factory keys. Recovery instructions must start from the recorded raw-variable backup and current firmware state. Local sbctl keys can be inspected with `sbctl status`, but their presence alone does not prove that re-enrollment preserves the machine's required trust.

## Design Philosophy

The approved design handles the parts of Secure Boot that Omarchy does not fully automate for this exact dual-boot flow:

- **One-time setup**: Key creation, Limine verification/enrollment settings, initial signing, key enrollment, Windows boot entry via `efi_boot_entry` protocol
- **Ongoing repair**: Enrolling and verifying the current Limine config, signing new EFI files (especially snapshots), and restoring the Windows entry. Windows uses a direct firmware handoff while recovery remains possible

It deliberately delegates everything else:

- **Ongoing re-signing** of known files: `zz-sbctl.hook`
- **UKI building**: `mkinitcpio`
- **Kernel and generic EFI entry management** in limine.conf: `limine-entry-tool`
- **Snapshot boot entries**: `limine-snapper-sync`

Don't automate what's already automated. Fill the gaps that aren't.

The approved package owns guarded pacman-triggered maintenance and Limine-originated repair through validated pre-hook and post-hook mechanisms.

`zz-sbctl.hook` works on Omarchy because UKIs use `CUSTOM_UKI_NAME="omarchy"` and live at `/boot/EFI/Linux/omarchy_linux.efi`.

## License

[MIT](LICENSE)

## Credits

Created by [peregrinus879](https://github.com/peregrinus879).
