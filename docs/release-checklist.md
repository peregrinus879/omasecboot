# Release checklist

What a release tag requires. Hermetic tests share assumptions with the code, so they are necessary and never sufficient: the hardware rows below are the evidence for everything that touches boot behaviour or firmware, and no public claim goes beyond the machines recorded.

## Before any hardware run

- [ ] `make lint` and `make test` pass on the candidate commit.
- [ ] CI ran `tests/container.sh` in its container on the same commit.
- [ ] `make test-contract` passes against the current Omarchy packages, and every section of [upstream-contracts.md](upstream-contracts.md) names the versions that were read.
- [ ] The README states only what the candidate does.

## Hardware acceptance

Run on a dedicated machine, never on a daily one. [field-testing.md](field-testing.md) is a shorter procedure for anyone's machine, without the drills; its reports add to the evidence and do not replace these rows. Every row is recorded with `sudo bash tests/acceptance-record.sh <row> -- <command>` from the login user's `sudo` (not a root shell); a record counts only when its checkout is clean and the installed files equal it, both of which it states. The recorder writes the state before, the full terminal transcript with the exit status, and the state after. Stop at the first STOP and review the record before going on; never reboot with Secure Boot on while `omasecboot status` fails: a restart that follows a `status` row runs as `sudo omasecboot status --quiet && systemctl reboot`, so a failed report keeps the machine up. A snapshot is taken only while `timedatectl` reports the clock synchronised, and its row is followed by the menu line that names it (C2 of [upstream-contracts.md](upstream-contracts.md)).

| Stage | Proves | STOP when |
| --- | --- | --- |
| 0 Baseline | The machine is stock before anything is installed | Setup Mode is on, or the factory PK is missing |
| 1 Boot files | The boot files are sealed and signed and stay so, with no firmware write | `setup` refuses, a transcript ends at a prompt, the timing budget is exceeded, or the fallback cannot be booted |
| 2 Enrollment | The user's keys enter the firmware beside the ones it holds | KEK or db changed when the PK was deleted, the PK came back on its own, any variable misses the local certificate after enrollment, or a backup entry is gone |
| 3 Secure Boot on | The machine keeps starting through updates, snapshots and an interrupted pass | `status` fails after any step |
| 4 Restore | A snapshot restore leaves a machine that starts | The restored system does not boot with Secure Boot on |
| 5 Windows | Windows starts from Limine's menu and through BootNext, and the entry survives upstream's rewrites | The preflight reports an unknown, an entry does not reach Windows Boot Manager, or the tool's entry is doubled, lost or no longer recognised (`windows status` says it holds an entry for another target, more than one, or this tool's comment in an entry it did not write) after upstream's rewrites |
| 6 Remove | pacman's warning when the package goes from a machine that is set up, and the way back to stock | pacman prints no warning or does not remove the package, the primary loader is still sealed, or a managed setting is still in `/etc/default/limine` |
| 7 Rebuild | Enrollment on firmware whose key menu clears KEK and db together with the Platform Key | The tool appends to an empty list, the confirmation does not name what cannot come back, a variable misses the local or Microsoft's certificates after the rebuild, or Windows no longer starts |

A release needs stages 0 to 6 on at least one machine and stage 7 on one whose key menu can clear every key, and every firmware vendor named in public text needs its own record. Rows that begin "With Windows encryption on" apply to a machine with BitLocker or Device Encryption on, the recovery key on paper and nothing suspended; a Windows start there records whether BitLocker asked for the key at the first and at a second start, and the PCR validation profile that `manage-bde -protectors -get C: -Type TPM` names.

### Stage 0: baseline

1. Stock machine: factory keys, Secure Boot off, stock `/etc/default/limine`. The clock is right and synchronised (`timedatectl`), here and before every snapshot of the run: a snapshot taken while the clock runs ahead, as after a Windows session that wrote local time to the hardware clock, keeps later snapshots out of Limine's menu (C2).
2. Record the state before the package is installed, take a snapshot, install the package.
3. `status` reports "not set up".

### Stage 1: boot files, no firmware write

1. With Windows on the machine: `windows preflight`. Then `setup`; accept the fallback loader where it offers one. On a machine whose fallback an earlier run added, remove `EFI/BOOT/BOOTX64.EFI` first, so that the offer is recorded.
2. Reinstall the kernel: the rebuilt UKI is signed before `sign` touches it.
3. Time the hook alone, right after the kernel reinstall: `time /etc/boot/hooks/post.d/90-omasecboot-sign`. Budget: two seconds per installed kernel.
4. Edit `limine.conf` with the watchers running: `status` passes within seconds.
5. The stale-checksum drill, with Secure Boot off and rescue media at hand: stop the watchers, edit `limine.conf`, `systemctl reboot` and confirm that the primary loader refuses, confirm that the firmware's boot menu offers the fallback, start it, `sign`.
6. `systemctl reboot`; `status`.

### Stage 2: enrollment

1. `setup`; `systemctl reboot --firmware-setup` and delete only the PK.
2. `setup` enrolls; `systemctl reboot`; `setup` confirms; `systemctl reboot --firmware-setup` and turn Secure Boot on; `status`; `sbctl status`.
3. With Windows encryption on: `systemctl reboot` and start Windows from the firmware's boot menu after the PK is deleted, after the keys are written and after Secure Boot is on.

