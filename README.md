# OmaSecBoot

[![CI](https://github.com/peregrinus879/omasecboot/actions/workflows/ci.yml/badge.svg)](https://github.com/peregrinus879/omasecboot/actions/workflows/ci.yml)
[![Upstream contracts](https://github.com/peregrinus879/omasecboot/actions/workflows/contracts.yml/badge.svg)](https://github.com/peregrinus879/omasecboot/actions/workflows/contracts.yml)

**Secure Boot for [Omarchy](https://omarchy.org) with your own keys.**

OmaSecBoot is an opt-in package for installed Omarchy systems. It leaves the work to the tools Omarchy already ships, sbctl and the Limine tools, fills the gaps between them, checks what they did, and tells you the truth about the result.

> [!CAUTION]
> **Status:** 0.1.0 is the first release. One machine, an ASUS Vivobook TP3402VA, has run stages 0 to 7 of the hardware acceptance in [docs/release-checklist.md](docs/release-checklist.md), from a stock baseline through `remove` and back to set up, on commit `2a8d324`, with Secure Boot on and Windows Home's device encryption on beside it. One change to the tool followed that run and has its hermetic proof but no hardware row yet (C10). What it showed is in section C10 of [docs/upstream-contracts.md](docs/upstream-contracts.md), and the evidence still owed is in [docs/maintenance.md](docs/maintenance.md). No other firmware has a record. Use the tool only on a machine you can afford to recover; [docs/field-testing.md](docs/field-testing.md) is how another machine gets its record.

## Why

Omarchy boots through Limine with unified kernel images and Snapper snapshot entries, and its manual tells users to turn Secure Boot off. The pieces for Secure Boot with your own keys all exist, and none of them closes the gaps between them:

- **sbctl** creates keys, signs EFI files and enrolls keys, but it knows nothing about Limine's configuration, and its enrollment replaces what the firmware trusts unless it is told otherwise.
- **The Limine tools** can seal the loader over `limine.conf` and sign it, but the feature is off by default and its failures are hidden.
- **Windows dual boot** adds BitLocker, which can react to a change of the firmware's keys or of Secure Boot's state.

## How it works

- sbctl signs each new kernel image while it is built, and Limine's own hook seals the loader: it writes a checksum of `limine.conf` into the Limine executable, so the loader refuses to start on a `limine.conf` it was not sealed over. OmaSecBoot turns those two upstream features on, proves after every change that they really happened, and repairs the loader when they did not.
- It integrates in two places only. A small Limine hook runs at the end of every Limine operation (kernel updates, Limine upgrades, snapshots). Two watchers, instances of one systemd path unit, re-seal the loader when `limine.conf` is edited or the loader itself is replaced: Omarchy's installer leaves a pacman hook that copies a raw loader over it after every Limine upgrade. OmaSecBoot never blocks an update. On a machine where `setup` never ran, the hook exits on its first line.
- It keeps a few small files under `/var/lib/omasecboot` and works out everything else from what it observes, so any interrupted step is finished by running the same command again. It rebuilds the loader from the raw Limine executable that upstream keeps beside the loader, the one upstream deployed, never from a newer one in the package that upstream is holding back.

The design, every decision behind it and the failure table are in [docs/spec.md](docs/spec.md). The upstream behaviour it relies on, with sources, is in [docs/upstream-contracts.md](docs/upstream-contracts.md).

## What it never signs or registers

- **Snapshot images.** limine-snapper-sync keeps a hash of every snapshot image it stores. Signing one later would break that hash for good, so images from before setup stay as they are: they boot with Secure Boot off, `status` counts them, and snapshot rotation retires them. To be rid of one sooner, delete that snapshot (`sudo snapper -c root delete NUMBER`), which removes its entry within seconds.
- **The fallback loader** `EFI/BOOT/BOOTX64.EFI`. It stays the raw copy upstream deploys; where there is none, `setup` offers to add one through upstream's own tool. The firmware refuses it while Secure Boot is on, and with Secure Boot off it is your rescue loader ([If the machine does not start](#if-the-machine-does-not-start)). The comments in upstream's `/etc/limine-entry-tool.conf` suggest signing it by hand; `sign` undoes that, because a fallback that is signed but not sealed would start under Secure Boot without enforcing `limine.conf`.
- **Microsoft's files and the 32-bit loader** `BOOTIA32.EFI`. Microsoft's files carry Microsoft's signature, and 64-bit firmware never starts the other.
- **A file that `limine.conf` names with a path hash.** A signature would change the file and make its entry stale. `setup` regenerates Limine's own entries without hashes; for an entry you wrote yourself it names the path and asks you to take the `#hash` off.
- **sbctl's file list.** OmaSecBoot adds nothing to it. `setup` only removes rows for snapshot images and the fallback loader, which sbctl's own pacman hook would otherwise sign in place.

Every other EFI program on the ESP that arrives unsigned is signed, a memory tester or a second system's loader included, and `status` names each.

## Requirements

Omarchy on x86_64 booted in UEFI mode, with Limine, unified kernel images (UKIs) and the EFI system partition (ESP) mounted as vfat, which is how Omarchy installs. Besides the base system the package depends on `sbctl`, `limine`, `limine-mkinitcpio-hook`, `efibootmgr`, `jq` and `gum`.

## Install

```bash
git clone --branch v0.1.0 https://github.com/peregrinus879/omasecboot
cd omasecboot
make package
sudo pacman -U omasecboot-0.1.0-1-any.pkg.tar.zst
```

`make package` needs `base-devel` and `git` and builds from the files of the checkout that git does not ignore. `make install` only stages a package and refuses the live system.

## Commands

| Command | What it does |
| --- | --- |
| `sudo omasecboot setup` | The one command you need; run it again after each step it asks for. It prepares the boot files, then takes one firmware step per run (below). |
| `sudo omasecboot status` | Reports the firmware, the settings, the boot files, rows in sbctl's file list that would do damage, the Windows entry, the hook and the watchers, and ends with the command that repairs what it found. Exit 0 healthy, 1 attention needed. `--quiet` prints nothing. |
| `sudo omasecboot sign` | The converge-and-verify pass that the hook and the watchers run: it proves the loader's seal and signature, rebuilds the loader when the proof fails, and signs what arrived unsigned. Safe at any time; exits 75 when another tool is working on the boot files. |
| `sudo omasecboot remove` | Returns the Limine settings and boot files to stock and takes the Windows entry out. Refuses while Secure Boot is on. Your keys stay. |
| `omasecboot windows preflight` | Looks for Windows and BitLocker volumes and prints what to do in Windows before Secure Boot changes. Read-only. |
| `sudo omasecboot windows setup` | Adds a Windows entry to Limine's menu; `windows remove` takes it out. |
| `sudo omasecboot windows status` | Shows the Windows target the firmware offers and the state of the entry. |
| `sudo omasecboot windows bootnext` | Asks the firmware to start Windows at the next boot, once. Exit 0 means the firmware took the request, nothing more. |
| `omasecboot version` | Prints the version. `omasecboot help` prints the commands. |

What `setup` does, run by run:

1. First run: creates signing keys with sbctl if there are none, sets `ENABLE_ENROLL_LIMINE_CONFIG=yes` and `ENABLE_VERIFICATION=no` in `/etc/default/limine` (remembering what was there), regenerates Limine's menu entries when they still carry path hashes, offers to add the fallback loader when there is none, seals and signs the loader, signs anything that arrived unsigned, enables the watchers of `limine.conf` and the loader, backs up the firmware's keys and tells you to delete only the Platform Key in the firmware and to leave Secure Boot disabled when you save.
2. Next run, in Setup Mode: enrolls your keys as described below.
3. After a restart it tells you to turn Secure Boot on.

A healthy machine with Windows beside it reads like this:

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

A line that starts with `✗` is a problem, and the `→` lines at the end say what to do next.

## How your keys get into the firmware

OmaSecBoot appends: it adds your certificates to the entries the firmware already holds in its key exchange list (KEK) and its list of trusted signers (db), and replaces only the Platform Key (PK), which you delete yourself in the firmware's key menu. The manufacturer's and Microsoft's certificates stay, including any that Windows or a firmware update added, and the revocation list (dbx) is never written. Before it asks you to delete anything it copies PK, KEK, db and dbx byte for byte to `/var/lib/omasecboot/firmware-backup/`, and before it writes it compares the firmware with that backup and refuses when more than the Platform Key is gone. Each variable is written on its own and read back, so an interrupted run is finished by running `setup` again.

Some firmware clears every key when it enters Setup Mode. Adding your certificates to empty lists would leave the machine without the certificates its option ROMs and Windows need, so `setup` never does that: it offers to rebuild KEK and db from your certificates, Microsoft's and the firmware's built-in defaults (Microsoft's alone where the firmware does not expose its defaults), and first lists every backup entry that this cannot bring back. Anything in between, some entries gone and others kept, is refused with the list and the way back.

## Windows

On a dual-boot machine `setup` asks one question before it tells you to delete the Platform Key and one before it writes your keys: whether the Windows recovery key is at hand, or there is no encrypted Windows on the machine. Both steps change what Windows measures at boot, and so does turning Secure Boot on or off; `setup` reminds you before it tells you to turn it on. After any of them BitLocker or Device Encryption may ask for the recovery key. The key is what you must have: with it a prompt is an inconvenience, without it a lockout. Disabling BitLocker's protectors before the change and enabling them afterwards only avoids the prompt; the tool works the same either way. `omasecboot windows preflight` prints the two `manage-bde` commands, which work on every edition of Windows; a machine without Windows is asked nothing. On the recorded machine BitLocker asked at one kind of change only, Secure Boot going from on to off while it was bound to PCR 7 and 11, and at none of the key changes made with Secure Boot off. When Secure Boot went on, Windows kept the binding it had, to PCR 0, 2, 4 and 11; after its protectors were disabled and enabled once it bound to PCR 7 and 11 with your keys, Microsoft's default, which is the binding that asks when Secure Boot is turned off again.

`sudo omasecboot windows setup` adds a Windows entry to Limine's menu. It uses Limine's `efi_boot_entry` protocol, which restarts the machine into the firmware's own "Windows Boot Manager" entry instead of chainloading it, so Windows starts the way it does when you pick it in the firmware and, by Microsoft's and the TCG's documents, nothing of Limine's is then in what BitLocker measures ([docs/spec.md](docs/spec.md), D11). On the recorded machine BitLocker did not tell this entry, a BootNext request and the firmware's boot menu apart. An entry that `limine-scan` added chainloads Windows through Limine, and there BitLocker asked for the recovery key at every change between the two ways: with an encrypted Windows, start it through the firmware only, the way that stayed quiet while the loader was sealed again. `status` says so when it finds such an entry beside a BitLocker volume, and prints upstream's command that takes it out. The entry stays behind Omarchy's entries, so Omarchy's default and its timeout are unchanged; `status` says so if it ever stands before them. The target is read from the firmware's boot entries every time: exactly one active Windows Boot Manager entry that the firmware's boot order lists, with a name no other entry shares, or the command refuses. The tool only ever deletes an entry that holds nothing but what it wrote. The tool never creates or renames firmware entries and never mounts or reads a Windows partition. When Omarchy replaces `limine.conf` from its template, the next `sign` pass puts the entry back.

`sudo omasecboot windows bootnext` asks the firmware to start Windows at the next boot, once, without the menu; it does not restart the machine. The package ships a "Reboot to Windows" row for Omarchy's menu as `/usr/share/doc/omasecboot/omarchy-menu.jsonc`; merge it into your own Omarchy menu extensions to use it.

## If the machine does not start

A sealed Limine loader refuses to start when `limine.conf` no longer matches its checksum, with Secure Boot on or off. The watchers and the hook keep them in step; if a change slipped through:

1. Turn Secure Boot off in the firmware.
2. In the firmware's boot menu pick the fallback loader (`EFI/BOOT/BOOTX64.EFI`, listed under the disk's name or a label of the firmware's own, "UEFI OS" on the recorded machine). It is not sealed and boots normally. With an encrypted Windows beside it, have the recovery key at hand: turning Secure Boot off changes what Windows measures.
3. If you did not change `limine.conf` yourself, read it first: `sign` seals the loader over whatever it holds. Then run `sudo omasecboot sign` and turn Secure Boot back on.

Omarchy installed beside another system starts without a fallback loader, and then step 2 needs rescue media. `setup` offers to add one through `limine-install --fallback`, only while nothing stands at that path, and warns while there is none or while another system's loader stands there.

From rescue media (the Omarchy installer on a USB stick), put a raw loader over the Limine loader; a raw loader checks nothing and starts:

```bash
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME
mount /dev/<the EFI system partition> /mnt
tar -xf /mnt/EFI/limine/limine_x64.bak -C /mnt/EFI/limine limine_x64.efi
```

If there is no `limine_x64.bak`, or tar reports an error, a live system that has the `limine` package holds the same executable at `/usr/share/limine/BOOTX64.EFI` (`pacman -Qo` that path says whether yours does; with a network, `pacman -Sy limine` puts it there): `cp /usr/share/limine/BOOTX64.EFI /mnt/EFI/limine/limine_x64.efi`. That is the packaged raw loader of the live system's Limine version, which normally starts the kernel images. Do not copy `/mnt/EFI/BOOT/BOOTX64.EFI` over it, which on a machine installed beside another system may be that system's. When the loader is in place, `umount /mnt`. Then start Omarchy with Secure Boot off and run `sudo omasecboot sign`, or go on to [Removing it](#removing-it).

If only the newest kernel is refused, boot a snapshot entry or turn Secure Boot off, then run `sudo omasecboot sign`.

## Troubleshooting

| Message or symptom | Meaning | What to do |
| --- | --- | --- |
| `The Limine loader is not sealed over the current limine.conf` | The loader would refuse to start, with Secure Boot on or off | `sudo omasecboot sign` before you reboot. If the machine is already down, see [If the machine does not start](#if-the-machine-does-not-start) |
| `The Limine loader is sealed over the current limine.conf but not signed` | It starts with Secure Boot off only | `sudo omasecboot sign` |
| `OmaSecBoot could not finish`, a red line after an update | The pass inside the update could not prove the boot files | `sudo omasecboot status`, then the command it names. Do not reboot with Secure Boot on until the report is clean |
| `The firmware has no active boot entry for the Limine loader` | The machine starts through the fallback path, which stays raw and is refused with Secure Boot on | Keep Secure Boot off, run `sudo limine-install`, check with `efibootmgr` that a Limine entry exists, then `sudo omasecboot setup` |
| `Stale path hash in limine.conf` | An OS entry still carries a hash of a file that has changed since | `sudo omasecboot setup`, which regenerates the entries |
| `Secure Boot is on, but the firmware does not hold your keys` | A firmware update or a CMOS reset put the factory keys back | Turn Secure Boot off, then `sudo omasecboot setup` |
| `sbctl has no signing keys` | The keys under `/var/lib/sbctl` are gone | Restore them from a snapshot or backup. With new keys, the firmware needs another round of `setup` |
| `limine.conf holds OmaSecBoot's Windows comment in an entry that is not as OmaSecBoot writes it` | The `/Windows` entry was edited by hand, or its comment line ended up in another entry | Remove that comment line, or the entry, then `sudo omasecboot sign` |
| `An earlier setup or remove did not finish` | One of the two stopped half way, for example when a Limine tool failed | `sudo omasecboot remove` to return to stock, or `sudo omasecboot setup` to set up again |
| `The firmware's keys are in a state OmaSecBoot will not write to` | The firmware's key menu removed more than the Platform Key | Restore the factory keys in the firmware, run `sudo omasecboot setup`, then delete only the Platform Key |
| `Boot files are busy` (exit 75) | Another tool holds the boot lock; a kernel install held it for a minute on the recorded machine | Run the command again when that tool has finished. Nothing failed |
| A snapshot entry stops at `PANIC: efi: LoadImage failure` with Secure Boot on | The snapshot image predates setup and is unsigned, so the firmware refuses it and Limine halts | Hold the power button, start again and pick another entry |
| A snapshot restore prints `Limine v12 requires verification hashes` and advises `ENABLE_VERIFICATION=yes` | The Limine tools' own check, which does not see Omarchy's UKI setting during a restore. The entries are UKIs, which the firmware verifies by signature | Nothing. `ENABLE_VERIFICATION=no` is one of the two settings `setup` manages, and the next `sign` writes it back if it is changed |

## Removing it

Turn Secure Boot off, run `sudo omasecboot remove`, then `sudo pacman -R omasecboot`. With an encrypted Windows beside it, have the recovery key at hand: turning Secure Boot off is where BitLocker asked on the recorded machine. In that order: pacman warns when the package goes while the machine is still set up, because nothing would then re-seal the loader after an edit of `limine.conf` or repair it after the next Limine upgrade. The state directory and your sbctl keys stay on disk, and so does a fallback loader that `setup` added. Your certificates stay in the firmware until you restore the factory keys in its own key menu.

## Limits

- The Omarchy installer ISO does not boot under Secure Boot; OmaSecBoot is for installed systems.
- Signing and sealing address changes made to the boot files while the system is off, as far as upstream's design allows. The raw loader that every Limine operation seals and signs comes from a backup on the ESP that nothing authenticates, and OmaSecBoot rebuilds from the same file: it adds no source of trust and removes none. A pass signs what it finds: every EFI program on the ESP that arrived unsigned, and whatever `limine.conf` holds is sealed, without knowing where either came from. Root, and physical access with the firmware's credentials, are trusted. Microsoft's certificates stay in db, so the firmware still starts any other system that Microsoft signed: OmaSecBoot protects Omarchy's own boot chain, and does not lock the machine to it ([docs/spec.md](docs/spec.md), section 3).
- Your keys being enrolled does not mean Secure Boot is on; `status` reports both.
- After the Platform Key is yours, updates that the manufacturer signs with its own Platform Key no longer apply. Microsoft's KEK entries stay, so the db and dbx updates that Microsoft signs can still be applied, as long as KEK holds Microsoft's 2023 certificate: the 2011 one expired in June 2026. `setup` warns before you delete the Platform Key when KEK lacks that certificate, because the manufacturer's updates are the easy way to get it, and `status` names any of Microsoft's 2023 certificates that KEK or db lack.
- The backup under `/var/lib/omasecboot/firmware-backup/` is what this machine trusted before the change, not a factory key set. OmaSecBoot never writes dbx and restores no firmware keys; the firmware's own key menu does that.
- Your signing keys under `/var/lib/sbctl` and the firmware backup live on the root filesystem and go back in time with a snapshot restore. Keep a copy of both off the machine.
- A BootNext request is one boot. It does not prove that Windows started, keep BitLocker quiet or keep its measurements stable, and a clean `windows preflight` means that no encrypted Windows was found, not that there is none.
- A full snapshot restore works on the boot files without the lock the Limine tools share, so the hook and the watchers leave them alone while it runs, and nothing runs when it ends. After a restore, run `sudo omasecboot sign`; `status` says so while the restore lock stands.
- A snapshot older than `setup` takes the tool, the keys and the settings with it when it is restored, while the ESP and the firmware keep the signed state. Keep Secure Boot off after such a restore until `setup` has run again.
- A kernel image that is rebuilt and signed again never deduplicates against its predecessor in the snapshot history, because every signature differs, so the ESP fills faster than before. `status` says when less space is free than the largest boot file needs; deleting old snapshots frees it.

## Help test it

Boot behaviour is proved only on the one machine recorded, so every further machine counts. [docs/field-testing.md](docs/field-testing.md) walks you through a test in three levels, the first of which changes no Secure Boot key or setting in the firmware and ends with everything returned to stock. It records every step and ends with a report whose attachments have your host and login names, machine-id and UUIDs renamed.

## Development

```bash
make lint            # bash -n, ShellCheck and the JSONC fragment
make test            # hermetic suites and the package build, about a minute
make test-contract   # the installed sbctl and Limine tools against the upstream contracts, in a sandbox
```

[CONTRIBUTING.md](CONTRIBUTING.md) has the principles, the layout, the conventions and how changes are verified. What a release needs is in [docs/release-checklist.md](docs/release-checklist.md), open work and recheck triggers are in [docs/maintenance.md](docs/maintenance.md), and what lives on Omarchy's side is in [docs/omarchy-integration.md](docs/omarchy-integration.md).

## Licence and credits

[MIT](LICENSE). Created by [peregrinus879](https://github.com/peregrinus879). OmaSecBoot builds on [sbctl](https://github.com/Foxboron/sbctl), [Limine](https://github.com/limine-bootloader/limine), Zesko's [limine-entry-tool](https://gitlab.com/Zesko/limine-entry-tool) and [limine-snapper-sync](https://gitlab.com/Zesko/limine-snapper-sync), and [Omarchy](https://omarchy.org).
