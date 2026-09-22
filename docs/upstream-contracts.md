# Upstream contracts

What OmaSecBoot relies on in other people's software, read from their source at the versions named, plus what real hardware showed. [spec.md](spec.md) cites these sections as [C1] to [C10]. [maintenance.md](maintenance.md) lists what to recheck when a package changes. `tests/contract-limine.sh` and `tests/contract-sbctl.sh` check parts of C1 to C4 and C9 against the installed packages.

Versions read: Limine 12.9.0, limine-mkinitcpio-hook 1.38.0 (built from the limine-entry-tool sources), limine-snapper-sync 1.31.0, sbctl 0.18 with go-uefi `69fb7dba244f`, systemd 261, pacman 7, efibootmgr 18, util-linux 2.41, Omarchy 4.0.x (`quattro` branch) and its installer, Linux 7.2.

## C1. Limine at boot

Source: `limine-bootloader/limine` tag `v12.9.0`, `common/lib/config.c`, `common/lib/uri.c`, `common/protos/chainload.c`, `common/menu.c`; `USAGE.md`. The files cited are the same in `v12.8.0`, which the machine of C10 ran, except `uri.c`, whose mismatch behaviour and text are unchanged.

- `config_get_value` compares a key with `strncasecmp`, so keys have no case: `PATH:` and `path:` are one key.
- Both Limine executables carry the marker `++CONFIG_B2SUM_SIGNATURE++` followed by 128 hex digits, all zero until `limine enroll-config` writes the BLAKE2b of `limine.conf` there.
- A non-zero enrolled checksum is checked unconditionally in `init_config`: on a mismatch Limine panics ("CHECKSUM MISMATCH FOR CONFIG FILE") whether firmware Secure Boot is on or off (seen with it off on the machine of C10), and the editor is disabled. An all-zero slot means no check and `secure_boot_active = false`.
- `secure_boot_active` holds only while the firmware reports Secure Boot and the enrolled checksum matches. It forces `hash_mismatch_panic` to yes and makes a missing path hash fatal, except for `protocol: efi` chainloading, where `chainload()` waives a missing hash. A hash that is present is verified for every protocol. Without `secure_boot_active`, `hash_mismatch_panic: no` turns a mismatch into a warning that waits for a key: "Press Y to continue, press any other key to return to menu" (`uri.c`).
- Limine searches for its config next to the executable, then `/boot/limine/`, `/boot/`, `/limine/`, then the ESP root; a higher-priority stray `limine.conf` shadows the real one.
- `protocol: efi` starts an image through the firmware's `LoadImage` and `StartImage` (`chainload.c`: "The firmware's LoadImage will verify the Secure Boot signature of the chainloaded EFI application"), so the firmware checks every UKI against db. The Limine executable has no `.sbat` section (`objdump -h` of the packaged `BOOTX64.EFI`: `.text`, `.reloc`, `.data`), which a shim demands of its second stage (rhboot/shim, `SBAT.md`), and `USAGE.md` documents one route to Secure Boot: "the executable is signed and the key used to sign it is added to the firmware's keychain".

## C2. The Limine tools

Source: `Zesko/limine-entry-tool` tag `1.38.0` (`install/arch-linux/limine-entry-tool/usr/lib/limine/limine-common-functions`, `usr/bin/limine-install`, `limine-mkinitcpio-hook/usr/share/libalpm/scripts/limine-mkinitcpio-install`, `README.md`, `Main.java`, `EfiScanner.java`, `LimineManager.java`, `Limine.java`); limine-snapper-sync 1.31.0 wrappers, README and `SnapshotManager.java`.

**The hook chain and the lock**

