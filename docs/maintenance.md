# Maintenance

Open work, the evidence still owed, and what triggers a recheck. A closed item leaves this page; Git history keeps it.

## Open work before a release

- The Omarchy side in [omarchy-integration.md](omarchy-integration.md), agreed with the maintainers, including the request about the installer's `99-omarchy-limine.hook`.
- Leftover detection covers installs of an earlier version that were copied into place without pacman. Drop it one release after 1.0.0: `leftover_candidates` and its report in `lib/status.sh`, the refusal in `setup`, the failure-table row and step 1 in [spec.md](spec.md), the README's troubleshooting row, the check in [field-testing.md](field-testing.md), the setup command's duty in omarchy-integration.md and the recorder's block in `tests/acceptance-record.sh`.

## Evidence owed

- Two rows of the recorded machine (C6 of [upstream-contracts.md](upstream-contracts.md)), each as a record: in stage 1, the hook's own time against the budget of two seconds per installed kernel; in stage 3, what Limine and the firmware show for an entry that predates enrollment.
- The acceptance rows on the release candidate. The record is of commit `3b43368`, and later commits changed code.
- A second machine's record, from another firmware vendor, through [field-testing.md](field-testing.md) or the release checklist.
- The rebuild path of enrollment, which needs firmware that clears KEK and db together with the Platform Key, and the Windows rows on a machine with BitLocker on. Enrollment is recorded on the append path only.
- The first scheduled run of the contract workflow on GitHub, which proves its container setup.

## Recheck when something changes

| What | Recheck |
| --- | --- |
| `limine` | C1: the checksum marker, the unconditional check, the lookup order of `limine.conf` |
| `limine-mkinitcpio-hook` | C2 and C3: hook names 89, 90 and 91 (ours sorts between the last two), the loader backup `limine_x64.bak`, `limine-install --no-efi-register` and `--fallback`, the lock path and descriptor, the configuration layers |
| `limine-snapper-sync` | C2 and C8: history file names, `snapshots.json`, the restore marker, what its rewrite of `limine.conf` keeps |
| `sbctl` | C4, every bullet; above all the owner GUID in `status --json`, the ESL export honouring `--append` with a PK in place, and `--partial` combined with `--append`, `--microsoft` and `--firmware-builtin` |
| `systemd` | C5: `PathChanged=` semantics, the start limit and `KillMode=mixed` |
| `pacman` | C7: `db.lck` held until the post-transaction hooks are done |
| `efibootmgr`, `limine`, `util-linux` | C8: `--bootnext`, the `efi_boot_entry` protocol and its `entry` option, `lsblk`'s `BitLocker` type |
| `omarchy` and its installer | C7: the default settings, `omarchy-refresh-limine`, the security command pairs, the installer's `99-omarchy-limine.hook` |
| 60 days without activity in the repository | GitHub disables the scheduled contract workflow; re-enable it |
