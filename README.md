# OmaSecBoot

**Secure Boot for [Omarchy](https://omarchy.com) with your own keys.**

OmaSecBoot is an opt-in package for installed Omarchy systems. It leaves the work to the tools Omarchy already ships, sbctl and the Limine tooling, fills the gaps between them, checks what they did, and tells you the truth about the result.

> [!CAUTION]
> **Development status, 2026-09-20:** no release exists and this build has not been accepted on hardware. It prepares and maintains the boot files (`setup`, `sign`, `status`, `remove`). Enrolling your keys in the firmware and the Windows boot entry are designed in [docs/spec.md](docs/spec.md) and not built yet. Do not turn Secure Boot on with this build.

## Why

Omarchy boots through Limine with unified kernel images and Snapper snapshot entries, and its manual tells users to turn Secure Boot off. The pieces for Secure Boot with your own keys all exist, and none of them closes the gaps between them:

- **sbctl** creates keys, signs EFI files and enrolls keys, but it knows nothing about Limine's configuration, and its enrollment replaces what the firmware trusts unless it is told otherwise.
- **The Limine tools** can seal the loader over `limine.conf` and sign it, but the feature is off by default and its failures are hidden.
- **Windows dual boot** adds BitLocker, which reacts to every change of the firmware's keys.

OmaSecBoot fills those gaps for this exact stack and leaves everything else to the tools Omarchy already ships.

## How it works

- sbctl signs each new kernel image while it is built, and Limine's own hook seals the loader: it writes a checksum of `limine.conf` into the Limine executable, so nobody can change your boot entries from outside the running system. OmaSecBoot turns those two upstream features on, proves after every change that they really happened, and repairs the loader when they did not.
- It integrates in two places only. A small Limine hook runs at the end of every Limine operation (kernel updates, Limine upgrades, snapshots, restores), and a systemd path unit re-seals the loader when `limine.conf` is edited. It installs no pacman hooks and never blocks an update. On a machine where `setup` never ran, the hook exits on its first line.
- It keeps a few small files under `/var/lib/omasecboot` and works out everything else from what it observes, so any interrupted step is finished by running the same command again. It rebuilds the loader from the raw Limine executable that upstream deployed, never from a newer one upstream is holding back.

The design, every decision behind it and the failure table are in [docs/spec.md](docs/spec.md). The upstream behaviour it relies on, with sources, is in [docs/upstream-contracts.md](docs/upstream-contracts.md).

## Requirements

Omarchy on x86_64 booted in UEFI mode, with Limine, unified kernel images and the ESP mounted as vfat, which is how Omarchy installs. Besides the base system the package depends on `sbctl`, `limine`, `limine-mkinitcpio-hook`, `jq` and `gum`.

## Install

```bash
make package
sudo pacman -U omasecboot-1.0.0-1-any.pkg.tar.zst
```

`make package` needs `base-devel` and git and builds from the files of the checkout that git does not ignore. `make install` only stages a package and refuses the live system.

## Commands

| Command | What it does |
| --- | --- |
| `sudo omasecboot setup` | Creates signing keys with sbctl if there are none, sets `ENABLE_ENROLL_LIMINE_CONFIG=yes` and `ENABLE_VERIFICATION=no` in `/etc/default/limine` (remembering what was there), regenerates the boot entries when they still carry path hashes, seals and signs the loader, signs anything that arrived unsigned, and enables the `limine.conf` watcher. It also removes the sbctl rows that would make sbctl sign a snapshot image or the fallback loader. Safe to run again. |
| `sudo omasecboot status` | Reports the firmware state, the settings, the loader proof, the fallback loader, the keys, every signed file, stale hashes, harmful sbctl rows, and leftovers of earlier installs, and ends with the command that repairs what it found. Exit 0 healthy, 1 attention needed. `--quiet` prints nothing. |
| `sudo omasecboot sign` | The same converge-and-verify pass the hook runs. Safe at any time; exits 75 when another tool is working on the boot files. |
| `sudo omasecboot remove` | Returns the Limine settings and boot files to stock. Refuses while Secure Boot is on. Your keys stay. |

## What it never touches

- **Snapshot images.** `limine-snapper-sync` keeps a hash of every snapshot image it stores. Signing one later would break that hash for good, so images from before setup stay as they are: they boot with Secure Boot off, `status` counts them, and snapshot rotation retires them.
- **The fallback loader** `EFI/BOOT/BOOTX64.EFI`. It stays the raw copy upstream deploys. The firmware refuses it while Secure Boot is on, and with Secure Boot off it is your rescue loader (next section).
- **sbctl's file list.** OmaSecBoot adds nothing to it. `setup` only removes rows for snapshot images and the fallback loader, which sbctl's own pacman hook would otherwise sign in place.

## If the machine does not boot

A sealed Limine loader refuses to start when `limine.conf` no longer matches its checksum, with Secure Boot on or off. The watcher and the hook keep them in step; if a change slipped through:

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
| `An earlier install of this tool is still present` | Files of a pre-package install remain, and their hooks keep running the old tool | Run the removal command that `setup` prints, then `setup` again |
| `sbctl has no signing keys` | The keys under `/var/lib/sbctl` are gone | Restore them from a snapshot or backup. With new keys, the firmware needs another round of `setup` |
| A snapshot entry does not boot with Secure Boot on | The snapshot image predates setup and is unsigned | Boot it with Secure Boot off, or let snapshot rotation retire it |

## Limits

- A snapshot older than `setup` takes the tool, the keys and the settings with it when it is restored, while the ESP and the firmware keep the signed state. Keep Secure Boot off after such a restore until `setup` has run again.
- The Omarchy installer ISO does not boot under Secure Boot; OmaSecBoot is for installed systems.

## Removing it

Turn Secure Boot off, run `sudo omasecboot remove`, then `sudo pacman -R omasecboot`. The state directory and your sbctl keys stay on disk.

## Development

```bash
make lint   # bash -n and ShellCheck
make test   # hermetic suites and the package build, about a minute
```

[CONTRIBUTING.md](CONTRIBUTING.md) has the principles, the layout, the conventions and how changes are verified. Open work and recheck triggers are in [docs/maintenance.md](docs/maintenance.md).

## License and credits

[MIT](LICENSE). Created by [peregrinus879](https://github.com/peregrinus879). OmaSecBoot builds on [sbctl](https://github.com/Foxboron/sbctl), [Limine](https://github.com/limine-bootloader/limine), Zesko's limine-entry-tool and limine-snapper-sync, and [Omarchy](https://omarchy.com).
