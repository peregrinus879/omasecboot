# Upstream contracts

What OmaSecBoot relies on in other people's software, read from their source at the versions named, plus what real hardware showed. [spec.md](spec.md) cites these sections as [C1] to [C8]. Recheck a section when its package changes version. `tests/contract-limine.sh` and `tests/contract-sbctl.sh` check parts of C1 to C4 against the installed packages.

Versions read (2026-09): Limine 12.8.0, limine-entry-tool and limine-mkinitcpio-hook 1.38.0, limine-snapper-sync 1.31.0, sbctl 0.18 with go-uefi `69fb7dba244f`, systemd 261, Omarchy 4.0.x (`quattro` branch), Linux 7.2.

## C1. Limine at boot

Source: `limine-bootloader/limine` tag `v12.8.0`, `common/lib/config.c`, `common/lib/uri.c`, `common/protos/chainload.c`, `common/menu.c`; `USAGE.md`.

- Both Limine executables carry the marker `++CONFIG_B2SUM_SIGNATURE++` followed by 128 hex digits, all zero until `limine enroll-config` writes the BLAKE2B of `limine.conf` there.
- A non-zero enrolled checksum is checked unconditionally in `init_config`: on a mismatch Limine panics ("CHECKSUM MISMATCH FOR CONFIG FILE") whether firmware Secure Boot is on or off, and the editor is disabled. An all-zero slot means no check and `secure_boot_active = false`.
- `secure_boot_active` holds only while the firmware reports Secure Boot and the enrolled checksum matches. It forces `hash_mismatch_panic` to yes and makes a missing path hash fatal, except for `protocol: efi` chainloading, where `chainload()` waives a missing hash. A hash that is present is verified for every protocol.
- Consequence: under Secure Boot a UKI started through `protocol: efi` is verified by the firmware's own image check, so its path hash adds nothing, while a stale hash (a file signed after its hash was written) stops that entry.
- Limine searches for its config next to the executable, then `/boot/limine/`, `/boot/`, `/limine/`, then the ESP root; a higher-priority stray `limine.conf` shadows the real one.

## C2. The Limine tools' hook chain

Source: `Zesko/limine-entry-tool` tag `1.38.0` (`install/arch-linux/limine-entry-tool/usr/lib/limine/limine-common-functions`, `usr/bin/limine-install`, `limine-mkinitcpio-hook/usr/share/libalpm/scripts/limine-mkinitcpio-install`, `README.md`); limine-snapper-sync 1.31.0 wrappers and README.

