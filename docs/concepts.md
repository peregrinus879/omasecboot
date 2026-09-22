# Concepts behind OmaSecBoot

What a first reader needs before the [spec](spec.md), which owns the design, and the [upstream contracts](upstream-contracts.md), which own the facts. Nothing here is a claim of its own: each section ends with where the facts live.

## What the firmware trusts at boot

With Secure Boot on, the firmware starts an EFI program only when it finds it trusted in `db`, which holds certificates, and not revoked in `dbx`, the revocation list. The Platform Key (PK) says who may change the Key Exchange Keys (KEK), and KEK says who may change `db` and `dbx`. A machine leaves the factory with the manufacturer's PK, and with Microsoft's certificates and usually the manufacturer's own in KEK and `db`, so Windows and what those certificates signed start, unless `dbx` revokes it, and nothing else does.

A signature answers one question, "did a trusted key sign these bytes?", and it moves with the file. A hash answers another, "are these the bytes I recorded?", and it needs a trusted place to keep the record. Both appear in this design: the firmware trusts signatures, and Limine keeps a hash where something already trusted can store it, in the loader itself.

Where the facts live: [C9](upstream-contracts.md#c9-microsofts-2011-and-2023-secure-boot-certificates), [D9](spec.md#d9-keys-are-enrolled-by-appending).

## Own keys

OmaSecBoot puts the user's own certificate into the firmware, beside Microsoft's, and replaces only the PK. From then on everything Omarchy boots is signed on the machine with a key that lives there: the Limine loader and the unified kernel images (UKIs), which the kernel hook builds and sbctl's hook signs on every update. The firmware then starts them like anything else it trusts.

The alternative, a shim that Microsoft signed and that carries the user's certificate itself, needs a shim in Arch's or Omarchy's repositories and a Limine that the shim accepts. The spec names the condition under which own keys would give way to it.

Where the facts live: [D1](spec.md#d1-the-users-certificate-goes-into-the-firmware-not-into-a-shim), [C1](upstream-contracts.md#c1-limine-at-boot), [C6](upstream-contracts.md#c6-pacman-and-omarchy).

## The seal

Limine reads `limine.conf`, which holds the menu, the kernel command lines and the paths of the images. A signature on the loader does not cover that file, so an attacker who can edit it can boot a signed kernel with arguments of their own. Limine's answer is to write a checksum of `limine.conf` into the loader itself, and a loader that carries one refuses to start on any other `limine.conf`, with Secure Boot on or off. That is the seal.

The seal is why `limine.conf` and the loader must change together: an edit of `limine.conf` without a re-seal stops the machine at Limine's panic, with Secure Boot on or off, and a raw loader copied over the sealed one checks nothing, and carries no signature, so the firmware refuses it once Secure Boot is on. It is also why a raw loader, one without a seal, is the rescue while Secure Boot is off: it starts whatever `limine.conf` holds.

The images themselves need no hash in `limine.conf`, because the firmware verifies each of them when Limine asks it to load one. A hash there binds an entry to one exact image, which is a different check from the signature's, and it goes stale whenever the image is signed again in place; the design trusts the signer for the current images and leaves the hash to the snapshot copies, which never change.

Where the facts live: [C1](upstream-contracts.md#c1-limine-at-boot), [D3](spec.md#d3-the-loader-is-sealed-over-limineconf-and-os-entries-carry-no-path-hashes).

## Two questions, not one

"Are my certificates in the firmware?" and "is Secure Boot enforcing?" are separate questions with separate answers. Keys can be enrolled while Secure Boot is off, which is how `setup` proceeds, and Secure Boot can be on with the factory keys, which is how a machine arrives. `status` reports both, and `setup` asks for Secure Boot to be turned on only while the firmware holds an active boot entry naming the Limine loader's path, since the fallback path is refused under Secure Boot; which partition that entry names, and which entry the firmware picks, is not proved.

A third state, Setup Mode, is what the firmware enters when its PK is deleted: while it lasts, the key variables can be written. Deleting a manufacturer's PK is a step only the firmware's own key menu can take, and what the tool then writes is taken back only there, by restoring the factory keys.

Where the facts live: [section 4 of the spec](spec.md#4-architecture), [section 6](spec.md#6-commands) for what `setup` compares, [D9](spec.md#d9-keys-are-enrolled-by-appending), [D10](spec.md#d10-one-firmware-step-per-run), [C4](upstream-contracts.md#c4-sbctl-018), [C7](upstream-contracts.md#c7-firmware-boot-entries-efi_boot_entry-and-bootnext).

## Observation instead of a journal

The tool keeps a few small files and derives everything else from what it observes: the firmware's variables, the files on the ESP, the settings in effect. A journal that said what the tool did last would be a second account of the machine, and one that can be wrong: the root filesystem rolls back with a snapshot restore while the ESP and the firmware do not.

The consequence is convergence: every command looks at the machine, does what is missing, and proves the result by reading it back; an interrupted command is finished by running it again. An observation can go stale while a command waits, so the pass looks again once it holds the lock, and what it finds then decides. Upstream's tools report success in cases where they did not do the work, which is why the tool never takes their exit status as proof.

Where the facts live: [D2](spec.md#d2-converge-and-verify-no-journal), [C2](upstream-contracts.md#c2-the-limine-tools).

## Who writes the boot files

Upstream writes them: the kernel hook builds the images and sbctl's hook signs them, the Limine tools deploy the loader, seal it and generate the menu, and the snapshot tools copy images into a history and rewrite the menu. They share one lock. OmaSecBoot runs at the end of that chain as a hook, and never fails a Limine tool from there: the boot files have changed by then, and a failing hook would only turn a finished update into a reported failure.

Two writers stand outside the chain: an editor on `limine.conf`, and the pacman hook that Omarchy's installer leaves, which copies a raw loader over the sealed one after every Limine upgrade. Two watchers, one on each file, run the pass when either changes. The pass rebuilds the loader only when its proof fails, and repeats, three rounds at most, until `limine.conf` held still across one; a change after that starts the pass again.

Where the facts live: [D8](spec.md#d8-watchers-re-seal-the-loader-when-limineconf-or-the-loader-changes), [section 5 of the spec](spec.md#5-integration-points), [C5](upstream-contracts.md#c5-systemd-path-units), [C6](upstream-contracts.md#c6-pacman-and-omarchy).

## Two things called snapshot

A Snapper snapshot is a copy of the root filesystem. It holds the tool, its state and the signing keys, and not the ESP, where the loader, the images and `limine.conf` live, and not the firmware's keys. The snapshot tools also keep a copy of each kernel image on the ESP, in a history, with a hash of the copy in its menu entry.

So an image copied into the history before `setup` is unsigned and stays so: signing it in place would break its hash for good. Such an entry boots with Secure Boot off and is refused with it on, until snapshot rotation retires it. And a restore takes the root back in time while the ESP keeps the signed state: after a restore, `sign` puts the two in step again. A restore to before `setup` takes the tool, the keys and the settings away while the firmware still trusts certificates whose keys are gone, and the next Limine operation returns the loader to stock: keep Secure Boot off until `setup` has run again, with new keys and another round through the firmware.

Where the facts live: [D5](spec.md#d5-snapshot-images-are-never-touched), [C2](upstream-contracts.md#c2-the-limine-tools), [section 7.4 of the spec](spec.md#74-snapshots-and-the-esp).

## The fallback loader

`EFI/BOOT/BOOTX64.EFI` is where firmware looks when it has no entry to start. Upstream deploys a raw Limine loader there, and OmaSecBoot leaves it raw: without a seal it starts whatever `limine.conf` holds, which makes it the rescue after a `limine.conf` mistake, and without a signature the firmware refuses it under Secure Boot, which makes it no way around the seal. A machine installed beside another system starts without one, and `setup` offers to add one only while nothing stands at that path.

"Raw" means unsealed and unsigned, and only the bytes prove it: `status` calls the fallback upstream's raw copy when they equal it, and otherwise says what sbctl can tell, no seal and no signature by the current key, which does not rule out a signature by another key the firmware trusts. The spec states that limit, and the one that upstream's install redeploys the fallback by the user's own setting, `remove` included.

Where the facts live: [D6](spec.md#d6-the-fallback-loader-stays-raw), [D4](spec.md#d4-every-efi-program-on-the-esp-is-signed-with-five-exceptions).

## Windows, measurements and the recovery key

BitLocker checks no signature itself; for its automatic unlock it asks the TPM whether the boot measured as it did when the disk's key was sealed. The TPM records, in registers called PCRs, hashes of what the firmware ran and of the Secure Boot state and keys, and the TPM releases the disk's key without a question only when the registers read as they did when it was sealed; otherwise BitLocker falls back on its other protectors, the recovery key among them. A change of PK, KEK, `db` or of Secure Boot's state changes those registers, which is why the recovery key must be at hand before any of them, and why the tool asks for it.

A start of Windows through Limine, a chainload, puts Limine into those measurements, and every re-seal of the loader changes them. A start through the firmware's own Windows entry, after a restart, by Microsoft's and the TCG's documents does not: nothing of Limine's runs. That is what the tool's Windows entry does, and what `windows bootnext` asks the firmware for once. A chainload entry, the kind `limine-scan` writes, is the other way, and the two ways do not mix.

Disabling BitLocker's protectors before a change and enabling them afterwards avoids the prompt, at the cost of an encryption key that lies unprotected on the drive in between. The recovery key is what the user must have; the suspension is optional.

Where the facts live: [D11](spec.md#d11-windows-starts-through-the-firmware-never-through-a-chainload), [C8](upstream-contracts.md#c8-bitlocker-and-the-tpm), [C10](upstream-contracts.md#c10-hardware-record).

## Owning the Platform Key

Once the PK is the user's, updates that the manufacturer signs with its own PK no longer apply; Microsoft's updates to `db` and `dbx` still do, as long as KEK holds Microsoft's certificate that signs them. The firmware's key menu restores the factory keys, `dbx` among them; the tool never writes `dbx`. `remove` returns the boot files and settings to stock and leaves the firmware to that menu.

Where the facts live: [D9](spec.md#d9-keys-are-enrolled-by-appending), [C9](upstream-contracts.md#c9-microsofts-2011-and-2023-secure-boot-certificates), [section 3 of the spec](spec.md#3-threat-model-non-goals-and-claim-limits), which also says what the tool never claims.
