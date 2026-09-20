# Field testing

How to try OmaSecBoot on your own machine and report what happened, so that the report can be acted on. Hermetic tests cannot show what firmware and a real boot do; records from real machines can. Read the status note at the top of the [README](../README.md) first: it says what has been proven on hardware so far.

[release-checklist.md](release-checklist.md) owns what a release needs, on a dedicated machine, drills included. This page is a shorter procedure for anyone's machine. Every step names what must be true before its commands, then the commands, then what to expect. Do not run a block before the lines above it are settled, and keep this page open on a second device or on paper: a machine that does not start cannot show it.

## Choose how far you go

| Level | What it changes | The way back | For whom |
| --- | --- | --- | --- |
| 1. Boot files | Limine settings, a sealed and signed loader, signing keys on disk. Secure Boot stays off, and no Secure Boot key or setting in the firmware changes | `sudo omasecboot remove`, which this page ends with | A machine you use every day, once "Before you start" is settled |
| 2. Your keys, Secure Boot on | The firmware's Platform Key is replaced and your certificates are added to KEK and db | The firmware's own menu that restores its factory keys. Those are the keys the machine was built with: updates to db, KEK and dbx that arrived since then come back only with the next firmware or Windows update. No snapshot brings firmware keys back | A machine whose firmware menus you know |
| 3. Drills | A deliberately stale seal, a snapshot restore, an interrupted pass | Rescue media, if a drill goes wrong | A spare machine only |

A Snapper snapshot holds the root filesystem. It does not hold the ESP, where the loader, the kernel images and `limine.conf` live, and it does not hold firmware keys. The snapshots this page takes are material for the snapshot rows; every one of them carries `omasecboot-test` in its description and is deleted at the end. Do not restore one while the tool is set up: that is a level 3 drill.

## What stop means

Stop means: do not reboot and do not go on to the next step. Go to "The way back", which copes with whatever state the machine is in and ends with a loader that starts whatever `limine.conf` holds, and then report where you stopped. A report of a run that stopped half way is as useful as one that went through.

One case has a repair first. When a `status` exits 1 on a machine where `setup` has run, record the repair and the report again, under the row's name with `-sign` and `-again` added:

```bash
sudo bash tests/acceptance-record.sh <row>-sign -- omasecboot sign
sudo bash tests/acceptance-record.sh <row>-again -- omasecboot status
```

Go on if that `status` exits 0. If it still exits 1, stop, and do not reboot with Secure Boot on.

## If the machine does not start

Read this now, not then.

- With Secure Boot on: turn it off in the firmware first. A loader the firmware refuses for its signature starts again with Secure Boot off.
- The primary loader refuses to start, with a message about the config's checksum: open the firmware's boot menu, start the fallback loader you identified in "Before you start", log in, and run `sudo omasecboot sign`.
- Without a working fallback: boot the rescue media, mount the ESP, and put a raw loader over the primary. A raw loader checks nothing and starts.

```bash
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME
mount /dev/<the EFI system partition> /mnt
tar -xf /mnt/EFI/limine/limine_x64.bak -C /mnt/EFI/limine limine_x64.efi
umount /mnt
```

If there is no `limine_x64.bak`, or tar reports an error, copy `/mnt/EFI/BOOT/BOOTX64.EFI` over `/mnt/EFI/limine/limine_x64.efi` instead. Then start Omarchy with Secure Boot off and run `sudo omasecboot sign`, or go to "The way back".

## Before you start

Nothing of the test is run yet. Settle each line first.

