# OmaSecBoot Implementation Contract

Status: This document defines the package-first implementation and release gates. A capability is not complete until its atomic work unit lands and passes verification. Changeable facts are scoped by the dates and versions recorded in `docs/maintenance.md` and must be re-fetched before implementation.

Labels: FACT is directly verified; JUDGMENT is the engineering decision applied by this project.

## 1. Delivery Shape

- JUDGMENT: Keep Secure Boot mechanics in OmaSecBoot, package a tagged release in omarchy-pkgs, and add thin setup, removal, menu, test, and manual integration to basecamp/omarchy.
- JUDGMENT: Deliver in this order: OmaSecBoot T-1 through T-9, the `v1.0.0` tag, omarchy-pkgs P-1, then Omarchy O-1 through O-3.
- JUDGMENT: Install only `omasecboot` from the Omarchy Package Repository. Its package dependency supplies the audited `sbctl=0.18` line; removal drops only `omasecboot`.
- JUDGMENT: Base Omarchy integration on `upstream/quattro` and keep tags, pushes, pull requests, and branch deletion maintainer-owned.
- FACT (verified 2026-08-26): The audited Omarchy ISO is not Secure Boot bootable. No ISO implementation belongs in these pull requests.
- JUDGMENT: A shipped menu default requires a fresh local ISO and graphical acceptance run unless Omarchy maintainers explicitly approve a deviation.

## 2. Durable Lifecycle

The product lifecycle is separate from the firmware and key-enrollment state used by the setup wizard.

| State | Contract |
| --- | --- |
| `unmanaged` | No durable lifecycle record. Existing settings require explicit adoption or a new initialization. |
| `disabled` | OmaSecBoot settings and automatic repair are inactive. Package removal is permitted after verification. |
| `active` | OmaSecBoot manages Limine settings and repair. This state does not claim firmware enrollment or Secure Boot is complete. |
| `transition` | A durable transaction is configuring, repairing, enrolling, resetting, recovering, or unconfiguring. |
| `recovery-required` | A mutation or rollback failed. Normal mutation and package removal are blocked. |

JUDGMENT: Every top-level mutation writes a root-owned transaction manifest before changing persistent state. The manifest records its ID, boot ID, owner PID and process start time, prior stable state, operation, completed phases, backup paths and hashes, captured service state, and quiesce/restore outcomes. Stable lifecycle state is committed last.

FACT: The package-first implementation has not shipped a lifecycle schema to users, so schema 2 starts without an in-place migration. Normal readers reject every other schema. The dormant removal classifier has one read-only exception for an exact historical schema-1 `disabled` record whose completed transaction manifest and recorded backup hashes validate; no other legacy document authorizes removal or mutation.

JUDGMENT: Lifecycle schema 2 uses exact-key validation for lifecycle state, transaction manifests, artifact references, root incident seals, and recovery-attempt seals. A failed or stale root transaction publishes one create-once `incident.json` seal that binds the final terminal manifest hash. Publication uncertainty preserves the terminal manifest bytes and records a sealed failure instead of rewriting completed history. Create-once publication uses an atomic same-directory no-replace rename and requires the destination directory to synchronize before lifecycle state may reference the seal.

JUDGMENT: Generic artifact references and transaction backups validate their current files and hashes. Firmware-backup and enrollment-plan fields retain historical transaction bindings because rollback can intentionally restore a different current plan file; firmware mutation boundaries validate those live artifacts directly before use.

JUDGMENT: T-6.1 validates future attempt manifests and seals as a chain linked to the immutable root and immediately preceding attempt, with root-captured service identity preserved throughout. The reader accepts at most 32 attempts, and the read-only capacity check rejects another attempt before any recovery writer is called. Incident reads classify evidence as `absent`, `supported`, `unsupported-schema`, `attempt-limit`, `malformed`, or `control-state-ambiguous`. Attempt creation, recovery dispatch, and stable-state recovery capability remain unavailable until their later T-6 units.

