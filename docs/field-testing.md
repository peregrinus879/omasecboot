# Field testing

How to try OmaSecBoot on your own machine and report what happened, so that the report can be acted on. Hermetic tests cannot show what firmware and a real boot do; records from real machines can. Read the status note at the top of the [README](../README.md) first: it says what has been proved on hardware so far.

[release-checklist.md](release-checklist.md) owns what a release needs, on a dedicated machine, drills included. This page is a shorter procedure for anyone's machine. Every step names what must be true before its commands, then the commands, then what to expect. Do not run a block before the lines above it are settled, and keep this page open on a second device or on paper: a machine that does not start cannot show it.

## Choose how far you go

| Level | What it changes | The way back | For whom |
| --- | --- | --- | --- |
| 1. Boot files | Limine settings, a sealed and signed loader, signing keys on disk. Secure Boot stays off, and no Secure Boot key or setting in the firmware changes | `sudo omasecboot remove`, which this page ends with | A machine you use every day, once [Before you start](#before-you-start) is settled |
| 2. Your keys, Secure Boot on | The firmware's Platform Key is replaced and your certificates are added to KEK and db | The firmware's own menu that restores its factory keys. Those are the keys the machine was built with: updates to db, KEK and dbx that arrived since then come back only with the next firmware or Windows update. No snapshot brings firmware keys back | A machine whose firmware menus you know |
| 3. Drills | A deliberately stale seal, a snapshot restore, an interrupted pass | Rescue media, if a drill goes wrong | A spare machine only |

A Snapper snapshot holds the root filesystem. It does not hold the ESP, where the loader, the kernel images and `limine.conf` live, and it does not hold firmware keys. The snapshots this page takes are material for the snapshot rows; every one of them carries `omasecboot-test` in its description and is deleted at the end. Do not restore one while the tool is set up: that is a level 3 drill.

## What stop means

Stop means: do not reboot and do not go on to the next step. Go to [The way back](#the-way-back), which copes with whatever state the machine is in and ends with a loader that starts whatever `limine.conf` holds, and then report where you stopped. A report of a run that stopped half way is as useful as one that went through.

One case has a repair first. When a `status` exits 1 on a machine where `setup` has run, record the repair and the report again, under the row's name with `-sign` and `-again` added:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh <row>-sign -- omasecboot sign
sudo bash tests/acceptance-record.sh <row>-again -- omasecboot status
```

Go on if that `status` exits 0. If it still exits 1, stop, and do not reboot with Secure Boot on.

## If the machine does not start

Read this now, not then.

- With Secure Boot on: turn it off in the firmware first. A loader the firmware refuses for its signature starts again with Secure Boot off.
- A snapshot entry stops at `PANIC: efi: LoadImage failure` with Secure Boot on: that snapshot is older than `setup` and its kernel image is unsigned. Nothing is broken. Hold the power button, start again and pick the normal entry.
- A sealed Limine loader refuses to start, with a message about the config's checksum: open the firmware's boot menu, start the fallback loader you identified in [Before you start](#before-you-start), log in, and run `sudo omasecboot sign`.
- Without a working fallback: boot the rescue media and follow the README's [If the machine does not start](../README.md#if-the-machine-does-not-start), which puts a raw loader over the Limine loader.

## Before you start

Nothing of the test is run yet. Settle each line first.

- The machine runs Omarchy on x86_64 with Limine, unified kernel images and a vfat ESP, as Omarchy installs it.
- Secure Boot is off and the firmware holds its factory keys: `bootctl status 2>/dev/null | command grep -i 'secure boot'` says `disabled`, without `(setup)` behind it. With `(setup)` the firmware is in Setup Mode and holds no Platform Key; report that line instead of testing. A machine on which you have enrolled Secure Boot keys of your own before is not one for this page: its way back would put the factory keys in their place.
- It is on AC power, and you have about half an hour for level 1 and an hour for level 2.
- You have rescue media (the Omarchy installer on a USB stick), you know the key that opens the firmware's boot menu, and you have started the fallback loader from that menu once: it is the entry that starts `EFI/BOOT/BOOTX64.EFI`, often named after the disk or "UEFI OS". It is an unsealed Limine and shows the same menu. Note its label. If that file is another system's loader (it does not show Limine's menu), leave it: the test then relies on rescue media alone, and the report should say so. `sudo ls /boot/EFI/BOOT/BOOTX64.EFI` must list it (Omarchy mounts the ESP for root alone); `sudo limine-install --fallback` adds it when it is missing.
- The ESP has room for two more kernel images: `df -h /boot` shows at least twice the size of the largest file that `sudo ls -lSh /boot/EFI/Linux` lists as available.
- The system is up to date and was rebooted since: run `omarchy update`, restart with `systemctl reboot`, and start the test then. Do not update again, and do not run `pacman -Sy`, before [The way back](#the-way-back) is done: the test reinstalls packages, which must be the versions you already run. `pacman -Qu` must print nothing about `limine` or your kernel.
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

Every row from here on is recorded. The number that starts a row's name is the stage of [release-checklist.md](release-checklist.md) it belongs to, not the level of this page. The recorder writes the machine's state before, the full terminal transcript with the exit status, and the state after, into `~/omasecboot/acceptance-records/`. Without a command it records the state alone. Its form, which the steps below fill in:

```text
sudo bash tests/acceptance-record.sh <row> -- <command>
```

Run it from `~/omasecboot`, from your own login with `sudo`, never from a root shell. Something only the screen shows, such as a message at boot, goes into a record of its own, in your words, whenever it happens. Its form:

```text
sudo bash tests/acceptance-record.sh 1-note -- echo "At boot Limine showed: <the text>"
```

After a restart, `command ls -t ~/omasecboot/acceptance-records | head -n 3` names your newest records, and the step that recorded them is where you are. Where a step restarts the machine, it gives the command: `systemctl reboot`, or `systemctl reboot --firmware-setup`, which opens the firmware's menus. With Secure Boot on, a restart that follows a `status` row is guarded: `status --quiet` runs first and the restart happens only when it passes, otherwise the line prints STOP and the machine stays up; the one exception is the restart into the firmware that turns Secure Boot off in [The way back](#the-way-back), which a failed `status` is a reason for. A snapshot is taken only while the clock is synchronised, in a block of its own that can be pasted again, and the line after it shows the menu entry the snapshot got: no line means no entry, which happens for hours after a snapshot taken while the clock ran ahead, as it does after a Windows session (C2 of [upstream-contracts.md](upstream-contracts.md)). If no line appears, record it with a `<row>-note` row (`sudo bash tests/acceptance-record.sh 1-snapshot-note -- echo "no menu entry for the snapshot"`), go on, and say so in the report; a step that starts that snapshot's entry then has none to start. If the firmware does not take that request, the command says so and does not restart: use `systemctl reboot` and the firmware's setup key.

Record the machine before anything is installed, then take the first snapshot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 0-before-install
```

```bash
cd ~/omasecboot
timedatectl | command grep -E 'Local time|System clock synchronized'
[[ $(timedatectl show -p NTPSynchronized --value) == yes ]] && sudo bash tests/acceptance-record.sh 0-snapshot-baseline -- snapper -c root create -d "omasecboot-test baseline" || echo "STOP: the clock is not synchronised; wait a minute and paste this block again"
sleep 15
sudo grep -n 'omasecboot-test baseline' /boot/limine.conf
```

Expected: the right time, and one line `comment: omasecboot-test baseline`.

## Level 1: boot files, Secure Boot off

Before: [Before you start](#before-you-start) and [Prepare](#prepare) are done, and Secure Boot is still off.

**1.** Install, and record the untouched machine. `command` goes past Omarchy's `ls` alias, which is another program with other options.

```bash
cd ~/omasecboot
sudo pacman -U --noconfirm "$(command ls -t omasecboot-*-any.pkg.tar.zst | head -n 1)"
sudo bash tests/acceptance-record.sh 0-baseline -- omasecboot status
make test-contract
```

Expected: "OmaSecBoot is not set up on this machine", exit status 0; the contract suites pass against your installed sbctl and Limine tools. Stop if a contract case fails: send its `FAIL` line, which names what changed upstream.

**2.** Set up the boot files. When KEK lacks Microsoft's 2023 certificate, `setup` first warns and asks whether to go on: at level 1 nothing in the firmware changes, so answer yes, and install the pending Windows and firmware updates before level 2. On a machine with Windows, or where it cannot tell whether there is one, it then prints what to do about BitLocker and asks once whether the Windows recovery key is at hand, or there is no encrypted Windows on the machine. Answer yes to that question only when it is true. With "no" to either it stops with "Cancelled", exit 1, after the boot files are set up: then run `status`, and go on or go to [The way back](#the-way-back) as you prefer. On a machine without a fallback loader it also asks "This machine has no fallback loader, which starts it after a limine.conf mistake. Add one now through limine-install?": yes.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 1-setup -- omasecboot setup
sudo bash tests/acceptance-record.sh 1-status -- omasecboot status
```

Expected: keys created if you had none, two settings written, the loader sealed and signed, the watchers enabled, a backup of the firmware's keys, and at the end the instruction to delete the Platform Key. At level 1 do not follow that instruction. `status` exits 0 and says your keys are not enrolled yet. Stop if `setup` refuses or `status` exits 1.

**3.** Reinstall the kernel you are running, which is what every kernel update does to the boot files.

```bash
kernel=$(pacman -Qqo "/usr/lib/modules/$(uname -r)/vmlinuz")
echo "$kernel"
```

Expected: one package name, such as `linux` or `linux-omarchy`. Stop if the line is empty: the running kernel is not the installed one, so run `systemctl reboot` and come back to this step.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 1-kernel -- pacman -S --noconfirm "$kernel"
sudo bash tests/acceptance-record.sh 1-hook-time -- bash -c 'time /etc/boot/hooks/post.d/90-omasecboot-sign'
sudo bash tests/acceptance-record.sh 1-status-kernel -- omasecboot status
```

Expected: the same version is reinstalled, the new kernel image is signed while it is built, the Limine hooks run, and `status` exits 0. The middle row runs the tool's hook alone, as the Limine tools run it; its budget is two seconds per installed kernel.

**4.** Reinstall Limine. Omarchy's installer leaves a pacman hook that copies the raw loader over the sealed one after every Limine upgrade; the tool's watcher must rebuild it on its own, a moment after pacman ends.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 1-limine -- pacman -S --noconfirm limine
sleep 15
sudo bash tests/acceptance-record.sh 1-status-limine -- omasecboot status
```

Expected: `status` exits 0 without your help.

**5.** Take a snapshot, which makes limine-snapper-sync rewrite `limine.conf`.

```bash
cd ~/omasecboot
timedatectl | command grep -E 'Local time|System clock synchronized'
[[ $(timedatectl show -p NTPSynchronized --value) == yes ]] && sudo bash tests/acceptance-record.sh 1-snapshot -- snapper -c root create -d "omasecboot-test level 1" || echo "STOP: the clock is not synchronised; wait a minute and paste this block again"
sleep 15
sudo grep -n 'omasecboot-test level 1' /boot/limine.conf
sudo bash tests/acceptance-record.sh 1-status-snapshot -- omasecboot status
```

Expected: one menu line for the snapshot, and `status` exits 0.

**6.** Reboot, only when the last `status` exited 0. Secure Boot is still off. If the loader refuses to start, the section [If the machine does not start](#if-the-machine-does-not-start) says what to do; note the text it showed.

```bash
systemctl reboot
```

After the reboot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 1-status-reboot -- omasecboot status
```

Expected: the machine starts from the Limine menu as always, and `status` exits 0.

If you stop at level 1, go to [The way back](#the-way-back).

## Windows, optional at any level

Before: Windows is installed on this machine and its recovery key is at hand. The entry restarts the machine into the firmware's own Windows Boot Manager entry and does not depend on Secure Boot. `windows bootnext` sets the firmware's one-time BootNext variable, which the firmware clears after one boot.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-preflight -- omasecboot windows preflight
```

Expected: any BitLocker volumes it found, the warning that Windows may ask for its recovery key, and the steps: the recovery key first, then how to avoid the prompt. Stop if it says that something could not be told.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-setup -- omasecboot windows setup
sudo bash tests/acceptance-record.sh 5-status -- omasecboot status
```

Expected: "Windows is in Limine's menu", and `status` exits 0. Stop otherwise. If `limine.conf` also holds a chainload entry for Windows, as `limine-scan` writes it, and Windows is encrypted, both commands add a note: BitLocker can ask for the recovery key whenever the way of starting Windows changes, so start it through the firmware only, which this entry does. Then reboot, pick "Windows" in Limine's menu, and come back to Omarchy.

```bash
sudo omasecboot status --quiet && systemctl reboot || echo "STOP: status failed, do not reboot"
```

Record what you saw, with the words that do not apply taken out:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-windows-menu -- echo "Windows from Limine's menu: started / did not start. BitLocker asked for a key: yes / no"
sudo bash tests/acceptance-record.sh 5-bootnext -- omasecboot windows bootnext
```

Expected: the firmware took the request. Reboot: Windows must start without the menu, and the boot after it must return to Omarchy.

```bash
sudo omasecboot status --quiet && systemctl reboot || echo "STOP: status failed, do not reboot"
```

Then record, again with the words that do not apply taken out:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 5-windows-bootnext -- echo "Windows through BootNext: started / did not start. The boot after it returned to Omarchy: yes / no"
sudo bash tests/acceptance-record.sh 5-status-after -- omasecboot status
```

## Level 2: your keys in the firmware, Secure Boot on

Before: level 1 is done and its last `status` exited 0; the firmware lines of [Before you start](#before-you-start) are settled. `setup` backs up what the firmware trusts, refuses when more than the Platform Key is gone, and only ever adds to KEK and db. The README's [How your keys get into the firmware](../README.md#how-your-keys-get-into-the-firmware) says what happens and why.

With Windows on the machine: at the restart after step 2, after step 4 and after step 5, start Windows first, from the firmware's boot menu (the key your firmware names at power-on), never through a chainload entry. In Windows, an administrator terminal shows the binding: `manage-bde -protectors -get C: -Type TPM`, read on the screen only, whose "PCR Validation Profile" line is the one value to note; never copy the recovery key or its identifier anywhere. Then start Omarchy and record, with the words that do not apply taken out:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 2-windows -- echo "After the PK was deleted / the keys were written / Secure Boot was turned on. Encryption was: on / suspended / off. BitLocker asked for a key: yes / no. A second start asked again: yes / no / not tried. PCR validation profile: <the line>"
```

**1.** Let `setup` make sure its backup of the firmware's keys is current and ask its Windows question again, right before the deletion. If KEK still lacks Microsoft's 2023 certificate, it asks "Go on without Microsoft's 2023 KEK certificate?" once more: answer no and install the pending Windows and firmware updates first, because once the Platform Key is yours the manufacturer can never add it.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 2-before-pk-delete -- omasecboot setup
```

Expected: the same instruction as at level 1: delete only the Platform Key.

**2.** In the firmware: delete only the Platform Key, keep KEK, db and dbx, leave Secure Boot disabled when you save, and start Omarchy. Some firmware shows its key menu only while Secure Boot is set to enabled: enable it to reach the menu, delete the key, set it back to disabled, then save.

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
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 2-enroll -- omasecboot setup
```

Expected: it says how many KEK and db entries it keeps ("Your certificates join the" and the count), on a machine with Windows asks "Is the Windows recovery key at hand, or is there no encrypted Windows on this machine?" (yes), asks "The Platform Key becomes yours. Write your keys to the firmware?" (yes), writes db, KEK and the Platform Key one at a time and reads each back, and ends with "Restart (systemctl reboot), then run sudo omasecboot setup once more". If it says instead that the firmware's key menu cleared KEK and db together with the Platform Key, and offers to rebuild them, answer no: that path writes other lists and needs a report of its own. Stop then, and also if it refuses; its message lists what is gone from the firmware, and the report needs that list. The way back's step 3 restores the factory keys.

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
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 3-kernel -- pacman -S --noconfirm "$kernel"
sudo bash tests/acceptance-record.sh 3-status-kernel -- omasecboot status
sudo bash tests/acceptance-record.sh 3-limine -- pacman -S --noconfirm limine
sleep 15
sudo bash tests/acceptance-record.sh 3-status-limine -- omasecboot status
```

```bash
cd ~/omasecboot
timedatectl | command grep -E 'Local time|System clock synchronized'
[[ $(timedatectl show -p NTPSynchronized --value) == yes ]] && sudo bash tests/acceptance-record.sh 3-snapshot -- snapper -c root create -d "omasecboot-test level 2" || echo "STOP: the clock is not synchronised; wait a minute and paste this block again"
sleep 15
sudo grep -n 'omasecboot-test level 2' /boot/limine.conf
sudo bash tests/acceptance-record.sh 3-status-snapshot -- omasecboot status
```

Expected: all three `status` rows exit 0, and one menu line for the snapshot. Stop otherwise, as [What stop means](#what-stop-means) says: a reboot with Secure Boot on and a loader that is not proved ends at a firmware refusal.

**7.** Restart, guarded by `status`; in Limine's menu start the entry of the snapshot you have just taken, and note whether it started. If the desktop offers to restore that snapshot, decline: a restore is a level 3 drill.

```bash
sudo omasecboot status --quiet && systemctl reboot || echo "STOP: status failed, do not reboot"
```

When the snapshot has started, run `systemctl reboot` inside it; after a refusal, hold the power button. Start the normal entry, and record there, with the words that do not apply taken out:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 3-snapshot-boot -- echo "The snapshot entry taken after setup: started / was refused, with the text: ..."
sudo bash tests/acceptance-record.sh 3-status-reboot -- omasecboot status
```

Expected: the snapshot entry and the normal entry both start, and `status` exits 0.

**8.** Optional: restart once more and start the entry of the "omasecboot-test baseline" snapshot, which predates `setup`. Its kernel image is unsigned, so with Secure Boot on the firmware must refuse it: Limine shows `PANIC: efi: LoadImage failure` and halts.

```bash
sudo omasecboot status --quiet && systemctl reboot || echo "STOP: status failed, do not reboot"
```

Note the text, hold the power button, start the normal entry, and record:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 3-old-snapshot -- echo "The snapshot entry from before setup: was refused with the text: ... / started"
```

## Level 3: drills, on a spare machine only

The rows are in [release-checklist.md](release-checklist.md), stages 1, 3 and 4: an edit of `limine.conf` with the watchers running, the stale-checksum drill (the same edit with the watchers stopped: watch the primary loader refuse, start from the fallback, `sign`), an interrupted `sign` followed by `sign`, and a snapshot restore followed by `sign`. A drill makes the machine refuse to start on purpose, and a restore rolls the root filesystem back. Do them only where that costs nothing.

## The way back

In this order, whatever level you reached.

**1.** Level 2 only: turn Secure Boot off in the firmware and start Omarchy. `remove` refuses while it is on and changes nothing then, because stock boot files are unsigned.

```bash
systemctl reboot --firmware-setup
```

**2.** Return the boot files and settings to stock. `remove` asks once; the answer is yes. It takes the Windows entry out as well. After a `setup` that never got as far as changing a setting it says "Nothing to remove" and exits 0.

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 6-remove -- omasecboot remove
sudo bash tests/acceptance-record.sh 6-status -- omasecboot status
```

Expected: `remove` exits 0 and `status` says "OmaSecBoot is not set up on this machine". If `status` says that a `setup` or `remove` did not finish, run the `remove` row again. Do not go on before `status` reads "not set up": until then the package is what keeps the loader and `limine.conf` together.

**3.** Level 2 only: restore the factory keys in the firmware's key menu, leave Secure Boot disabled when you save, and start Omarchy. Where the key menu shows only while Secure Boot is set to enabled, enable it to reach the menu, restore the keys, set it back to disabled, then save.

```bash
systemctl reboot --firmware-setup
```

After the reboot:

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
cd ~/omasecboot
grep -h -A5 '^### sbctl status' ~/omasecboot/acceptance-records/*-0-before-install.md | head -n 8
grep -h "package 'sbctl' was not found" ~/omasecboot/acceptance-records/*-0-before-install.md
```

If the first shows `Installed: ✓ sbctl is installed`, the keys were yours before the test and were never replaced: skip the rest of this step and go on to step 6. Only if it shows `Installed: ✗ sbctl is not installed`, or that the `sbctl` command was not found, were the keys made by this test, and this removes them:

```bash
sudo rm -rf /var/lib/sbctl
```

If the second prints a line, the test also brought the package, and `sudo pacman -Rns sbctl` removes it. The other packages that came with the tool or with [Prepare](#prepare) stay; remove the ones you do not want.

**6.** Reboot, see that the machine starts as it did before, and record the final state.

```bash
systemctl reboot
```

After the reboot:

```bash
cd ~/omasecboot
sudo bash tests/acceptance-record.sh 6-final
```

## Report

The records are written for a private review. They hold your host name, login name, machine-id and the UUIDs of your partitions and encrypted volume. Make the copies that are fit for a public issue:

```bash
cd ~/omasecboot
bash tests/acceptance-share.sh
```

It writes `acceptance-records/share/` and `omasecboot-records.tgz` inside it. In the copies every such value is renamed (`uuid-1`, `id-1`, `user`, `host`), the same value the same way in every record, so nothing is lost for the review. What stays is what the review needs or no rule can know: the machine's model and firmware version, package versions, disk sizes, boot entry labels, the time zone of time stamps, hashes of boot files, and every text typed by hand, such as snapshot descriptions and your notes. The command's last lines say where your names still occur. Skim the copies before you share them; some firmware puts a disk's model or serial number into a boot entry's label.

Then open a [field report](https://github.com/peregrinus879/omasecboot/issues/new?template=field-report.yml). The form asks for the machine, the firmware, the commit, how far you went, what happened at each step that no record can show (texts on the screen, firmware menu wording, whether Windows started, whether BitLocker asked for its key), how the way back went, and the archive: drag `omasecboot-records.tgz` into the last field, or write "none" there when the run ended in [Prepare](#prepare). Quote from the copies in `share/`, never from the records themselves. Attach only that archive, and never recovery keys, serial numbers or anything from `/var/lib/sbctl` or `/var/lib/omasecboot/firmware-backup`.

When the report is filed, `rm -rf ~/omasecboot` removes the checkout and the records.