- The machine runs Omarchy on x86_64 with Limine, unified kernel images and a vfat ESP, as Omarchy installs it.
- Secure Boot is off and the firmware holds its factory keys: `bootctl status 2>/dev/null | grep -i 'secure boot'` says `disabled`, without `(setup)` behind it. With `(setup)` the firmware is in Setup Mode and holds no Platform Key; report that line instead of testing. A machine on which you have enrolled Secure Boot keys of your own before is not one for this page: its way back would put the factory keys in their place.
- It is on AC power, and you have about half an hour for level 1 and an hour for level 2.
- You have rescue media (the Omarchy installer on a USB stick), you know the key that opens the firmware's boot menu, and you have started the fallback loader from that menu once: it is the entry that starts `EFI/BOOT/BOOTX64.EFI`, often named after the disk or "UEFI OS". It is an unsealed Limine and shows the same menu. Note its label. `sudo ls /boot/EFI/BOOT/BOOTX64.EFI` must list it (Omarchy mounts the ESP for root alone); `sudo limine-install --fallback` adds it when it is missing.
- The ESP has room for two more kernel images: `df -h /boot` shows at least twice the size of the largest file that `sudo ls -lSh /boot/EFI/Linux` lists as available.
- The system is up to date and was rebooted since: run `omarchy update`, reboot, and start the test then. Do not update again, and do not run `pacman -Sy`, before "The way back" is done: the test reinstalls packages, which must be the versions you already run. `pacman -Qu` must print nothing about `limine` or your kernel.
- No earlier install of this tool, copied into place without pacman, is on the machine; its hooks would keep running the old tool, and `setup` refuses beside them. This must print nothing but "No such file":

```bash
ls -d /usr/local/bin/omasecboot /usr/local/lib/omasecboot /etc/pacman.d/hooks/*omasecboot* /etc/boot/hooks/post.d/zzz-omasecboot-sign
```

- With Windows on the same machine, at any level: the BitLocker or Device Encryption recovery key is backed up and at hand. `setup` asks about it, and changing Secure Boot keys or its state can make Windows ask for the key.
- Level 2: you know the firmware setup password if one is set. You have looked, without changing anything, for the firmware menu that deletes the Platform Key alone and the one that restores the factory keys, and written their wording down for the report. If the firmware offers only "clear all keys" or "reset to Setup Mode" with no choice of key, do not go to level 2; report that wording instead. Some firmware shows its key menu only while Secure Boot is set to enabled: there you set it to enabled, change the keys, and set it back to disabled before you save.

## Prepare

```bash
sudo pacman -S --needed base-devel git shellcheck jq bubblewrap
git clone https://github.com/peregrinus879/omasecboot.git ~/omasecboot
cd ~/omasecboot
git log --oneline -1
make lint && make test && make package
```

Expected: lint and the suites pass and one `omasecboot-<version>-1-any.pkg.tar.zst` exists. Note the commit line; the report asks for it. If a suite fails, nothing has changed on the machine yet: report its `FAIL` lines, which name the case, and leave out lines that hold your paths.

Every row from here on is recorded. The recorder writes the machine's state before, the full terminal transcript with the exit status, and the state after, into `~/omasecboot/acceptance-records/`. Without a command it records the state alone. Its form, which the steps below fill in:

```text
sudo bash tests/acceptance-record.sh <row> -- <command>
```

Run it from `~/omasecboot`, from your own login with `sudo`, never from a root shell. Something only the screen shows, such as a message at boot, goes into a record of its own, in your words, whenever it happens. Its form:

```text
sudo bash tests/acceptance-record.sh 1-note -- echo "At boot Limine showed: <the text>"
```