- Every hook-aware operation (kernel install and removal, `limine-install`, `limine-update`, snapshot sync, restore) takes `/run/lock/boot-partition.lock` on descriptor 200, runs `/etc/boot/hooks/pre.d`, works, runs `/etc/boot/hooks/post.d`, unlocks. Hooks are plain executables run in lexical order with the caller's environment and descriptors; files that are not executable or end in `.disabled` are skipped. Upstream ships `pre.d/10-limine-reset-enroll`, `post.d/89-warn-missing-file-hashes` and `post.d/90-limine-enroll-config`, plus two disabled examples, `pre.d/05-example-esp-set-rw` and `post.d/91-example-esp-set-ro`, that remount the ESP writable before and read-only after the operation; a post-hook that writes to the ESP therefore sorts before 91. Lock waits are 10 or 30 seconds and the tools continue unlocked after a timeout. A full restore runs with `--no-mutex` and holds `/run/lock/limine-snapper-restore.lock` instead.
- The `limine-reset-enroll` command takes no lock of its own.
- Exit codes: 1 to 99 is a warning, 100 or more aborts a pre-hook's caller. The last post-hook's status becomes the caller's exit status, and `limine-mkinitcpio-install` treats any non-zero from it as fatal (exit 3). A third-party post-hook sorted last must therefore exit 0.
- The post-hook `89-warn-missing-file-hashes` only prints, and exits 0 whatever it finds (1 when upstream's function library fails to load). With Secure Boot on, Limine 12, `ENABLE_ENROLL_LIMINE_CONFIG=yes` and neither `ENABLE_VERIFICATION` nor `ENABLE_UKI` reading `yes` in its caller's environment, it warns that "Limine v12 requires verification hashes for all loaded files except EFI chainload" and advises `ENABLE_VERIFICATION=yes`. A UKI entry is an EFI chainload (C1), and the hook's condition exempts `ENABLE_UKI=yes`.
  - `limine-snapper-restore` exports `/etc/limine-snapper-sync.conf` and `/etc/default/limine` and, inside a read-only snapshot, the copy of the latter it keeps as `/tmp/limine-snapper-sync.conf`. It never reads the other layers of C3, and Omarchy sets `ENABLE_UKI=yes` in one of them (C6). A restore that root starts on a machine that is set up therefore prints the warning although every OS entry is a UKI (C10). Started from a desktop login it hands over to a terminal and `pkexec` or `sudo`, and what reaches the hooks on that route has not been read or recorded.

**`limine-install` and the primary loader**

- Primary loader cycle: `limine-install` copies the package's `/usr/share/limine/BOOTX64.EFI` (or `LIMINE_BINARY_PATH`) to `/EFI/limine/limine_x64.efi` and keeps that raw executable beside it as a one-member tar, `limine_x64.bak`.
  - It skips the copy when the package holds an older Limine than the ESP or a major outside 8 to 12, so the deployed loader can lag the package.
  - The pre-hook (`limine-reset-enroll`, also a command of its own) restores the primary loader from that backup and only falls back to `limine enroll-config --reset` when there is none; `90-limine-enroll-config` enrolls the checksum only when `ENABLE_ENROLL_LIMINE_CONFIG=yes`, then runs `sbctl sign` (a no-op without keys).
  - Enroll and sign failures are masked: the hook's status is that of its final `sync`.
- `limine-install --no-efi-register` deploys without touching the firmware's boot entries. Its argument parser prints the usage text and exits 0 for any flag it does not know, so a renamed flag would silently do nothing; the result is judged by the files.
- `limine-install` with `--skip-uefi`, or after a failed registration, leaves a machine that starts through `EFI/BOOT` alone, with no firmware entry for the primary loader.

**The fallback loader**

- Fallback loader: `limine-install` copies `/EFI/BOOT/BOOTX64.EFI` raw whenever policy deploys it and its hash differs from the package source, so a signed fallback is overwritten on every run, and so is a file that is not Limine's, whose version it reads as 0.
  - Its version checks (no downgrade, majors 8 to 12) run only over a fallback that exists: an empty place is filled with the package's executable whatever its major, and a failed copy does not fail the tool.
  - `--fallback` deploys it whatever `ENABLE_LIMINE_FALLBACK` says and combines with `--no-efi-register`; upstream never signs or enrolls it and its README offers it as the way to boot after a config checksum panic.
  - The comments in `/etc/limine-entry-tool.conf` advise a user who wants it signed to set `ENABLE_LIMINE_FALLBACK=no`, run `limine-install --fallback` once and sign it by hand, which leaves a loader that is signed and never sealed.
- With `FIND_BOOTLOADERS=yes`, Omarchy's default, `limine-install` adds an `/EFI fallback` entry for `EFI/BOOT/BOOTX64.EFI` to `limine.conf` through `limine-entry-tool --add-efi`. That entry never carries a path hash, whatever `ENABLE_VERIFICATION` says (`LimineManager.java`, `addEfi`: `b2sum()` is used for kernel, initramfs, module and UKI paths only), and an entry that exists is not rewritten.
- The limine package ships `BOOTIA32.EFI` beside `BOOTX64.EFI`. archinstall's Limine step copies both to `EFI/BOOT` on an x86 machine and registers the one that matches the firmware's bitness (`archinstall/lib/installer.py`), while upstream's tools deploy only the loader of the running machine (`limine_efi_arch` in `limine-common-functions`: `X64` on x86_64). UEFI firmware looks for the removable-media loader of its own machine type (UEFI 2.10, 3.5.1.1), so 64-bit firmware never starts `BOOTIA32.EFI`.
- Linux compares names on a vfat ESP without case (kernel `Documentation/filesystems/vfat.rst`: `check=n`, the default, is case insensitive), which is how the tool finds a `bootx64.efi` that another system wrote in lower case.

**`limine-scan` and `limine-remove-entry`**

- `limine-scan` runs `limine-entry-tool --scan`, which lists the EFI loaders it finds on FAT partitions and writes the one the user picks through the same `addEfi` (`Main.java`, `EfiScanner.java`): a `protocol: efi` chainload entry whose `path:` stands on `boot():`, or on `uuid(<partition>):` for a loader on another partition such as Windows' own ESP, without a hash. The entry stands at the top level under the name the user confirms at a prompt, by default the firmware's label of that loader ("Windows Boot Manager" in C10), and its body is not indented: a `###` line, two `comment:` lines, `protocol: efi` and `path:`. Omarchy's manual sends dual-boot users to it (C6).
- Every top-level entry limine-entry-tool writes carries a `comment:` line with `order-priority=<n>`, which orders its entries: an OS entry `order-priority=50` after its machine id, an `--add-efi` entry its `--priority`, default 50, the fallback 10 (README, "--add-efi"; CHANGELOG 1.7.0; the file of C10). The snapshot block of limine-snapper-sync is nested under the OS entry and carries none. `limine-update` keeps a foreign entry where it stands and writes its own after it (C10).
- `limine-remove-entry` is `limine-entry-tool --remove-entry "<entry name/sub-entry name>" [position]`: it removes the first entry of that name, or the one at the given position, counted over the entries of that name in the order of the file, and matches names without their slashes and the `+` of an expanded directory (README, "Remove an entry from the boot menu"; `LimineManager.removeEntry`, `Limine.cleanName`). It runs inside the hook chain, so the loader is sealed over the result.

**UKIs**

- UKIs: `limine-mkinitcpio-install` builds each UKI in a temporary file, sbctl's initcpio post hook signs it there when keys exist, then `limine-entry-tool --add-uki` copies it to `/EFI/Linux/` and writes `path: ...#<blake2b>` only when `ENABLE_VERIFICATION` is on. With sbctl and Snapper present the UKI embeds no command line; it comes from `limine.conf`. A failed UKI build still returns success.
- Everything that rebuilds the initramfs (kernel, firmware, microcode, dkms, systemd) goes through this script, because `/etc/pacman.d/hooks/90-mkinitcpio-install.hook` shadows mkinitcpio's own hook.

**limine-snapper-sync**

- limine-snapper-sync copies the current UKI into `<ESP>/<machine-id>/limine_history/` with the content hash in the filename (`.efi_` followed by `sha1`, `sha256`, `b3`, `blake3`, `xxh` or `xxhash`, an underscore and the hash; that suffix is not a path hash), stores each entry's path hash in `snapshots.json`, reuses it on every sync and has no verification switch. Signing a history file in place therefore leaves its entry stale for good; a snapshot taken after signing copies an already-signed UKI and stays consistent.
- `limine-snapper-watcher`, the process of `limine-snapper-sync.service`, follows creations and deletions under `/.snapshots` and syncs after each, so deleting a snapshot retires its entry. A sync adds an entry for Snapper's newest snapshot only when that snapshot's UTC time is later than the `lastUTCTime` its `snapshots.json` holds, or equal with a higher number (`SnapshotManager.sync`, the same at 1.31.0 and 1.32.0): after a snapshot taken while the clock ran ahead, no new snapshot gets an entry until real time has passed that stamp (C10). A backup of `snapshots.json` lives on the root filesystem at `/var/lib/limine/snapshots.json`, so a restore rolls it back. sbctl's signatures are not reproducible, so a UKI that was rebuilt and signed again never deduplicates against its predecessor (README, "Why does my boot partition usage grow too fast?").
- A full restore (`limine-snapper-sync --restore`, which `limine-snapper-restore` runs without the boot lock) creates `/run/lock/limine-snapper-restore.lock` when it starts and removes it in its exit trap, so the lock is gone when the command returns; it runs the post-hooks while the lock stands, then offers a reboot (`/usr/bin/limine-snapper-sync`, 1.31.0).

## C3. Configuration layers

Source: limine-entry-tool 1.38.0, `limine-common-functions` (`load_config`) and `ConfigReader.java`.

Layers, last one wins: `/usr/share/limine-entry-tool.d/*.conf`, `/etc/limine-entry-tool.conf`, `/etc/limine-entry-tool.d/*.conf`, `/etc/default/limine`. `ENABLE_ENROLL_LIMINE_CONFIG` is reset to empty before the last layer, so it is honoured only in `/etc/default/limine`. `ENABLE_VERIFICATION`, `ENABLE_UKI`, `ENABLE_LIMINE_FALLBACK` (yes: deploy and overwrite on every `limine-update`; no: do nothing; unset: deploy only when missing), `FIND_BOOTLOADERS` and `ESP_PATH` are honoured in every layer. Upstream ships verification on and enrollment off. A line is `KEY=value` with optional blanks around the name and the equals sign; one trailing and one leading double quote are dropped, nothing else is interpreted, and the last assignment wins (`load_key_value_config`). Upstream uses `ESP_PATH` as a prefix (`"${ESP_PATH}/EFI/..."` in `limine-install`), so a trailing or doubled slash in it still names the ESP. With `ESP_PATH` empty, upstream takes the first of `/efi`, `/boot`, `/boot/efi` and `/limine` that is mounted vfat (`find_boot_partition`).

## C4. sbctl 0.18

Source: `Foxboron/sbctl` tag `0.18` (`cmd/sbctl/enroll-keys.go`, `verify.go`, `sign.go`, `list-files.go`, `remove-file.go`, `keys.go`, `sbctl.go`, `siglist.go`, `util.go`, `guid.go`, `backend/`, `lsm/`), go-uefi at the pinned revision.

- `create-keys` creates its directories itself and writes nothing when `keys/PK`, `keys/KEK` and `keys/db` already exist, so nothing may be pre-created under `/var/lib/sbctl`; its own commands leave that directory 755. Key files are written 0400, and the owner GUID 0644 only when it is absent (`backend/backend.go`, `guid.go`).
- sbctl confines itself with Landlock (`lsm/lsm.go`): beyond a few system files it reaches only the parent of its key directory, efivarfs, and its GUID and database files; `verify` adds the ESP and the tracked files, and an export adds the working directory. That is why `verify` answers `null` for any other file and why the export lands in the current directory.
- `enroll-keys` writes whole variables (never `EFI_VARIABLE_APPEND_WRITE`) in the order db, KEK, PK, stops at the first error and does not roll back. db is signed by the local KEK, KEK by the local PK, PK by itself; the OEM's keys are never needed in Setup Mode.
- `sbctl enroll-keys` writes PK, KEK and db only (`--partial [PK,KEK,db]`) and has no command for dbx: a dbx that a key menu cleared stays empty until a firmware update, fwupd or Windows writes it again.
- Every entry sbctl writes is owned by its own GUID (`KeySync` appends its certificates with `GetGUID`), which `status --json` reports as `guid`; `rotate-keys` keeps it. OmaSecBoot identifies the local certificates by that owner in a `--microsoft --export esl`, which does not read the firmware.
- `--append` reads the current db, KEK and PK and adds the local certificates to them, so nothing already trusted is removed.
  - It is not idempotent: a second run adds the local certificate again, because its duplicate check compares the PEM it holds with the DER in the variable.
  - OmaSecBoot does not depend on that: it never appends to a variable that already holds the certificate.
  - It also skips sbctl's option-ROM check, and on empty variables it yields local keys only.
  - With a PK in place an append export shows a PK of two entries, which firmware rejects (EDK2 `AuthService.c`: `IsPk && SigCount > 1`), so a PK is only ever written when none is present.
- `--partial <PK|KEK|db>` writes one variable and combines with `--append`.
- Without `--append`, `--microsoft` and `--firmware-builtin` build KEK and db from the local certificate, Microsoft's certificates and the firmware's `KEKDefault` and `dbDefault`, and the PK is the local certificate alone.
- `--export esl` honours `--append`, needs root and the local keys, needs neither Setup Mode nor `--ignore-immutable`, writes `db.esl`, `KEK.esl`, `PK.esl` into the current directory and is a faithful dry run; `--export auth` is not.
- Without `--append`, `--microsoft`, `--tpm-eventlog` or the force flag, sbctl first checks the TPM event log for option ROMs and refuses when it finds one, also for an export.
- Outside Setup Mode the firmware accepts a new PK only in a write that the PK in place signed (UEFI 2.10, 32.3.1), and the manufacturer holds that key, so only the firmware's own key menu can take a manufacturer's PK away.
- The kernel marks PK, KEK and db immutable in efivarfs. `--ignore-immutable` only skips sbctl's pre-check; the write path clears the flag itself. `chattr` is never needed.
- `sign-all` (run by `zz-sbctl.hook` after package transactions) signs every file in sbctl's database; a file that is not in the database is left alone. `sign` replaces the file in place: it truncates it and writes the signed image back, exits 0 on a file that is already signed, and `sign -s` does not register such a file.
- `verify --json FILE` exits 0 whatever it finds and answers with an array of one `{file_name, is_signed}` entry, `is_signed` being 1, 0, or -1 for a file that does not exist; for a file its sandbox may not read (anything outside the ESP and the tracked paths) it answers `null`, seen on 0.18-2. `status --json` carries `installed`. `list-files --json` is an array of `{file, output_file, is_signed}`; to fill `is_signed` it verifies, and so reads, every tracked file, and it leaves out rows whose file is gone. `remove-file PATH` drops one row. A Limine executable modified after signing cannot be re-signed (sbctl issue 408), so enrollment comes before signing.
- sbctl takes the ESP from the `ESP_PATH` environment variable when it is set and detects one otherwise (`GetESP`). OmaSecBoot always passes the ESP that Limine's configuration resolves, so the two tools agree on a machine with two ESPs (C10).
- `sbctl status --json` hides read errors of the mode variables; read them from efivarfs. There is no `--version`; `sbctl version` prints it.

## C5. systemd path units

Source: systemd 261 `src/core/path.c`, `systemd.path(5)`, `systemd.unit(5)`, `systemd-escape(1)`.

- `PathChanged=` fires on close-after-write, attribute change, deletion and a rename over the watched file, and re-arms by pathname afterwards.
- Changes that arrive while the triggered service runs are merged, not queued, so the service must look at the file's current state.
- A service that hits its start limit fails the path unit with it; `StartLimitIntervalSec=0` avoids that.
- A stop signals every process of the service unless `KillMode=mixed` is set, which sends SIGTERM to the main process alone and SIGKILL to the rest only after the stop timeout (`systemd.kill(5)`).
- Templates are valid: `%f` is the unescaped instance as a path, and the instance name comes from `systemd-escape --template=NAME@.path -p <file>`.
- Path units depend on the mount of the watched path implicitly.
- An enabled instance whose package was removed leaves a harmless dangling link that `systemctl disable` still removes.
- On the vfat ESP of C10 an instance fired both on a line appended to `limine.conf` and on a `cp` over the primary loader.

## C6. pacman and Omarchy

Source: `omacom/omarchy`, `quattro` branch at 4.0.4; `omacom/omarchy-iso` at `7cfb711` for the installer and at `10bd6632` for the maintainers' plan; pacman 7 (`alpm-hooks(5)`, `lib/libalpm/trans.c`); Arch's and Omarchy's package repositories on 2026-09-21.

**Omarchy**

- Defaults that matter: `ENABLE_UKI=yes` (in `/etc/limine-entry-tool.d/omarchy-uki.conf`, which `omarchy-settings` ships), `ENABLE_LIMINE_FALLBACK=yes`, `FIND_BOOTLOADERS=yes`, `MAX_SNAPSHOT_ENTRIES=6` with Snapper keeping 5 in its configuration `root`, `hash_mismatch_panic: no` in the `limine.conf` template, and an `/etc/default/limine` holding only `ESP_PATH` and the command line. On an install beside existing partitions the installer adds `ENABLE_LIMINE_FALLBACK=no` there (`phases_impl.py`, `_boot_intent`: `enable_fallback` is `not ctx.is_protected`), so such a machine starts without a fallback loader, and upstream never refreshes one that is added later. Omarchy features add drop-ins under `/etc/limine-entry-tool.d` at runtime that no package owns (`resume.conf`, `rtc-alarm.conf`, `omarchy-initramfs-async.conf`).
- Omarchy's installer (`omacom/omarchy-iso`, `orchestrator/phases_impl.py`, `_write_limine_pacman_hook`) leaves `/etc/pacman.d/hooks/99-omarchy-limine.hook`, owned by no package: after every upgrade of `limine` it copies `/usr/share/limine/BOOTX64.EFI` over `/boot/EFI/limine/limine_x64.efi` with a plain `cp`. It sorts after upstream's `80-limine-efi-deploy.hook`, so the loader that upstream has just sealed and signed is raw again, outside any Limine hook chain and any lock. Seen on the machine of C10 with Secure Boot on: without a watcher the loader stayed raw until `sign` ran (seen with commit `3b43368`); with one it was sealed and signed again three seconds after the copy, a second after pacman ended. An older install carries `99-limine.hook`, which copies to `EFI/BOOT` instead.
- `omarchy-refresh-limine` and `omarchy-reinstall-configs` move `limine.conf` aside and copy the template over it outside any lock, then run `limine-update` and `limine-snapper-sync`; anything appended to `limine.conf` by hand is lost. The template (`default/limine/limine.conf`) holds the global settings and no menu entry, and its `default_entry: 2` names the first kernel under the expanded Omarchy directory, counted from the top of the menu, so an entry written before Omarchy's changes what the timeout starts. Omarchy issue 7867 reports a Windows entry lost that way, and a dual-boot install that creates an ESP of its own beside Windows' (the two ESPs of C10).
- `omarchy update` takes a snapshot, runs pacman, then offers a reboot when the kernel changed. Nothing between those steps can block the reboot prompt; `omarchy-hook post-update` runs user hooks but cannot stop it.
- Opt-in security features are command pairs `omarchy-setup-security-<x>` and `omarchy-remove-security-<x>` (`#!/bin/bash`, `# omarchy:summary=`, `# omarchy:requires-sudo=true`) with menu rows in `default/omarchy/omarchy-menu.jsonc`; remove rows use a `when` guard that must be unprivileged and silent.
- The manual tells users to turn Secure Boot off (`omacom/omarchy`, `manual/02-getting-started.md`). Its "Dual Boot Install" page adds other systems to the menu with `limine-scan` ("run `limine-scan` and follow the prompts") and, where the installer reports BitLocker, has the user switch Device Encryption off in Windows first, so an Omarchy machine beside Windows often starts with encryption off, and its owner may switch it on again later.
- The maintainers' plan is `omacom/omarchy-iso`, `plans/consumer-secure-boot.md` (2026-08-15): a Microsoft-signed Omarchy shim for the ISO and the installed system, a machine-local Machine Owner Key that signs the UKIs, "No custom firmware key enrollment for v1 consumer installs", and another boot manager than Limine "unless we later prove Limine enforces signed payloads correctly". It names the signed shim as its critical path, and leaves open whether Limine can enforce verification of the UKIs and the config it loads, and how snapshot entries work with signed UKIs. Nothing of it is implemented.

**pacman and the repositories**

- pacman holds `db.lck` in its database directory from the start of a transaction until `alpm_trans_release`, which follows the post-transaction hooks (`lib/libalpm/trans.c`); a pacman that crashed leaves the file behind.
- `AbortOnFail` "only applies to PreTransaction hooks" (`alpm-hooks(5)`): a post-transaction hook that fails cannot stop or undo a transaction.
- Arch's `extra` ships `shim` 16.1-1, "EFI preloader (unsigned EFI binaries)". No repository of Arch or Omarchy ships a shim that Microsoft signed (`pacman -Ss '^shim'`, `pacman -Sl omarchy`, 2026-09-21). The AUR's `shim-signed` repackages Fedora's binaries, with Fedora's vendor certificate. Since 27 June 2026 Microsoft signs new shims under its 2023 certificate alone (rhboot/shim-review, README).

## C7. Firmware boot entries, `efi_boot_entry` and BootNext

Source: UEFI 2.10 sections 3.1.1 to 3.1.3, Limine's `CONFIG.md`, `ChangeLog` and `common/protos/efi_boot_entry.c` at v12.9.0, efibootmgr 18's usage text, Linux 7.2 `fs/efivarfs/vars.c`.

Hardware: the entry, the BootNext request and upstream's rewrites are recorded on the machine of C10.

- `BootOrder` is a list of little-endian uint16 numbers; `Boot####` (upper-case hex) is an `EFI_LOAD_OPTION`: uint32 attributes with bit 0 for active, the uint16 length of the device path, the description as NUL-terminated UTF-16, then device path nodes of type, subtype and uint16 length. A file path node is type 4, subtype 4, its text UTF-16. efivarfs puts four attribute bytes before every variable's data and lets any user read these variables. The kernel lists `Boot*`, `BootOrder` and `BootNext` as removable (`fs/efivarfs/vars.c`, `variable_validate`), so they never carry the immutable flag that PK, KEK and db do (C4).
- `efibootmgr --bootnext XXXX` sets `BootNext`, which the firmware consumes at the next start; when that entry cannot be started the firmware goes on with `BootOrder` (UEFI 2.10, 3.1.1).
- Windows registers `\EFI\Microsoft\Boot\bootmgfw.efi` as "Windows Boot Manager"; firmware compares such paths without case.
- Limine's `efi_boot_entry` protocol, added in Limine 11.0.0, takes `entry`, "the name of the EFI boot entry to reboot into". It takes the first entry of `BootOrder` whose description equals the name, folding ASCII case, sets `BootNext` and resets the machine (`efi_boot_entry.c`); an entry outside `BootOrder` ends in "Failed to find boot entry". OmaSecBoot therefore requires a target that stands in `BootOrder` and whose name no other `Boot####` variable shares.
- limine-entry-tool and limine-snapper-sync rewrite their own entries and keep a foreign top-level entry with its body; a comment line beside it is not safe. On the machine of C10 a snapshot sync and a regeneration of hashed entries each dropped the comment line that stood between the last snapshot entry and a trailing `/Windows` entry, and kept the entry and a comment line after it; a kernel reinstall kept all of it. Omarchy's `omarchy-refresh-limine` replaces the whole file (C6).

## C8. BitLocker and the TPM

Source: Microsoft Learn, "BitLocker drive encryption in Windows 11 for OEMs" (updated 2025-08-12), "Configure BitLocker" (updated 2025-07-29) and "manage-bde protectors" (updated 2026-02-16); the TCG PC Client Platform Firmware Profile; util-linux's libblkid.

Hardware: C10 holds what BitLocker did on one machine, Windows Home with device encryption.

- libblkid names a BitLocker volume's type `BitLocker`, which Device Encryption on Windows Home uses too; `lsblk --raw --noheadings --output PATH,FSTYPE` prints it from the udev database and needs no privileges.
- BitLocker's TPM binding, in Microsoft's words: "When Secure Boot State (PCR7) support is available, the default platform validation profile secures the encryption key using Secure Boot State (PCR 7) and the BitLocker access control (PCR 11)"; otherwise the UEFI default is PCR 0, 2, 4 and 11, where PCR 4 is the "Boot Manager".
  - PCR 7 holds the contents of `SecureBoot`, PK, KEK, db and dbx, then the db entries that verified what ran in the boot path, and "BitLocker expects only one entry here": "Any extra CA hash (even Windows Prod CA) before final bootmgr Windows Prod CA will prevent BitLocker from choosing to use PCR7." So every change of PK, KEK or db changes PCR 7, and a loader verified with another certificate before `bootmgfw.efi` rules the PCR 7 binding out.
  - The firmware measures every UEFI application it loads into PCR 4 (TCG), so a chainload leaves the Limine loader there as well. PCRs start anew at a restart, and both `efi_boot_entry` and a BootNext request start Windows only after one.
  - Microsoft's procedure, in the page for OEMs, for a device bound to PCR 7 when "the Secure Boot policy" changes: suspend BitLocker, apply, restart, resume.
  - `manage-bde -protectors -disable <drive> -RebootCount 0` suspends protection "indefinitely" by "making the encryption key available unsecured on drive", nothing is decrypted, and `-enable` resumes it; without a count, protection resumes "after Windows is restarted" (Microsoft Learn, "manage-bde protectors", updated 2026-02-16). Its page names no edition of Windows.

## C9. Microsoft's 2011 and 2023 Secure Boot certificates

Source: Microsoft's support article "Windows Secure Boot certificate expiration and CA updates" as updated on 2026-05-18; the certificates `Foxboron/sbctl` tag `0.18` ships under `certs/microsoft/`, with their own expiry dates.

- The 2011 certificates expire in 2026: Microsoft Corporation KEK CA 2011 (KEK, 24 June), which signs Microsoft's updates to db and dbx; Microsoft Corporation UEFI CA 2011 (db, 27 June), for third-party loaders and option ROMs; Microsoft Windows Production PCA 2011 (db, 19 October), for the Windows boot loader.
- Their replacements: Microsoft Corporation KEK 2K CA 2023 in KEK; Windows UEFI CA 2023, Microsoft UEFI CA 2023 and Microsoft Option ROM UEFI CA 2023 in db.
- Microsoft: a machine without the new certificates keeps starting and keeps installing ordinary updates, but no longer receives new protections for the early boot process: boot manager updates, database updates and revocations.
- A KEK update must be signed by the Platform Key's owner. Once the PK is the user's, the manufacturer's updates can no longer add the 2023 KEK certificate; with it in KEK, Microsoft's db and dbx updates keep arriving, the three db certificates among them.
- The SHA-256 of each certificate's DER form, which is what a signature-list entry holds:
  - Microsoft Corporation KEK 2K CA 2023: `3cd3f0309edae228767a976dd40d9f4affc4fbd5218f2e8cc3c9dd97e8ac6f9d`
  - Windows UEFI CA 2023: `076f1fea90ac29155ebf77c17682f75f1fdd1be196da302dc8461e350a9ae330`
  - Microsoft UEFI CA 2023: `f6124e34125bee3fe6d79a574eaa7b91c0e7bd9d929c1a321178efd611dad901`
  - Microsoft Option ROM UEFI CA 2023: `e5be3e64c6e66a281457ecdece0d6d0787577aad2a3a0144262c10c14ba8d8f1`
- sbctl 0.18 carries all seven for `--microsoft`, so the rebuild path of enrollment writes the 2023 certificates; the append path writes none of Microsoft's and keeps what the firmware held (C4).

## C10. Hardware record

ASUS Vivobook TP3402VA, AMI BIOS 307, with Omarchy 4.0.4. The release's record: stages 0 to 7 of [release-checklist.md](release-checklist.md) with commit `2a8d324` on 2026-09-22, Windows Home beside it with device encryption on, the recovery key at hand and nothing suspended, 88 rows, every one as the checklist expects. Two earlier runs on the same machine, `d567e1f` (stages 0 to 6, encryption off) and `ccc6e8a` (stages 0 to 7 without the rows that need a snapshot entry, encryption on), are the source of the observations marked with their commit. One change to the tool followed the release's record: the pass writes the Windows entry only beside Omarchy's entries and moves one that stands before them (the observation under Windows below). It is proved by its hermetic cases and by a replay of the readers over the 172 `limine.conf` files the records captured; checklist 5.4 of the next run records it on hardware.

- Boot files and the tools:
  - A stock install carries path hashes of unsigned UKIs; after setup the OS entry was regenerated without a hash, while two snapshot entries older than enrollment stayed stale once their history files had been signed in place, as a trial, and limine-snapper-sync did not rewrite them (seen with commit `3b43368`).
  - sbctl refused to create keys into directories made beforehand, and created `/var/lib/sbctl` with mode 755 (C4). `gum confirm` without a terminal declined without a word. A kernel install held the boot lock for a minute.
  - The hook alone, run as the Limine tools run it, took 1.1 seconds with two kernels installed. The watcher sealed the loader again within a second of a change to `limine.conf`, under its service's `NoNewPrivileges`, `PrivateNetwork` and `ProtectHome`.
  - With Secure Boot on, SIGTERM stopped a `sign` after it had sealed and signed its staged copy and before the rename. The primary loader stayed sealed over the `limine.conf` from before the drill's edit, which Limine refuses (C1). The next `sign` rebuilt the loader and swept the staged copy, and `status` passed.
- The fallback loader:
  - The machine has two ESPs (Omarchy's and Windows'), `ENABLE_LIMINE_FALLBACK=no` as the installer wrote it (C6) and no fallback loader until `limine-install --fallback` added one. The firmware's boot menu lists that loader as "UEFI OS", and it started the machine with Secure Boot off while the sealed primary refused. With nothing at the fallback path, `setup` asked, ran upstream's step and left the package's raw loader there and the installer's setting as it was. With a loader that is not Limine's at that path under the lower-case name `bootx64.efi`, as another system writes it, `setup` found it under the upper-case name, asked nothing and left it byte for byte (seen with commit `5e98d09`).
- Firmware and enrollment:
  - The firmware exposes neither AuditMode nor DeployedMode (pre-UEFI 2.5 model). Its key menu appears only while Secure Boot is set to enabled. Deleting only the PK keeps KEK, db and dbx and enters Setup Mode.
  - Per-variable writes of db, KEK and PK over the immutable variables succeeded with `--ignore-immutable` and read back exactly. After the PK write, `SetupMode` kept reading 1 until the next boot, although the variables already held the new keys; enrollment must be judged by the variables.
  - Deleting only the PK kept all eight KEK and db entries; the append wrote db, KEK and PK, each read back, and the machine started with Secure Boot on.
  - The key menu's "clear every key" emptied PK, KEK, db and dbx. `setup` said so, found every KEK and db entry of the backup in what sbctl can put back, warned that dbx differed, asked, and wrote db, KEK and PK, each read back; the machine and Windows started with Secure Boot on (seen with commit `ccc6e8a`).
  - KEK held Microsoft Corporation KEK 2K CA 2023, and db held Windows UEFI CA 2023 and Microsoft UEFI CA 2023 but not Microsoft Option ROM UEFI CA 2023 (C9): a firmware can carry a part of the 2023 set.
- Snapshots:
  - An entry that predates enrollment does not start with Secure Boot on: the firmware refuses the unsigned image, and Limine reports `PANIC: efi: LoadImage failure (0x800000000000000f)`, which is the firmware's `EFI_ACCESS_DENIED` (UEFI 2.10, Appendix D), and halts, so the machine needs a power cycle. The entry of a snapshot taken after `setup` started.
  - The restore of stage 4 ran from inside that entry; `sign` and `status` passed after it.
  - Three snapshots got no menu entry although Snapper made them and the watcher synced: `snapshots.json` held a `lastUTCTime` four hours in the future, from a snapshot taken while the clock ran ahead by the machine's UTC offset, as it does when Windows has written local time to the hardware clock (C2; seen with commit `ccc6e8a`).
  - Inside the booted snapshot `snapper list` failed ("subvolume is not a btrfs subvolume"), and `limine-snapper-restore` offered the snapshot it ran in, with a list on request. During the restore upstream printed its verification-hash warning (C2). The restored system started with Secure Boot on, `ENABLE_VERIFICATION=no` still in place.
- Windows:
  - Limine's `efi_boot_entry` entry and a BootNext request each started Windows Boot Manager with Secure Boot on and the user's keys enrolled, and the boot after BootNext returned to Limine.
  - `omarchy refresh limine` with the entry enabled: the watcher fired on the template copy and the pass wrote the entry into it before `limine-update` filled it, so the entry stood first, Omarchy's `default_entry` pointed at the directory line, and the timeout no longer started Omarchy's kernel (C6; seen with commit `2a8d324`).
- BitLocker (device encryption on Windows Home, the recovery key at hand, nothing suspended; seen with commits `ccc6e8a` and `2a8d324`):
  - It asked for the recovery key when Secure Boot went from on to off while the protector was bound to PCR 7 and 11, twice; after the first, Windows also asked for a new sign-in PIN. Afterwards the profile read 0, 2, 4, 11.
  - With Secure Boot off and that profile it asked at none of the key changes: factory keys restored, the PK deleted, the user's keys written, every key cleared and rebuilt. It did not ask when Secure Boot went on with the user's keys, at the first or the second start, and the profile stayed 0, 2, 4, 11.
  - After `manage-bde -protectors -disable C:` and `-enable C:` the profile read 7, 11 with the user's keys in the firmware, and Windows stayed quiet. Windows Home accepted the command with and without `-RebootCount 0` (seen on screen, outside the records).
  - It did not tell the firmware's boot menu, the tool's `efi_boot_entry` entry and a BootNext request apart, under either profile, while `limine.conf` was rewritten and the loader sealed again several times in between.
  - With Secure Boot on and the profile 7, 11, the first start through a `limine-scan` chainload entry asked for the key and a new PIN, the second did not, and the next start through the tool's entry asked again. Whether a chainload start survives a re-seal of the loader has no record.
- The package:
  - pacman printed the package's removal warning while the machine was set up and removed the package. After a reinstall the two watchers were still active and `status` passed; after `remove`, a second removal printed nothing.