JUDGMENT: The retained recovery draft contributes root-first publication ordering and failure-injection points. Schema 2 replaces mutable-manifest sealing and prepared attempt records with separate terminal seal documents and exact references. Generic callback recovery runners and stable-state recovery activation are removed.

JUDGMENT: Existing installations require an explicit adoption flow. It displays the existing managed settings and records either a user-confirmed original value or `unknown`; it never invents the pre-OmaSecBoot state. Automatic `unconfigure` refuses an unknown original value.

## 3. Locking And Hook Protocol

FACT: Limine, limine-entry-tool, and limine-snapper-sync share `/run/lock/boot-partition.lock`, normally through FD 200. Callers in the versions recorded in `docs/maintenance.md` can ignore `mutex_lock` failure, and some helpers unlink and recreate the pathname after an open failure.

FACT: `limine-snapper-restore` 1.31.0 invokes `limine-snapper-sync --restore --no-mutex`; no parent shared lock exists for that full restore.

JUDGMENT: Replace the environment-only hook bypass with a pre-hook and post-hook protocol:

1. A root-owned transition token must match the durable manifest, current boot ID, owner process start time, and process ancestry before a nested hook treats a transition as its own.
2. An inherited FD 200 must resolve to the same device and inode as the current lock pathname.
3. The hook runs `flock` on inherited FD 200. This retains a valid parent lock and can acquire the parent's open descriptor when the parent ignored its own lock failure.
4. A post-hook without a valid inherited descriptor acquires the shared lock itself before repair.
5. An external hook-aware mutation exits fatally from the pre-hook during an OmaSecBoot transition.
6. A nested post-hook owned by the transaction does not run repair; the top-level transaction performs the final repair and proof.

JUDGMENT: Add ALPM PreTransaction hooks with `AbortOnFail` to block boot-mutating package transactions during `transition` or `recovery-required`, and to block removal unless state is verified `disabled` or pristine.

JUDGMENT: Enforcing the captured active or inactive state of `limine-snapper-sync.service` after transition publication and restoring that state before stable commit is an auxiliary quiescing step. Indeterminate pre-transaction service state aborts before publication. Quiescing is not the concurrency boundary because Snapper plugins and cleanup can launch independent syncs.

JUDGMENT: Permit full snapshot restore only in stable state, serialize its post-repair, reject it during OmaSecBoot transitions, and document that upstream's mutation window itself is not serialized until upstream removes the `--no-mutex` path.

## 4. Limine And EFI Proof

FACT: Upstream enrollment can mask `limine enroll-config` or signing failure. It enrolls only `/EFI/limine/limine_x64.efi`. `/etc/pacman.d/hooks/99-limine.hook` can overwrite `/EFI/BOOT/BOOTX64.EFI` with a raw packaged binary.

FACT: Limine embeds `++CONFIG_B2SUM_SIGNATURE++` followed by the 128-character BLAKE2B value in an enrolled executable.

JUDGMENT: Every proof operation performs this sequence:

1. Repair the managed `/etc/default/limine` settings without calling `limine-update` from `sign`.
2. Enroll the current `/boot/limine.conf` checksum into both primary and fallback Limine x64 executables.
3. Verify the embedded checksum directly in both executables.
4. Clean stale sbctl tracking entries.
5. Run `sign_all_efi()` as the final mutation so newly created snapshot UKIs are discovered and registered.
6. Read back every discovered non-Microsoft EFI artifact and require the local signature and sbctl tracking state.
7. Print enrollment or Secure Boot enablement instructions only after the read-only proof passes.

JUDGMENT: Preserve `ENABLE_VERIFICATION=no` and `ENABLE_ENROLL_LIMINE_CONFIG=yes`. Do not add Limine path hashes while Omarchy boots UKIs through `protocol: efi`.

## 5. Firmware Backup And Enrollment

