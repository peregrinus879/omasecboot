# Maintenance

Open work, the evidence still owed, and what triggers a recheck. A closed item leaves this page; Git history keeps it.

## Open work

- Nothing starts a pass when upstream's snapshot restore ends (spec, section 4): let the watcher's pass wait for the restore lock, bounded, as it waits for pacman, with a hermetic case for a lock that stays and a hardware row in stage 4.
- During a snapshot restore that root starts on a machine that is set up, upstream's `89-warn-missing-file-hashes` prints its warning, because `limine-snapper-restore` exports `/etc/default/limine` to the hooks but not the drop-in that holds `ENABLE_UKI=yes` (C2 of [upstream-contracts.md](upstream-contracts.md)). Report it upstream: the hook is limine-entry-tool's, the restore command limine-snapper-sync's. The README's troubleshooting row covers it until then.
- Report to limine-snapper-sync that a `lastUTCTime` in the future, left by one snapshot taken while the clock ran ahead, keeps every later snapshot out of the menu until real time has passed it (C2, C10), and to Omarchy that a dual-boot machine meets this when Windows has written local time to the hardware clock.
- Agree the Omarchy side in [omarchy-integration.md](omarchy-integration.md) with the maintainers, including the request about the installer's `99-omarchy-limine.hook`. It follows a release and does not gate one.
- A lifecycle lock across `setup`, `remove` and the Windows commands, held through the intervals in which the boot lock is released around upstream's tools: today the boot lock serialises the boot files and the pass looks again under it (spec, D2), while two of those commands run at once only by operator error.
- A positive proof that the fallback loader is unsigned by anyone, from the executable's certificate table, in place of sbctl's answer about the current key (spec, D6); and a return to stock that spares another system's fallback where `ENABLE_LIMINE_FALLBACK=yes`.
- The firmware's boot entry for the Limine loader compared by partition identity and `BootOrder` membership, as the Windows target is, instead of by path alone (spec, section 4).
- The watchers' event schedules on a real systemd: a change that lands after the pass's last proof and before it exits, and a stop at shutdown while the pass waits (spec, D8).
- The enrollment proof by Microsoft's fingerprints (C9) besides "more than the local certificate", and the identity of signature-list headers of unknown types.
- The recorder's own failures beyond the two it now stops at (a record header or a transcript that cannot be written): a state block that fails half way, and a row whose "State after" was never written, should end the row with a status of the recorder's own.
- Mount ordering for the watcher service: `RequiresMountsFor=%f` would state what the path unit's implicit dependency (C5) gives it; whether `Triggers=` carries that ordering to the service at shutdown is unverified.
- Pin the workflow actions to commit SHAs instead of major tags; the report job holds `issues: write`.
- Deferred until field reports show the need: a way to add Microsoft's 2023 KEK certificate with the user's own keys on a machine that lacks it after the Platform Key changed hands (C9). sbctl's append always adds the local certificate again (C4), so it needs a route of its own.

## Evidence owed

- The first hardware rows of what changed in the tool after the release's records, which C10 lists: checklist 5.4, `omarchy refresh limine` with the entry enabled, for the Windows entry's place, and a full run of stages 0 to 7 for the guards and the changes beside them.
- Whether BitLocker stays quiet when Windows is started through a chainload entry alone and the loader is sealed again in between (checklist, stage 5): Microsoft's pages say it cannot (C8), and no machine has a record.
- A second machine's record, from another firmware vendor, through [field-testing.md](field-testing.md) or the release checklist.
- The record of a stock single-boot Omarchy install, where the fallback loader and its `/EFI fallback` menu entry exist from the start. The recorded machine (C10) was installed beside Windows and had neither.
- BitLocker on Windows Pro, Enterprise or Education, where an organisation's policy can change the binding.
- The contract workflow's issue on a failed scheduled run. No scheduled run has failed.

## Recheck when something changes

| What | Recheck |
| --- | --- |
| `limine` | C1: keys without case, the checksum marker, the unconditional check, the lookup order of `limine.conf`, the path grammar and its resources, `LoadImage` for a chainload, the missing `.sbat` section. C7: the `efi_boot_entry` protocol, its `entry` option and its search of `BootOrder` alone |
| `limine-mkinitcpio-hook` | C2 and C3: hook names 89, 90 and 91 (`90-omasecboot-sign` sorts between the last two), the condition of hook 89, what `limine-scan` writes (a `protocol: efi` entry without a hash, its name and layout), the form of `limine-remove-entry` and its first-match rule, the `order-priority` comment on every entry it writes and the one `comment:` line of an OS entry that carries `machine-id=` with it, which `remove`'s proof keys on, the loader backup `limine_x64.bak`, `limine-install --no-efi-register` and `--fallback`, when the fallback is deployed and that the step copies over whatever is there, the lock path and descriptor, the configuration layers |
| `limine-snapper-sync` | C2 and C7: history file names, `snapshots.json` and the `lastUTCTime` rule that decides whether a snapshot is new, the restore lock, the files the restore command exports, what its rewrite of `limine.conf` keeps |
| `sbctl` | C4, every bullet; above all the owner GUID in `status --json`, the ESL export honouring `--append` with a PK in place, and `--partial` combined with `--append`, `--microsoft` and `--firmware-builtin`. C9: the four fingerprints against the certificates it ships |
| `systemd` | C5: `PathChanged=` semantics, the start limit and `KillMode=mixed` |
| `pacman` | C6: `db.lck` held until the post-transaction hooks are done; `AbortOnFail` for pre-transaction hooks only |
| `efibootmgr`, `util-linux` | C7: `--bootnext`. C8: `lsblk`'s `BitLocker` type |
| `omarchy` and its installer | C6: the default settings, `omarchy-refresh-limine`, the security command pairs, the installer's `99-omarchy-limine.hook` and its fallback choice (`_boot_intent`), the manual's Secure Boot and Dual Boot Install pages, the maintainers' Secure Boot plan, a Microsoft-signed shim in Arch's or Omarchy's repositories (a condition of the spec's D1), and archinstall's copy of `BOOTIA32.EFI` (C2) |
| Microsoft's BitLocker pages and its certificate article | C8: the default validation profile, the single-entry rule for PCR 7, the suspend procedure, `manage-bde`. C9: names, dates and fingerprints |
| 60 days without activity in the repository | GitHub disables the scheduled contract workflow; re-enable it |