Record the machine before anything is installed, and take the first snapshot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 0-before-install
sudo snapper -c root create -d "omasecboot-test baseline"
```

## Level 1: boot files, Secure Boot off

Before: "Before you start" and "Prepare" are done, and Secure Boot is still off.

**1.** Install, and record the untouched machine. `command` goes past Omarchy's `ls` alias, which is another program with other options.

```bash
cd ~/omasecboot
sudo pacman -U "$(command ls -t omasecboot-*-any.pkg.tar.zst | head -n 1)"
sudo bash tests/acceptance-record.sh 0-baseline -- omasecboot status
make test-contract
```

Expected: "OmaSecBoot is not set up on this machine", exit status 0; the contract suites pass against your installed sbctl and Limine tools. Stop if a contract case fails: send its `FAIL` line, which names what changed upstream.

**2.** Set up the boot files. On a machine with Windows, or where it cannot tell whether there is one, `setup` prints what to do about BitLocker and asks once whether Windows encryption is suspended or off, or its recovery key at hand. Answer yes only when that is true. With "no" it stops with "Cancelled", exit 1, after the boot files are set up: then run `status`, and go on or go to "The way back" as you prefer.

```bash
sudo bash tests/acceptance-record.sh 1-setup -- omasecboot setup
sudo bash tests/acceptance-record.sh 1-status -- omasecboot status
```

Expected: keys created if you had none, two settings written, the loader sealed and signed, the watchers enabled, a backup of the firmware's keys, and at the end the instruction to delete the Platform Key. At level 1 do not follow that instruction. `status` exits 0 and says your keys are not enrolled yet. Stop if `setup` refuses or `status` exits 1.

**3.** Reinstall the kernel you are running, which is what every kernel update does to the boot files.

```bash
kernel=$(pacman -Qqo "/usr/lib/modules/$(uname -r)/vmlinuz")
echo "$kernel"
```

Expected: one package name, such as `linux` or `linux-omarchy`. Stop if the line is empty: the running kernel is not the installed one, so reboot and come back to this step.

```bash
sudo bash tests/acceptance-record.sh 1-kernel -- pacman -S --noconfirm "$kernel"
sudo bash tests/acceptance-record.sh 1-hook-time -- bash -c 'time /etc/boot/hooks/post.d/90-omasecboot-sign'
sudo bash tests/acceptance-record.sh 1-status-kernel -- omasecboot status
```

Expected: the same version is reinstalled, the new kernel image is signed while it is built, the Limine hooks run, and `status` exits 0. The middle row runs the tool's hook alone, as the Limine tools run it; its budget is two seconds per installed kernel.

**4.** Reinstall Limine. Omarchy's installer leaves a pacman hook that copies the raw loader over the sealed one after every Limine upgrade; the tool's watcher must rebuild it on its own, a moment after pacman ends.

```bash
sudo bash tests/acceptance-record.sh 1-limine -- pacman -S --noconfirm limine
sleep 15
sudo bash tests/acceptance-record.sh 1-status-limine -- omasecboot status
```

Expected: `status` exits 0 without your help.

**5.** Take a snapshot, which makes limine-snapper-sync rewrite `limine.conf`.

```bash
sudo bash tests/acceptance-record.sh 1-snapshot -- snapper -c root create -d "omasecboot-test level 1"
sleep 15
sudo bash tests/acceptance-record.sh 1-status-snapshot -- omasecboot status
```

Expected: exit 0.

**6.** Reboot, only when the last `status` exited 0. Secure Boot is still off. If the loader refuses to start, "If the machine does not start" says what to do; note the text it showed.

```bash
systemctl reboot
```

After the reboot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 1-status-reboot -- omasecboot status
```

Expected: the machine starts from the Limine menu as always, and `status` exits 0.

### Windows, optional at any level

Before: Windows is installed on this machine and its recovery key is at hand. The entry restarts the machine into the firmware's own Windows Boot Manager entry and does not depend on Secure Boot. `windows bootnext` sets the firmware's one-time BootNext variable, which the firmware clears after one boot.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-preflight -- omasecboot windows preflight
```

Expected: the BitLocker volumes it found with what to do in Windows first, or a line that none was found. Stop if it says that something could not be told.

```bash
sudo bash tests/acceptance-record.sh 5-setup -- omasecboot windows setup
sudo bash tests/acceptance-record.sh 5-status -- omasecboot status
```

Expected: "Windows is in the boot menu", and `status` exits 0. Stop otherwise. Then reboot, pick "Windows" in Limine's menu, and come back to Omarchy. Record what you saw, with the words that do not apply taken out:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-windows-menu -- echo "Windows from Limine's menu: started / did not start. BitLocker asked for a key: yes / no"
sudo bash tests/acceptance-record.sh 5-bootnext -- omasecboot windows bootnext
```

Expected: the firmware took the request. Reboot: Windows must start without the menu, and the boot after it must return to Omarchy. Then record, again with the words that do not apply taken out:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-windows-bootnext -- echo "Windows through BootNext: started / did not start. The boot after it returned to Omarchy: yes / no"
sudo bash tests/acceptance-record.sh 5-status-after -- omasecboot status
```

If you stop at level 1, go to "The way back".

## Level 2: your keys in the firmware, Secure Boot on

Before: level 1 is done and its last `status` exited 0; the firmware lines of "Before you start" are settled. `setup` backs up what the firmware trusts, refuses when more than the Platform Key is gone, and only ever adds to KEK and db. The README's "How your keys get into the firmware" says what happens and why.

**1.** Let `setup` make sure its backup of the firmware's keys is current and ask its Windows question again, right before the deletion.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 2-before-pk-delete -- omasecboot setup
```

