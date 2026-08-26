# OmaSecBoot

**[Omarchy](https://omarchy.com) Secure Boot: sbctl signing, Limine enrollment, pacman hook, and Windows BootNext handoff.**

Creates signing keys, configures Limine for Omarchy's current Secure Boot model, signs EFI files, enrolls keys into firmware, and adds Windows to the Limine boot menu via firmware BootNext handoff. After setup, a cleanup hook (`zz-omasecboot-cleanup.hook`) removes stale sbctl entries before sbctl's pacman hook (`zz-sbctl.hook`) re-signs known files, a repair hook (`zzz-omasecboot.hook`) discovers new EFI files after relevant package transactions, and a Limine post-hook (`zzz-omasecboot-sign`) repairs state after upstream Limine tools finish changing boot files.

## Why This Tool

[Omarchy Quattro](https://github.com/basecamp/omarchy/releases/tag/v4.0.0) supports installation into free space alongside Windows, and its [dual-boot guide](https://omarchy.org/manual/dual-boot-install/) documents `limine-scan` for adding Windows to Limine. The current scanner creates a generic `protocol: efi` chainload entry. OmaSecBoot builds on that native dual-boot foundation with a firmware BootNext path designed for Secure Boot and BitLocker-sensitive systems.

Omarchy uses Limine with Unified Kernel Images (UKIs) and Snapper snapshots. That stack still has Secure Boot lifecycle gaps:

- **sbctl** manages keys and signs EFI binaries, but does not handle Limine config enrollment, snapshot UKI discovery, or durable Windows BootNext entries.
- **shim/MOK** is designed for the GRUB and systemd-boot chains. Limine uses direct UEFI Secure Boot verification with custom keys enrolled via sbctl.
- **systemd-boot** is not Omarchy's bootloader. This tool is specific to the Limine + UKI + Snapper stack that Omarchy ships.

This tool fills those gaps: it automates Limine config enrollment, discovers and signs snapshot UKIs, replaces Windows chainloading with firmware BootNext, restores the managed entry after config resets, and keeps everything consistent through pacman hooks plus a Limine post-hook.

## Table of Contents

- [Why This Tool](#why-this-tool)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Quick Start](#quick-start)
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
| **Setup Mode** | UEFI firmware state where Secure Boot keys can be enrolled. Entered by clearing existing keys in BIOS settings. |
| **UKI** | Unified Kernel Image. Single EFI file containing kernel, initramfs, and command line. Built by `mkinitcpio` on Omarchy. |
| **BootNext** | UEFI firmware variable that overrides the boot order for one boot only. Used by `efi_boot_entry` and `efibootmgr -n` to boot Windows directly from firmware. |
| **Config enrollment** | Embedding `limine.conf`'s checksum into the Limine EFI binary so it can verify config integrity at boot. |
| **Signing** | Attaching a cryptographic signature to an EFI binary so UEFI firmware can verify it has not been tampered with. |

</details>

## Prerequisites

- **[Omarchy](https://omarchy.com)** with Limine bootloader, UKI, and btrfs/Snapper
- [sbctl](https://github.com/Foxboron/sbctl) - Secure Boot key manager
- [jq](https://jqlang.github.io/jq/) - JSON parser
- [gum](https://github.com/charmbracelet/gum) - interactive prompts (setup, enroll, windows)
- UEFI firmware with Secure Boot support
- EFI System Partition mounted at `/boot`
- For dual-boot: Windows Boot Manager present in the firmware boot entries

```bash
sudo pacman -S --needed sbctl jq gum
```

### Before You Begin (Dual-Boot with Windows)

If your Windows installation uses BitLocker drive encryption:

1. **Back up your BitLocker recovery key** before starting. Find it at [aka.ms/myrecoverykey](https://aka.ms/myrecoverykey) or in its existing USB, print, Active Directory, or Microsoft Entra ID backup.
2. In Windows, run `manage-bde.exe -protectors -get C:` as an administrator. If it reports `Uses Secure Boot for integrity validation`, suspend BitLocker before enrolling custom Secure Boot keys. [Microsoft recommends suspension](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/faq#do-i-have-to-suspend-bitlocker-protection-to-download-and-install-system-updates-and-upgrades) for manual or non-Microsoft Secure Boot database changes.
3. After successful key enrollment and a verified Windows boot, resume BitLocker so its protectors reseal to the new measured values.
4. Keep the recovery key available. Firmware policy, protector configuration, and other boot changes determine whether recovery is requested; OmaSecBoot does not guarantee a single recovery event.

## Installation

`OmaSecBoot` is the product name; `omasecboot` is the command, repository slug, and machine-facing namespace.

```bash
git clone https://github.com/peregrinus879/omasecboot.git ~/Projects/eyrie/omasecboot
cd ~/Projects/eyrie/omasecboot
sudo make install
```

Installs to:
- `/usr/local/bin/omasecboot`
- `/usr/local/lib/omasecboot/`
- `/etc/pacman.d/hooks/zz-omasecboot-cleanup.hook`
- `/etc/pacman.d/hooks/zzz-omasecboot.hook`
- `/etc/boot/hooks/post.d/zzz-omasecboot-sign`
- `/var/lib/omasecboot/`

To uninstall: `sudo make uninstall`

## Quick Start

**Step 1** - Create keys and sign EFI files:

```bash
sudo omasecboot setup
```

**Step 2** - Reboot into BIOS/UEFI, clear Secure Boot keys (enter Setup Mode), save and exit.

> [!WARNING]
> **Dual-boot with BitLocker?** Have your recovery key ready before Step 3.
> Enrolling custom Secure Boot keys can trigger BitLocker recovery if protection
> is not suspended. See [Before You Begin](#before-you-begin-dual-boot-with-windows).

**Step 3** - Enroll keys into firmware:

```bash
sudo omasecboot enroll
```

**Step 4** - Reboot into BIOS/UEFI, enable Secure Boot, save and exit.

**Step 5** *(dual-boot only)* - Add Windows to Limine boot menu:

```bash
sudo omasecboot windows setup
```

This adds Windows to the Limine menu using the `efi_boot_entry` protocol (firmware BootNext). Use `sudo omasecboot windows reboot` for an immediate Windows handoff, or select Windows from the Limine boot menu. The pacman hooks handle package-triggered maintenance, and the Limine post-hook handles boot drift created by `limine-update` or `limine-snapper-sync`.

For Omarchy Quattro, `omarchy/omarchy-menu.jsonc` contains a `system.windows` entry for the user-owned `~/.config/omarchy/extensions/omarchy-menu.jsonc`. It arms BootNext in a visible terminal, then calls `omarchy system reboot` so Quattro closes application windows before rebooting.

## Commands

### `setup`

Creates signing keys (or skips if they exist), enforces `ENABLE_VERIFICATION=no` plus Limine config enrollment settings, regenerates boot entries, refreshes snapshot entries, ensures the Windows boot entry uses the `efi_boot_entry` protocol, re-enrolls the `limine.conf` checksum if the config changed, cleans stale sbctl database entries, and signs all EFI files on the ESP.

### `enroll`

Checks that firmware is in Setup Mode, then enrolls signing keys with:
- `-m` Microsoft keys (required for Windows dual-boot and Option ROMs)
- `-f` firmware-builtin keys (safety net for vendor components)

### `windows`

Provides explicit Windows firmware handoff operations:

- `windows available` checks silently, without root, for a Windows Boot Manager firmware entry.
- `windows setup` adds the Limine `efi_boot_entry`, enrolls the config checksum, and signs EFI files. It does not reboot.
- `windows bootnext` sets firmware BootNext without rebooting.
- `windows reboot` sets BootNext and reboots immediately.

Detection matches the `bootmgfw.efi` loader path rather than the firmware label. Selecting Windows from the Limine boot menu triggers the same firmware BootNext handoff. Requires `efibootmgr`.

### `status`

Shows Secure Boot state, ESP mount state, hook status, Limine 12 readiness diagnostics for path hashes and interface colors, Windows entry, Omarchy Direct Boot firmware entries, stale sbctl tracking entries, and enrolled file verification. Works without root for basic info; stale tracking diagnostics and file verification require root.

### `sign`

Repairs Linux-side Secure Boot state after updates by enforcing the Limine verification/enrollment settings in `/etc/default/limine`, ensuring the Windows boot entry uses the `efi_boot_entry` protocol, re-enrolling the `limine.conf` checksum if the config changed, cleaning stale database entries, and signing all EFI files currently present on the ESP. Used manually, by the pacman hooks, and by the Limine post-hook.

### `cleanup`

Removes stale sbctl tracked-file entries after validating that `/boot` is mounted as the FAT32 ESP. Used by `zz-omasecboot-cleanup.hook` before `zz-sbctl.hook`; run manually if `status` reports stale tracked files.

### `help`

Prints usage and the five-step workflow.

## How It Works

### EFI File Discovery

Finds all `.efi`/`.EFI` files under `/boot`, plus snapshot UKIs with hash suffixes such as `*.efi_sha256_*`, `*.efi_sha1_*`, `*.efi_b3_*`, and `*.efi_xxh_*` (created by limine-snapper-sync with a content hash in the filename). Excludes:

| Pattern | Reason |
|---|---|
| `*/Microsoft/*` | Signed by Microsoft; trusted via `-m` enrollment flag |
| `BOOTIA32.EFI` | 32-bit bootloader; irrelevant on x86_64 |
| `*.bak` | Backup files; not loaded by firmware |

### Signing and Database Registration

This repo treats **signature state** and **tracking state** as separate concerns:

- A file can be correctly signed but still missing from sbctl's tracked-file database.
- `zz-sbctl.hook` only re-signs files that are tracked by sbctl.

For normal unsigned files, `sbctl sign -s` both signs and tracks the file.

For already-signed files, Arch's current `sbctl` (0.18) has an upstream bug where `--save` may be ignored. Snapshot UKIs can hit exactly that case, because limine-snapper-sync may copy already-signed EFI files into snapshot history. When that happens, this repo writes the expected sbctl file entry directly so the file becomes truly tracked and future `zz-sbctl.hook` runs include it.

This is why `sign` may report a snapshot UKI as `registered` instead of `signed`.

Tracking reads use `sbctl list-files` first, then fall back to the on-disk sbctl file database only when needed. Stale-entry cleanup also merges in readable database entries so deleted snapshot UKIs do not remain hidden from cleanup if sbctl's CLI view is incomplete. If a fallback is required, this repo prefers `files.db` over `files.json`.

### Automatic Maintenance

Package-triggered repair uses pacman hooks. Limine-originated repair uses Limine's own post-hook mechanism, which runs after `limine-update` or `limine-snapper-sync` finishes writing boot files:

| Trigger | Scope | Purpose |
|---|---|---|
| `zz-omasecboot-cleanup.hook` (ours) | Same Path triggers as `zz-sbctl.hook` | Removes stale sbctl entries before sbctl re-signs |
| `zz-sbctl.hook` (sbctl built-in) | Boot/EFI path changes | Re-signs files already in sbctl's database |
| `zzz-omasecboot.hook` (ours) | `linux*`, `limine*`, `snapper*` packages | Runs lightweight repo repair after relevant package updates |
| `zzz-omasecboot-sign` (ours) | Limine post-hook | Runs lightweight repo repair after upstream Limine tools finish changing boot files |

Pacman hook ordering relies on filename sort: `zz-omasecboot-cleanup` < `zz-sbctl` < `zzz-omasecboot`. The cleanup hook mirrors `zz-sbctl.hook`'s `Type = Path` triggers so it fires in the same transactions, refuses to run unless `/boot` is the mounted FAT32 ESP, and removes stale tracked entries before sbctl runs. The repair hook uses `Type = Package` triggers for `linux*`, `limine*`, and `snapper*`. The Limine post-hook is named `zzz-omasecboot-sign` so it runs after Limine's packaged `90-limine-enroll-config` post-hook.

**Why this matters:** The current Omarchy stack works with three separate pieces:

- UEFI firmware verifies EFI binaries, so Omarchy UKIs, Limine EFI binaries, and the fallback loader must be signed.
- Limine config enrollment embeds the current `limine.conf` checksum into the Limine EFI binary.
- Limine path-hash generation is kept disabled with `ENABLE_VERIFICATION=no` for Omarchy's current UKI flow. Limine 12 and newer can still enforce BLAKE2B path hashes when Secure Boot and config checksum enrollment are both active; `status` reports this without changing current Omarchy behavior.

**Why config enrollment is required:** Limine protects Secure Boot systems by embedding the checksum of `limine.conf` into the Limine EFI binary. Any time `limine.conf` changes, the checksum must be re-enrolled with `limine-enroll-config`. This enrollment mutates `limine_x64.efi`, which is why Windows must boot via firmware BootNext (not chainload) to avoid TPM PCR measurement drift.

**Why path hashes are not managed here:** Limine also supports `path: ...#<blake2b>` suffixes, but Omarchy's current working state uses `ENABLE_VERIFICATION=no` and boots UKIs through EFI paths, which Limine 12 exempts from path-hash enforcement. Snapshot filenames such as `omarchy_linux.efi_sha256_<hex>` come from `limine-snapper-sync`; that SHA256 is part of the filename, not a Limine `path:` hash suffix. If future Omarchy entries load non-EFI paths under Limine 12 Secure Boot enforcement, `status` flags the missing BLAKE2B suffixes.

**Why the repo does not rely only on sbctl internals:** sbctl deployments may store tracking state in either `files.json` or `files.db`, while the public `sbctl list-files` CLI is the normal read path for tracking state. This repo reads tracking state from the CLI first, and only falls back to or merges the database for cleanup and compatibility logic.

### Windows Boot Path

Quattro's documented `limine-scan` path adds Windows through `protocol: efi`, which chainloads `bootmgfw.efi` from Limine. OmaSecBoot instead uses Limine's `efi_boot_entry` protocol. When you select Windows from the Limine menu, Limine sets the firmware BootNext variable and triggers a reboot. On that reboot, firmware loads `bootmgfw.efi` directly, bypassing `limine_x64.efi` entirely.

This keeps Limine out of the Windows boot measurement chain, avoiding one source of TPM PCR drift that can trigger BitLocker recovery. `limine-snapper-sync` re-enrolls `limine_x64.efi` as snapshot state changes, mutating the binary. With chainloading (`protocol: efi`), Windows boot measurements include that binary. With `efi_boot_entry`, TPM PCRs reset on the firmware reboot and firmware loads Windows directly.

The `windows reboot` command provides a direct reboot-to-Windows path from Linux via `efibootmgr -n` (same firmware handoff, skips the Limine menu).

Current `limine-update` and `limine-snapper-sync` update the existing configuration tree. Template-reset paths such as `omarchy refresh limine`, config reinstall, factory reset, or owner provisioning can replace `limine.conf` and remove the Windows entry. OmaSecBoot's repair paths restore an opted-in managed entry with the correct `efi_boot_entry` protocol. `status` also warns about Windows EFI chainload entries (`protocol: efi`, `efi_chainload`, or `uefi`) that may still need manual cleanup.

### Quattro Menu Integration

The tracked `omarchy/omarchy-menu.jsonc` fragment adds `Reboot to Windows` under Quattro's System menu. Merge its `system.windows` object into the user-owned `~/.config/omarchy/extensions/omarchy-menu.jsonc`; do not modify `/usr/share/omarchy`. Quattro watches the user file, and `omarchy menu refresh` requests an immediate refresh.

Keep the user file valid JSONC. Quattro strips only whole-line `//` comments, and a parse failure silently drops every user entry while the shipped menu keeps working. `omarchy refresh config omarchy/extensions/omarchy-menu.jsonc` replaces the file with the shipped sample and keeps a `.bak.<epoch>` copy; `omarchy reinstall configs` (also run by `omarchy reinstall`) overwrites it from `/etc/skel` without a backup. Merge the fragment again after either.

Run `sudo omasecboot windows setup` before using the menu action. The action opens a visible terminal, runs `sudo omasecboot windows bootnext`, then returns to user context for `omarchy system reboot` so Quattro can close application windows. If the reboot step is cancelled after BootNext is armed, the next boot still enters Windows once.

### After Setup

The package-triggered maintenance chain:

```
Kernel update
  -> mkinitcpio builds UKI
  -> limine-entry-tool updates limine.conf
  -> zz-omasecboot-cleanup.hook removes stale sbctl entries
  -> zz-sbctl.hook re-signs UKI (already in database)
  -> zzz-omasecboot.hook ensures Windows boot entry and signs new files

Snapshot creation or cleanup
  -> limine-snapper-sync copies UKIs to snapshot locations and rewrites snapshot entries
  -> limine-entry-tool hooks re-enroll and re-sign limine_x64.efi
  -> zzz-omasecboot-sign discovers and signs new snapshot UKIs

Bootloader update
  -> Limine hook copies fresh bootloader files
  -> zz-omasecboot-cleanup.hook removes stale sbctl entries
  -> zz-sbctl.hook re-signs bootloader files
  -> zzz-omasecboot.hook ensures Windows boot entry and signs new files
```

### Code Structure

Single dispatcher (`bin/omasecboot`) sources modular libraries:

- `common.sh` -- output helpers, quiet mode, backup/restore
- `checks.sh` -- prerequisite validation (root, deps, EFI mount)
- `discover.sh` -- EFI file discovery and sbctl database queries
- `sign.sh` -- key creation, signing, Limine config management
- `enroll.sh` -- firmware key enrollment
- `windows.sh` -- Windows firmware BootNext handoff and Limine `efi_boot_entry` management
- `status.sh` -- status display and file verification

Maintainer-facing reference sources, versioned compatibility findings, workaround removal triggers, and deferred work live in [docs/maintenance.md](docs/maintenance.md). Current operational constraints remain in `AGENTS.md`.

## Troubleshooting

### Key creation or enrollment fails

sbctl may store keys under `/usr/share/secureboot/keys/` or `/var/lib/sbctl/keys/`. Check both locations if troubleshooting key issues:

```bash
ls /usr/share/secureboot/keys/db/db.key 2>/dev/null || ls /var/lib/sbctl/keys/db/db.key
```

### `enroll` says firmware is not in Setup Mode

Clear/reset the Secure Boot keys in your BIOS first. The exact menu location varies by manufacturer. Look under Security, Boot, or Authentication for "Clear Secure Boot keys", "Reset to Setup Mode", or similar.

### `sbctl verify` shows Microsoft files as unsigned

Normal. Microsoft files are signed with Microsoft's own keys, not yours. The firmware trusts them because you enrolled Microsoft's keys with the `-m` flag.

### Windows not found during `windows` setup

Ensure the Windows disk is connected and visible in BIOS. Check with `efibootmgr -v`. The command looks for a boot entry whose loader path contains `bootmgfw.efi`.

### Secure Boot enabled but system won't boot

Boot into BIOS, temporarily disable Secure Boot, boot into Linux, then:

```bash
sudo omasecboot status    # Check what's unsigned or misconfigured
sudo omasecboot sign      # Repair config drift and sign EFI files
```

Re-enable Secure Boot after confirming all files verify.

### Snapshot fails to boot after kernel update

Run `sudo omasecboot sign` to discover and sign new snapshot UKIs if you need an immediate manual repair. The pacman hooks and Limine post-hook normally cover package-triggered and Limine-originated boot drift automatically.

### Limine panics about config checksum enrollment

This means Limine's Secure Boot config enrollment drifted out of sync after an update. Boot once with Secure Boot disabled, then run:

```bash
sudo limine-enroll-config
sudo omasecboot sign
```

This re-enrolls the current config checksum, restores the required `/etc/default/limine` settings, repairs repo-managed config drift, and signs EFI files. The pacman hooks and Limine post-hook do this automatically in normal operation.

### `status` warns that `limine-snapper-sync.service` is not active

This warning is informational. It refers to Omarchy's upstream snapshot service, not this repo's core commands.

- Package-triggered repair still works through `zz-omasecboot-cleanup.hook` and `zzz-omasecboot.hook`.
- Limine-originated repair still works through `/etc/boot/hooks/post.d/zzz-omasecboot-sign`.
- Manual repair still works through `sudo omasecboot sign`.

### `status` reports untracked snapshot UKIs

This means new EFI files exist under `/boot` but are not yet in sbctl's database. Register and sign them with:

```bash
sudo omasecboot sign
```

This is most common after snapshot activity that happened before the Limine post-hook repaired the new files, or after boot drift introduced multiple changes at once.

If this still appears immediately after a successful `sign`, check `sudo sbctl list-files` and verify the repo version is current. This repo includes a compatibility workaround for Arch `sbctl` 0.18, where `sbctl sign -s` may refuse to save an already-signed file.

### `status` reports stale sbctl tracked files

This means sbctl still tracks an EFI file that no longer exists, commonly an old snapshot UKI removed by `limine-snapper-sync`. Clean the stale entries before the next package transaction so `zz-sbctl.hook` does not fail trying to sign deleted files:

```bash
sudo omasecboot cleanup
```

If cleanup cannot remove an entry, inspect `sudo sbctl list-files` and run `sudo omasecboot status` again. The cleanup path checks that `/boot` is mounted as the FAT32 ESP before it removes any entries.

### `status` warns about Omarchy Direct Boot

Omarchy's Direct Boot toggle creates a firmware entry named `Omarchy` that boots `/boot/EFI/Linux/omarchy*.efi` directly. This is compatible with Secure Boot as long as the UKI is signed, but it bypasses the Limine menu, so snapshot entries and the repo-managed Windows BootNext menu entry will not appear on normal boot. Disable Direct Boot from Omarchy's toggle if you want Limine to be the default boot path.

### Windows disappeared from Limine boot menu

This can happen after a template reset such as `omarchy refresh limine`, config reinstall, factory reset, or owner provisioning. Ordinary current `limine-update` and `limine-snapper-sync` runs update the existing configuration tree. OmaSecBoot restores the opted-in entry automatically with the correct `efi_boot_entry` protocol. To restore immediately:

```bash
sudo omasecboot sign
```

### `Reboot to Windows` is missing from the System menu

Quattro hides the row when its guard fails, and it drops every user entry when the extension file fails to parse. Check, as the desktop user:

```bash
command -v omasecboot && omasecboot windows available
grep -n '"system.windows"' ~/.config/omarchy/extensions/omarchy-menu.jsonc
sed '/^[[:space:]]*\/\//d' ~/.config/omarchy/extensions/omarchy-menu.jsonc | jq . >/dev/null
```

The guard needs `omasecboot` on the user's `PATH` (`/usr/local/bin` by default) and a Windows Boot Manager entry in firmware. The `jq` check is stricter than Quattro's parser (it rejects trailing commas) but catches the inline comments and syntax errors that make Quattro drop the user entries. A config refresh or reinstall replaces the file with the shipped sample; merge the fragment again and run `omarchy menu refresh`.

### `status` warns about a Windows EFI chainload entry

For repo-managed Windows entries, run `sudo omasecboot sign` to restore the `protocol: efi_boot_entry` block. The managed entry uses firmware BootNext, which keeps `limine_x64.efi` out of the Windows boot measurement chain and removes that source of PCR drift.

If `status` reports a Windows EFI chainload entry, add the managed BootNext entry with `sudo omasecboot windows setup`, then remove any duplicate chainload entry manually if `limine-scan` created one.

### `status` warns about Limine 12 path hashes

Limine 12 enforces BLAKE2B hashes on non-EFI loaded paths when Secure Boot is active and a config checksum is enrolled. Omarchy's current UKI entries use EFI paths, which Limine 12 exempts because firmware Secure Boot verifies those EFI binaries. If future entries use non-EFI path values such as `path:`, `module_path:`, `kernel_path:`, `image_path:`, `dtb_path:`, or `global_dtb:` without `#<blake2b>`, `status` flags them before they can cause a Secure Boot panic.

### `status` warns about Limine 12 colors

Limine 12 changed interface color options from 0-7 color indexes to `RRGGBB` hex values. If `status` flags an old value such as:

```text
interface_branding_color: 2
```

Replace it in `/boot/limine.conf` with a hex color, then re-enroll and sign:

```bash
sudo cp -a /boot/limine.conf "/boot/limine.conf.bak.$(date +%Y%m%d-%H%M%S)"
sudo sed -i 's/^interface_branding_color: 2$/interface_branding_color: 9ece6a/' /boot/limine.conf
sudo limine-enroll-config
sudo omasecboot sign
```

`9ece6a` matches Omarchy's Tokyo Night green accent. Current Quattro templates already use six-digit color values.

### Windows runs a disk check on boot

Windows `Scanning and repairing drive` or `chkdsk` is separate from BitLocker recovery. This repo uses firmware BootNext for Windows and does not mount or modify Windows NTFS volumes, so repeated disk checks usually mean Windows has set the NTFS dirty bit, had an interrupted shutdown/update, or saw a Fast Startup/hibernation state.

From Linux, check for duplicate or unmanaged Windows boot paths and whether Windows partitions are mounted:

```bash
sudo omasecboot status
sudo efibootmgr -v | grep -i 'bootmgfw\.efi'
findmnt -t ntfs3,ntfs,fuseblk
grep -nA4 -B2 'omasecboot:windows\|protocol: efi\|protocol: efi_chainload\|protocol: uefi\|bootmgfw' /boot/limine.conf
```

From Windows Admin PowerShell or Command Prompt, check the dirty bit and recent disk-check logs:

```powershell
fsutil dirty query C:
chkntfs C:
chkdsk C: /scan
Get-WinEvent -FilterHashtable @{LogName="Application"; ProviderName="Wininit"} -MaxEvents 5 | Format-List TimeCreated,Message
Get-WinEvent -FilterHashtable @{LogName="Application"; ProviderName="Chkdsk"} -MaxEvents 5 | Format-List TimeCreated,Message
```

If Windows reports the volume is dirty, repair it from Windows with `chkdsk C: /f` and let it run at the next Windows boot. Avoid mounting Windows NTFS partitions read-write from Linux. If the issue repeats and you do not need Windows hibernation, disable Fast Startup/hibernation from Windows with `powercfg /h off`.

### `windows setup` says Windows Boot Manager not found

Ensure the Windows disk is connected and visible in BIOS. Check with `efibootmgr -v`. The command looks for a boot entry whose loader path contains `bootmgfw.efi`.

## Recovery / Rollback

### Emergency boot recovery

If the system will not boot with Secure Boot enabled:

1. Enter BIOS/UEFI firmware settings
2. Disable Secure Boot temporarily
3. Boot into Linux normally
4. Diagnose with `sudo omasecboot status`
5. Repair with `sudo omasecboot sign`
6. Re-enable Secure Boot in BIOS after confirming all files verify

### Full rollback

To remove Secure Boot entirely and return to an unsigned boot state:

1. Disable Secure Boot in BIOS/UEFI firmware settings
2. Optionally reset Secure Boot keys to factory defaults (re-enrolls Microsoft-only keys)
3. Run `sudo make uninstall` from the repo to remove the tool, pacman hooks, Limine post-hook, and repo state directory

Existing EFI signatures are harmless with Secure Boot disabled. No need to re-sign or strip signatures.

### Re-enrollment after key reset

If BIOS keys are cleared (factory reset, accidental clear, or hardware change):

1. The local signing keys from `sbctl create-keys` are still on disk. No need to recreate them.
2. Enter Setup Mode in BIOS (clear/reset Secure Boot keys)
3. Run `sudo omasecboot enroll` to re-enroll your keys
4. Enable Secure Boot in BIOS

If you need to verify your keys still exist: `sbctl status`

## Design Philosophy

This tool handles the parts of Secure Boot that Omarchy does not fully automate for this exact dual-boot flow:

- **One-time setup**: Key creation, Limine verification/enrollment settings, initial signing, key enrollment, Windows boot entry via `efi_boot_entry` protocol
- **Ongoing repair**: Re-enrolling changed Limine configs, signing new EFI files (especially snapshots), and restoring the Windows boot entry. Windows boots via firmware BootNext for TPM/BitLocker compatibility

It deliberately delegates everything else:

- **Ongoing re-signing** of known files: `zz-sbctl.hook`
- **UKI building**: `mkinitcpio`
- **Kernel and generic EFI entry management** in limine.conf: `limine-entry-tool`
- **Snapshot boot entries**: `limine-snapper-sync`

Don't automate what's already automated. Fill the gaps that aren't.

This repo owns pacman-triggered maintenance and Limine-originated boot-drift repair through Limine's post-hook mechanism.

`zz-sbctl.hook` works on Omarchy because UKIs use `CUSTOM_UKI_NAME="omarchy"` and live at `/boot/EFI/Linux/omarchy_linux.efi`.

## License

[MIT](LICENSE)

## Credits

Created by [peregrinus879](https://github.com/peregrinus879).
