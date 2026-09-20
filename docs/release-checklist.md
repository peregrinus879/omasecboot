# Release checklist

What a release tag requires. Hermetic tests share assumptions with the code, so they are necessary and never sufficient: the hardware rows below are the evidence for everything that touches boot behaviour or firmware, and no public claim goes beyond the machines recorded.

## Before any hardware run

- [ ] `make lint` and `make test` pass on the candidate commit.
- [ ] CI ran `tests/container.sh` in its container on the same commit.
- [ ] `make test-contract` passes against the current Omarchy packages, and every section of [upstream-contracts.md](upstream-contracts.md) names the versions that were read.
- [ ] The README states only what the candidate does.

## Hardware acceptance

Run on a dedicated machine, never on a daily one. [field-testing.md](field-testing.md) is a shorter procedure for anyone's machine, without the drills; its reports add to the evidence and do not replace these rows. Every row is recorded with `sudo bash tests/acceptance-record.sh <row> -- <command>` from the login user's `sudo` (not a root shell); a record counts only when its checkout is clean and the installed files equal it, both of which it states. The recorder writes the state before, the full terminal transcript with the exit status, and the state after. Stop at the first STOP and review the record before going on; never reboot with Secure Boot on while `omasecboot status` fails.

| Stage | Rows | STOP when |
| --- | --- | --- |
| 0 Baseline | Stock machine: factory keys, Secure Boot off, stock `/etc/default/limine`, no earlier install. `status` reports "not set up". | Setup Mode is on, the factory PK is missing, or leftovers are reported |
| 1 Boot files, no firmware write | `setup`, which offers the fallback loader on a machine without one: accept it; the rebuilt UKI was already signed before `sign` touched it; the hook's own time right after the kernel reinstall, `time /etc/boot/hooks/post.d/90-omasecboot-sign` (budget: two seconds per installed kernel); stale-checksum drill with Secure Boot off and rescue media at hand (stop the watchers, edit `limine.conf`, confirm the primary refuses, confirm the firmware boot menu offers the fallback, boot it, `sign`); the same edit with the watchers running; reboot | `setup` refuses, a transcript ends at a prompt, the timing budget is exceeded, or the fallback cannot be booted |
| 2 Enrollment | Delete only the PK in firmware; `setup` enrolls; reboot; `setup` confirms; enable Secure Boot; `status` | KEK or db changed when the PK was deleted, the PK came back on its own, any variable misses the local certificate after enrollment, or a backup entry is gone |
| 3 Secure Boot on | Kernel reinstall and reboot; snapshot create and boot its entry; boot an entry that predates enrollment and record what Limine and the firmware show; `omarchy refresh limine`, `status`, reboot; `limine` reinstall, where Omarchy's installer hook puts the raw loader back and the loader's watcher must have rebuilt it a few seconds after pacman ended; an interrupted `sign` followed by `sign`: stop the watchers, add a comment line to `limine.conf` so the pass has a loader to rebuild, run `sudo timeout -s TERM 0.5 omasecboot sign`, with a shorter time until `timeout` exits 124, then `sign` | `status` fails after any step |
| 4 Restore | Start the entry of a snapshot taken after setup and run `limine-snapper-restore` from inside it, under the recorder, answering no to its reboot offer so the state after is written; reboot; `sign`; update. The records survive because `/home` is a subvolume of its own | The restored system does not boot with Secure Boot on |
| 5 Windows | `windows preflight`; `windows setup`; pick the entry in Limine's menu; return to Omarchy; `windows bootnext`; reboot; return; a kernel reinstall and a snapshot, then `status` (the entry must still be there once, and any entry `FIND_BOOTLOADERS` adds recorded); `omarchy refresh limine`, `status` | The preflight reports an unknown, an entry does not reach Windows Boot Manager, or the entry is doubled, lost or no longer recognised (`windows status` says "stale" or "misplaced") after upstream's rewrites |
| 6 Remove | Secure Boot off; `remove`; the primary loader equals the raw executable in upstream's backup; remove the package; the state directory remains | The primary loader is still sealed, or a managed setting is still in `/etc/default/limine` |

A release needs all seven stages on at least one machine, and every firmware vendor named in public text needs its own record.

## Tag

- [ ] `pkgver` in `PKGBUILD` and `OMASECBOOT_VERSION` in `lib/common.sh` name the release, and the tag is `v` followed by that number, which the recipe's source line expects.
- [ ] `CHANGELOG.md` has the release's section, with its date.
- [ ] The acceptance records for the candidate commit are reviewed and their summary is published with the release, from the copies `tests/acceptance-share.sh` makes; they contain no serial numbers, recovery keys, firmware backup payloads, host or login names, machine-ids or UUIDs of the machine.

Delivery through Omarchy follows a tag and does not gate it: [omarchy-integration.md](omarchy-integration.md) owns that side, and its recipe pins the tagged archive's checksum.
