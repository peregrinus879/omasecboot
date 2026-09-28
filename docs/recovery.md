# Recovery

What to do when the machine does not start, when the ESP reports a write error, and what the tool's messages mean. One rule holds throughout: restart only when `sudo omasecboot status --quiet` exits 0, or where a step below says so; the last lines of `sudo omasecboot status` say what to do next. The [spec](spec.md) owns the design behind each step, and its section 7 the failure table.

## If the machine does not start

A sealed Limine loader refuses to start, with Secure Boot on or off, when `limine.conf` no longer matches the checksum sealed into it. The watchers and the hook keep the two in step; this is the way back when a change slipped through.

### With the fallback loader

Before: an earlier `sudo omasecboot status` said the fallback loader carries no seal, as upstream's raw copy or as far as sbctl can tell; where it named another system's loader there, or none, go to [Without a fallback loader](#without-a-fallback-loader). With an encrypted Windows on the machine, have its recovery key at hand, since turning Secure Boot off changes what Windows measures. Know the key that opens the firmware's boot menu.

1. Turn Secure Boot off in the firmware.
2. In the firmware's boot menu, start the fallback loader, `EFI/BOOT/BOOTX64.EFI`, listed under the disk's name or a label of the firmware's own ("UEFI OS" on the recorded machine). Expected: Limine's menu, and Omarchy starts, since the fallback carries no seal.
3. If you did not change `limine.conf` yourself, read it first: `sign` seals the loader over whatever it holds. Then:

   ```bash
   sudo omasecboot sign
   ```

   Expected: it exits 0 and says "Boot files are sealed and signed". Where it names a write error of the ESP, go to [If the ESP reports a write error](#if-the-esp-reports-a-write-error) instead.
4. Where Secure Boot was off before step 1, the procedure ends here. Where it was on, read the report first:

   ```bash
   sudo omasecboot status
   ```

   Expected: it says "Your keys are enrolled in the firmware". Where it says instead that your keys are not enrolled yet, leave Secure Boot off and continue with `sudo omasecboot setup`. Otherwise, with Windows' recovery key at hand if Windows is encrypted, turn Secure Boot back on in the firmware, which the command opens only while the report is clean:

   ```bash
   sudo omasecboot status --quiet && systemctl reboot --firmware-setup
   ```

   Expected: the machine restarts into the firmware. While the report fails, nothing happens, and the report says why.

Omarchy installed beside another system has no fallback loader; `setup` offers to add one while nothing stands at that path. Without one, the way back is rescue media.

### Without a fallback loader

Before: rescue media (the Omarchy installer on a USB stick), started with Secure Boot off; with an encrypted Windows, its recovery key at hand. A raw loader put over the Limine loader checks nothing and starts. Stop at the first command that reports an error, apart from tar in step 3, whose way around is given there.

1. Find the EFI system partition:

   ```bash
   lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME
   ```

2. Mount it, with its own device name in place of the placeholder:

   ```text
   mount /dev/<the EFI system partition> /mnt
   ```

   Expected: mount prints nothing.

3. Put back the raw loader that upstream keeps beside the Limine loader:

   ```bash
   tar -xf /mnt/EFI/limine/limine_x64.bak -C /mnt/EFI/limine limine_x64.efi
   ```

   Expected: tar prints nothing. Where there is no `limine_x64.bak`, or tar reports an error, a live system with the `limine` package holds a raw loader at `/usr/share/limine/BOOTX64.EFI` (`pacman -Qo` that path says whether yours does; with a network, `pacman -Sy limine` puts it there): `cp /usr/share/limine/BOOTX64.EFI /mnt/EFI/limine/limine_x64.efi`. That is the live system's Limine; it serves for the one start, and `sign` then rebuilds the loader from the installed one. Do not copy `/mnt/EFI/BOOT/BOOTX64.EFI` over it, which on a machine installed beside another system may be that system's. If the copy fails too, stop and report it.
4. `umount /mnt`, then start Omarchy with Secure Boot off.
5. Where `limine_x64.bak` exists and tar reported an error, move the damaged copy aside and have upstream write a fresh one; `sign` builds the loader from upstream's copy while one exists, refuses while it cannot read it, and builds from the package's executable without one:

   ```bash
   sudo mv /boot/EFI/limine/limine_x64.bak /boot/EFI/limine/limine_x64.bak.damaged
   sudo limine-install
   ```

   Expected: both exit 0.

6. Go on at step 3 of [With the fallback loader](#with-the-fallback-loader), or [remove the tool](../README.md#removing-it).

### When the firmware refuses the loader

A firmware update or a reset of its settings can put the factory keys back, and the firmware then refuses the loader signed with yours. With Windows' recovery key at hand if Windows is encrypted, turn Secure Boot off, start Omarchy, and run `sudo omasecboot status`, which names the way back.

### When only the newest kernel is refused

Start a snapshot entry, or, with Windows' recovery key at hand if Windows is encrypted, turn Secure Boot off; then run `sudo omasecboot sign`.

## If the ESP reports a write error

A write error of the ESP may concern any file on it, not only the one just written, and once a sync by any program has seen it, a sync that opens the ESP afterwards no longer reports it: no later sync or check shows which write was lost ([C2](upstream-contracts.md#c2-the-limine-tools)). OmaSecBoot says it where it happens and records it as an incident with an ID of its own. Until you acknowledge it, `status` blocks on it, whether or not the machine is set up, `sign`, `setup`, `windows setup`, `remove` and `windows remove` fail, and `windows bootnext` refuses.

Before: keep the machine running, and install, update and snapshot nothing until the last step. Some steps end non-zero on purpose: `status` while the incident stands, `fsck.fat -n` where it finds errors, and `sign` in step 8.

1. Note the incident:

   ```bash
   sudo omasecboot status
   ```

   Expected: it exits 1 and names the incident's ID and when it was recorded: note both. Where it says instead that `/var/lib/omasecboot/needs-attention` cannot be read or holds a line OmaSecBoot does not write, there is no ID; step 10 says how that ends.
2. Read the kernel's messages about the error, with `-b -1`, `-b -2` and so on in place of `-b` where the machine has restarted since the incident's time:

   ```bash
   journalctl -k -b | grep -iE 'fat|i/o error'
   ```

   Expected: lines that name the ESP's device. Errors that keep coming call for a look at the storage before anything else writes to it: the disk's own health report, where `smartmontools` is installed (`sudo smartctl -a` with the disk's device), and, for a removable or external disk, its connection. Repeated errors alone do not say which part is at fault.
3. Note the ESP's device, stop what writes to the ESP, and unmount it:

   ```bash
   findmnt -no SOURCE /boot
   sudo systemctl stop limine-snapper-sync.service 'omasecboot-watch@*'
   sudo umount /boot
   ```

   ```text
   findmnt --source <the device>
   ```

   Expected: `findmnt` prints nothing. If `umount` says the target is busy, close what uses `/boot`, such as a shell or a file manager open there, and run it again. Do not go on while the device is mounted anywhere: `fsck.fat` does not check that it is not.
4. Check the structure without changing it (package `dosfstools`):

   ```text
   sudo fsck.fat -n <the device>
   ```

   Expected: exit 0, and on to step 5. The check covers the allocation table and the directories, not whether a file's content is right. Exit 2 means it did not read the device: check the device name. Exit 1 means it found errors: copy the partition first, named after the incident, or after the date where there is no ID, then repair it and check again:

   ```text
   sudo cp <the device> /var/tmp/esp-<the incident's ID>.img
   sudo fsck.fat -a <the device>
   sudo fsck.fat -n <the device>
   ```

   Expected: the copy exits 0 and the second check exits 0. The repair may drop damaged files; the steps below write Omarchy's anew. If the copy fails for lack of space, free space in `/var/tmp`, remove the partial image and copy again. If it reports an input/output error, the storage cannot be read in full: do not repair, leave the ESP unmounted and the machine running, and have the storage examined first. If the second check still finds errors, keep the copy, do not mount the ESP, and [report it](https://github.com/peregrinus879/omasecboot/issues/new?template=bug-report.yml).
5. Mount the ESP again, onto an empty mount point:

   ```bash
   command ls -A /boot
   sudo mount /boot
   ```

   Expected: `ls` prints nothing, and `findmnt /boot` then shows the device. Anything `ls` lists was written while the ESP was away: move it to `/var/tmp` before the mount hides it.
6. Read `/boot/limine.conf`: `sign` seals the loader over whatever it holds. If it is damaged or gone, `omarchy refresh limine` puts Omarchy's template back, which loses entries written by hand.
7. Write Omarchy's boot files anew and start the snapshot sync again:

   ```bash
   sudo limine-update
   sudo systemctl start limine-snapper-sync.service
   ```

   Expected: both exit 0. Where OmaSecBoot is set up, `limine-update` runs its pass, which says "stands until you acknowledge it" for the incident, as expected here, and starts again the watchers that step 3 stopped.
8. Where OmaSecBoot is set up:

   ```bash
   sudo omasecboot sign
   ```

   Expected: it says "stands until you acknowledge it" and exits 1; any other problem it names comes first. Where it is not set up, as after `remove`, `sign` refuses, and step 7 has written the boot files.
9. What `limine-update` does not write stays as the error left it: the snapshot images limine-snapper-sync keeps on the ESP, whose entries are a way back only while those images are intact, and the files of other owners, such as Windows Boot Manager or another system's loader, which are theirs to recover with their own tools.
10. Look at the report again:

    ```bash
    sudo omasecboot status
    ```

    Expected: it names the ID you noted and no other problem. Then acknowledge that incident:

    ```text
    sudo omasecboot acknowledge <the incident's ID>
    ```

    Expected: it says "is acknowledged. That records your decision", and the decision is yours: the acknowledgement proves nothing about the ESP. Another ID means a write error happened during these steps: start again at step 2. Where the report says that the record cannot be read or holds a line OmaSecBoot does not write, there is no ID: correct `/var/lib/omasecboot/needs-attention` by hand, as root, keeping its other lines; where it cannot be read at all, the root filesystem needs checking first.
11. Restart only when the report passes:

    ```bash
    sudo omasecboot status --quiet && systemctl reboot
    ```

    Expected: the machine restarts. While the report fails, nothing happens, and `sudo omasecboot status` says why.

## Messages and what to do

| Message or symptom | Meaning | What to do |
| --- | --- | --- |
| `The Limine loader is not sealed over the current limine.conf` | The loader would refuse to start, with Secure Boot on or off | `sudo omasecboot sign` before you reboot. If the machine is already down, see [If the machine does not start](#if-the-machine-does-not-start) |
| `The Limine loader is sealed over the current limine.conf but not signed` | It starts with Secure Boot off only | `sudo omasecboot sign` |
| `OmaSecBoot could not finish`, a red line after an update | The pass inside the update could not prove the boot files | `sudo omasecboot status`, then what it names. Do not reboot while its last line warns against it |
| `The firmware has no active boot entry for the Limine loader` | The machine starts through the fallback path, which stays raw and is refused with Secure Boot on; without a raw fallback there, nothing starts Omarchy | Before a restart, run `sudo limine-install` and check with `efibootmgr` that a Limine entry exists, keeping Secure Boot off until then; then `sudo omasecboot setup` |
| `names a file the ESP does not hold` | An OS entry's kernel image is missing from the ESP, deleted by hand or lost to a copy that failed; that entry would not start, with Secure Boot on or off | `sudo limine-update` before a restart, which builds it again |
| `Stale path hash in limine.conf` | An OS entry still carries a hash of a file that has changed since | `sudo omasecboot setup`, which regenerates the entries |
| `cannot be checked: the path is not under boot():/` | An entry names its hashed file under a resource other than `boot():/`, which only the firmware resolves | Nothing; it is a note. A file of that path on the ESP stays unsigned, and `status` says so if it is one the pass would sign |
| `Secure Boot is on, but the firmware does not hold your keys` | A firmware update or a CMOS reset put the factory keys back | With Windows' recovery key at hand if Windows is encrypted, turn Secure Boot off, then `sudo omasecboot setup` |
| `The firmware reports no SetupMode variable` | Some firmware drops it after its key menu erased every Secure Boot key | Restore the factory keys in the firmware's key menu, where it offers the choice delete only the Platform Key, then `sudo omasecboot setup` |
| `sbctl has no signing keys` | The keys under `/var/lib/sbctl` are gone | Restore them from a snapshot or backup. With new keys, the firmware needs another round of `setup` |
| `limine.conf holds OmaSecBoot's Windows comment where OmaSecBoot did not write it` | OmaSecBoot's Windows entry was edited by hand, or its comment line ended up elsewhere | Remove the whole edited entry, which the next pass writes again while the Windows entry is enabled; anywhere else, remove the comment line alone. Then `sudo omasecboot sign` |
| `limine.conf holds no menu entries` | Omarchy's template stands, as `omarchy refresh limine` leaves it until `limine-update` fills it, so Limine would not start Omarchy | `sudo limine-update`, then `sudo omasecboot status`; do not reboot before |
| `An earlier setup or remove did not finish` | One of the two stopped half way, for example when a Limine tool failed | `sudo omasecboot remove` to return to stock, or `sudo omasecboot setup` to set up again |
| `The firmware's keys are in a state OmaSecBoot will not write to` | The firmware's key menu removed more than the Platform Key, or dbx changed after the backup | Restore the factory keys in the firmware, run `sudo omasecboot setup`, then delete only the Platform Key, starting no other system in between |
| `Boot files are busy` (exit 75) | Another tool holds the boot lock; a kernel install held it for a minute on the recorded machine | Run the command again when that tool has finished. Nothing failed |
| `A Limine loader that is not sealed carries your signature` | It starts under Secure Boot and reads whatever `limine.conf` it finds without checking it | Delete it if nothing starts from it, as a copy Omarchy 3 left in `EFI/arch-limine`; if another system starts from it, seal it with that system's tools |
| `OmaSecBoot seals and signs nothing on this machine`, after an upgrade | The ESP's mount lets users other than root write it, or cannot be read | `sudo omasecboot status`, then the row below |
| `The ESP must be writable by root alone` | Users other than root can write the ESP, or its mount does not show that they cannot. Anyone who can write it can change what boots, so OmaSecBoot seals and signs nothing until only root can; a change of `limine.conf`, or of the loader with Secure Boot on, meanwhile leaves a machine that does not start | Take any `uid=` off the ESP's line in `/etc/fstab` and give it an `fmask` and a `dmask` without write for group and others, as Omarchy's `fmask=0022,dmask=0022` have, and unmount any idmapped mount of it. vfat keeps its options on a remount, so mount it afresh: `sudo systemctl daemon-reload && sudo umount /boot && sudo mount /boot`, then `sudo omasecboot sign` |
| `The ESP reported a write error` | A sync of the ESP failed, so a restart may not find the boot files as they were written; the error may concern any file on the ESP | Do not reboot. Follow [If the ESP reports a write error](#if-the-esp-reports-a-write-error) |
| `holds a line OmaSecBoot does not write` | The record of findings cannot be read, or holds a line OmaSecBoot did not write, such as a damaged incident, so whether the ESP reported a write error cannot be told; it counts as one | Do not reboot. Follow [If the ESP reports a write error](#if-the-esp-reports-a-write-error), whose step 10 says how it ends |
| `it carries Limine's marker, and its checksum slot does not tell whether it checks limine.conf` | The file has Limine's marker in a form this tool cannot judge, so it stays unsigned and does not start with Secure Boot on | Delete it if nothing starts from it. If it is a kernel image, report it |
| `cannot be read to tell whether it is a Limine loader that is not sealed` | Reading the file failed | Check the ESP for read errors, then `sudo omasecboot sign` |
| A new snapshot gets no menu entry | limine-snapper-sync takes a snapshot as new only when its time is later than the newest it recorded, and one taken while the clock ran ahead, as after Windows wrote local time to the hardware clock, recorded a time in the future ([maintenance.md](maintenance.md) holds the report upstream) | Check that `timedatectl` reports the clock synchronised before a snapshot, and beside Windows keep both systems on one convention for the hardware clock (omacom/omarchy#13367); entries come back once real time has passed that recorded time |
| A snapshot entry stops at `PANIC: efi: LoadImage failure` with Secure Boot on | The snapshot image predates setup and is unsigned, so the firmware refuses it and Limine halts | Hold the power button, start again and pick another entry |
| A snapshot restore prints `Limine v12 requires verification hashes` and advises `ENABLE_VERIFICATION=yes` | The Limine tools' own check, which does not see Omarchy's UKI setting during a restore. The entries are UKIs, which the firmware verifies by signature | Nothing. `ENABLE_VERIFICATION=no` is one of the two settings `setup` manages, and the next `sign` writes it back if it is changed |
