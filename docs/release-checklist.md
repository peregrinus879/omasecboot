# Release checklist

What a release tag requires. Hermetic tests share assumptions with the code, so they are necessary and never sufficient: the hardware rows below are the evidence for everything that touches boot behaviour or firmware, and no public claim goes beyond the machines recorded.

## Before any hardware run

- [ ] `make lint` and `make test` pass on the candidate commit.
- [ ] `tests/package.sh` passes and CI ran `tests/container.sh` in its container on the same commit.
- [ ] The contract suites named in [spec.md](spec.md) section 11 pass against the current Omarchy packages, and every section of [upstream-contracts.md](upstream-contracts.md) names the versions that were read.
- [ ] The README states only what the candidate does.

## Hardware acceptance

Run on a dedicated machine, never on a daily one. [field-testing.md](field-testing.md) is a shorter procedure for anyone's machine, without the drills; its reports add to the evidence and do not replace these rows. Every row is recorded with `sudo bash tests/acceptance-record.sh <row> -- <command>` from the login user's `sudo` (not a root shell); the recorder writes the state before, the full terminal transcript with the exit status, and the state after. Stop at the first STOP and bring the record back; never reboot with Secure Boot on while `omasecboot status` fails.

| Stage | Rows | STOP when |
| --- | --- | --- |
| 0 Baseline | Stock machine: factory keys, Secure Boot off, stock `/etc/default/limine`, no earlier install. `status` reports "not set up". | Setup Mode is on, the factory PK is missing, or leftovers are reported |
| 1 Walking skeleton, no firmware write | `setup`; the rebuilt UKI was already signed before `sign` touched it; hook timing during a kernel reinstall (budget: two seconds per installed kernel); `limine-install --fallback` if the machine has no fallback; stale-checksum drill with Secure Boot off and rescue media at hand (stop the watcher, edit `limine.conf`, confirm the primary refuses, confirm the firmware boot menu offers the fallback, boot it, `sign`); the same edit with the watcher running; reboot | `setup` refuses, a transcript ends at a prompt, the timing budget is exceeded, or the fallback cannot be booted |
| 2 Enrollment | Delete only the PK in firmware; `setup` enrolls; reboot; `setup` confirms; enable Secure Boot; `status` | KEK or db changed when the PK was deleted, any variable misses the local certificate after enrollment, or a backup entry is gone |
| 3 Secure Boot on | Kernel reinstall and reboot; snapshot create and boot its entry; boot an entry that predates enrollment and record what Limine and the firmware show; `omarchy refresh limine`, `status`, reboot; `limine` reinstall, where Omarchy's installer hook puts the raw loader back and the loader's watcher must have rebuilt it a few seconds after pacman ended; an interrupted `sign` followed by `sign` | `status` fails after any step |
| 4 Restore | Restore a snapshot taken after setup; `sign`; update | The restored system does not boot with Secure Boot on |
| 5 Windows | `windows preflight`; `windows setup`; pick the entry in Limine's menu; return to Omarchy; `windows bootnext`; reboot; return; a kernel reinstall and a snapshot, then `status` (the entry must still be there once, and any entry `FIND_BOOTLOADERS` adds recorded); `omarchy refresh limine`, `status` | The preflight reports an unknown, an entry does not reach Windows Boot Manager, or the entry is doubled, lost or no longer recognised (`windows status` says "stale" or "misplaced") after upstream's rewrites |
| 6 Remove | Secure Boot off; `remove`; the primary loader equals the raw executable in upstream's backup; remove the package; the state directory remains | Anything is left sealed or signed by the tool's settings |

Stages 2 and 5 exist once their commands do; a release needs all seven stages on at least one machine, and every firmware vendor named in public text needs its own record.

## Tag

- [ ] The acceptance records for the candidate commit are reviewed and their summary is published with the release, from the copies `tests/acceptance-share.sh` makes; they contain no serial numbers, recovery keys, firmware backup payloads, host or login names, machine-ids or UUIDs of the machine.
- [ ] The Omarchy-side pieces in [omarchy-integration.md](omarchy-integration.md) are agreed with the maintainers, and the omarchy-pkgs recipe pins the tagged archive checksum.
