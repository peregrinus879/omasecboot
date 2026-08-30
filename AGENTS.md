# AGENTS.md - OmaSecBoot

OmaSecBoot: sbctl signing, Limine enrollment, pacman hook, and Windows BootNext handoff for Omarchy.

Naming boundary: `OmaSecBoot` is the product/display name; `omasecboot` is the sole user command and machine-facing namespace. The command, library, state, hooks, Windows marker, and Limine hook protocol use the canonical namespace.

## Load Map

- `README.md` carries user-facing setup, commands, design, recovery, and troubleshooting guidance.
- `docs/maintenance.md` is the on-demand ledger for primary sources, versioned compatibility findings, workaround removal triggers, and deferred work. Read it before changing Secure Boot flow, sbctl tracking, Limine configuration semantics, pacman hooks, UKI handling, Windows dual-boot behavior, or a deferred item; re-fetch changeable facts at change time.
- `docs/implementation-contract.md` is the package-first implementation contract for lifecycle, firmware, Windows, packaging, Omarchy integration, public claims, and atomic delivery.
- Reference repository purposes and upstream sources are recorded in the maintenance ledger; do not assume a contributor's local checkout layout.

## Key Files

- `README.md` - User documentation, design philosophy, troubleshooting
- `bin/omasecboot` - Entry point and command dispatcher
- `lib/*.sh` - Modular function libraries (common, lifecycle, checks, discover, sign, enroll, windows, status)
- `pacman-hooks/00-omasecboot-transition-guard.hook` - PreTransaction guard for boot paths and producer packages
- `pacman-hooks/zz-omasecboot-cleanup.hook` - Pre-sbctl lifecycle checkpoint, ordered before `zz-sbctl.hook`
- `pacman-hooks/zzz-omasecboot.hook` - Post-sbctl lifecycle checkpoint for boot paths and producer packages
- `limine-hooks/000-omasecboot-guard` - Limine pre-hook for lifecycle and FD 200 ownership validation
- `limine-hooks/zzz-omasecboot-sign` - Limine post-hook for owned suppression or serialized recovery recording
- `tests/lifecycle.sh`, `tests/artifacts.sh`, `tests/hooks.sh`, `tests/guards.sh`, `tests/dispatcher.sh` - Hermetic lifecycle, artifact-proof, and failure-injection checks
- `tests/install.sh` - Staged install, upgrade, hook-target, and uninstall contract checks
- `tests/windows.sh` - Hermetic Windows firmware handoff and Quattro menu contract checks
- `tests/windows-preflight.sh` - Hermetic Windows signal, encryption guidance, advisory signer, privilege-drop, and no-NTFS checks
- `tests/windows-entry.sh` - Hermetic managed-marker and idempotence checks
- `omarchy/omarchy-menu.jsonc` - Quattro user-menu fragment for graceful reboot-to-Windows handoff
- `docs/implementation-contract.md` - Remaining implementation and release-gate contract
- `docs/maintenance.md` - On-demand sources, compatibility findings, removal triggers, and deferred work
- `Makefile` - Install/uninstall targets

## Architecture

Single dispatcher sources lib modules. Each lib file owns one concern:
- `common.sh` - constants, colors, output helpers, quiet mode
- `lifecycle.sh` - versioned state, durable manifests, transaction handling, hook ownership, and guards
- `checks.sh` - root, deps, EFI mount, gum validation
- `discover.sh` - EFI file discovery, sbctl tracked-file discovery, sbctl database fallback helpers
- `sign.sh` - key creation, signing, sbctl compatibility registration, stale entry cleanup, Limine verification/enrollment helpers
- `enroll.sh` - key enrollment with `-m -f` flags
- `windows.sh` - Windows firmware BootNext handoff and Limine `efi_boot_entry` management
- `status.sh` - status display, hook checks, Limine verification/enrollment checks, tracked vs discovered EFI verification

## Dependencies

sbctl, jq, gum (interactive only), efibootmgr, util-linux, and sbsigntools. Omarchy provides the rest (`limine-update`, `limine-enroll-config`, `limine-reset-enroll`, `limine-snapper-sync`).

## Approved Implementation Contracts

The current implementation provides the lifecycle boundary, tested artifact-proof transaction, validated Windows target identity, and read-only Windows encryption preflight, but deliberately reports repair capability unavailable until interrupted recovery lands. `setup`, `enroll`, `sign`, `cleanup`, Windows mutation, active producer automation, and uninstall remain blocked. The remaining contracts are mandatory for the package-first release and must not be described as shipped until their implementation and tests land.

