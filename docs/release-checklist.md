# Release Checklist - OmaSecBoot

This checklist defines what must be true before a release tag is created. It separates hermetic evidence, package evidence, and privileged hardware evidence, because none of them substitutes for another. A release is blocked while any mandatory item is open or any claim exceeds recorded evidence.

## 1. Candidate

- [ ] The candidate is one commit on `main` with a clean tree and green CI.
- [ ] `omasecboot version`, `pkgver` in `PKGBUILD`, and the version named in `README.md` agree.
- [ ] `docs/maintenance.md` has been revalidated at the candidate: the three activation pins (`limine-mkinitcpio-hook`, `limine-snapper-sync`, `sbctl`) and the efibootmgr floor match what Arch and omarchy-pkgs currently ship, and every "rechecked" date that the release depends on has been refreshed.
- [ ] No documentation carries a validation placeholder or a claim that exceeds the evidence recorded below.
- [ ] The Deferred Items in `docs/maintenance.md` that are marked as release decisions have a recorded ruling.

## 2. Hermetic evidence

- [ ] `make test` passes on the candidate (19 suites). Record the date, host, and elapsed time.
- [ ] `make lint` passes.

## 3. Package evidence

- [ ] `tests/package.sh` passes on the candidate.
- [ ] `tests/package-root.sh` passes in a disposable Arch container: CI's package job, or the same two steps locally with Docker: `docker run --rm -e OMASECBOOT_DISPOSABLE_ROOT=1 -v "$PWD:/src:ro" archlinux:base-devel bash -c 'pacman -Syu --noconfirm --needed git jq diffutils util-linux libarchive >/dev/null && cp -a /src /work && cd /work && useradd --create-home builder && chown -R builder . && runuser -u builder -- env HOME=/home/builder bash tests/package.sh && bash tests/package-root.sh'`. Run it before pushing a change to either script or the workflow; runner facts (the image's `NoExtract` rules, checkout ownership, efivarfs visibility) only show up inside the container.
- [ ] The built package was inspected by hand once: `pacman -Qip`, `pacman -Qlp`, and `bsdtar -tvf` output reviewed for the payload, modes, and the dependencies declared in `PKGBUILD`.

## 4. Privileged hardware acceptance

Hermetic tests do not prove firmware behavior. The matrix below is the minimum. Every row is recorded with `tests/acceptance-capture.sh`, which writes one self-contained file per run: firmware and package state before, the full terminal transcript of the row's command, and the state after. Run it from a checkout on the target machine as `sudo bash tests/acceptance-capture.sh <row> -- <command>`, through `sudo` from your own login rather than from a root shell started with `su`, because git identifies the checkout's owner through `sudo` and a root login shell records an ownership error instead of the commit; for a firmware-menu step, run it without a command after the reboot to record a checkpoint. The files land in `./acceptance-records/`; copy that directory to the reviewer, who derives pass or fail from the records. The script never records DMI serial numbers or UUIDs, MAC or NVMe device-path nodes, recovery keys, or raw firmware backup payloads; it does record partition identifiers, boot IDs, and the lifecycle records the review needs. Every record names the checkout commit and its dirty state, hashes the installed command and modules, and compares that payload with the checkout byte for byte; a record whose checkout is dirty or whose payload does not match satisfies no row. Reviewed records are stored under `docs/acceptance/`.

Target machine preparation, in this order:

1. Install Windows first, then Omarchy from the ISO alongside it with Secure Boot off. Confirm in the firmware Secure Boot menu that the PK can be deleted on its own; firmware that offers only "clear all keys" is recorded as a refusal for that firmware. Some firmware shows its key-management menu only while Secure Boot is enabled (the ASUS Vivobook TP3402VA does): there, a PK-only delete is enable Secure Boot, delete the PK, disable Secure Boot again, then boot Linux. Firmware that exposes no AuditMode or DeployedMode variable is accepted; the records show both as absent.
2. Back up every Windows recovery key (BitLocker or Device Encryption) somewhere off the machine.
3. Check the producer set and the stale-copy condition before building anything: `pacman -Q limine-mkinitcpio-hook limine-snapper-sync sbctl efibootmgr` must show exactly 1.38.0-1.1, 1.31.0-1.1, and 0.18-2 with efibootmgr at 18 or newer, and `ls /usr/local/bin/omasecboot /usr/local/lib/omasecboot` must report both missing. Any other producer version fails activation by design and needs a re-audit commit before acceptance continues.
4. Clone the repository at the candidate commit (a git clone, not an archive: the build reads its file list from git), then `make package`, `sudo pacman -U omasecboot-1.0.0-1-any.pkg.tar.zst`, and `omasecboot version`.
5. Keep a `notes.md` in `acceptance-records/` for what the recorder cannot see: the firmware menu wording, whether Windows asked for a recovery key after the handoff, and anything the firmware refused.

