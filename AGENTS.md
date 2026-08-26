# AGENTS.md - OmaSecBoot

OmaSecBoot: sbctl signing, Limine enrollment, pacman hook, and Windows BootNext handoff for Omarchy.

Naming boundary: `OmaSecBoot` is the product/display name; `omasecboot` is the sole user command and machine-facing namespace. The command, library, state, hooks, Windows marker, and Limine-hook sentinel use the canonical namespace.

## Load Map

- `README.md` carries user-facing setup, commands, design, recovery, and troubleshooting guidance.
- `docs/maintenance.md` is the on-demand ledger for primary sources, versioned compatibility findings, workaround removal triggers, and deferred work. Read it before changing Secure Boot flow, sbctl tracking, Limine configuration semantics, pacman hooks, UKI handling, Windows dual-boot behavior, or a deferred item; re-fetch changeable facts at change time.
- Reference checkouts live under `~/Projects/quarry/`; their exact paths and purposes are recorded in the maintenance ledger.

## Key Files

- `README.md` - User documentation, design philosophy, troubleshooting
- `bin/omasecboot` - Entry point and command dispatcher
- `lib/*.sh` - Modular function libraries (common, checks, discover, sign, enroll, windows, status)
- `pacman-hooks/zz-omasecboot-cleanup.hook` - Pacman hook that removes stale sbctl entries before `zz-sbctl.hook` runs
- `pacman-hooks/zzz-omasecboot.hook` - Pacman hook that runs `sign` after kernel, bootloader, or snapshot-related package updates
- `limine-hooks/zzz-omasecboot-sign` - Limine post-hook that runs `sign` after upstream Limine tools mutate boot files
- `tests/install.sh` - Staged install, upgrade, hook-target, and uninstall contract checks
- `tests/windows.sh` - Hermetic Windows firmware handoff and Quattro menu contract checks
- `tests/windows-entry.sh` - Hermetic managed-marker and idempotence checks
- `omarchy/omarchy-menu.jsonc` - Quattro user-menu fragment for graceful reboot-to-Windows handoff
- `docs/maintenance.md` - On-demand sources, compatibility findings, removal triggers, and deferred work
- `Makefile` - Install/uninstall targets

## Architecture

Single dispatcher sources lib modules. Each lib file owns one concern:
- `common.sh` - constants, colors, output helpers, quiet mode
- `checks.sh` - root, deps, EFI mount, gum validation
- `discover.sh` - EFI file discovery, sbctl tracked-file discovery, sbctl database fallback helpers
- `sign.sh` - key creation, signing, sbctl compatibility registration, stale entry cleanup, Limine verification/enrollment helpers
- `enroll.sh` - key enrollment with `-m -f` flags
- `windows.sh` - Windows firmware BootNext handoff and Limine `efi_boot_entry` management
- `status.sh` - status display, hook checks, Limine verification/enrollment checks, tracked vs discovered EFI verification

## Dependencies

sbctl, jq, gum (interactive only). Omarchy provides the rest (`limine-update`, `limine-enroll-config`, `limine-reset-enroll`, `limine-snapper-sync`).

## Operational Invariants

- Preserve the naming and deployment contracts above, including the durable Windows opt-in in canonical state.
- `setup` and `sign` maintain signed EFI binaries plus enrolled `limine.conf` checksums with `ENABLE_VERIFICATION=no` and `ENABLE_ENROLL_LIMINE_CONFIG=yes`. Keep `ensure_limine_secure_boot_settings` in the sign path and keep its Quattro write target at `/etc/default/limine`, outside package-owned drop-ins.
- Do not reintroduce Limine `path: ...#hash` management while Omarchy boots UKIs through `protocol: efi`. Warn on incompatible non-EFI paths instead of mutating them automatically.
- limine-snapper-sync snapshot filenames can end in `.efi_sha256_<hash>`, `.efi_sha1_*`, `.efi_b3_*`, or `.efi_xxh_*`; that suffix belongs to the filename and is not a Limine path hash.
- Limine strips leading whitespace and generated sub-entries are indented. Entry-boundary parsers in `status.sh` must match trimmed lines rather than column-zero markers.
- `with_limine_lock` uses `/run/lock/boot-partition.lock`, the mutex shared with limine-entry-tool and limine-snapper-sync. A different path does not serialize boot mutations.
- `cmd_setup()` is the provisioning path and may regenerate Limine-managed boot state. `cmd_sign()` is the lightweight repair path and must not call `limine-update` or rebuild UKIs.
- `cmd_setup()` and `cmd_sign()` run `sign_all_efi()` as their final mutation. Config repair and checksum re-enrollment happen before signing.
- Keep `sign_all_efi()` in `cmd_sign()` so new snapshot UKIs are discovered and registered; `zz-sbctl.hook` re-signs only files already known to sbctl.
- Keep `reenroll_limine_config_if_changed()` in `cmd_sign()` so repo-restored `limine.conf` changes are enrolled without duplicating upstream enrollment.
- Prefer `sbctl list-files` as the tracked-file source of truth. Direct database reads are fallback and cleanup/compatibility paths; prefer `files.db` over `files.json`.
- Retain `save_sbctl_file_entry()` while Arch ships the affected sbctl release; its evidence and removal trigger live in `docs/maintenance.md`.
- Pacman PostTransaction ordering must remain `zz-omasecboot-cleanup` before `zz-sbctl` before `zzz-omasecboot`. The cleanup hook mirrors `zz-sbctl.hook` path triggers; other hooks may sort between them. Package repair and the Limine post-hook cover different mutation sources and are not redundant.
- Windows uses `protocol: efi_boot_entry` so firmware BootNext launches `bootmgfw.efi` without measuring mutable `limine_x64.efi` in the Windows boot chain. Detect Windows by loader path, not firmware label. `windows bootnext` only arms BootNext; `windows reboot` arms it and reboots.
- Keep enrollment and signing in interactive `add_windows_boot_entry()` so `windows setup` completes the full mutation cycle in one invocation.
- `status` may identify Quattro's native `protocol: efi` Windows chainloads but never removes them automatically. Prefer minimal repo-owned automation over replacing mkinitcpio, limine-entry-tool, or limine-snapper-sync behavior.
- `omarchy/omarchy-menu.jsonc` is a user-owned menu fragment. Its guard runs inside Quattro's batched guard shell, so it stays unprivileged, non-interactive, and `command -v`-based (package-presence checks cannot see a `make`-installed binary); its visible-terminal action runs privileged `windows bootnext` before user-context `omarchy system reboot`. Never execute that action during automated or deployment verification.
- Treat Windows disk-check prompts separately from BitLocker recovery; troubleshoot the Windows dirty bit, interrupted shutdown/update, Fast Startup or hibernation, duplicate firmware entries, and NTFS mounts before changing Secure Boot flow.

## Post-Change Verification

- Run `make test` after code, hook, install, or menu changes.
- Run `bash -n bin/omasecboot lib/*.sh limine-hooks/zzz-omasecboot-sign tests/*.sh` and `shellcheck` over the same shell files.
- Parse `omarchy/omarchy-menu.jsonc` with `jq` after menu changes.

## Conventions

- Bash with `set -euo pipefail`
- ShellCheck clean
- No `--` prefix on subcommands (`setup` not `--setup`)
- Output helpers: `pass()`, `fail()`, `warn()`, `act()`, `die()`
- Quiet mode via `QUIET=true` (set by `--quiet` flag)
