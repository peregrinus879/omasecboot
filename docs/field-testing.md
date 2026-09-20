# Field testing

How to try OmaSecBoot on your own machine and report what happened, so that the report can be acted on. Hermetic tests cannot show what firmware and a real boot do; records from real machines can. [release-checklist.md](release-checklist.md) owns what a release needs; this page is the way anyone can add to that evidence.

Every step below names what must be true before its commands, then the commands, then what to expect and when to stop. Do not run a command before the lines above it are settled.

## Choose how far you go

| Level | What it changes | The way back | For whom |
| --- | --- | --- | --- |
| 1. Boot files | Limine settings, a sealed and signed loader, signing keys on disk. Secure Boot stays off and nothing is written to the firmware | `sudo omasecboot remove`, which this page ends with | A machine you use every day |
| 2. Your keys, Secure Boot on | The firmware's Platform Key is replaced and your certificates are added to KEK and db | The firmware's own menu that restores its factory keys. No snapshot brings firmware keys back | A machine whose firmware menus you know, with rescue media at hand |
| 3. Drills | A deliberately stale seal, a snapshot restore, an interrupted pass | Rescue media, if a drill goes wrong | A spare machine only |

A Snapper snapshot holds the root filesystem. It does not hold the ESP, where the loader, the kernel images and `limine.conf` live, and it does not hold firmware keys. The snapshots this page takes are a second way back for the root filesystem and material for the snapshot rows; every one of them carries `omasecboot-test` in its description and is deleted at the end.

## Before you start

Nothing is run yet. Settle each line first.

- The machine runs Omarchy on x86_64 with Limine, unified kernel images and a vfat ESP, as Omarchy installs it.
- It is on AC power, and you have about half an hour for level 1 and an hour for level 2.
- You have rescue media (the Omarchy installer on a USB stick) and know the key that opens the firmware's boot menu.
- Level 2: you know the firmware setup password if one is set, and you have found, without changing anything, the firmware menu that deletes the Platform Key and the one that restores the factory keys. Write their wording down; it belongs in the report.
- Level 2 with Windows on the same machine: the BitLocker or Device Encryption recovery key is backed up and at hand. Changing Secure Boot keys can make Windows ask for it.
- The system is up to date and was rebooted since: run `omarchy update` first, so an update's effects do not mix with the test's.
- You have never installed an earlier, copied-in version of this tool. If you have, remove it first; `omasecboot status` names what is left.

## Prepare

```bash
sudo pacman -S --needed base-devel git shellcheck jq bubblewrap
git clone https://github.com/peregrinus879/omasecboot.git ~/omasecboot
cd ~/omasecboot
git log --oneline -1
make lint && make test && make package
ls /boot/EFI/BOOT/BOOTX64.EFI
sudo snapper -c root create -d "omasecboot-test baseline"
```

Expected: lint and the suites pass, one `omasecboot-<version>-1-any.pkg.tar.zst` exists, the fallback loader is listed, and the snapshot is created. Note the commit line; the report asks for it.

Stop if a suite fails (report that, with its output) or if the fallback loader is missing. A machine without a fallback loader has no second way to start when the primary loader refuses; `sudo limine-install --fallback` adds one, and then you can go on.

Every row from here on is recorded. The recorder writes the machine's state before, the full terminal transcript with the exit status, and the state after, into `~/omasecboot/acceptance-records/`:

```bash
sudo bash tests/acceptance-record.sh <row> -- <command>
```

Run it from `~/omasecboot`, from your own login with `sudo`, never from a root shell. Something you see on the screen and no command can show, such as a message at boot, goes into a record of its own, in your words:

```bash
sudo bash tests/acceptance-record.sh 1-note -- echo "At boot Limine showed: ..."
```

## Level 1: boot files, Secure Boot off

Before: Secure Boot is off in the firmware (`bootctl status | grep -i 'secure boot'` says disabled).

1. Install, and record the untouched machine.
   ```bash
   cd ~/omasecboot
   sudo pacman -U omasecboot-*-any.pkg.tar.zst
   sudo bash tests/acceptance-record.sh 0-baseline -- omasecboot status
   make test-contract
   ```
   Expected: "OmaSecBoot is not set up on this machine", exit status 0; the contract suites pass against your installed sbctl and Limine tools. Stop if `status` names leftovers of an earlier install, or if a contract case fails: send its `FAIL` line, which names what changed upstream.
2. Set up the boot files.
   ```bash
   sudo bash tests/acceptance-record.sh 1-setup -- omasecboot setup
   sudo bash tests/acceptance-record.sh 1-status -- omasecboot status
   ```
   Expected: keys created if you had none, two settings written, the loader sealed and signed, the watchers enabled, a backup of the firmware's keys, and at the end the instruction to delete the Platform Key. At level 1 do not follow that instruction. `status` exits 0 and says your keys are not enrolled yet. Stop if `setup` refuses or `status` exits 1.
