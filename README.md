# OmaSecBoot

[![CI](https://github.com/peregrinus879/omasecboot/actions/workflows/ci.yml/badge.svg)](https://github.com/peregrinus879/omasecboot/actions/workflows/ci.yml)
[![Upstream contracts](https://github.com/peregrinus879/omasecboot/actions/workflows/contracts.yml/badge.svg)](https://github.com/peregrinus879/omasecboot/actions/workflows/contracts.yml)

**Secure Boot for [Omarchy](https://omarchy.org) with your own keys.**

OmaSecBoot is an opt-in package for installed Omarchy systems. It leaves the work to the tools Omarchy already ships, sbctl and the Limine tools, fills the gaps between them, checks what they did, and tells you the truth about the result.

> [!CAUTION]
> **Status:** 0.1.1 corrects 0.1.0, the first release. One machine, an ASUS Vivobook TP3402VA, has run stages 0 to 7 of the hardware acceptance in [docs/release-checklist.md](docs/release-checklist.md), from a stock baseline through `remove` and back to set up, on commit `2a8d324`, with Secure Boot on and Windows Home's device encryption on beside it. Every change since that run, 0.1.1's included, is verified by software alone and has no hardware row yet: section C10 of [docs/upstream-contracts.md](docs/upstream-contracts.md) lists each with the tests that verify it and the rows still owed, which [docs/maintenance.md](docs/maintenance.md) tracks, and says what the run showed. No other firmware has a record. Use the tool only on a machine you can afford to recover; [docs/field-testing.md](docs/field-testing.md) is how another machine gets its record.

## Why

Omarchy boots through Limine with unified kernel images and Snapper snapshot entries, and its manual tells users to turn Secure Boot off. The pieces for Secure Boot with your own keys all exist, and none of them closes the gaps between them:

- **sbctl** creates keys, signs EFI files and enrolls keys, but it knows nothing about Limine's configuration, and its enrollment replaces what the firmware trusts unless it is told otherwise.
- **The Limine tools** can seal the loader over `limine.conf` and sign it, but the feature is off by default and its failures are hidden.
- **Windows dual boot** adds BitLocker, which can react to a change of the firmware's keys or of Secure Boot's state.

## How it works

- sbctl signs each new kernel image while it is built, and Limine's own hook seals the loader: it writes a checksum of `limine.conf` into the Limine executable, so the loader refuses to start on a `limine.conf` it was not sealed over. OmaSecBoot turns those two upstream features on, proves after every change that they really happened, and repairs the loader when they did not.
- It integrates in two places only. A small Limine hook runs at the end of every Limine operation (kernel updates, Limine upgrades, snapshots). Two watchers, instances of one systemd path unit, re-seal the loader when `limine.conf` is edited or the loader itself is replaced: Omarchy's installer leaves a pacman hook that copies a raw loader over it after every Limine upgrade. OmaSecBoot never blocks an update. On a machine where `setup` never ran, the hook exits on its first line.
- It keeps a few small files under `/var/lib/omasecboot` and works out everything else from what it observes, so an interrupted step is finished by running the same command again. A write error the ESP reports is the exception: no later run can see it again, so it stands until you have recovered the ESP and acknowledged it ([docs/recovery.md](docs/recovery.md#if-the-esp-reports-a-write-error)). A clean report proves what it names, the seal, the signatures and the settings, not that the machine will start or that the storage kept every write. It rebuilds the loader from the raw Limine executable that upstream keeps beside the loader, the one upstream deployed, and from the package's only where upstream kept no copy.

[docs/concepts.md](docs/concepts.md) explains the concepts a first reader needs. The design, every decision behind it and the failure table are in [docs/spec.md](docs/spec.md). The upstream behaviour it relies on, with sources, is in [docs/upstream-contracts.md](docs/upstream-contracts.md).

## What it never signs or registers

- **Snapshot images.** limine-snapper-sync keeps a hash of every snapshot image it stores. Signing one later would break that hash for good, so images from before setup stay as they are: they boot with Secure Boot off, `status` counts them, and snapshot rotation retires them. To be rid of one sooner, delete that snapshot (`sudo snapper -c root delete NUMBER`), which removes its entry within seconds.
- **The fallback loader** `EFI/BOOT/BOOTX64.EFI`. It stays the raw copy upstream deploys, your rescue loader with Secure Boot off ([docs/recovery.md](docs/recovery.md#if-the-machine-does-not-start)), which the firmware refuses while Secure Boot is on; where there is none, `setup` offers to add one through upstream's own tool. Where it was signed by hand, as upstream's comments suggest, `sign` restores the raw copy, since a signed fallback without a seal would start under Secure Boot without checking `limine.conf` ([D6](docs/spec.md#d6-the-fallback-loader-stays-raw)).
- **Microsoft's files and the 32-bit loader** `BOOTIA32.EFI`. Microsoft's files carry Microsoft's signature, and 64-bit firmware never starts the other.
- **A file that `limine.conf` names with a path hash.** A signature would change the file and make its entry stale. `setup` regenerates Limine's own entries without hashes; for an entry you wrote yourself it names the path and asks you to take the `#hash` off.
- **A Limine loader that is not sealed**, wherever it stands, such as the copy Omarchy 3 left in `EFI/arch-limine`. Signed, it would start under Secure Boot and read whatever `limine.conf` it finds without checking it; unsigned, the firmware refuses it. `status` names it. A file with Limine's marker whose seal cannot be told is not signed either, since what it would check cannot be known; the pass fails on it and `status` names it. Delete either if nothing starts from it; if another system starts from it, seal it over that system's `limine.conf` with that system's tools, and the next pass signs it.
- **sbctl's file list.** OmaSecBoot adds nothing to it. `setup` only removes rows for snapshot images, the fallback loader and any Limine executable, because sbctl's own pacman hook signs whatever stands at a row's path, a raw loader included.

Every other EFI program on the ESP that does not carry your signature is signed with your key, a memory tester or a second system's loader included, even one another key signed, such as a shim Microsoft signed; `status` names each.

## Requirements

Omarchy on x86_64 booted in UEFI mode, with Limine, unified kernel images (UKIs) and the EFI system partition (ESP) mounted as vfat and writable by root alone, which is how Omarchy installs. Besides the base system the package depends on `sbctl`, `limine`, `limine-mkinitcpio-hook`, `efibootmgr`, `jq`, `gum` and `diffutils`.

## Install

```bash
git clone --branch v0.1.1 https://github.com/peregrinus879/omasecboot
cd omasecboot
make package
sudo pacman -U omasecboot-0.1.1-1-any.pkg.tar.zst
```

`make package` needs `base-devel` and `git` and builds from the files of the checkout that git does not ignore. `make install` only stages a package and refuses the live system.

## Commands

| Command | What it does |
| --- | --- |
| `sudo omasecboot setup` | The one command you need; run it again after each step it asks for. It prepares the boot files, then takes one firmware step per run (below). |
| `sudo omasecboot status` | Reports the firmware, the settings, the boot files, rows in sbctl's file list that would do damage, the Windows entry, the hook and the watchers, and ends with the command that repairs what it found. Exit 0 healthy, 1 attention needed. `--quiet` prints nothing. |
| `sudo omasecboot sign` | The converge-and-verify pass that the hook and the watchers run: it proves the loader's seal and signature, rebuilds the loader when the proof fails, and signs what arrived unsigned. Safe at any time; exits 75 when another tool is working on the boot files. |
| `sudo omasecboot remove` | Returns the Limine settings and boot files to stock and takes the Windows entry out. Refuses while Secure Boot is on. Your keys stay. |
| `sudo omasecboot acknowledge ID` | Clears the ESP incident whose ID `status` prints, after the [recovery](docs/recovery.md#if-the-esp-reports-a-write-error), and nothing else. It records your decision and proves nothing about the ESP. |
| `omasecboot windows preflight` | Looks for Windows and BitLocker volumes and prints what to do in Windows before Secure Boot changes. Read-only. |
| `sudo omasecboot windows setup` | Adds a Windows entry to Limine's menu; `windows remove` takes it out. |
| `sudo omasecboot windows status` | Shows the Windows target the firmware offers and the state of the entry. |
| `sudo omasecboot windows bootnext` | Asks the firmware to start Windows at the next boot, once. Exit 0 means the firmware took the request, nothing more. |
| `omasecboot version` | Prints the version. `omasecboot help` prints the commands. |

What `setup` does, run by run:

1. First run: creates signing keys with sbctl if there are none, sets `ENABLE_ENROLL_LIMINE_CONFIG=yes` and `ENABLE_VERIFICATION=no` in `/etc/default/limine` (remembering what was there), regenerates Limine's menu entries when they still carry path hashes, offers to add the fallback loader when there is none, seals and signs the loader, signs anything that arrived unsigned, enables the watchers of `limine.conf` and the loader, backs up the firmware's keys and tells you to delete only the Platform Key in the firmware and to leave Secure Boot disabled when you save.
2. Next run, in Setup Mode: enrolls your keys as described below.
3. After a restart it tells you to turn Secure Boot on.

A healthy machine with Windows beside it reads, for example, like this:

```text
$ sudo omasecboot status

OmaSecBoot - Status

  ✓ Secure Boot is on
  ✓ Your keys are enrolled in the firmware
  ✓ ENABLE_VERIFICATION=no is in effect
  ✓ ENABLE_ENROLL_LIMINE_CONFIG=yes is in effect
  ✓ The Limine loader is sealed over the current limine.conf and signed
  ✓ The fallback loader is upstream's raw copy, the rescue loader when Secure Boot is off
  ✓ sbctl's signing keys exist
  ✓ Signed: /boot/EFI/Linux/omarchy_linux-omarchy.efi
  ✓ Signed: /boot/EFI/limine/limine_x64.efi
  ✓ The Windows entry restarts the machine into Windows Boot Manager
  ✓ The Limine hook is installed
  ✓ The watchers of limine.conf and the loader are active
  → Nothing to do
```

A line that starts with `✗` is a problem, `·` is a note and `!` a warning, and the `→` lines at the end say what to do next and, where a problem stops a start, not to reboot.

## How your keys get into the firmware

`setup` appends: it adds your certificates to the firmware's key exchange list (KEK) and its list of trusted signers (db) beside the entries already there, the manufacturer's and Microsoft's included, and replaces only the Platform Key (PK), which you delete yourself in the firmware's key menu. The revocation list (dbx) is never written. Before it asks you to delete anything it copies PK, KEK, db and dbx byte for byte to `/var/lib/omasecboot/firmware-backup/`, and before it writes it refuses when more than the Platform Key is gone or dbx changed since the backup. Key menus differ by model and firmware version: find the entry that deletes the Platform Key alone before you run `setup`. Firmware that clears every key with the Platform Key gets an offer to rebuild KEK and db instead, with a list of the backup entries a rebuild cannot bring back. [D9](docs/spec.md#d9-keys-are-enrolled-by-appending) owns the rules, and [docs/concepts.md](docs/concepts.md#owning-the-platform-key) what owning the Platform Key means.

## Windows

With Windows beside Omarchy, have its BitLocker or Device Encryption recovery key at hand before any firmware step: deleting the Platform Key, writing keys and turning Secure Boot on or off each change what Windows measures, and Windows may then ask for the key. `setup` asks about it before the first two and reminds you before the others. `omasecboot windows preflight` looks for Windows and BitLocker volumes and prints the optional `manage-bde` steps that avoid the prompt. Why the key is needed is in [docs/concepts.md](docs/concepts.md#windows-measurements-and-the-recovery-key), and what BitLocker did on the recorded machine in [C10](docs/upstream-contracts.md#c10-hardware-record).

`sudo omasecboot windows setup` adds a Windows entry to Limine's menu that restarts the machine into the firmware's own Windows Boot Manager entry instead of chainloading it ([D11](docs/spec.md#d11-windows-starts-through-the-firmware-never-through-a-chainload)). The entry stays behind Omarchy's entries, and the next pass puts it back after Omarchy replaces `limine.conf`. With an encrypted Windows, start it through the firmware only: an entry that `limine-scan` added chainloads Windows through Limine, and there BitLocker asked for the recovery key at every change between the two ways; `status` names such an entry beside a BitLocker volume and prints the command that takes it out. The target is read from the firmware's boot entries every time, and the tool never creates or renames firmware entries or reads a Windows partition.

`sudo omasecboot windows bootnext` asks the firmware to start Windows at the next boot, once, without the menu; it does not restart the machine. The package ships a "Reboot to Windows" row for Omarchy's menu as `/usr/share/doc/omasecboot/omarchy-menu.jsonc`; merge it into `~/.config/omarchy/extensions/omarchy-menu.jsonc` to use it.

## When something goes wrong

`sudo omasecboot status` ends with what to do and says whether a restart is at risk; restart only when `sudo omasecboot status --quiet` exits 0, or where a procedure here says so. [docs/recovery.md](docs/recovery.md), installed as `/usr/share/doc/omasecboot/docs/recovery.md`, is the way back: [if the machine does not start](docs/recovery.md#if-the-machine-does-not-start), [if the ESP reports a write error](docs/recovery.md#if-the-esp-reports-a-write-error), and [what each message means](docs/recovery.md#messages-and-what-to-do).

## Removing it

Before: `sudo omasecboot status` does not say "Do not reboot, with Secure Boot on or off"; where it does, follow what it says first. With an encrypted Windows beside it, have the recovery key at hand, since turning Secure Boot off is where BitLocker asked on the recorded machine. Open the firmware, turn Secure Boot off and start Omarchy:

```bash
systemctl reboot --firmware-setup
```

Then:

```bash
sudo omasecboot remove && sudo pacman -R omasecboot
```

`remove` refuses while Secure Boot is on, and exits 1 while an ESP write error stands, which keeps the package for the [recovery](docs/recovery.md#if-the-esp-reports-a-write-error); pacman warns when the package goes from a machine that is still set up, because nothing would then re-seal the loader after an edit of `limine.conf` or repair it after the next Limine upgrade. The state directory and your sbctl keys stay on disk, and so does a fallback loader that `setup` added. Your certificates stay in the firmware until you restore the factory keys in its key menu, and while sbctl's keys stay, upstream signs the Limine loader at every Limine operation, without a seal unless `ENABLE_ENROLL_LIMINE_CONFIG=yes` is in effect: keep Secure Boot off until the factory keys are back. `remove` and `status` say so.

Before Omarchy's Reset Computer, or before the machine changes hands, do the same, then restore the factory keys in the firmware's key menu: the reset keeps neither sbctl nor this tool, rebuilds the boot files unsigned, and would leave your certificate trusted by the firmware.

`remove` runs upstream's `limine-install`, which writes upstream's fallback loader over whatever stands at `EFI/BOOT/BOOTX64.EFI` when `ENABLE_LIMINE_FALLBACK=yes` is in effect ([D6](docs/spec.md#d6-the-fallback-loader-stays-raw)). Where another system's loader stands there with `yes` in effect, `remove` says so before its question: answer no, set `ENABLE_LIMINE_FALLBACK=no` in `/etc/default/limine`, the layer that wins over the others, and run `remove` again.

## Limits

- The Omarchy installer ISO does not boot under Secure Boot; OmaSecBoot is for installed systems.
- Signing and sealing address changes made to the boot files while the system is off, as far as upstream's design allows. The raw loader that every Limine operation seals and signs comes from a backup on the ESP that nothing authenticates, and OmaSecBoot rebuilds from the same file: it adds no source of trust and removes none. A pass signs what it finds: every EFI program on the ESP that arrived unsigned, and whatever `limine.conf` holds is sealed, without knowing where either came from. Root, and physical access with the firmware's credentials, are trusted. Microsoft's certificates stay in db, so the firmware still starts any other system that Microsoft signed: OmaSecBoot protects Omarchy's own boot chain, and does not lock the machine to it ([docs/spec.md](docs/spec.md), section 3).
- Your keys being enrolled does not mean Secure Boot is on; `status` reports both.
- fwupd's firmware updates need its helper signed outside the ESP, which the pass never looks at: `sudo sbctl sign -s -o /usr/lib/fwupd/efi/fwupdx64.efi.signed /usr/lib/fwupd/efi/fwupdx64.efi`, and `DisableShimForSecureBoot=true` in fwupd's configuration, then restart fwupd ([docs/spec.md](docs/spec.md), 7.5).
- After the Platform Key is yours, updates that the manufacturer signs with its own Platform Key no longer apply. Microsoft's KEK entries stay, so the db and dbx updates that Microsoft signs can still be applied, as long as KEK holds Microsoft's 2023 certificate: the 2011 one has expired (C9 of [docs/upstream-contracts.md](docs/upstream-contracts.md)). `setup` warns before you delete the Platform Key when KEK lacks that certificate, because the manufacturer's updates are the easy way to get it, and `status` names any of Microsoft's 2023 certificates that KEK or db lack.
- The backup under `/var/lib/omasecboot/firmware-backup/` is what this machine trusted before the change, not a factory key set. OmaSecBoot never writes dbx and restores no firmware keys; the firmware's own key menu does that.
- Your signing keys under `/var/lib/sbctl` and the firmware backup live on the root filesystem and go back in time with a snapshot restore. Keep a copy of both off the machine. The backup's `PK`, `KEK`, `db` and `dbx` are each the variable as efivarfs shows it, four attribute bytes and then the signature list; a firmware's key menu that enrolls from a file takes the list alone, `sudo tail -c +5 FILE >NAME.esl`, where it takes that format at all.
- A BootNext request is one boot. It does not prove that Windows started, keep BitLocker quiet or keep its measurements stable, and a clean `windows preflight` means that no encrypted Windows was found, not that there is none.
- A full snapshot restore works on the boot files without the lock the Limine tools share, so the hook and the watchers leave them alone while it runs, and nothing runs when it ends. After a restore, run `sudo omasecboot sign`; `status` says so while the restore lock stands.
- A snapshot older than `setup` takes the tool, the keys and the settings with it when it is restored, while the ESP and the firmware keep the signed state. Keep Secure Boot off after such a restore until `setup` has run again.
- A kernel image that is rebuilt and signed again never deduplicates against its predecessor in the snapshot history, because every signature differs, so the ESP fills faster than before. `status` says when less space is free than the largest boot file needs; deleting old snapshots frees it.

## Help test it

Boot behaviour has a record from one machine only, so every further machine counts. [docs/field-testing.md](docs/field-testing.md) walks you through a test in three levels, the first of which changes no Secure Boot key or setting in the firmware and ends with everything returned to stock. It records every step and ends with a report whose attachments have your host and login names, machine-id and UUIDs renamed.

## Development

```bash
make lint            # bash -n, ShellCheck and the JSONC fragment
make test            # hermetic suites and the package build, a few minutes
make test-mutations  # each listed safety predicate disabled in turn: its case must fail
make test-contract   # the installed sbctl, Limine tools and findmnt against the upstream contracts, in a sandbox
```

[CONTRIBUTING.md](CONTRIBUTING.md) has the principles, the layout, the conventions and how changes are verified. What a release needs is in [docs/release-checklist.md](docs/release-checklist.md), open work and recheck triggers are in [docs/maintenance.md](docs/maintenance.md), and what lives on Omarchy's side is in [docs/omarchy-integration.md](docs/omarchy-integration.md).

## Licence and credits

[MIT](LICENSE). Created by [peregrinus879](https://github.com/peregrinus879). OmaSecBoot builds on [sbctl](https://github.com/Foxboron/sbctl), [Limine](https://github.com/limine-bootloader/limine), Zesko's [limine-entry-tool](https://gitlab.com/Zesko/limine-entry-tool) and [limine-snapper-sync](https://gitlab.com/Zesko/limine-snapper-sync), and [Omarchy](https://omarchy.org).