Expected: the same instruction as at level 1: delete only the Platform Key.

**2.** In the firmware: delete only the Platform Key, leave Secure Boot disabled when you save, and start Omarchy.

```bash
systemctl reboot --firmware-setup
```

After the reboot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 2-after-pk-delete
```

Expected: `SetupMode=1` under "Secure Boot variables", and `sbctl status` still lists the vendor keys without the builtin PK. Stop if the record shows that more than the Platform Key is gone, or that the Platform Key came back on its own.

**3.** Enroll.

```bash
sudo bash tests/acceptance-record.sh 2-enroll -- omasecboot setup
```

Expected: it says how many KEK and db entries it keeps, asks before it writes (on a machine with Windows also about the recovery key), writes db, KEK and the Platform Key one at a time and reads each back, and ends with "Reboot, then run sudo omasecboot setup once more". If it says instead that the firmware's key menu cleared KEK and db together with the Platform Key, and offers to rebuild them, answer no: that path writes other lists and needs a report of its own. Stop then, and also if it refuses; its message lists what is gone from the firmware, and the report needs that list. The way back's step 3 restores the factory keys.

**4.** Reboot, and let `setup` confirm.

```bash
systemctl reboot
```

After the reboot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 2-confirm -- omasecboot setup
```

Expected: "Your keys are enrolled and every boot file is proved", exit 0, and the instruction to turn Secure Boot on. Stop on anything else, and leave Secure Boot off.

**5.** Only after that: turn Secure Boot on in the firmware and start Omarchy. If the machine does not start, turn Secure Boot off again, boot, record `status`, and report.

```bash
systemctl reboot --firmware-setup
```

After the reboot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 2-secure-boot-on -- omasecboot status
sudo bash tests/acceptance-record.sh 2-sbctl -- sbctl status
```

Expected: Secure Boot on, your keys enrolled, exit 0.

**6.** The same changes as at level 1, now with Secure Boot on.

```bash
cd ~/omasecboot
kernel=$(pacman -Qqo "/usr/lib/modules/$(uname -r)/vmlinuz")
echo "$kernel"
```

Expected: the package name again. Stop if the line is empty.

```bash
sudo bash tests/acceptance-record.sh 3-kernel -- pacman -S --noconfirm "$kernel"
sudo bash tests/acceptance-record.sh 3-status-kernel -- omasecboot status
sudo bash tests/acceptance-record.sh 3-limine -- pacman -S --noconfirm limine
sleep 15
sudo bash tests/acceptance-record.sh 3-status-limine -- omasecboot status
sudo bash tests/acceptance-record.sh 3-snapshot -- snapper -c root create -d "omasecboot-test level 2"
sleep 15
sudo bash tests/acceptance-record.sh 3-status-snapshot -- omasecboot status
```

Expected: all three `status` rows exit 0. Stop otherwise, as "What stop means" says: a reboot with Secure Boot on and a loader that is not proved ends at a firmware refusal.

**7.** Only when the three rows exited 0: reboot, start the snapshot entry you have just taken from Limine's menu, and note whether it started. If the desktop offers to restore that snapshot, decline: a restore is a level 3 drill. Reboot into the normal entry and record, with the words that do not apply taken out:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 3-snapshot-boot -- echo "The snapshot entry taken after setup: started / was refused, with the text: ..."
sudo bash tests/acceptance-record.sh 3-status-reboot -- omasecboot status
```

Expected: both entries start and `status` exits 0.

