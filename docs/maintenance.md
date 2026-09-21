# Maintenance

Open work, the evidence still owed, and what triggers a recheck. A closed item leaves this page; Git history keeps it.

## Open work

- Nothing starts a pass when upstream's snapshot restore ends (spec, section 4): let the watcher's pass wait for the restore lock, bounded, as it waits for pacman, with a hermetic case for a lock that stays and a hardware row in stage 4.
- During a snapshot restore that root starts on a machine that is set up, upstream's `89-warn-missing-file-hashes` prints its warning, because `limine-snapper-restore` exports `/etc/default/limine` to the hooks but not the drop-in that holds `ENABLE_UKI=yes` (C2 of [upstream-contracts.md](upstream-contracts.md)). Report it upstream: the hook is limine-entry-tool's, the restore command limine-snapper-sync's. The README's troubleshooting row covers it until then.
- Agree the Omarchy side in [omarchy-integration.md](omarchy-integration.md) with the maintainers, including the request about the installer's `99-omarchy-limine.hook`. It follows a release and does not gate one.
- Deferred until field reports show the need: a way to add Microsoft's 2023 KEK certificate with the user's own keys on a machine that lacks it after the Platform Key changed hands (C9). sbctl's append always adds the local certificate again (C4), so it needs a route of its own.

## Evidence owed

- The acceptance rows on the code to be released, with Windows encryption on, and stage 7, the rebuild path of enrollment, which no machine has run. The record is of commit `d567e1f`, with encryption off (C10); a release's records must be of the tagged tool ([release-checklist.md](release-checklist.md), Tag).
- A second machine's record, from another firmware vendor, through [field-testing.md](field-testing.md) or the release checklist.
- The record of a stock single-boot Omarchy install, where the fallback loader and its `/EFI fallback` menu entry exist from the start. The recorded machine (C10) was installed beside Windows and had neither.
- BitLocker on Windows Pro, Enterprise or Education, where an organisation's policy can change the binding.
- The contract workflow's issue on a failed scheduled run. No scheduled run has failed.

## Recheck when something changes

| What | Recheck |
| --- | --- |
| `limine` | C1: the checksum marker, the unconditional check, the lookup order of `limine.conf`, `LoadImage` for a chainload, the missing `.sbat` section. C7: the `efi_boot_entry` protocol, its `entry` option and its search of `BootOrder` alone |
| `limine-mkinitcpio-hook` | C2 and C3: hook names 89, 90 and 91 (`90-omasecboot-sign` sorts between the last two), the condition of hook 89, what `limine-scan` writes (a `protocol: efi` entry without a hash), the loader backup `limine_x64.bak`, `limine-install --no-efi-register` and `--fallback`, when the fallback is deployed and that the step copies over whatever is there, the lock path and descriptor, the configuration layers |
| `limine-snapper-sync` | C2 and C7: history file names, `snapshots.json`, the restore lock, the files the restore command exports, what its rewrite of `limine.conf` keeps |
| `sbctl` | C4, every bullet; above all the owner GUID in `status --json`, the ESL export honouring `--append` with a PK in place, and `--partial` combined with `--append`, `--microsoft` and `--firmware-builtin`. C9: the four fingerprints against the certificates it ships |
| `systemd` | C5: `PathChanged=` semantics, the start limit and `KillMode=mixed` |
| `pacman` | C6: `db.lck` held until the post-transaction hooks are done; `AbortOnFail` for pre-transaction hooks only |
| `efibootmgr`, `util-linux` | C7: `--bootnext`. C8: `lsblk`'s `BitLocker` type |
| `omarchy` and its installer | C6: the default settings, `omarchy-refresh-limine`, the security command pairs, the installer's `99-omarchy-limine.hook` and its fallback choice (`_boot_intent`), the manual's Secure Boot and Dual Boot Install pages, the maintainers' Secure Boot plan, a Microsoft-signed shim in Arch's or Omarchy's repositories (a condition of the spec's D1), and archinstall's copy of `BOOTIA32.EFI` (C2) |
| Microsoft's BitLocker pages and its certificate article | C8: the default validation profile, the single-entry rule for PCR 7, the suspend procedure, `manage-bde`. C9: names, dates and fingerprints |
| 60 days without activity in the repository | GitHub disables the scheduled contract workflow; re-enable it |