Tier A runs on a dedicated bare-metal laptop that can be wiped, with an Omarchy installation made from the ISO with Secure Boot off and, for the Windows rows, a Windows installation alongside it. Real firmware is the target of this tool, so the mutating path is accepted only on real firmware; an OVMF virtual machine may be used as an optional rehearsal but does not satisfy any row. Record the firmware vendor and version, and record a refusal (for example firmware that offers only "clear all keys") as a valid result for that firmware, not as a pass.

| Row | Check | Expected result | Mandatory |
| --- | --- | --- | --- |
| A1 | `sudo omasecboot status` on a fresh install | Lifecycle `unmanaged`, no hook errors | Yes |
| A2 | `sudo omasecboot setup` (setup state 1) | Raw firmware backup written, plan compared, PK fingerprints shown, PK-only delete instruction printed, lifecycle `active` | Yes |
| A3 | Delete only PK in the firmware Secure Boot menu, then `sudo omasecboot enroll` (state 2) | db, KEK, PK written in that order, direct readback proved, enablement instruction printed | Yes |
| A4 | Enable Secure Boot in firmware, boot Linux, `sudo omasecboot status` | Secure Boot on, setup state 5, all artifacts signed and tracked | Yes |
| A5 | Kernel package upgrade or reinstall with the lifecycle active | Transition guard admits the producer, the repair hook runs, UKI and snapshot artifacts re-signed and proved, lifecycle returns to `active` | Yes |
| A6 | Interrupt a `sign` transaction (SIGTERM during signing), then `sudo omasecboot repair` | Lifecycle `recovery-required`, then recovery completes and returns `active` | Yes |
| A7 | Disable Secure Boot in firmware, `sudo omasecboot unconfigure` | Recorded settings restored, stock Limine state rebuilt and proved, lifecycle `disabled` | Yes |
| A8 | `sudo pacman -R omasecboot` from `disabled` | Removal allowed, `/var/lib/omasecboot` and `/var/lib/sbctl` preserved | Yes |
| A9 | Restore a snapshot taken after A4 through `limine-snapper-restore` with the lifecycle active | Restore producer admitted, post-repair proof passes; after the reboot the lifecycle is `active` and `status` may report the snapshot UKI registered after the snapshot as signed but untracked, because the restore also replaced `/var/lib/sbctl/files.json`; `sudo omasecboot sign` then proves every artifact | Recommended |
| A10 | Windows 11 on the same laptop: `windows preflight`, `windows setup`, `windows bootnext`, reboot | Preflight guidance matches the edition, BootNext armed and consumed, Windows starts; record whether BitLocker prompted | Yes when Windows is present |

Tier B runs on a second, in-use dual-boot machine with the exact pinned producer set installed, no stale `/usr/local` copy of the tool, and Windows present. It exercises the non-destructive path and the Windows handoff on a different firmware; it does not require entering Setup Mode on that machine unless the owner accepts that risk. When the Tier A laptop already covered A10, Tier B is recommended rather than mandatory.

| Row | Check | Expected result | Mandatory |
| --- | --- | --- | --- |
| B1 | `sudo omasecboot status` | Correct firmware, hook, Limine, and Windows observations | Yes |
| B2 | `sudo omasecboot adopt` on an existing configuration, or `setup` on a fresh one | Lifecycle `active` with recorded originals | Yes |
| B3 | `sudo omasecboot sign` | Both Limine targets enrolled and verified, every artifact signed and tracked | Yes |
| B4 | `sudo omasecboot windows preflight` | Edition-appropriate guidance, exit 0 only after acknowledgment | Yes |
| B5 | `sudo omasecboot windows setup` | Validated target recorded, managed Limine block written | Yes |
| B6 | `sudo omasecboot windows bootnext` then reboot | Windows starts by firmware handoff; record whether BitLocker prompted | Yes |
| B7 | Boot back to Linux, `sudo omasecboot status` | BootNext absent, lifecycle `active`, Windows block intact | Yes |
| B8 | `omarchy update` with a kernel update available | Hooks run, artifacts re-proved, update completes | Recommended |

Commands per Tier A row, run in this order with the firmware steps between them:

| Row | Run |
| --- | --- |
| A1 | `sudo bash tests/acceptance-capture.sh A1 -- omasecboot status` |
| A2 | `sudo bash tests/acceptance-capture.sh A2 -- omasecboot setup`. Answer every confirmation with Enter or `y`; `n`, Esc, or Ctrl-C cancels, the command says so, and a transcript that ends at a prompt or without the PK fingerprints and the delete instruction satisfies no row |
| firmware | Reboot into firmware settings, delete only the PK (enable Secure Boot first and disable it afterwards if the key menu needs it), boot Linux, then `sudo bash tests/acceptance-capture.sh A3-setupmode`. That record must show `SetupMode=1` with sbctl's `Vendor Keys` still listing the builtin KEK and db and Microsoft; a firmware that cleared them with the PK, or that reinstalled its default keys on the next boot, is recorded as a refusal for that firmware and A3 is not run |
| A3 | `sudo bash tests/acceptance-capture.sh A3 -- omasecboot enroll` |
| firmware | Reboot into firmware settings, enable Secure Boot, boot Linux |
| A4 | `sudo bash tests/acceptance-capture.sh A4 -- omasecboot status` |
| A5 | `sudo bash tests/acceptance-capture.sh A5 -- pacman -S --noconfirm linux` (if Omarchy's update guard refuses, use `omarchy update` instead), then reboot and `sudo bash tests/acceptance-capture.sh A5-boot -- omasecboot status` |
| A6 | `sudo bash tests/acceptance-capture.sh A6-interrupt -- timeout -s TERM 3 omasecboot sign`, then `sudo bash tests/acceptance-capture.sh A6 -- omasecboot repair` (if the first record shows `sign` completed before the signal, rerun with `timeout -s TERM 1`) |
| A9 | After A5-boot, create a snapshot to restore: `sudo snapper -c root create -d "omasecboot A9"` (`omarchy-snapshot create` is equivalent but labels it with the Omarchy version). Then `sudo bash tests/acceptance-capture.sh A9 -- limine-snapper-restore`, choose that snapshot by its ID and description, and answer `n` to the reboot prompt so the recorder can write the after-state; reboot, then `sudo bash tests/acceptance-capture.sh A9-boot -- omasecboot status`. Never restore a snapshot older than A2: a full restore replaces the root subvolume, including the package, its hooks, the sbctl keys, and `/var/lib/omasecboot`, while the ESP and firmware keep the signed state, and the machine then needs the recovery route in the README before any further row (recommended) |
| A10 | `sudo bash tests/acceptance-capture.sh A10-preflight -- omasecboot windows preflight`, `... A10-setup -- omasecboot windows setup`, `... A10-bootnext -- omasecboot windows bootnext`, reboot, use Windows, boot Linux, `... A10-return -- omasecboot status` |
| firmware | Reboot into firmware settings, disable Secure Boot, boot Linux |
| A7 | `sudo bash tests/acceptance-capture.sh A7 -- omasecboot unconfigure` |
| A8 | `sudo bash tests/acceptance-capture.sh A8 -- pacman -R --noconfirm omasecboot` |

Pass rule: every mandatory Tier A row passes on the candidate commit, and Tier B rows are mandatory only when Tier A had no Windows installation. A failed mandatory row blocks the tag until the fix lands and the row is rerun. Recommended rows that were not run are listed in the release record as unexercised.

For a historical A3 incident whose terminal PK command returned 0 but whose readback was recorded failed, capture `A3-reboot` with Secure Boot still off, then `A3-repair -- omasecboot repair` on the compatible recovery build. The recovery must establish strict F3 by fresh direct comparison, issue no additional firmware write, preserve the failed root and prior attempt seals, prove boot artifacts, and return the lifecycle to `active`. A SetupMode value of 0 alone does not satisfy that row. Obtain the enablement instruction from `setup` only after recovery succeeds. A kernel transaction performed with Secure Boot off is useful producer evidence but does not replace the post-A4 boot/update acceptance.

Always unexercised in this release, and named as such in the release notes: dbx modification, firmware factory-key restoration, firmware vendors other than those recorded, and any generalization about BitLocker recovery beyond the machines recorded.

## 5. Tag and publication

These steps are performed by the repository owner after the sections above are complete.

- [ ] `git tag -a v1.0.0 -m "OmaSecBoot 1.0.0"` on the candidate commit, then `git push origin v1.0.0`.
- [ ] Create the GitHub release from the tag and record the SHA-256 of `v1.0.0.tar.gz` for the omarchy-pkgs recipe.
- [ ] Open the omarchy-pkgs recipe change (`source: local`, tagged archive, recorded checksum) only after the tag exists.