FACT: `sbctl export-enrolled-keys` excludes dbx, normally cannot export PK in Setup Mode, requires a fresh destination, and DER output cannot represent every EFI signature-list type. `sbctl enroll-keys -m -f --export esl` plans PK, KEK, and db but no dbx; bare `-f` adds the default firmware KEK and db, not the current or default PK. `sbctl reset` removes the PK and enters Setup Mode; it is not a factory-key restoration.

JUDGMENT: Before any instruction that may change firmware trust, save the raw PK, KEK, db, and dbx efivar payloads plus attributes, hashes, absence records, the raw one-byte SetupMode, AuditMode, DeployedMode, and SecureBoot values, and a valid DMI product UUID in a root-only backup. Call this the pre-change firmware set, not factory keys.

JUDGMENT: Refuse enrollment when firmware is already in Setup Mode and no validated pre-change backup exists.

JUDGMENT: Generate the planned PK, KEK, and db set with `sbctl enroll-keys -m -f --export esl`, then compare exact EFI signature-list entries. A conforming current single-entry X.509 OEM PK may be intentionally replaced by the planned single local PK only after raw backup, exact fingerprint display, and explicit confirmation. Every supported current KEK and db entry must occur byte-for-byte in the plan with at least the same multiplicity. Unknown organizational certificates, unsupported entry types or headers, malformed lists, duplicate planned entries, or any current KEK/db entry the plan would lose block v1 enrollment. Do not preserve trust by subject name or use `--append` as repair.

JUDGMENT: V1 has no dbx writer. Before a Setup Mode instruction, require present one-byte AuditMode and DeployedMode values equal to zero and explicit confirmation that firmware offers a PK-only delete or custom-mode operation. Absence is unknown, never inferred as zero. After the firmware operation, require PK absent, formal Setup Mode, and raw KEK, db, and dbx state unchanged from the confirmed backup. Clear-all-only firmware, missing mode variables, or any KEK/db/dbx change is unsupported and aborts before enrollment. After enrollment, compare actual PK, KEK, and db with the confirmed plan and require dbx still equals the confirmed backup.

JUDGMENT: Keep three distinct recovery procedures: software `unconfigure`, `sbctl reset` with a verified Setup Mode postcondition, and firmware factory-key restoration. Do not call the combined workflow automatically reversible.

### Setup States

The setup state is derived from local-key presence, direct enrollment comparison, Setup Mode, and Secure Boot status. Unsupported, contradictory, or indeterminate combinations fail closed rather than being assigned to a state.

| State | Predicate | Required outcome |
| --- | --- | --- |
| 1 | No local sbctl keys | Run the Windows gate, record the pre-change firmware set, create local keys, build and compare the planned trust set, obtain explicit confirmation, configure and prove boot artifacts, then authorize only a PK-delete Setup Mode instruction. Refuse if firmware is already in Setup Mode without a validated pre-change backup. |
| 2 | Local keys exist; enrollment is absent or partial; firmware is in Setup Mode | Run the Windows gate, require a validated pre-change backup and unchanged KEK/db/dbx, rebuild and compare the confirmed plan, prove every boot artifact before enrollment, enroll db then KEK then PK, prove each readback, repeat the artifact proof, then authorize the Secure Boot enablement instruction. |
| 3 | Local keys exist; enrollment is absent or partial; firmware is in user mode | Run the Windows gate, record the pre-change firmware set, build and compare the planned trust set, obtain explicit confirmation, prove boot artifacts, then authorize only a PK-delete Setup Mode instruction without enrolling. |
| 4 | The planned trust set is enrolled; Secure Boot is off | Run the Windows gate and complete the final artifact proof before printing the Secure Boot enablement instruction. |
| 5 | The planned trust set is enrolled; Secure Boot is on | Verify status and complete only guarded, explicitly confirmed post-enrollment work such as Windows opt-in. |

