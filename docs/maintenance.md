# Maintenance Ledger - OmaSecBoot

This on-demand ledger preserves reference sources, versioned compatibility findings, known limitations, removal triggers, and deferred work for OmaSecBoot.

Read this file before changing Secure Boot flow, sbctl tracking, Limine configuration semantics, pacman hooks, UKI handling, Windows dual-boot behavior, or a deferred item. Current operational policy remains in `AGENTS.md`. The package-first contract is `docs/implementation-contract.md`. Re-fetch documentation-derived facts, package behavior, release status, and version gates when acting on an entry.

## Reference Repositories

- [basecamp/omarchy](https://github.com/basecamp/omarchy) - boot chain, Limine configuration, and install scripts
- [omacom-io/omarchy-pkgs](https://github.com/omacom-io/omarchy-pkgs) - package builds for limine-mkinitcpio-hook and limine-snapper-sync

## Reference Sources

### Secure Boot

- [Arch Wiki: Unified Extensible Firmware Interface/Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot) - comprehensive Secure Boot guide for Arch
- [Foxboron/sbctl](https://github.com/Foxboron/sbctl) - Secure Boot key manager (README, man page, JSON output format)
- [sbctl Arch Wiki](https://wiki.archlinux.org/title/Sbctl) - Arch-specific sbctl usage
- [UEFI Specification: Boot Manager](https://uefi.org/specs/UEFI/2.11/03_Boot_Manager.html) - BootOrder, BootNext, load-option, and device-path semantics
- [sbsigntools](https://git.kernel.org/pub/scm/linux/kernel/git/jejb/sbsigntools.git/) - PE signature inspection implementation and release state

### Bootloader

- [Limine Bootloader](https://github.com/limine-bootloader/limine) - upstream repository
- [Limine CONFIG.md](https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md) - configuration reference (`efi`, `efi_boot_entry`, and `guid(...):/path` semantics)
- [Arch Wiki: Limine](https://wiki.archlinux.org/title/Limine) - Arch-specific Limine setup

### Omarchy

- [The Omarchy Manual](https://learn.omacom.io/2/the-omarchy-manual) - setup guides and workflows
- [Omarchy Quattro dual boot](https://omarchy.org/manual/dual-boot-install/) - free-space installation and `limine-scan` workflow
- [Omarchy AI](https://omarchy.org/manual/ai/) - installed agent skills and customization model
- [Omarchy 4.0.0 release](https://github.com/basecamp/omarchy/releases/tag/v4.0.0) - Quattro feature and architecture baseline
- [Omarchy 4.0.1 release](https://github.com/basecamp/omarchy/releases/tag/v4.0.1) - security backport release cut from branch `v4-0-1`
- [Omarchy menu docs](https://github.com/basecamp/omarchy/blob/quattro/docs/menu.md) - menu schema, JSONC parsing, guard batching, and providers
- [basecamp/omarchy](https://github.com/basecamp/omarchy) - main repository (install scripts, Limine config, boot chain)
- [omacom-io/omarchy-pkgs](https://github.com/omacom-io/omarchy-pkgs) - package builds (limine-mkinitcpio-hook, limine-snapper-sync)

### UEFI and Boot

- [Arch Wiki: UEFI](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface) - UEFI overview, boot process, and EFI variables
- [Arch Wiki: EFI system partition](https://wiki.archlinux.org/title/EFI_system_partition) - ESP layout, mounting, and management
- [Arch Wiki: Unified kernel image](https://wiki.archlinux.org/title/Unified_kernel_image) - UKI creation and mkinitcpio integration

### Tools

- [jqlang/jq](https://jqlang.github.io/jq/manual/) - jq manual
- [charmbracelet/gum](https://github.com/charmbracelet/gum) - interactive shell prompts
- [Arch Wiki: Pacman hooks](https://wiki.archlinux.org/title/Pacman#Hooks) - alpm hook format, ordering, and triggers

### Dual Boot

- [Arch Wiki: Dual boot with Windows](https://wiki.archlinux.org/title/Dual_boot_with_Windows) - EFI considerations, partition layout, and bootloader discovery
- [Microsoft BitLocker FAQ](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/faq) - suspension, recovery, and Secure Boot measurement guidance
- [Microsoft BitLocker overview](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/) - edition support and Windows 11 24H2 device-encryption eligibility
- [Microsoft Device Encryption](https://support.microsoft.com/en-us/windows/device-encryption-in-windows-cf7e2b6f-3e70-4882-9532-18633605b7df) - Home-compatible Settings decryption workflow
- [Microsoft BitLocker configuration](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/configure) - protection and PCR-profile policy
- [Microsoft BitLocker recovery overview](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/recovery-overview) - recovery-key storage and retrieval
- [Microsoft Secure Boot key management](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-secure-boot-key-creation-and-management-guidance) - authenticated variable and OEM PK requirements

### Public Claims

Rechecked 2026-08-30. Re-fetch these sources before changing public claims.

- [EA: Battlefield 6 Secure Boot information](https://www.ea.com/en/games/battlefield/battlefield-6/news/secure-boot-information) - publisher requirement for Secure Boot on PC
- [Activision: TPM 2.0 and Secure Boot for Call of Duty](https://support.activision.com/articles/trusted-platform-module-and-secure-boot) - publisher requirements for Black Ops 7 and Warzone
- [Riot: Windows 11 VAN9001 and VAN9003](https://support-valorant.riotgames.com/hc/en-us/articles/10088435639571-Troubleshooting-the-VAN9001-or-VAN-9003-Error-on-Windows-11-VALORANT) - VALORANT Secure Boot and TPM guidance
- [FACEIT security rollout](https://www.faceit.com/en/news/faceit-rollout-of-tpm-secure-boot-iommu-and-vbs) - platform-wide Secure Boot requirement
- [Highguard Secure Boot and TPM guide](https://wildlight.helpshift.com/hc/en/4-highguard/section/22-secure-boot-and-tpm-2-0-guide/) - publisher requirement for PC play
- [Microsoft Intune Windows compliance settings](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-windows-settings) - configurable Secure Boot compliance and device-attestation behavior
- [Microsoft Entra Conditional Access grant controls](https://learn.microsoft.com/en-us/entra/identity/conditional-access/concept-conditional-access-grant) - compliant-device access control and Intune compliance flow
- [Microsoft Secure Boot certificate deployment guidance](https://support.microsoft.com/en-us/topic/windows-secure-boot-certificate-updates-guidance-for-it-professionals-and-organizations-e2b43f9f-b424-42df-bc6a-8476db65ab2f) - ordered 2023 certificate and boot-manager servicing
- [Microsoft Secure Boot troubleshooting](https://support.microsoft.com/en-us/topic/secure-boot-troubleshooting-guide-5d1bf6b4-7972-455a-a421-0184f1e1ed7d) - OEM PK authorization, firmware limitations, and unsupported manual KEK recovery
- [Omarchy ISO consumer Secure Boot plan](https://github.com/omacom-io/omarchy-iso/blob/main/plans/consumer-secure-boot.md) - maintainer architecture and scope
- [rhboot shim-review](https://github.com/rhboot/shim-review) - submission requirements and the Microsoft UEFI CA 2023-only signing boundary after 2026-06-27
- [Microsoft Linux Secure Boot certificate guidance](https://techcommunity.microsoft.com/blog/linuxandopensourceblog/what-it-teams-need-to-know-about-linux-secure-boot-certificates-expiring-in-2026/4530725) - 2011 and 2023 shim compatibility boundary

## Known Limitations

- Limine 12 can enforce BLAKE2B hashes on non-EFI loaded paths when Secure Boot and config checksum enrollment are both active. Omarchy boots UKIs through `protocol: efi`, which is exempt because firmware Secure Boot verifies EFI binaries. Limine 12 expects interface colors as `RRGGBB` values. Do not add automatic path-hash rewriting unless Omarchy moves to non-EFI loaded paths or explicitly enables that model; `status` warns about incompatible non-EFI path hashes and color values. As of 2026-08-26, Arch ships Limine 12.6.1, and the 12.x changelog through 12.6.1 keeps the 12.0.0 hash-enforcement, enrollment, `efi_boot_entry`, and color semantics.
- Omarchy Quattro 4.0 ships as pacman packages (`omarchy`, `omarchy-settings`) under `/usr/share/omarchy`. Limine settings live in `/etc/limine-entry-tool.d/{omarchy-defaults,omarchy-uki}.conf`, including `CUSTOM_UKI_NAME="omarchy"`; `/etc/default/limine` overrides both `/etc/limine-entry-tool.conf` and the `/etc/limine-entry-tool.d/*.conf` drop-ins (limine-entry-tool states this precedence in its config header) and carries `root=` plus this repo's Secure Boot settings. No Omarchy drop-in sets `ENABLE_VERIFICATION` or `ENABLE_ENROLL_LIMINE_CONFIG`, and the precedence keeps any drop-in from overriding them, so `/etc/default/limine` remains the repo's durable write target. Omarchy does not provision sbctl keys or expose an end-to-end Secure Boot workflow; its limine-entry-tool dependency provides scanner, enrollment, signing, and locking primitives that this repo integrates with. The `00-omarchy-update-guard.hook` blocks direct `pacman -Syu` unless `OMARCHY_UPDATE_PACMAN=1`; it sorts before `zz-*` and leaves this repo's hook-ordering invariant intact. As of 2026-08-26, Omarchy `v4.0.1` (`13f18b2c` on branch `v4-0-1`, installed as 4.0.1-1) and `quattro` HEAD `0ae16948` carry the boot chain, Limine drop-ins, `omarchy-system-reboot`, `omarchy-launch-floating-terminal-with-presentation`, and `system.*` menu ids described here, and no migration added since `v4.0.0` touches boot state.
- Quattro supports free-space installation alongside Windows and documents `limine-scan`. limine-entry-tool 1.37.1 writes scanner entries as `protocol: efi` plus `path:`. The current OmaSecBoot branch offers a preliminary `efi_boot_entry` path, but `find_windows_boot_entry()` selects the first textual `efibootmgr -v` loader-path match. Limine 12.6 selects the first case-insensitive label match while scanning BootOrder. The approved release must structurally parse BootOrder and the exact `File(\EFI\Microsoft\Boot\bootmgfw.efi)` device path, map its GPT HD node to one FAT ESP, verify the loader read-only, require one active target and a unique label, prove numeric and Limine resolution agree, persist Boot number, label, PARTUUID, and loader path, and revalidate before every write. Ambiguity fails closed; never create or relabel a firmware option automatically.
- Quattro's menu overlays the user-owned `~/.config/omarchy/extensions/omarchy-menu.jsonc` on the shipped menu per key and watches both files. Its parser strips only whole-line `//` comments; an inline trailing comment or any other parse failure silently drops every user entry while the shipped menu keeps working. Guards (`when`, `checked`, `disabled`) run unprivileged in one batched bash process per reload and per open; inside that batch `omarchy-cmd-present` is a `command -v` function while `omarchy-pkg-present` answers from a `pacman -Q` snapshot, so a `make`-installed `/usr/local/bin/omasecboot` is visible only to `command -v`. `omarchy refresh config omarchy/extensions/omarchy-menu.jsonc` replaces the user file with the shipped sample and keeps `<file>.bak.<epoch>`; `omarchy reinstall configs` (also run by `omarchy reinstall`) copies `/etc/skel/.` over `$HOME` without a backup, where omarchy-settings ships the same sample, then runs `omarchy refresh limine`. Both drop the `system.windows` entry until the fragment is merged again.
- Current Limine packages provide `/etc/boot/hooks/pre.d/10-limine-reset-enroll`, `/etc/boot/hooks/post.d/89-warn-missing-file-hashes`, and `/etc/boot/hooks/post.d/90-limine-enroll-config`. The warning hook sorts before `zzz-omasecboot-sign` and stays silent for EFI-exempt UKI builds on current versions. limine-entry-tool reads sbctl state through JSON. As of 2026-08-26, limine-entry-tool 1.37.1 (2026-07-16) and limine-snapper-sync 1.31.0 (2026-06-30) are the newest upstream tags and the installed omarchy-pkgs builds.
- limine-entry-tool and limine-snapper-sync use FD 200 and `/run/lock/boot-partition.lock`, but several audited wrappers continue after `mutex_lock` failure. Full `limine-snapper-restore` invokes `limine-snapper-sync --restore --no-mutex` without a parent shared lock. Stopping `limine-snapper-sync.service` does not quiesce Snapper plugins, transient units, or the cleanup service's `ExecStopPost`. The lifecycle boundary validates inherited descriptor ownership plus pathname device and inode, calls `flock` on validated FD 200, rejects external mutation during owned transitions, closes the full-restore admission race with its runtime marker and repair lock, and uses dependency-independent ALPM PreTransaction guards for boot paths and producer packages. Active producers remain blocked while complete repair capability is unavailable.
- Limine hook ownership requires the durable transaction token, boot ID, owner PID and process start time, ancestry, a matching root-owned manifest, and validated FD 200. The complete manifest schema remains governed by `docs/implementation-contract.md`; do not maintain a partial duplicate here. Stable state is committed last, stale ownership and failed mutation enter `recovery-required`, and existing unrecorded configurations require explicit adoption.
- Upstream config enrollment can mask failure and modifies primary Limine while pacman hook `99-limine.hook` can write a raw fallback binary. Change-since-start hashing also misses a checksum that was stale before repair began. Both bootable Limine executables expose `++CONFIG_B2SUM_SIGNATURE++` followed by the enrolled 128-character BLAKE2B value. The approved release enrolls the current checksum unconditionally, verifies it directly in `/EFI/limine/limine_x64.efi` and `/EFI/BOOT/BOOTX64.EFI`, signs last, then verifies local signatures and sbctl tracking for every discovered non-Microsoft EFI artifact.
- Arch's sbctl 0.18-2, a packaging-only rebuild of the 0.18 tag, ignores `sign -s` for already-signed files. Snapshot UKIs can therefore be signed but untracked. `save_sbctl_file_entry()` writes the expected `SigningEntry` directly into sbctl's file database. Upstream fixed this on master in commit `ae9c8958` (issue #482) on 2026-01-01, but no later release was tagged as of 2026-08-26 (Arch `sbctl 0.18-2`, updated 2026-08-10). Remove the workaround only after a tagged fixed release reaches Arch; verify with `pacman -Q sbctl` and the upstream release list.
- `sbctl export-enrolled-keys` omits dbx, normally cannot export PK in Setup Mode, requires a fresh destination, and DER output cannot represent every EFI signature-list type. `sbctl reset` removes PK and enters Setup Mode; it does not restore factory keys. Before any Setup Mode instruction, the approved release records raw PK, KEK, db, and dbx data, attributes, hashes, absence, and machine identity. It compares exact planned semantic trust and blocks unknown or unsupported entries rather than matching subjects or repairing with `--append`.
- Arch `sbsigntools 0.9.5` does not apply dbx and does not include upstream trust-chain fix `db731f0c4dd75e112e2abdfbe9443065742e58c3`. Until a tagged fixed release is packaged and a complete db and dbx verifier is implemented and tested, `sbverify --cert` remains advisory and cannot establish firmware bootability. Recheck the Arch package and upstream tags before changing this boundary.
- `zz-sbctl.hook` runs `sbctl sign-all -g`; `-g` tells sbctl to generate or rebuild UKI bundles. With `CUSTOM_UKI_NAME="omarchy"` and limine-entry-tool building UKIs while its own `sb_sign()` is disabled, this should be a no-op. If it causes issues, replace `zz-sbctl.hook` with a custom hook that runs `sbctl sign-all` without `-g`.
- The cleanup hook filename must sort before sbctl's package hook. If upstream renames `zz-sbctl.hook`, `status` reports it missing and the cleanup hook filename may also need adjustment.
- Microsoft documents Device Encryption decryption through Settings on Home but no Home suspension workflow. Pro, Enterprise, and Education have documented BitLocker suspension; managed devices require administrator approval. Windows 11 24H2 broadens automatic-encryption eligibility but does not make encryption universal. `blkid` can identify BitLocker format but not protection state or edition. OmaSecBoot never mounts or modifies NTFS, reads offline registry hives, or diagnoses hibernation from a failed mount.
- UEFI BootNext is a one-boot request. Limine `efi_boot_entry` is selected to request direct firmware handoff instead of a managed chainload, but it does not prove successful Windows boot, stable measurements, PCR7 binding, or absence of BitLocker recovery. Require recovery-key preparation and direct post-boot checks. Firmware and Windows certificate servicing after replacing the OEM PK remain limitations, not product benefits.
- Software `unconfigure`, PK reset, raw-key recovery, and firmware factory restoration are distinct operations. In the approved release, package removal from verified `disabled` or pristine state preserves lifecycle, transaction, recovery, firmware-backup, durable Windows-opt-in, lock-path, and local-key state and removes only `omasecboot`.
- The delivery is package-first: OmaSecBoot functional units and CI, the `v1.0.0` tag, a `source: local` omarchy-pkgs recipe with `sbctl>=0.17`, then minimal Omarchy wrappers, menu integration, and manual changes. The setup wrapper refuses Intel Mac firmware using Omarchy's Apple `bios_vendor` guard pattern, finishes prechecks before package mutation, installs only `omasecboot`, and invokes `/usr/bin/omasecboot`. Shipped menu behavior requires a fresh local ISO acceptance run unless Omarchy maintainers explicitly approve a deviation.
- The current Omarchy ISO is not Secure Boot bootable and these PRs do not change it. The maintainer-aligned durable route is an Omarchy-owned Microsoft-signed shim, systemd-boot, and signed UKIs. Since 2026-06-27 new shim submissions receive only a Microsoft UEFI CA 2023 signature, so coverage depends on firmware already trusting that CA; public sources provide no safe percentage. A borrowed dual-signed shim is a possible bridge but conflicts with the maintainers' plan and inherits another distribution's SBAT lifecycle.
- Public claims stay within the approved evidence boundaries: hard-requirement examples are Battlefield 6, Call of Duty Black Ops 7 and Warzone, VALORANT on Windows 11, FACEIT, and Highguard. Do not infer Linux availability, universal Intune denial, universal Windows encryption, guaranteed certificate servicing, factory-state restoration, PCR behavior, quiet BitLocker, or successful Windows boot.

## Deferred Items

- Consider a separate marketplace companion plugin rather than listing this repository directly. omarchyplugins.com is a community marketplace (HANCORE, repository `HANCORE-linux/omarchy-plugin-marketplace`, unaffiliated with 37signals) for Quattro-format plugins: a git repository plus `manifest.json` schema version 1, with kinds limited to six QML shell surfaces. Its user-level `omarchy plugin add` channel has no scripts or root access and cannot install this repo's command and hooks. A viable companion could use an ID outside `omarchy.*`, such as `peregrinus.secureboot`, with `bar-widget` and `menu` surfaces for Secure Boot status and reboot-to-Windows, while documenting the released package workflow as a prerequisite. `elynch303/security-scan` is precedent for a listed plugin with a manual `install.sh`. The marketplace baseline review-allows installers, sudo, and package-manager use; it auto-blocks NOPASSWD sudoers, curl-piped-to-shell, unpinned remote execution, and `/tmp` PID abuse, none of which this design uses. Open questions are maintainer acceptance of the pacman-hook-installing prerequisite and whether the discretionary `suite` listing type can carry the CLI tool alone.
