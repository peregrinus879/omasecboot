# Maintenance

Open work, the evidence still owed, and what triggers a recheck. A closed item leaves this page; Git history keeps it.

## Open work before a release

- Firmware enrollment ([spec.md](spec.md) D4 and the `setup` row) is written and covered by the hermetic suite, whose sbctl stub models C4. Done when stage 2 of [release-checklist.md](release-checklist.md) passes on hardware; until then nothing about a firmware write is proven.
- The Windows entry, the BootNext request and the encryption acknowledgment are written and covered by the hermetic suite, whose fixtures model C8. Done when stage 5 passes on hardware.
- The Omarchy side in [omarchy-integration.md](omarchy-integration.md), agreed with the maintainers.
- Hardware acceptance, stages 0 to 6, on at least one machine.

## Remove when no longer needed

- Leftover detection (`leftover_candidates` in `lib/status.sh`, its `setup` refusal and failure-table row): it covers installs of the pre-package version that were copied into place from this repository. Drop it one release after 1.0.0.

## Evidence owed

- This tool has no hardware record yet. Every claim about boot behaviour rests on [upstream-contracts.md](upstream-contracts.md) until stage 1 runs.
- The weekly contract job has not run on GitHub yet; its first run proves the container setup, not the suites, which pass locally against the versions [upstream-contracts.md](upstream-contracts.md) names. GitHub disables scheduled workflows in a public repository after 60 days without activity, so the workflow needs re-enabling after a quiet period.
- The budget of two seconds per installed kernel for the hook is unmeasured; stage 1 measures it.
- How `sbctl enroll-keys --firmware-builtin` behaves on firmware without `KEKDefault` or `dbDefault` is unverified; the tool does not ask sbctl for it there. How firmware answers a write outside Setup Mode is an assumption of the test stub only, because the tool never attempts one.

## Recheck when a package changes

| Package | Recheck |
| --- | --- |
| `limine` | C1: the checksum marker, the unconditional check, the lookup order of `limine.conf` |
| `limine-mkinitcpio-hook`, `limine-entry-tool` | C2 and C3: hook names 89, 90 and 91 (ours sorts between the last two), the loader backup `limine_x64.bak`, `limine-install --no-efi-register`, the lock path and descriptor, the configuration layers |
| `limine-snapper-sync` | C2: history file names, `snapshots.json`, the restore marker |
| `sbctl` | C4, every bullet; above all the owner GUID in `status --json`, the ESL export honouring `--append` with a PK in place, and `--partial` combined with `--append`, `--microsoft` and `--firmware-builtin` |
| `systemd` | C5: `PathChanged=` semantics and the start limit |
| `efibootmgr`, `limine`, `util-linux` | C8: `--bootnext`, the `efi_boot_entry` protocol and its `entry` option, `lsblk`'s `BitLocker` type |
| `omarchy` | C7: the default settings, `omarchy-refresh-limine`, the security command pairs |