JUDGMENT: Every state that prints a Setup Mode instruction first proves the explicit PK replacement and preservation of every supported current KEK/db entry, unchanged dbx, valid mode variables, and PK-only firmware capability. An unknown entry or unsupported signature-list type blocks the instruction. States 1 through 4 rerun the same Windows preflight immediately before any firmware instruction and reject every nonzero result. Every mutating state runs as a durable top-level transaction, uses the shared boot lock, applies auxiliary producer quiescing, restores prior service state on every exit, and commits stable lifecycle state last. Setup is idempotent in every state.

JUDGMENT: T-5 implements backup, plan, classification, enrollment ordering, and failure proof behind a production predicate that remains false while interrupted recovery is unavailable. The predicate is checked at entry, before artifact mutation, and before every db, KEK, and PK write. `setup` and `enroll` remain blocked and print no firmware instructions until T-6 supplies recovery for every interruption point and deliberately enables the predicate and dispatcher.

JUDGMENT: Before artifact mutation, an enrollment transaction binds the exact firmware-backup manifest, confirmed plan manifest, ESL and normalized-entry hashes, and dbx baseline. It records each db, KEK, and PK attempt before invoking the pinned package executable and records both command status and direct readback afterward. Immediately before the first possible firmware write, it durably changes file-failure handling from restoring prior boot artifacts to preserving the newly proved set. A later failure remains `recovery-required`; generic file rollback must not reintroduce artifacts that may be untrusted by the partially changed firmware state.

## 6. Windows Target Contract

FACT: A first textual `efibootmgr -v` match and Limine's BootOrder label scan can select different Boot options. Numeric BootNext and the Limine menu must resolve to the same validated target.

JUDGMENT: A root Windows mutation command must:

1. Parse `BootOrder` and each verbose Boot option structurally.
2. Require the complete case-insensitive `File(\EFI\Microsoft\Boot\bootmgfw.efi)` node.
3. Map the GPT HD node by PARTUUID, partition number, start, and size to exactly one FAT ESP.
4. Reuse an existing mount or mount only that ESP read-only at an owned mount point.
5. Verify the exact loader file without writing the ESP.
6. Require one active valid Windows target and a case-insensitively unique label under Limine's BootOrder algorithm.
7. Reject stale mappings, duplicate labels, entries outside BootOrder, multiple Windows installations, and numeric/Limine disagreement.
8. Persist Boot number, label, PARTUUID, and loader path, then revalidate them before every BootNext write and managed Limine block update.

JUDGMENT: Never create or relabel firmware entries automatically. If a durable opt-in no longer resolves safely, suppress only the repo-owned managed block, retain the opt-in, and report the failure. Never remove native `limine-scan` chainloads without confirmation.

FACT: UEFI BootNext requests one next-boot attempt. It does not prove the target boot succeeds, establish PCR values, or prevent BitLocker recovery.

## 7. Windows And BitLocker Gate

JUDGMENT: The gate runs before every firmware instruction in setup states 1 through 4 and before enrollment or PK reset whenever any Windows signal exists: a Windows firmware option, a BitLocker filesystem signature, or a Microsoft loader on an ESP.

JUDGMENT: Windows Home follows Microsoft's documented Device Encryption workflow: turn Device Encryption off in Settings and wait for decryption. Do not offer an undocumented Home suspension workflow.

JUDGMENT: Pro, Enterprise, and Education may use documented BitLocker suspend and resume commands. A managed device stops without administrator approval.

JUDGMENT: Never mount or modify NTFS. `blkid` identifies the BitLocker filesystem format but does not prove protection is enabled or suspended. Do not infer hibernation from a failed mount.

JUDGMENT: Boot-manager signature inspection may block an unknown artifact, but successful inspection is advisory. Stock `sbverify --cert` is not firmware-bootability proof, lacks dbx evaluation, and has an unreleased trust-chain fix. Direct Windows boot, recovery-key preparation, and post-boot BitLocker verification remain mandatory.

JUDGMENT: Describe `efi_boot_entry` and numeric BootNext as direct firmware handoffs chosen to avoid Limine chainloading. Do not promise PCR7 binding, stable measurements, successful boot, or absence of a recovery prompt.

