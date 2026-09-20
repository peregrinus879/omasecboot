# Maintenance

Open work, the evidence still owed, and what triggers a recheck. A closed item leaves this page; Git history keeps it.

## Open work

- The Omarchy side in [omarchy-integration.md](omarchy-integration.md), agreed with the maintainers, including the request about the installer's `99-omarchy-limine.hook`. It follows a release and does not gate one.
- Leftover detection covers installs of an earlier version that were copied into place without pacman. Drop it one release after the first: `leftover_candidates` and its report in `lib/status.sh`, the refusal in `setup`, the failure-table row and step 1 in [spec.md](spec.md), the README's troubleshooting row, the check in [field-testing.md](field-testing.md), the setup command's duty in omarchy-integration.md and the recorder's block in `tests/acceptance-record.sh`.

## Evidence owed

- The acceptance rows on the release candidate. The records are of commits `3b43368` and `5e98d09` (C6 of [upstream-contracts.md](upstream-contracts.md)), and a later commit that changes code asks for them again.
- The record of a stock single-boot Omarchy install, where the fallback loader and its `/EFI fallback` menu entry exist from the start. The recorded machine was installed beside Windows and had neither.
- A second machine's record, from another firmware vendor, through [field-testing.md](field-testing.md) or the release checklist.
- The rebuild path of enrollment, which needs firmware that clears KEK and db together with the Platform Key, and the Windows rows on a machine with BitLocker on. Enrollment is recorded on the append path only.
- The contract workflow's issue on a failed scheduled run. Its suites have run green on GitHub, and no scheduled run has failed yet.

## Deferred

- A way to add Microsoft's 2023 KEK certificate with the user's own keys on a machine that lacks it after the Platform Key changed hands [C9 of [upstream-contracts.md](upstream-contracts.md)]. sbctl's append always adds the local certificate again (C4), so it needs a route of its own, and field reports that show the need.

## Recheck when something changes

| What | Recheck |
| --- | --- |
| `limine` | C1: the checksum marker, the unconditional check, the lookup order of `limine.conf` |
| `limine-mkinitcpio-hook` | C2 and C3: hook names 89, 90 and 91 (ours sorts between the last two), the loader backup `limine_x64.bak`, `limine-install --no-efi-register` and `--fallback`, when the fallback is deployed and that the step copies over whatever is there, the lock path and descriptor, the configuration layers |
| `limine-snapper-sync` | C2 and C8: history file names, `snapshots.json`, the restore marker, what its rewrite of `limine.conf` keeps |
| `sbctl` | C9: the four fingerprints against the certificates it ships. C4, every bullet; above all the owner GUID in `status --json`, the ESL export honouring `--append` with a PK in place, and `--partial` combined with `--append`, `--microsoft` and `--firmware-builtin` |
| `systemd` | C5: `PathChanged=` semantics, the start limit and `KillMode=mixed` |
| `pacman` | C7: `db.lck` held until the post-transaction hooks are done |
| `efibootmgr`, `limine`, `util-linux` | C8: `--bootnext`, the `efi_boot_entry` protocol and its `entry` option, `lsblk`'s `BitLocker` type |
| `omarchy` and its installer | C7: the default settings, `omarchy-refresh-limine`, the security command pairs, the installer's `99-omarchy-limine.hook` and its fallback choice (`_boot_intent`) |
| 60 days without activity in the repository | GitHub disables the scheduled contract workflow; re-enable it |