**8.** Optional: reboot once more and start the entry of the "omasecboot-test baseline" snapshot, which predates `setup`. Its kernel image is unsigned, so with Secure Boot on it must be refused; the README says why. Note the text, start the normal entry, and record:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 3-old-snapshot -- echo "The snapshot entry from before setup: was refused with the text: ... / started"
```

## Level 3: drills, on a spare machine only

The rows are in [release-checklist.md](release-checklist.md), stages 1, 3 and 4: the stale-checksum drill (stop the watchers, edit `limine.conf`, watch the primary loader refuse, start from the fallback, `sign`), the same edit with the watchers running, an interrupted `sign` followed by `sign`, and a snapshot restore followed by `sign`. A drill makes the machine refuse to start on purpose, and a restore rolls the root filesystem back. Do them only where that costs nothing.

## The way back

In this order, whatever level you reached.

**1.** Level 2 only: turn Secure Boot off in the firmware and start Omarchy. `remove` refuses while it is on and changes nothing then, because stock boot files are unsigned.

**2.** Return the boot files and settings to stock. `remove` asks once; the answer is yes. It takes the Windows entry out as well. After a `setup` that never got as far as changing a setting it says "Nothing to remove" and exits 1, which is fine.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 6-remove -- omasecboot remove
sudo bash tests/acceptance-record.sh 6-status -- omasecboot status
```

Expected: `remove` exits 0, or said "Nothing to remove", and `status` says "OmaSecBoot is not set up on this machine". If `status` says that a `setup` or `remove` did not finish, run the `remove` row again. Do not go on before `status` reads "not set up": until then the package is what keeps the loader and `limine.conf` together.

**3.** Level 2 only: restore the factory keys in the firmware's key menu, leave Secure Boot disabled when you save, start Omarchy, and record.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 6-factory-keys -- sbctl status
```

Expected: Setup Mode disabled and the vendor keys listed.

**4.** Remove what the test created, the package first.

```bash
sudo pacman -R omasecboot
```

Then the test's snapshots, by number:

```bash
sudo snapper -c root list | grep omasecboot-test
sudo snapper -c root delete <numbers>
```

After level 1, `sudo rm -rf /var/lib/omasecboot` removes the tool's state. After level 2 keep that directory: its `firmware-backup` is the only record of what your firmware trusted before the test.

**5.** Signing keys. `setup` created keys under `/var/lib/sbctl` only if there were none, and Limine's tools sign with whatever keys are there. After level 2, do this step only once step 3 matched its Expected: until then the firmware may still trust these keys. Look at what the machine had before the test:

```bash
grep -h -A5 '^### sbctl status' ~/omasecboot/acceptance-records/*-0-before-install.md | head -n 8
grep -h "package 'sbctl' was not found" ~/omasecboot/acceptance-records/*-0-before-install.md
```

If the first shows `Installed: ✓ sbctl is installed`, the keys were yours before the test and were never replaced: skip the rest of this step and go on to step 6. Only if it shows `Installed: ✗ sbctl is not installed`, or that the `sbctl` command was not found, were the keys made by this test, and this removes them:

```bash
sudo rm -rf /var/lib/sbctl
```

If the second prints a line, the test also brought the package, and `sudo pacman -Rns sbctl` removes it. The other packages that came with the tool or with "Prepare" stay; remove the ones you do not want.

**6.** Reboot, see that the machine starts as it did before, and record the final state.

```bash
systemctl reboot
```

After the reboot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 7-final
```

## Report

The records are written for a private review. They hold your host name, login name, machine-id and the UUIDs of your partitions and encrypted volume. Make the copies that are fit for a public issue:

```bash
cd ~/omasecboot
bash tests/acceptance-share.sh
```

It writes `acceptance-records/share/` and `omasecboot-records.tgz` inside it. In the copies every such value is renamed (`uuid-1`, `id-1`, `user`, `host`), the same value the same way in every record, so nothing is lost for the review. What stays is what the review needs or no rule can know: the machine's model and firmware version, package versions, disk sizes, boot entry labels, the time zone of time stamps, hashes of boot files, and every text typed by hand, such as snapshot descriptions and your notes. The command's last lines say where your names still occur. Skim the copies before you share them; some firmware puts a disk's model or serial number into a boot entry's label.

Then open a [field report](https://github.com/peregrinus879/omasecboot/issues/new?template=field-report.yml). The form asks for the machine, the firmware, the commit, how far you went, what happened at each step that no record can show (texts on the screen, firmware menu wording, whether Windows started), and the archive: drag `omasecboot-records.tgz` into the last field, or write "none" there when the run ended in "Prepare". Quote from the copies in `share/`, never from the records themselves. Attach only that archive, and never recovery keys, serial numbers or anything from `/var/lib/sbctl` or `/var/lib/omasecboot/firmware-backup`.

When the report is filed, `rm -rf ~/omasecboot` removes the checkout and the records.