## 8. Unconfigure And Package Removal

JUDGMENT: `unconfigure` requires Secure Boot confirmed off, enters a durable transition, suppresses only its own nested repair, restores managed Limine defaults through a three-way merge, removes the repo-owned Windows block, resets config enrollment, rebuilds stock Limine state with each child status checked, verifies the result, and commits `disabled` last.

JUDGMENT: Three-way restoration changes only recorded managed entries or command tokens. A conflicting user edit stops without modifying the file.

JUDGMENT: Package removal is allowed only after the guard verifies disabled or pristine state. Remove trigger hooks with the package, but preserve lifecycle state, transaction records, firmware backups, Windows opt-in, local sbctl keys, and the stable repair-lock pathname.

JUDGMENT: The Omarchy Remove wizard drops only `omasecboot`. A separately installed or dependency-retained `sbctl` is not part of the removal contract.

## 9. Omarchy Integration Contract

JUDGMENT: The setup wrapper performs UEFI, Limine, Apple firmware, stale `/usr/local`, candidate availability, repository provenance, dependency, and candidate-version checks before package mutation. It then installs only `omasecboot` and executes `/usr/bin/omasecboot setup`.

JUDGMENT: Use the existing Apple `bios_vendor` guard pattern and refuse Intel Mac firmware, whose documented Omarchy path requires Apple's Secure Boot disabled.

JUDGMENT: Add _Setup > Security > Secure Boot_, _Remove > Security > Secure Boot_, and _System > Reboot to Windows_. The Windows action runs privileged `windows bootnext` before user-context `omarchy system reboot` and is never executed by automated tests.

JUDGMENT: Preserve the existing `manual/02-getting-started.md` sentence verbatim and append only a link to the new Secure Boot page.

## 10. Public Claim Boundaries

- Secure Boot changes can trigger BitLocker recovery; they do not always do so.
- Eligible Windows 11 devices may enable Device Encryption after qualifying and backing up a recovery key; this is not universal for Windows 11 24H2.
- Intune policy can mark a device noncompliant and Conditional Access may deny access; do not claim universal loss of company applications.
- Microsoft certificate rotation is a prerequisite and custom-PK servicing limitation, not a benefit this workflow guarantees.
- Firmware authenticates EFI applications; Limine separately authenticates its config and applies its protocol-specific payload rules.
- Package and hook automation provide repair plus verification, not a promise that no user action will ever be required.
- The supported game examples are Battlefield 6, Call of Duty Black Ops 7 and Warzone, VALORANT on Windows 11, FACEIT, and Highguard, each with its existing primary vendor source.
- Do not claim BootNext keeps BitLocker quiet, preserves PCR7, or guarantees Windows boots.
- Do not call signature inspection firmware-bootability proof.
- Do not promise OEM PK, dbx, or factory-state restoration.

## 11. ISO Position

FACT (verified 2026-08-26): The audited Omarchy ISO uses unsigned standalone GRUB with `--disable-shim-lock`, plus unsigned kernel and initramfs, and cannot boot under ordinary factory Secure Boot trust.

JUDGMENT: The maintainer-aligned durable path is an Omarchy-owned Microsoft-signed shim, systemd-boot, and signed UKIs. Since 2026-06-27 new shim signatures use only Microsoft UEFI CA 2023, so firmware coverage is conditional on that CA already being trusted.

JUDGMENT: Borrowing another distribution's dual-signed shim is technically viable as a bridge but conflicts with the maintainers' written policy and carries another distribution's SBAT and revocation lifecycle. Custom keys before installation do not satisfy factory-key, no-firmware-interaction boot.

## 12. Atomic Implementation Map

