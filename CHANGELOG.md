# Changelog

What changed for someone who runs the tool. Git history holds the rest.

## 0.1.0, not yet released

The first release.

- `setup` creates signing keys through sbctl, writes two Limine settings and remembers what stood there, seals and signs the loader, signs what arrived unsigned, enables two watchers, backs up the firmware's keys and, in Setup Mode, adds the user's certificates beside the KEK and db entries the firmware holds and replaces only the Platform Key. It warns before the Platform Key is deleted when KEK lacks Microsoft's 2023 certificate. It offers a fallback loader where a machine has none, only into an empty place.
- `sign` is the converge-and-verify pass that the Limine hook and the watchers run. `status` reports the firmware, the settings, the loader proof, the fallback, every signable file, an ESP that is running out of room, Microsoft's 2023 certificates that are missing, the Windows entry, the hook and the watchers, and names the command that repairs what it found. `remove` returns the settings and the boot files to stock.
- `windows setup` adds an entry to Limine's menu that restarts the machine into the firmware's Windows Boot Manager entry; `windows bootnext` does the same once, without the menu.
- `setup` tells the user to turn Secure Boot on only when the firmware has an active boot entry for the Limine loader, and `status` blocks without one: a machine that starts through the fallback path would stop.
- pacman warns when the package is removed from a machine that is still set up; it never blocks the removal.
- Snapshot images and the fallback loader are never signed or sealed, sbctl's file list is never added to, the hook never fails a Limine tool, and nothing blocks pacman.
- `tests/acceptance-record.sh` records a hardware run, and `tests/acceptance-share.sh` makes the copies that are fit for a public issue.
- Hardware record: ASUS Vivobook TP3402VA, AMI BIOS 307, Omarchy 4.0.4, every stage of `docs/release-checklist.md`.