- Every hook-aware operation (kernel install and removal, `limine-install`, `limine-update`, snapshot sync, restore) takes `/run/lock/boot-partition.lock` on descriptor 200, runs `/etc/boot/hooks/pre.d`, works, runs `/etc/boot/hooks/post.d`, unlocks. Hooks are plain executables run in lexical order with the caller's environment and descriptors; files that are not executable or end in `.disabled` are skipped. Upstream ships `pre.d/10-limine-reset-enroll`, `post.d/89-warn-missing-file-hashes` and `post.d/90-limine-enroll-config`, plus two disabled examples, `pre.d/05-example-esp-set-rw` and `post.d/91-example-esp-set-ro`, that remount the ESP writable before and read-only after the operation; a post-hook that writes to the ESP therefore sorts before 91. Lock waits are 10 or 30 seconds and the tools continue unlocked after a timeout. A full restore runs with `--no-mutex` and holds `/run/lock/limine-snapper-restore.lock` instead.
- Exit codes: 1 to 99 is a warning, 100 or more aborts a pre-hook's caller. The last post-hook's status becomes the caller's exit status, and `limine-mkinitcpio-install` treats any non-zero from it as fatal (exit 3). A third-party post-hook sorted last must therefore exit 0.
- Primary loader cycle: `limine-install` copies the package's `/usr/share/limine/BOOTX64.EFI` (or `LIMINE_BINARY_PATH`) to `/EFI/limine/limine_x64.efi` and keeps that raw executable beside it as a one-member tar, `limine_x64.bak`. It skips the copy when the package holds an older Limine than the ESP or a major outside 8 to 12, so the deployed loader can lag the package. The pre-hook (`limine-reset-enroll`, also a command of its own) restores the primary from that backup and only falls back to `limine enroll-config --reset` when there is none; `90-limine-enroll-config` enrolls the checksum only when `ENABLE_ENROLL_LIMINE_CONFIG=yes`, then runs `sbctl sign` (a no-op without keys). Enroll and sign failures are masked: the hook's status is that of its final `sync`.
- `limine-install --no-efi-register` deploys without touching the firmware's boot entries. Its argument parser prints the usage text and exits 0 for any flag it does not know, so a renamed flag would silently do nothing; the result is judged by the files.
- Fallback loader: `limine-install` copies `/EFI/BOOT/BOOTX64.EFI` raw whenever policy deploys it and its hash differs from the package source, so a signed fallback is overwritten on every run; upstream never signs or enrolls it and its README offers it as the way to boot after a config checksum panic.
- UKIs: `limine-mkinitcpio-install` builds each UKI in a temporary file, sbctl's initcpio post hook signs it there when keys exist, then `limine-entry-tool --add-uki` copies it to `/EFI/Linux/` and writes `path: ...#<blake2b>` only when `ENABLE_VERIFICATION` is on. With sbctl and Snapper present the UKI embeds no command line; it comes from `limine.conf`. A failed UKI build still returns success.
- Everything on Omarchy that rebuilds the initramfs (kernel, firmware, microcode, dkms, systemd) goes through this script, because `/etc/pacman.d/hooks/90-mkinitcpio-install.hook` shadows mkinitcpio's own hook.
- limine-snapper-sync copies the current UKI into `<ESP>/<machine-id>/limine_history/` with the content hash in the filename (`.efi_sha256_<hash>` and similar; that suffix is not a path hash), stores each entry's path hash in `snapshots.json`, reuses it on every sync and has no verification switch. Signing a history file in place therefore leaves its entry stale for good; a snapshot taken after signing copies an already-signed UKI and stays consistent.
- pacman PostTransaction hooks do not run after a failed transaction and their failure does not fail pacman.

## C3. Configuration layers

Source: `limine-common-functions` (`load_config`), `ConfigReader.java`.

Layers, last one wins: `/usr/share/limine-entry-tool.d/*.conf`, `/etc/limine-entry-tool.conf`, `/etc/limine-entry-tool.d/*.conf`, `/etc/default/limine`. `ENABLE_ENROLL_LIMINE_CONFIG` is reset to empty before the last layer, so it is honoured only in `/etc/default/limine`. `ENABLE_VERIFICATION`, `ENABLE_UKI`, `ENABLE_LIMINE_FALLBACK` (yes, no, or unset meaning "deploy when missing"), `FIND_BOOTLOADERS` and `ESP_PATH` are honoured in every layer. Upstream ships verification on and enrollment off.

## C4. sbctl 0.18

Source: `Foxboron/sbctl` tag `0.18` (`cmd/sbctl/enroll-keys.go`, `verify.go`, `sign.go`, `list-files.go`, `remove-file.go`, `keys.go`, `sbctl.go`, `siglist.go`, `util.go`, `backend/`), go-uefi at the pinned revision.