1. **T-1 `feat: add durable Secure Boot lifecycle`**: version contract, lifecycle module, manifests, validated hook protocol, transition guards, adoption, and lifecycle tests.
2. **T-2 `fix: prove Limine boot artifacts`**: both Limine binaries, embedded checksum proof, failure propagation, final EFI signing and tracking proof, and fixtures.
3. **T-3 `feat: validate Windows firmware handoff`**: structured BootOrder parser, ESP mapping, root loader validation, numeric/Limine equivalence, durable target identity, and ambiguity tests.
4. **T-4 `feat: add the Windows encryption preflight`**: edition and management gate, Home decryption, Pro and higher suspension, advisory signer inspection, and no-NTFS tests.
5. **T-5 `feat: make setup and enrollment state-aware`**: raw firmware backup, planned-set comparison, five setup states, dormant enrollment proof, producer quiescing, and failure injection; production mutation remains blocked.
6. **T-6.1 `feat: seal lifecycle recovery incidents`**: schema-2 exact validators, create-once root seals, exact attempt-seal schemas, bounded read validation, publication-uncertainty evidence, and the exact read-only legacy-disabled removal classifier; attempt mutation and production recovery gates remain closed.
7. **T-6.2 `feat: recover boot artifact producers`**: registry-selected producer recovery, ancestor-bound producer leases, failed-package handling, and serialized repair coverage for package, Limine, snapshot, and restore producers.
8. **T-6.3 `feat: recover firmware trust mutations`**: phase-aware continuation for firmware backup binding, preservation-policy publication, write-attempt records, direct readback, and the supported PK-only trust plan.
9. **T-6.4 `feat: add dormant Windows BootNext mutation`**: direct target revalidation and BootNext write/readback behind a closed production gate.
10. **T-6.5 `feat: recover Windows handoff mutations`**: boot-ID-bound Windows handoff recovery and the `consumed-unknown` outcome without claiming that Windows booted.
11. **T-6.6 `feat: add software unconfiguration`**: conflict-detecting three-way restore of owned settings, verification of both Limine targets, durable-state preservation, and final `disabled` commit.
12. **T-6.7 `feat: add recoverable Secure Boot commands`**: setup, signing, enrollment, Windows mutation, cleanup, and unconfiguration through the recovery registry while the consolidated production gate remains closed.
13. **T-6.8 `feat: activate recoverable Secure Boot lifecycle`**: production capability after interrupted-recovery, ownership, producer, firmware, Windows, and uninstall tests prove the complete lifecycle contract.
14. **T-7 `build: add the Arch package layout`**: FHS install, PKGBUILD, package script, tmpfiles, hook deployment, and staged install, upgrade, and removal tests.
15. **T-8 `docs: document lifecycle and recovery`**: README, maintenance ledger, operational invariants, and end-user boundaries.
16. **T-9 `ci: verify shell and package builds`**: tests, syntax, ShellCheck, and package build workflow.
17. **P-1 `build: add omasecboot`**: tagged release recipe and `source: local` metadata in omarchy-pkgs.
18. **O-1 `feat: add Secure Boot setup and removal`**: both Omarchy wrappers and focused shell tests.
19. **O-2 `feat: add Secure Boot menu actions`**: three menu entries and guard tests.
20. **O-3 `docs: document Secure Boot`**: the new manual page and edits to manuals 02, 50, and 26.

Touched code conforms to each repository's style as part of its functional unit.

## 13. Verification And Release Gates

- Every T unit runs `make test`, Bash syntax checks, and ShellCheck over all shipped shell files.
- Lock, lifecycle, firmware, Windows, and package tests include failure injection and assert state after every failed phase.
- T-7 receives staged install, upgrade, and removal tests plus package inspection. P-1 receives a clean-chroot build against the release tag.
- Real-machine mutation is not implied by hermetic tests. Privileged hardware checks must be run and recorded separately; real enrollment, reset, dbx restoration, and factory restoration remain explicitly unexercised until records establish otherwise.
- Omarchy runs focused command, style, menu, guard, and aggregate tests, running-UI screenshots, and the fresh local ISO acceptance suite unless maintainers explicitly approve a deviation.
- No pull request opens with validation placeholders or claims that exceed recorded results.
