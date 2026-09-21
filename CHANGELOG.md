# Changelog

What changed for someone who runs the tool. Git history holds the rest.

## 0.1.0, not yet released

The first release.

- `setup` is the one command: run it again after each step it asks for. It creates signing keys through sbctl, writes two Limine settings and remembers what stood there, seals and signs the loader, signs what arrived unsigned, enables two watchers and backs up the firmware's keys. In Setup Mode it adds the user's certificates beside the KEK and db entries the firmware holds and replaces only the Platform Key; where the firmware's key menu cleared KEK and db as well, it offers to rebuild them and lists what cannot come back. It warns before the Platform Key is deleted when KEK lacks Microsoft's 2023 certificate, offers a fallback loader where a machine has none, only into an empty place, and tells the user to turn Secure Boot on only when the firmware has an active boot entry for the Limine loader. Beside Windows it asks for the recovery key before each firmware step and says how to avoid BitLocker's prompt.
- `sign` is the converge-and-verify pass that the Limine hook and the watchers run.
- `status` reports the firmware, the settings, the loader proof, the fallback, every signable file, an ESP that is running out of room, Microsoft's 2023 certificates that are missing, a machine whose firmware has no active boot entry for the Limine loader, the Windows entry, the hook and the watchers, and names the command that repairs what it found.
- `remove` returns the settings and the boot files to stock. It stops at a nearly full ESP before it changes anything, says so when the watchers could not be disabled, and on a machine that is not set up says that there is nothing to remove.
- `windows preflight` looks for Windows and BitLocker volumes; `windows setup` adds an entry to Limine's menu that restarts the machine into the firmware's Windows Boot Manager entry; `windows bootnext` asks the firmware to start that entry at the next boot, once, without the menu. Where a chainload entry for Windows stands beside a BitLocker volume, `status`, `windows setup` and `windows status` say that the two ways of starting Windows do not mix.
- pacman warns when the package is removed from a machine that is still set up; it never blocks the removal.
- Snapshot images and the fallback loader are never signed or sealed, sbctl's file list is never added to, the hook never fails a Limine tool, and nothing blocks pacman.
- `tests/acceptance-record.sh` records a hardware run, and `tests/acceptance-share.sh` makes the copies that are fit for a public issue.
- Hardware record: ASUS Vivobook TP3402VA, AMI BIOS 307, Omarchy 4.0.4, stages 0 to 6 with commit `d567e1f`, Windows beside it with its encryption off, and stages 0 to 7 without the snapshot rows with commit `ccc6e8a`, its encryption on (`docs/upstream-contracts.md`, C10).
