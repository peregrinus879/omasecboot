# OmaSecBoot

**Secure Boot for [Omarchy](https://omarchy.com) with your own keys.**

OmaSecBoot is an opt-in package for installed Omarchy systems. It leaves the work to the tools Omarchy already ships, sbctl and the Limine tooling, fills the gaps between them, checks what they did, and tells you the truth about the result.

> [!CAUTION]
> **Development status:** no release exists. One machine, an ASUS Vivobook TP3402VA, has run the hardware acceptance in [docs/release-checklist.md](docs/release-checklist.md) from `setup` to `remove`, with Secure Boot on and Windows beside it. What it showed is in section C6 of [docs/upstream-contracts.md](docs/upstream-contracts.md), and the rows it still owes are in [docs/maintenance.md](docs/maintenance.md). No other firmware has a record. Use the tool only on a machine you can afford to recover; [docs/field-testing.md](docs/field-testing.md) is how another machine gets its record.

## Why

Omarchy boots through Limine with unified kernel images and Snapper snapshot entries, and its manual tells users to turn Secure Boot off. The pieces for Secure Boot with your own keys all exist, and none of them closes the gaps between them:

- **sbctl** creates keys, signs EFI files and enrolls keys, but it knows nothing about Limine's configuration, and its enrollment replaces what the firmware trusts unless it is told otherwise.
- **The Limine tools** can seal the loader over `limine.conf` and sign it, but the feature is off by default and its failures are hidden.
- **Windows dual boot** adds BitLocker, which reacts to every change of the firmware's keys.

OmaSecBoot fills those gaps for this exact stack and leaves everything else to the tools Omarchy already ships.

## How it works

- sbctl signs each new kernel image while it is built, and Limine's own hook seals the loader: it writes a checksum of `limine.conf` into the Limine executable, so nobody can change your boot entries from outside the running system. OmaSecBoot turns those two upstream features on, proves after every change that they really happened, and repairs the loader when they did not.
- It integrates in two places only. A small Limine hook runs at the end of every Limine operation (kernel updates, Limine upgrades, snapshots, restores), and a systemd path unit re-seals the loader when `limine.conf` is edited or the loader itself is replaced, which the pacman hook that Omarchy's installer leaves does after every Limine upgrade. It never blocks an update. On a machine where `setup` never ran, the hook exits on its first line.
- It keeps a few small files under `/var/lib/omasecboot` and works out everything else from what it observes, so any interrupted step is finished by running the same command again. It rebuilds the loader from the raw Limine executable that upstream deployed, never from a newer one upstream is holding back.

The design, every decision behind it and the failure table are in [docs/spec.md](docs/spec.md). The upstream behaviour it relies on, with sources, is in [docs/upstream-contracts.md](docs/upstream-contracts.md).

## Requirements

Omarchy on x86_64 booted in UEFI mode, with Limine, unified kernel images and the ESP mounted as vfat, which is how Omarchy installs. Besides the base system the package depends on `sbctl`, `limine`, `limine-mkinitcpio-hook`, `efibootmgr`, `jq` and `gum`.

## Install

```bash
make package
sudo pacman -U omasecboot-*-any.pkg.tar.zst
```

`make package` needs `base-devel` and git and builds from the files of the checkout that git does not ignore. `make install` only stages a package and refuses the live system.

## Commands

| Command | What it does |
| --- | --- |
| `sudo omasecboot setup` | The one command you need; run it again after each step it asks for. First run: creates signing keys with sbctl if there are none, sets `ENABLE_ENROLL_LIMINE_CONFIG=yes` and `ENABLE_VERIFICATION=no` in `/etc/default/limine` (remembering what was there), regenerates the boot entries when they still carry path hashes, seals and signs the loader, signs anything that arrived unsigned, enables the watchers of `limine.conf` and the loader, backs up the firmware's keys and tells you to delete only the Platform Key in the firmware. Next run, in Setup Mode: enrolls your keys as described below. After a reboot it tells you to turn Secure Boot on. |
| `sudo omasecboot status` | Reports the firmware state, the settings, the loader proof, the fallback loader, the keys, every signable file, stale hashes, harmful sbctl rows, the Windows entry, the hook and the watchers, and leftovers of an earlier install, and ends with the command that repairs what it found. Exit 0 healthy, 1 attention needed. `--quiet` prints nothing. |
| `sudo omasecboot sign` | The same converge-and-verify pass the hook runs. Safe at any time; exits 75 when another tool is working on the boot files. |
| `sudo omasecboot remove` | Returns the Limine settings and boot files to stock and takes the Windows entry out. Refuses while Secure Boot is on. Your keys stay. |
| `omasecboot windows preflight` | Looks for Windows and BitLocker volumes and prints what to do in Windows before Secure Boot changes. Read-only. |
| `sudo omasecboot windows setup` | Adds a Windows entry to the boot menu; `windows remove` takes it out. |
| `sudo omasecboot windows status` | Shows the Windows target the firmware offers and the state of the entry. |
| `sudo omasecboot windows bootnext` | Asks the firmware to start Windows at the next boot, once. Exit 0 means the firmware took the request, nothing more. |

## How your keys get into the firmware

OmaSecBoot appends: it adds your certificates to the KEK and db entries the firmware already holds and replaces only the Platform Key, which you delete yourself in the firmware's menu. The manufacturer's and Microsoft's certificates stay, including any that Windows or a firmware update added, and the revocation list (dbx) is never written. Before it asks you to delete anything it copies PK, KEK, db and dbx byte for byte to `/var/lib/omasecboot/firmware-backup/`, and before it writes it compares the firmware with that backup and refuses when more than the Platform Key is gone. Each variable is written on its own and read back, so an interrupted run is finished by running `setup` again.

Some firmware clears every key when it enters Setup Mode. Adding your certificates to empty lists would leave the machine without the certificates its option ROMs and Windows need, so `setup` never does that: it offers to rebuild KEK and db from your certificates, Microsoft's and the firmware's built-in defaults (Microsoft's alone where the firmware does not expose its defaults), and first lists every backup entry that this cannot bring back. Anything in between, some entries gone and others kept, is refused with the list and the way back.

## Windows

On a dual-boot machine `setup` asks one question before it tells you to delete the Platform Key and one before it writes your keys: whether Windows encryption is suspended or off, or its recovery key at hand. Both steps change what Windows measures at boot, and BitLocker or Device Encryption may then ask for the recovery key. `omasecboot windows preflight` prints the steps for Windows Pro and Home; a machine without Windows is asked nothing.

`sudo omasecboot windows setup` adds a Windows entry to Limine's menu. It uses Limine's `efi_boot_entry` protocol, which restarts the machine into the firmware's own "Windows Boot Manager" entry instead of chainloading it, so Windows starts the way it does when you pick it in the firmware. The target is read from the firmware's boot entries every time: exactly one active Windows Boot Manager entry with a name no other entry shares, or the command refuses. `limine.conf` is only ever changed together with the loader's seal over it, or while the loader carries no seal at all, and the tool only ever deletes an entry that holds nothing but what it wrote. The tool never creates or renames firmware entries and never mounts or reads a Windows partition. When Omarchy replaces `limine.conf` from its template, the next `sign` pass puts the entry back.

`sudo omasecboot windows bootnext` does the same without the menu. The package ships a "Reboot to Windows" row for Omarchy's menu as `/usr/share/doc/omasecboot/omarchy-menu.jsonc`; merge it into your own Omarchy menu extensions to use it.

## What it never touches

- **Snapshot images.** `limine-snapper-sync` keeps a hash of every snapshot image it stores. Signing one later would break that hash for good, so images from before setup stay as they are: they boot with Secure Boot off, `status` counts them, and snapshot rotation retires them.
- **The fallback loader** `EFI/BOOT/BOOTX64.EFI`. It stays the raw copy upstream deploys. The firmware refuses it while Secure Boot is on, and with Secure Boot off it is your rescue loader (next section).
- **sbctl's file list.** OmaSecBoot adds nothing to it. `setup` only removes rows for snapshot images and the fallback loader, which sbctl's own pacman hook would otherwise sign in place.

## If the machine does not boot

A sealed Limine loader refuses to start when `limine.conf` no longer matches its checksum, with Secure Boot on or off. The watchers and the hook keep them in step; if a change slipped through:

1. Turn Secure Boot off in the firmware.
2. In the firmware's boot menu pick the fallback loader (`EFI/BOOT/BOOTX64.EFI`). It is not sealed and boots normally.
3. Run `sudo omasecboot sign`, then turn Secure Boot back on.

A machine without a fallback loader needs rescue media for step 2; `setup` warns about that, and `sudo limine-install --fallback` adds one. If only the newest kernel is refused, boot a snapshot entry or turn Secure Boot off, then run `sudo omasecboot sign`.

## Troubleshooting

| Message or symptom | Meaning | What to do |
| --- | --- | --- |
| `Boot files are busy` (exit 75) | Another tool holds the boot lock; a kernel install holds it for up to a minute | Run the command again when that tool has finished. Nothing failed |
| A red line after an update: `OmaSecBoot could not finish` | The pass inside the update could not prove the boot files | `sudo omasecboot status`, then the command it names. Do not reboot with Secure Boot on until the report is clean |
| `The Limine loader is not sealed with the current limine.conf` | The loader would refuse to start, with Secure Boot on or off | `sudo omasecboot sign` before you reboot. If the machine is already down, see "If the machine does not boot" |
| `Stale path hash in limine.conf` | An OS entry still carries a hash of a file that has changed since | `sudo omasecboot setup`, which regenerates the entries |
| `An earlier setup or remove did not finish` | One of the two stopped half way, for example when a Limine tool failed | `sudo omasecboot remove` to return to stock, or `sudo omasecboot setup` to set up again |
| `An earlier install of this tool is still present` | Files of an earlier install, copied into place without pacman, remain, and their hooks keep running the old tool | Run the removal command that `setup` prints, then `setup` again |
| `The firmware's keys are in a state this tool will not write to` | The firmware's key menu removed more than the Platform Key | Restore the factory keys in the firmware, run `setup`, then delete only the Platform Key |
| `Secure Boot is on, but the firmware does not hold your keys` | A firmware update or a CMOS reset put the factory keys back | Turn Secure Boot off, then `setup` |
| `sbctl has no signing keys` | The keys under `/var/lib/sbctl` are gone | Restore them from a snapshot or backup. With new keys, the firmware needs another round of `setup` |
| A snapshot entry does not boot with Secure Boot on | The snapshot image predates setup and is unsigned | Boot it with Secure Boot off, or let snapshot rotation retire it |
| `limine.conf holds this tool's Windows comment in an entry this tool did not write that way` | The `/Windows` entry was edited by hand, or its comment line ended up in another entry | Remove that comment line, or the entry, then `sudo omasecboot sign` |

## Limits

- Your keys being enrolled does not mean Secure Boot is on; `status` reports both.
- After the Platform Key is yours, updates that the manufacturer signs with its own Platform Key no longer apply. Microsoft's KEK stays, so the db and dbx updates that Microsoft signs can still be applied.
- The backup under `/var/lib/omasecboot/firmware-backup/` is what this machine trusted before the change, not a factory key set. OmaSecBoot never writes dbx and restores no firmware keys; the firmware's own key menu does that.
- A BootNext request is one boot. It does not prove that Windows started, keep BitLocker quiet or keep its measurements stable, and a clean `windows preflight` is an observation, not a clearance of the firmware.
- A snapshot older than `setup` takes the tool, the keys and the settings with it when it is restored, while the ESP and the firmware keep the signed state. Keep Secure Boot off after such a restore until `setup` has run again.
- The Omarchy installer ISO does not boot under Secure Boot; OmaSecBoot is for installed systems.

## Removing it

Turn Secure Boot off, run `sudo omasecboot remove`, then `sudo pacman -R omasecboot`. The state directory and your sbctl keys stay on disk.

## Help test it

Boot behaviour is proven only on the machines recorded, so every further machine counts. [docs/field-testing.md](docs/field-testing.md) walks you through a test in three levels, the first of which changes no Secure Boot key or setting in the firmware and ends with everything returned to stock. It records every step and ends with a report whose attachments have your host and login names, machine-id and UUIDs renamed.

## Development

```bash
make lint            # bash -n, ShellCheck and the JSONC fragment
make test            # hermetic suites and the package build, about a minute
make test-contract   # the installed sbctl and Limine tools against the upstream contracts, in a sandbox
```

[CONTRIBUTING.md](CONTRIBUTING.md) has the principles, the layout, the conventions and how changes are verified. What a release needs is in [docs/release-checklist.md](docs/release-checklist.md), open work and recheck triggers are in [docs/maintenance.md](docs/maintenance.md), and what lives on Omarchy's side is in [docs/omarchy-integration.md](docs/omarchy-integration.md).

## License and credits

[MIT](LICENSE). Created by [peregrinus879](https://github.com/peregrinus879). OmaSecBoot builds on [sbctl](https://github.com/Foxboron/sbctl), [Limine](https://github.com/limine-bootloader/limine), Zesko's limine-entry-tool and limine-snapper-sync, and [Omarchy](https://omarchy.com).