### Stage 3: Secure Boot on

1. Reinstall the kernel; `status`.
2. Reinstall `limine`: Omarchy's installer hook puts the raw loader back, and the loader's watcher must have rebuilt it a few seconds after pacman ended; `status`.
3. Create a snapshot and see its entry in `limine.conf`; `status`; `systemctl reboot` and start the snapshot's entry, then the normal entry, which starts the reinstalled kernel, then each other kernel entry of the menu once: Omarchy installs two kernels, and both images are signed.
4. Start an entry that predates enrollment and record what Limine and the firmware show.
5. `omarchy refresh limine`, `status`.
6. An interrupted `sign`: stop the watchers, add a comment line to `limine.conf` so the pass has a loader to rebuild, run `sudo timeout -s TERM 0.5 omasecboot sign`, with a shorter time until `timeout` exits 124, then `sign`, `status`, `systemctl reboot`, `status`.

### Stage 4: restore

1. Start the entry of a snapshot taken after setup and run `limine-snapper-restore` from inside it, under the recorder. The restore command offers that snapshot itself; `snapper list` fails inside a booted snapshot (C10). The records survive because `/home` is a subvolume of its own.
2. Answer no to its reboot offer, so the state after is written; `systemctl reboot`.
3. `sign`; `status`.

### Stage 5: Windows

1. `windows preflight`; `windows setup`; `status`.
2. `systemctl reboot` and pick the entry in Limine's menu; from Windows, restart and return to Omarchy.
3. `windows bootnext`; `systemctl reboot`; return.
4. A kernel reinstall and a snapshot, then `status`: the entry must still be there once, and any entry `FIND_BOOTLOADERS` adds is recorded. `omarchy refresh limine`, `status`, `windows status`: the entry must stand after Omarchy's entries, and Limine's timeout must still start Omarchy's kernel at the next restart.
5. With Windows encryption on: disable and enable the protectors once in Windows, then start Windows through the menu entry and through BootNext again.
6. With Windows encryption on, the chainload note (spec D11): add a chainload entry with `limine-scan` beside the tool's; `status` and `windows status` carry the note; the command the note prints takes the entry out; `status` is clean again. Windows is not started through the chainload entry.

### Stage 6: remove

1. Remove the package while set up: pacman prints the warning and goes through. Reinstall; `status`.
2. `systemctl reboot --firmware-setup` and turn Secure Boot off. With Windows encryption on: `systemctl reboot` and start Windows once.
3. `remove`; `status`; the primary loader equals the raw executable in upstream's backup.
4. Remove the package; the state directory remains.

### Stage 7: rebuild

1. Restore the factory keys in the firmware; `setup`.
2. `systemctl reboot --firmware-setup` and clear every Secure Boot key, instead of deleting the PK alone.
3. `setup`: it says that the key menu cleared KEK and db with the PK, lists the backup entries the rebuild cannot bring back, and asks. Answer yes; it writes db, KEK and PK and reads each back.
4. `systemctl reboot`; `setup` confirms; `systemctl reboot --firmware-setup` and turn Secure Boot on; `status`; `sbctl status`.
5. With Windows on the machine: start it.
6. `systemctl reboot --firmware-setup` and turn Secure Boot off; `remove`; `systemctl reboot --firmware-setup` and restore the factory keys.

## Tag

- [ ] `pkgver` in `PKGBUILD` and `OMASECBOOT_VERSION` in `lib/common.sh` name the release, and the tag is `v` followed by that number, which the recipe's source line expects.
- [ ] `CHANGELOG.md` has the release's section, with its date, and the README's status note and install line name the release.
- [ ] The acceptance records are of the tagged commit, or of an ancestor of it with the same tool: `git diff --name-only <recorded> <tag>` lists nothing under `bin/`, `lib/`, `limine/`, `systemd/` or `omarchy/`, and none of `PKGBUILD`, `Makefile` and `omasecboot.install`. Where the tool changed after the records, C10 of [upstream-contracts.md](upstream-contracts.md) names the change, what proves it without hardware (its hermetic cases, and for a reader of `limine.conf` a replay over every `limine.conf` the records captured), and the row of the next run that records it, which [maintenance.md](maintenance.md) lists as owed.
- [ ] The rows above are the rows the records ran.
- [ ] `make lint`, `make test` and CI, which runs `tests/container.sh`, pass on the tagged commit.
- [ ] The recipe builds from an archive made as the tag's will be, with the same payload as `make package`: in a scratch directory holding copies of `PKGBUILD` and `omasecboot.install`, `git archive --prefix=omasecboot-<version>/ -o omasecboot-<version>.tar.gz <commit>`, then `PKGEXT=.pkg.tar.zst makepkg --nodeps --noconfirm --nosign`, and `diff <(bsdtar -tf that package) <(bsdtar -tf the one make package built)` prints nothing. They differ only where an untracked file stands under `lib/` or `docs/`.
- [ ] The records are reviewed and their summary is published with the release, from the copies `tests/acceptance-share.sh` makes; they contain no serial numbers, recovery keys, firmware backup payloads, host or login names, machine-ids or UUIDs of the machine.

Delivery through Omarchy follows a tag and does not gate it: [omarchy-integration.md](omarchy-integration.md) owns that side, and its recipe pins the tagged archive's checksum.