- Preserve the naming and deployment contracts above, including the durable Windows opt-in in canonical state.
- Durable lifecycle state distinguishes `unmanaged`, `disabled`, `active`, `transition`, and `recovery-required`. A top-level mutation writes its root-owned manifest and backups before mutation, commits stable state last, and leaves `recovery-required` when rollback fails. Existing unrecorded configurations require explicit adoption; never infer their original defaults.
- Hook suppression is valid only for an owned transition whose token, boot ID, owner PID and process start time, ancestry, and root-owned manifest agree. An environment boolean is not ownership proof.
- `setup` and `sign` maintain signed EFI binaries plus enrolled `limine.conf` checksums with `ENABLE_VERIFICATION=no` and `ENABLE_ENROLL_LIMINE_CONFIG=yes`. Keep `ensure_limine_secure_boot_settings` in the sign path and keep its Quattro write target at `/etc/default/limine`, outside package-owned drop-ins.
- Do not reintroduce Limine `path: ...#hash` management while Omarchy boots UKIs through `protocol: efi`. Warn on incompatible non-EFI paths instead of mutating them automatically.
- limine-snapper-sync snapshot filenames can end in `.efi_sha256_<hash>`, `.efi_sha1_*`, `.efi_b3_*`, or `.efi_xxh_*`; that suffix belongs to the filename and is not a Limine path hash.
- Limine strips leading whitespace and generated sub-entries are indented. Entry-boundary parsers in `status.sh` must match trimmed lines rather than column-zero markers.
- `with_limine_lock` uses `/run/lock/boot-partition.lock`, the mutex shared with limine-entry-tool and limine-snapper-sync. Validate inherited descriptor ownership and the current pathname's device and inode, then call `flock` on inherited FD 200 before entering the critical section. A different pathname, an unchecked inherited FD, or validation without locking does not serialize boot mutations.
- A Limine pre-hook rejects external hook-aware mutation during an OmaSecBoot transition. A post-hook validates and locks inherited FD 200 or acquires the shared lock itself before repair. ALPM PreTransaction guards block boot-mutating package transactions during `transition` and `recovery-required`, and block package removal until state is verified `disabled` or pristine.
- Keep repair capability unavailable until interrupted recovery can handle stale manual, Limine, snapshot, and package mutations. Artifact proof alone does not authorize producer automation, and a PostTransaction backup cannot represent a package artifact's pre-transaction state.
- Pausing `limine-snapper-sync.service` is auxiliary quiescing, not the concurrency boundary. Snapper plugins, transient units, cleanup, and full restore are separate producers. Full `limine-snapper-restore` has no parent shared lock on the audited release; allow it only in stable state, serialize post-repair, and reject it during `transition` and `recovery-required`.
- `cmd_setup()` is the provisioning path and may regenerate Limine-managed boot state. `cmd_sign()` is the lightweight repair path and must not call `limine-update` or rebuild UKIs.
- `cmd_setup()` and `cmd_sign()` run `sign_all_efi()` as their final mutation. Config repair and checksum re-enrollment happen before signing.
- Keep `sign_all_efi()` in `cmd_sign()` so new snapshot UKIs are discovered and registered; `zz-sbctl.hook` re-signs only files already known to sbctl.
- Keep current-config enrollment in `cmd_sign()`. Do not rely only on change-since-start detection or upstream exit status. Enroll and directly verify the current checksum in both `/EFI/limine/limine_x64.efi` and `/EFI/BOOT/BOOTX64.EFI` before final signing.
- Build each enrolled Limine target from the unsigned package executable in a same-directory staging file. Enroll, locally sign, directly verify, and sync the staging file before atomically replacing the target; never durably publish an unsigned boot target.
- Reject higher-priority Limine config candidates on the ESP before proving `/boot/limine.conf`; a signed binary containing the wrong config checksum is not a successful proof.
- Enrollment or Secure Boot enablement instructions require a read-only proof after final signing that every discovered non-Microsoft EFI artifact has the local signature and sbctl tracking state.
- Prefer `sbctl list-files` as the tracked-file source of truth. Resolve `files_db` from one explicit plain top-level scalar in `/etc/sbctl/sbctl.conf`; without that file, match sbctl 0.18's legacy `/usr/share/secureboot/files.db` selection or `/var/lib/sbctl/files.json` default. Unsupported config syntax fails closed. Direct database reads are fallback and cleanup/compatibility paths.
- Retain `save_sbctl_file_entry()` while Arch ships the affected sbctl release; its evidence and removal trigger live in `docs/maintenance.md`.
- Pacman PostTransaction ordering must remain `zz-omasecboot-cleanup` before `zz-sbctl` before `zzz-omasecboot`. The cleanup hook mirrors `zz-sbctl.hook` path triggers; other hooks may sort between them. Package repair and the Limine post-hook cover different mutation sources and are not redundant.
- Windows uses `protocol: efi_boot_entry` so the managed path requests a direct firmware handoff instead of chainloading Windows through Limine. BootNext is a one-boot request; do not claim successful Windows boot, PCR7 binding, stable measurements, or absence of BitLocker recovery.
- Safe Windows targeting parses BootOrder and the exact `File(\EFI\Microsoft\Boot\bootmgfw.efi)` device path, maps the GPT HD node to one FAT ESP, validates the loader read-only, requires one active target and a case-insensitively unique Limine label, and proves numeric and Limine resolution agree. Reject ambiguity and never create or relabel firmware entries automatically.
- Keep enrollment and signing in interactive `add_windows_boot_entry()` so `windows setup` completes the full mutation cycle in one invocation.
- `status` may identify Quattro's native `protocol: efi` Windows chainloads but never removes them automatically. Prefer minimal repo-owned automation over replacing mkinitcpio, limine-entry-tool, or limine-snapper-sync behavior.
- `omarchy/omarchy-menu.jsonc` is a user-owned menu fragment. Its guard runs inside Quattro's batched guard shell, stays unprivileged and non-interactive, and requires the packaged command plus durable Windows opt-in. Its visible-terminal action runs privileged `/usr/bin/omasecboot windows bootnext` before user-context `omarchy system reboot`. Never execute that action during automated or deployment verification.
- Treat Windows disk-check prompts separately from BitLocker recovery. OmaSecBoot never mounts or modifies NTFS and never infers hibernation from a failed mount.
- Windows Home follows Microsoft's documented Device Encryption decryption workflow; do not offer undocumented Home suspension. Pro, Enterprise, and Education may use documented BitLocker suspension. Managed devices require administrator approval.
- The Windows preflight evaluates firmware options, direct BitLocker signatures, and Microsoft loaders on internal GPT ESPs independently as `present`, `absent`, or `unknown`. A complete negative is a bounded observation, not firmware clearance. Every positive or unknown run requires an encryption-state check and recovery-key preparation acknowledgment. Any technical unknown prints preparation guidance, returns nonzero, and has no override that a firmware-mutating command may consume.
- External ESPs are not mounted or PE-parsed. Internal boot managers are copied under the boot and repair locks, then inspected through inherited FD 3 by `sbverify --list` after `setpriv` drops to `nobody`, clears groups and capabilities, resets the environment, and sets `no_new_privs`. Signer output is untrusted input and recognized issuer metadata never relaxes the preparation checklist.
- Windows boot-manager signature inspection is advisory unless a complete db and dbx verifier is implemented and tested. Stock `sbverify --cert` is not firmware-bootability proof. Keep util-linux and sbsigntools in the T-7 package dependencies; recheck current Microsoft sources before recognizing a new issuer.
- Before any Setup Mode instruction, back up raw PK, KEK, db, and dbx data, attributes, hashes, absence records, and machine identity. Unknown or unsupported trust entries that the planned `-m -f` set would lose block v1 enrollment; never preserve by subject name or repair with `--append`.
- Keep software `unconfigure`, PK reset, raw-key recovery, and firmware factory restoration distinct. Package removal is permitted from verified `disabled` or pristine state, preserves lifecycle, transactions, firmware backups, durable Windows opt-in, local sbctl keys, and the stable lock pathname, and removes only `omasecboot`.

## Post-Change Verification

- Run `make test` after code, hook, install, or menu changes.
- Run `bash -n bin/omasecboot lib/*.sh limine-hooks/* tests/*.sh` and `shellcheck` over the same shell files.
- Parse `omarchy/omarchy-menu.jsonc` with `jq` after menu changes.

## Conventions

- Bash with `set -euo pipefail`
- ShellCheck clean
- No `--` prefix on subcommands (`setup` not `--setup`)
- Output helpers: `pass()`, `fail()`, `warn()`, `act()`, `die()`
- Quiet mode via `QUIET=true` (set by `--quiet` flag)
