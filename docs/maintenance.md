# Maintenance

Open work, the evidence still owed, and what triggers a recheck. A closed item leaves this page; Git history keeps it.

## Open work before a release

- Firmware enrollment ([spec.md](spec.md) D4 and the `setup` row): the backup, the signature-list reader, the proofs, the per-variable append and the confirmation. Done when the enrollment stage of hardware acceptance passes.
- The Windows entry, the BootNext request and the encryption acknowledgment before the firmware steps (the `windows` commands in the spec). Done when the Windows stage of hardware acceptance passes.
- The Omarchy side in [omarchy-integration.md](omarchy-integration.md), agreed with the maintainers.
- The real-tool contract suites and the weekly CI job of spec section 11.
- Hardware acceptance, stages 0 to 6, on at least one machine.

## Remove when no longer needed

- Leftover detection (`leftover_candidates` in `lib/status.sh`, its `setup` refusal and failure-table row): it covers installs of the pre-package version that were copied into place from this repository. Drop it one release after 1.0.0.

## Evidence owed

- This tool has no hardware record yet. Every claim about boot behaviour rests on [upstream-contracts.md](upstream-contracts.md) until stage 1 runs.
- C4's `sbctl verify`, `list-files` and `sign` answers come from sbctl's source, plus the `null` and `-1` answers seen unprivileged; the real-sbctl suite replaces that reading.
- The budget of two seconds per installed kernel for the hook is unmeasured; stage 1 measures it.

## Recheck when a package changes

| Package | Recheck |
| --- | --- |
| `limine` | C1: the checksum marker, the unconditional check, the lookup order of `limine.conf` |
| `limine-mkinitcpio-hook`, `limine-entry-tool` | C2 and C3: hook names 89, 90 and 91 (ours sorts between the last two), the loader backup `limine_x64.bak`, `limine-install --no-efi-register`, the lock path and descriptor, the configuration layers |
| `limine-snapper-sync` | C2: history file names, `snapshots.json`, the restore marker |
| `sbctl` | C4, every bullet |
| `systemd` | C5: `PathChanged=` semantics and the start limit |
| `omarchy` | C7: the default settings, `omarchy-refresh-limine`, the security command pairs |