3. Reinstall the kernel you are running, which is what every kernel update does to the boot files.
   ```bash
   kernel=$(pacman -Qqo "/usr/lib/modules/$(uname -r)/vmlinuz")
   sudo bash tests/acceptance-record.sh 1-kernel -- bash -c "time pacman -S --noconfirm $kernel"
   sudo bash tests/acceptance-record.sh 1-status-kernel -- omasecboot status
   ```
   Expected: the new kernel image is signed while it is built, the Limine hooks run, `status` exits 0.
4. Reinstall Limine. Omarchy's installer leaves a pacman hook that copies the raw loader over the sealed one after every Limine upgrade; the tool's watcher must rebuild it on its own.
   ```bash
   sudo bash tests/acceptance-record.sh 1-limine -- pacman -S --noconfirm limine
   sleep 15
   sudo bash tests/acceptance-record.sh 1-status-limine -- omasecboot status
   ```
   Expected: `status` exits 0 without your help. If it exits 1, do not reboot: run `sudo omasecboot sign`, record `status` once more, and report both.
5. Take a snapshot, which makes limine-snapper-sync rewrite `limine.conf`.
   ```bash
   sudo bash tests/acceptance-record.sh 1-snapshot -- snapper -c root create -d "omasecboot-test level 1"
   sleep 15
   sudo bash tests/acceptance-record.sh 1-status-snapshot -- omasecboot status
   ```
   Expected: exit 0.
6. Reboot, only when the last `status` exited 0. Secure Boot is still off.
   ```bash
   systemctl reboot
   ```
   After the reboot:
   ```bash
   cd ~/omasecboot
   sudo bash tests/acceptance-record.sh 1-status-reboot -- omasecboot status
   ```
   Expected: the machine starts from the Limine menu as always, `status` exits 0. If the loader refuses to start: open the firmware's boot menu, pick the fallback loader (`EFI/BOOT/BOOTX64.EFI`), boot, run `sudo omasecboot sign`, record `status`, and report the text the loader showed.

Dual boot with Windows, optional at this level, because the Windows entry does not depend on Secure Boot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-preflight -- omasecboot windows preflight
sudo bash tests/acceptance-record.sh 5-setup -- omasecboot windows setup
```

Reboot, pick "Windows" in Limine's menu, come back to Omarchy, and record what you saw. Then ask for one boot into Windows without the menu, reboot, come back, and record that too:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-windows-menu -- echo "Windows from Limine's menu: started / did not start. BitLocker asked for a key: yes / no"
sudo bash tests/acceptance-record.sh 5-bootnext -- omasecboot windows bootnext
systemctl reboot
```
```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-windows-bootnext -- echo "Windows through BootNext: started / did not start. The boot after it returned to Omarchy: yes / no"
sudo bash tests/acceptance-record.sh 5-status -- omasecboot status
```

If you stop at level 1, go to "The way back".

## Level 2: your keys in the firmware, Secure Boot on

Before: level 1 is done and its last `status` exited 0; the firmware menus are found and written down; with Windows, the recovery key is at hand. `setup` backs up what the firmware trusts, refuses when more than the Platform Key is gone, and only ever adds to KEK and db. The README's "How your keys get into the firmware" says what happens and why.

1. Record the state, delete only the Platform Key in the firmware, boot Omarchy with Secure Boot still off, and record again.
   ```bash
   cd ~/omasecboot
   sudo bash tests/acceptance-record.sh 2-before-pk-delete
   systemctl reboot --firmware-setup
   ```
   ```bash
   cd ~/omasecboot
   sudo bash tests/acceptance-record.sh 2-after-pk-delete
   ```
   If the firmware offers only "clear all keys" or "reset to Setup Mode" without a choice of key, stop here and report the menu's wording: that firmware clears more than the Platform Key, which `setup` handles on another path that needs its own report.
2. Enroll.
   ```bash
   sudo bash tests/acceptance-record.sh 2-enroll -- omasecboot setup
   ```
   Expected: it says how many KEK and db entries it keeps, asks once, writes db, KEK and the Platform Key one at a time and reads each back. Stop if it refuses; its message lists what is gone, and the report needs that list.
3. Reboot, let `setup` confirm, turn Secure Boot on in the firmware, boot, and record.
   ```bash
   systemctl reboot
   ```
   ```bash
   cd ~/omasecboot
   sudo bash tests/acceptance-record.sh 2-confirm -- omasecboot setup
   systemctl reboot --firmware-setup
   ```
   ```bash
   cd ~/omasecboot
   sudo bash tests/acceptance-record.sh 2-secure-boot-on -- omasecboot status
   sudo bash tests/acceptance-record.sh 2-sbctl -- sbctl status
   ```
   Expected: Secure Boot on, your keys enrolled, exit 0. If the machine does not start with Secure Boot on: turn it off again, boot, record `status`, and report.