- `create-keys` creates its directories itself and writes nothing when `keys/PK`, `keys/KEK` and `keys/db` already exist, so nothing may be pre-created under `/var/lib/sbctl`; its own commands leave that directory 755.
- `enroll-keys` writes whole variables (never `EFI_VARIABLE_APPEND_WRITE`) in the order db, KEK, PK, stops at the first error and does not roll back. db is signed by the local KEK, KEK by the local PK, PK by itself; the OEM's keys are never needed in Setup Mode.
- Every entry sbctl writes is owned by its own GUID (`KeySync` appends its certificates with `GetGUID`), which `status --json` reports as `guid`; `rotate-keys` keeps it. OmaSecBoot identifies the local certificates by that owner in a `--microsoft --export esl`, which does not read the firmware.
- `--append` reads the current db, KEK and PK and adds the local certificates to them, so nothing already trusted is removed. It is not idempotent: a second run adds the local certificate again, because its duplicate check compares the PEM it holds with the DER in the variable. OmaSecBoot does not rely on that staying so, but it does rely on never appending to a variable that already holds the certificate. It also skips sbctl's option-ROM check, and on empty variables it yields local keys only. `--partial <PK|KEK|db>` writes one variable and combines with `--append`. Without `--append`, `--microsoft` and `--firmware-builtin` build KEK and db from the local certificate, Microsoft's certificates and the firmware's `KEKDefault` and `dbDefault`, and the PK is the local certificate alone. `--export esl` honours `--append`, needs root and the local keys, needs neither Setup Mode nor `--ignore-immutable`, writes `db.esl`, `KEK.esl`, `PK.esl` into the current directory and is a faithful dry run; `--export auth` is not. With a PK in place an append export shows a PK of two entries, which firmware rejects (EDK2 `AuthService.c`: `IsPk && SigCount > 1`), so a PK is only ever written when none is present. Without `--append`, `--microsoft`, `--tpm-eventlog` or the force flag, sbctl first checks the TPM event log for option ROMs and refuses when it finds one, also for an export.
- The kernel marks PK, KEK and db immutable in efivarfs. `--ignore-immutable` only skips sbctl's pre-check; the write path clears the flag itself. `chattr` is never needed.
- `sign-all` (run by `zz-sbctl.hook` after package transactions) signs every file in sbctl's database; a file that is not in the database is left alone. `sign` replaces the file in place: it truncates it and writes the signed image back, exits 0 on a file that is already signed, and `sign -s` does not register such a file.
- `verify --json FILE` exits 0 whatever it finds and answers with an array of one `{file_name, is_signed}` entry, `is_signed` being 1, 0, or -1 for a file that does not exist; for a file its sandbox may not read (anything outside the ESP and the tracked paths) it answers `null`, seen on 0.18-2. `status --json` carries `installed`. `list-files --json` is an array of `{file, output_file, is_signed}`; to fill `is_signed` it verifies, and so reads, every tracked file, and it leaves out rows whose file is gone. `remove-file PATH` drops one row. A Limine executable modified after signing cannot be re-signed (sbctl issue 408), so enrollment comes before signing.
- `sbctl status --json` hides read errors of the mode variables; read them from efivarfs. There is no `--version`; `sbctl version` prints it.

## C5. systemd path units

Source: systemd 261 `src/core/path.c`, `systemd.path(5)`, `systemd.unit(5)`, `systemd-escape(1)`.

`PathChanged=` fires on close-after-write, attribute change, deletion and a rename over the watched file, and re-arms by pathname afterwards. Changes that arrive while the triggered service runs are merged, not queued, so the service must look at the file's current state. A service that hits its start limit fails the path unit with it; `StartLimitIntervalSec=0` avoids that. Templates are valid: `%f` is the unescaped instance as a path, and the instance name comes from `systemd-escape --template=NAME@.path -p <file>`. Path units depend on the mount of the watched path implicitly. An enabled instance whose package was removed leaves a harmless dangling link that `systemctl disable` still removes.

## C6. Firmware and hardware findings

ASUS TP3402VA, AMI BIOS 307, observed on 2026-09-09 and 2026-09-10 with a development version of this tool. A second laptop has run the pre-package version under Secure Boot since 2026-08, through kernel, Limine and hook upgrades.

