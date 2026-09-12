# Omarchy Integration - OmaSecBoot

What remains outside this repository before OmaSecBoot reaches Omarchy users, and the rules those changes follow. Everything about the tool itself is in `README.md` and `AGENTS.md`; compatibility facts are in `docs/maintenance.md`; release gates are in `docs/release-checklist.md`.

## Order of delivery

1. Tag `v1.0.0` in this repository once `docs/release-checklist.md` is complete.
2. omarchy-pkgs: a recipe for `omasecboot` with `source: local` metadata against the tagged archive and its recorded SHA-256. The recipe declares the same resolver floors as `PKGBUILD`; the exact producer versions are enforced by the tool at runtime, not by the recipe.
3. omacom/omarchy, based on `upstream/quattro`: a setup wrapper, a removal wrapper, three menu entries, and a manual page, each with focused tests. Tags, pushes, pull requests, and branch deletion stay maintainer-owned.

The core, producer integration patches, package recipes, and cross-tool tests are maintained together in OmaSecBoot. Producer patches apply to pinned upstream sources in disposable build trees and preserve the owning package's files and data model. omarchy-pkgs carries the resulting reviewed build recipes; each integration records its compatibility contract and upstream removal trigger. Missing migration, transaction-admission, or restore interfaces must be resolved before the corresponding release claim is made.

Install only `omasecboot` from the Omarchy Package Repository; its dependencies bring the rest. Removal drops only `omasecboot` and preserves the durable state under `/var/lib/omasecboot`.

## Package update completion

Omarchy owns the normal update workflow, including its lock, snapshots, keyring update, system packages, migrations, post-update hooks, AUR packages and restart offer. `omarchy-update-system-pkgs` also owns its conflict retry and interactive terminal behavior. The OmaSecBoot integration must preserve those interfaces and the unattended `-y` contract. Package installs/removals and standalone producers remain relevant even when the whole-update command is not used.

Pacman's successful exit does not prove its PostTransaction hooks succeeded. The intended stock-pacman integration therefore needs producer-owned expectation hooks with matching triggers, a fixed runner recording actual producer exits, and core completion that requires every expected operation plus direct boot-artifact proof. A producer that fails before self-registration must leave an unmet expectation. The canonical effective hook set must be proved before and after the transaction. `make test-pacman-contract` establishes the underlying stock-tool behavior; these production interfaces remain release work in the maintenance ledger.

After a successful pacman invocation, the managed Omarchy path must check OmaSecBoot completion before reporting success or proceeding to migrations/reboot. Keep this result separate from pacman's own failure: a completed package transaction with failed boot repair must not enter the file-conflict retry as though package installation failed. Both the normal and interactive-retry paths need this check. The check must also account for later package/producer operations in the overall update; an early success is not a final reboot proof.

Build and verify against each target channel's actual package set. Stable/RC and edge can carry different Limine, mkinitcpio and systemd versions; the newest global Arch release is not automatically the stable Omarchy baseline. The existing OPR channel and package-signing machinery remains the delivery route.

## Setup wrapper

Before any package mutation, the wrapper checks, in order: UEFI boot mode, Limine as the installed bootloader, non-Apple firmware, no stale copy of the tool (`/usr/local/bin/omasecboot`, `/usr/local/lib/omasecboot/`, same-named hooks in `/etc/pacman.d/hooks/`, an unowned `/etc/boot/hooks/post.d/zzz-omasecboot-sign`), package availability and repository provenance, dependencies, and the candidate version. It then installs `omasecboot` and runs `/usr/bin/omasecboot setup`.

Intel Mac firmware is refused with Omarchy's existing Apple `bios_vendor` guard pattern; Omarchy's documented path for those machines requires Apple's Secure Boot to be disabled.

## Removal wrapper

Runs `/usr/bin/omasecboot unconfigure` when the lifecycle is `active`. Exit 3 means only recovery completed: report that outcome and ask the operator to run the removal flow again, rather than continuing to package removal. Exit 75 means the boot state is busy. Remove the package only after a fresh observation establishes verified `disabled` or pristine state; the package's own PreTransaction guard remains authoritative.

## Menu entries

- _Setup > Security > Secure Boot_ runs the setup wrapper.
- _Remove > Security > Secure Boot_ runs the removal wrapper.
- _System > Reboot to Windows_ is the tracked `omarchy/omarchy-menu.jsonc` fragment: an unprivileged, silent guard (`omasecboot windows available`) and a visible-terminal action that runs privileged `omasecboot windows bootnext` before user-context `omarchy system reboot`. Automated tests never execute the action.

A shipped menu default requires a fresh local ISO and graphical acceptance run unless the Omarchy maintainers approve a deviation.

## Manual page

Add one Secure Boot page. Preserve the existing sentence in `manual/02-getting-started.md` and append only a link to the new page. The page states the boundaries the tool itself states:

- Secure Boot changes can trigger BitLocker recovery; they do not always do so. Back up recovery keys first.
- Windows 11 devices may enable Device Encryption after qualifying; this is not universal, including on 24H2.
- Intune policy can mark a device noncompliant and Conditional Access can deny access; do not claim universal loss of company applications.
- Microsoft certificate rotation is a servicing limitation of custom keys, not a benefit of this workflow.
- Firmware authenticates EFI applications; Limine separately authenticates its configuration.
- Hooks provide repair plus verification, not a promise that no user action will ever be required.
- Games with a published Secure Boot requirement: Battlefield 6, Call of Duty Black Ops 7 and Warzone, VALORANT on Windows 11, FACEIT, and Highguard, each cited to its vendor source in `docs/maintenance.md`.
- Never claim that BootNext keeps BitLocker quiet, preserves PCR7, or guarantees Windows boots; never call signature presence a firmware-bootability proof; never promise OEM PK, dbx, or factory-state restoration.

## The ISO

The Omarchy ISO boots unsigned GRUB with `--disable-shim-lock` and an unsigned kernel, so it cannot boot under factory Secure Boot trust. None of the changes above touch the ISO. The maintainers' durable route is an Omarchy-owned Microsoft-signed shim with systemd-boot and signed UKIs; since 2026-06-27 new shim signatures carry only the Microsoft UEFI CA 2023, so coverage depends on firmware already trusting that CA. OmaSecBoot is the opt-in complement for installed systems, not a substitute for that route.

## Verification on the Omarchy side

Omarchy's focused command, style, menu, guard, and aggregate tests, running-UI screenshots, and the fresh local ISO acceptance suite apply, unless the maintainers approve a deviation. No pull request opens with validation placeholders or claims that exceed recorded results.