4. With Secure Boot on, the same changes as at level 1. Never reboot with Secure Boot on while `status` exits 1: run `sudo omasecboot sign`, record `status` again, and if it still fails turn Secure Boot off before you reboot.
   ```bash
   cd ~/omasecboot
   kernel=$(pacman -Qqo "/usr/lib/modules/$(uname -r)/vmlinuz")
   sudo bash tests/acceptance-record.sh 3-kernel -- pacman -S --noconfirm "$kernel"
   sudo bash tests/acceptance-record.sh 3-status-kernel -- omasecboot status
   sudo bash tests/acceptance-record.sh 3-limine -- pacman -S --noconfirm limine
   sleep 15
   sudo bash tests/acceptance-record.sh 3-status-limine -- omasecboot status
   sudo bash tests/acceptance-record.sh 3-snapshot -- snapper -c root create -d "omasecboot-test level 2"
   sleep 15
   sudo bash tests/acceptance-record.sh 3-status-snapshot -- omasecboot status
   systemctl reboot
   ```
   In Limine's menu, start the snapshot entry you have just taken, note whether it started, reboot into the normal entry, and record:
   ```bash
   cd ~/omasecboot
   sudo bash tests/acceptance-record.sh 3-snapshot-boot -- echo "The snapshot entry taken after setup: started / was refused, with the text: ..."
   sudo bash tests/acceptance-record.sh 3-status-reboot -- omasecboot status
   ```
   Expected: every `status` exits 0 and both entries start. A snapshot entry from before `setup` is refused with Secure Boot on; that is expected and named in the README.

## Level 3: drills, on a spare machine only

The rows are in [release-checklist.md](release-checklist.md), stages 1, 3 and 4: the stale-checksum drill (stop the watchers, edit `limine.conf`, watch the primary loader refuse, start from the fallback, `sign`), the same edit with the watchers running, an interrupted `sign` followed by `sign`, and a snapshot restore followed by `sign`. A drill makes the machine refuse to start on purpose, and a restore rolls the root filesystem back. Do them only where that costs nothing.

## The way back

In this order, whatever level you reached.

1. Level 2 only: turn Secure Boot off in the firmware. `remove` refuses while it is on, because stock boot files are unsigned.
2. Return the boot files and settings to stock, and check.
   ```bash
   cd ~/omasecboot
   sudo bash tests/acceptance-record.sh 6-remove -- omasecboot remove
   sudo bash tests/acceptance-record.sh 6-status -- omasecboot status
   ```
   Expected: `remove` exits 0 and `status` says the machine is not set up. If `status` says a `remove` did not finish, run `remove` again and record it.
3. Level 2 only: restore the factory keys in the firmware's key menu, boot, and record `sudo bash tests/acceptance-record.sh 6-factory-keys -- sbctl status`. Expected: Setup Mode disabled and the vendor keys listed.
4. Make the copies for the report: see "Report".
5. Remove the package and what the test created.
   ```bash
   sudo pacman -R omasecboot
   sudo rm -rf /var/lib/omasecboot
   sudo snapper -c root list | grep omasecboot-test
   ```
   Delete the listed snapshots by number: `sudo snapper -c root delete <numbers>`. The `0-baseline` record shows whether sbctl had keys before the test. If it had none and you do not use sbctl yourself, remove the test's keys too, and the package if nothing else needs it: `sudo rm -rf /var/lib/sbctl` and `sudo pacman -Rns sbctl`.
6. Reboot once and see that the machine starts as it did before. When the report is filed, `rm -rf ~/omasecboot` removes the checkout and the records.

## Report

The records are written for a private review. They hold your host name, login name, machine-id and the UUIDs of your partitions and encrypted volume. Make the copies that are fit for a public issue:

```bash
cd ~/omasecboot
bash tests/acceptance-share.sh
```

It writes `acceptance-records/share/` and `omasecboot-records.tgz` inside it. In the copies every such value is renamed (`uuid-1`, `id-1`, `user`, `host`), the same value the same way in every record, so nothing is lost for the review. Text you typed yourself, such as snapshot descriptions and your notes, is copied as it is; the command's last lines say where your names still occur. Read those places before you share.

Then open a [field report](https://github.com/peregrinus879/omasecboot/issues/new?template=field-report.yml). The form asks for the machine, the firmware, the commit, how far you went, what happened at each step that no record can show (texts on the screen, firmware menu wording, whether Windows started), and the archive: drag `omasecboot-records.tgz` into the last field. Attach only that archive, never files from `acceptance-records/` itself, and never recovery keys, serial numbers or anything from `/var/lib/sbctl` or `/var/lib/omasecboot/firmware-backup`.

A report of a run that stopped half way is as useful as one that went through. Say where it stopped and what the machine showed.
