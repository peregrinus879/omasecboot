# Maintenance

Open work, the evidence still owed, and what triggers a recheck. A closed item leaves this page; Git history keeps it.

## Open work before a release

- The Omarchy side in [omarchy-integration.md](omarchy-integration.md), agreed with the maintainers.
- The two rows of stage 3 that the accepted machine still owes, each as a record: starting a snapshot entry taken after `setup` with Secure Boot on, and what Limine and the firmware show for an entry that predates enrollment.
- A second machine's record, from another firmware vendor, through [field-testing.md](field-testing.md) or the release checklist.

## Remove when no longer needed

- Leftover detection (`leftover_candidates` in `lib/status.sh`, its `setup` refusal and failure-table row): it covers installs of the pre-package version that were copied into place from this repository. Drop it one release after 1.0.0.

## Evidence owed

- One machine has a record (C6 of [upstream-contracts.md](upstream-contracts.md)). For every other firmware, each claim about boot behaviour and firmware writes rests on the contracts alone.
- Enrollment was proven on the append path only. The rebuild path, for firmware that clears KEK and db together with the Platform Key, has no hardware record, and neither has a machine with BitLocker on.
- The weekly contract job has not run on GitHub yet; its first run proves the container setup, not the suites, which pass locally against the versions [upstream-contracts.md](upstream-contracts.md) names. GitHub disables scheduled workflows in a public repository after 60 days without activity, so the workflow needs re-enabling after a quiet period.
- The budget of two seconds per installed kernel for the hook is unmeasured: the recorded kernel reinstall took 19 seconds as a whole, and the hook's own share needs a row that times it alone.
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