- The firmware exposes neither AuditMode nor DeployedMode (pre-UEFI 2.5 model). Its key menu appears only while Secure Boot is set to enabled. Deleting only the PK keeps KEK, db and dbx and enters Setup Mode.
- Per-variable writes of db, KEK and PK over the immutable variables succeeded with `--ignore-immutable` and read back exactly. After the PK write, `SetupMode` kept reading 1 until the next boot, although the variables already held the new keys; enrollment must be judged by the variables.
- A stock install carries path hashes of unsigned UKIs; after setup the OS entry was regenerated without a hash, while two snapshot entries older than enrollment stayed stale after their history files were signed in place, and `limine-snapper-sync` did not rewrite them.
- `sbctl` refused to create keys into pre-created directories, and setup must accept the 755 `/var/lib/sbctl`. `gum confirm` without a terminal declines silently, so prompts need a TTY and must say what was cancelled. A Limine tool holding the boot lock for a minute is normal and must read as "busy".
- The machine has two ESPs (Omarchy's and Windows'), `ENABLE_LIMINE_FALLBACK=no` and no fallback loader, and no BitLocker. Neither the Windows handoff nor a BitLocker prompt has been exercised on hardware.

## C7. Omarchy

Source: `omacom/omarchy`, `quattro` branch, 2026-09.

- Opt-in security features are command pairs `omarchy-setup-security-<x>` and `omarchy-remove-security-<x>` (`#!/bin/bash`, `# omarchy:summary=`, `# omarchy:requires-sudo=true`) with menu rows in `default/omarchy/omarchy-menu.jsonc`; remove rows use a `when` guard that must be unprivileged and silent.
- Defaults that matter: `ENABLE_UKI=yes`, `ENABLE_LIMINE_FALLBACK=yes`, `FIND_BOOTLOADERS=yes`, `MAX_SNAPSHOT_ENTRIES=6` with Snapper keeping 5, `hash_mismatch_panic: no` in the `limine.conf` template, and an `/etc/default/limine` holding only `ESP_PATH` and the command line.
- `omarchy-refresh-limine` and `omarchy-reinstall-configs` replace `limine.conf` from the template outside any lock, then run `limine-update` and `limine-snapper-sync`; anything appended to `limine.conf` by hand is lost.
- `omarchy update` takes a snapshot, runs pacman, then offers a reboot when the kernel changed. Nothing between those steps can block the reboot prompt; `omarchy-hook post-update` runs user hooks but cannot stop it.
- The manual tells users to turn Secure Boot off, and the maintainers' own route for the installer is a Microsoft-signed shim; OmaSecBoot is the option for installed systems.

## C8. Firmware boot entries, Limine's `efi_boot_entry` and efibootmgr 18

Source: UEFI 2.10 sections 3.1.1 to 3.1.3, Limine's `CONFIG.md` and `ChangeLog` at v12.8.0, efibootmgr 18's usage text, util-linux's libblkid. The reader was tried read-only on 2026-09-20 on the second laptop of C6, a dual-boot machine; nothing else in this section has a hardware record yet.

- `BootOrder` is a list of little-endian uint16 numbers; `Boot####` (upper-case hex) is an `EFI_LOAD_OPTION`: uint32 attributes with bit 0 for active, the uint16 length of the device path, the description as NUL-terminated UTF-16, then device path nodes of type, subtype and uint16 length. A file path node is type 4, subtype 4, its text UTF-16. efivarfs puts four attribute bytes before every variable's data and lets any user read these variables.
- Windows registers `\EFI\Microsoft\Boot\bootmgfw.efi` as "Windows Boot Manager"; firmware compares such paths without case.
- Limine's `efi_boot_entry` protocol, added in Limine 11.0.0, takes `entry`, "the name of the EFI boot entry to reboot into". How it matches the name is not documented, so OmaSecBoot requires the name to be unique among every `Boot####` variable, folding ASCII case.
- On the second laptop of C6 a trailing `/Windows` entry with a comment line above it has stayed in `limine.conf` since 2026-08, through upstream's kernel, snapshot and Limine updates: limine-entry-tool and limine-snapper-sync rewrite their own entries and keep what follows. Omarchy's `omarchy-refresh-limine` replaces the whole file (C7).
- `efibootmgr --bootnext XXXX` sets `BootNext`, which the firmware consumes at the next start; when that entry cannot be started the firmware goes on with `BootOrder` (UEFI 2.10, 3.1.1).
- libblkid names a BitLocker volume's type `BitLocker`, which Device Encryption on Windows Home uses too; `lsblk --raw --noheadings --output PATH,FSTYPE` prints it from the udev database and needs no privileges.

