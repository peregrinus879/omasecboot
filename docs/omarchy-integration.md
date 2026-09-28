# Omarchy integration

What OmaSecBoot needs on Omarchy's side when it is delivered through Omarchy. The package itself is complete without any of it. [maintenance.md](maintenance.md) marks the open work that must close before that delivery.

## What Omarchy's side would add

| Piece | Shape |
| --- | --- |
| Package recipe | One recipe in omarchy-pkgs for the tagged release, pinning the archive checksum and carrying `omasecboot.install`, which only prints: a warning before removal from a machine that is set up, and one after an upgrade on a machine that is set up whose ESP fails the mount rule. `arch=any`, no patched upstream packages, no version pins. A watch, as omarchy-pkgs asks of every new package (its `docs/upstream-sources.md`): `github` `peregrinus879/omasecboot` with the pattern `v(?P<version>[0-9]+(?:\.[0-9]+)*)`, so every published release, drafts and prereleases excepted, becomes a new version of the recipe. |
| Offline package list | `omasecboot` and `sbctl` in the list the ISO builder reads (`install/omarchy-other.packages`), once the package resolves from a repository. |
| Setup command | `omarchy-setup-security-secure-boot`: installs the package, then runs `sudo omasecboot setup`, which the user runs again after each firmware step it asks for; the menu row starts it again. Follows the `omarchy-setup-security-fido2` pattern. |
| Remove command | `omarchy-remove-security-secure-boot`: runs `sudo omasecboot remove`, which refuses while Secure Boot is on and reminds of Windows' recovery key there, then removes the package only when `remove` succeeded, and keeps `remove`'s closing note in view, the only place left to say when Secure Boot must stay off. While an ESP incident stands `remove` does its work and exits 1, which keeps the package that reports and acknowledges the incident. |
| Menu rows | Setup > Security > Secure Boot and Remove > Security > Secure Boot; the remove row's guard is `omarchy-pkg-present omasecboot`. The setup row, and the Windows row below, show on x86_64 alone, because `setup` refuses any other architecture. |
| Menu row for Windows | The package ships `omarchy-menu.jsonc` beside its documentation: a "Reboot to Windows" row whose guard is the silent, unprivileged `omasecboot windows available` and whose action runs `sudo omasecboot windows bootnext` and reboots only when that succeeded. |
| Update check | A step in `omarchy-update` right after `omarchy-update-status`, inside the phase the update's one authorisation covers, that runs `sudo omasecboot status --quiet` when the package is set up and, on a non-zero exit, tells the user to run `sudo omasecboot status`, whose last lines say what to do and whether a restart is at risk. The reboot phase after it does no privileged work, and AUR builds run after the authorisation ends (C6), so the hook's red line alone covers what they change. Until the step exists, that red line is the only signal. |
| Manual page | One page: what it does, the firmware steps, the rescue procedure, within the claim limits of [spec.md](spec.md) section 3. |

## Requests about the installer

| Subject | Request |
| --- | --- |
| Installer hook | `99-omarchy-limine.hook` (C6 of [upstream-contracts.md](upstream-contracts.md)) undoes `ENABLE_ENROLL_LIMINE_CONFIG` for every user of that upstream feature. The request to the maintainers, also reported as omacom/omarchy#10945: drop the hook, or run `limine-install` in its place. The tool's watcher rebuilds the loader either way. Not the fix #10945 also offers, `sbctl sign` on the copied loader: a signed loader that is not sealed starts under Secure Boot without checking `limine.conf` ([spec.md](spec.md), D4). |
| Fallback on installs beside another system | The installer writes `ENABLE_LIMINE_FALLBACK=no` there (C6), so such a machine starts without a fallback loader. The request: deploy the fallback when the ESP is Omarchy's own and holds no `BOOTX64.EFI`. Until then `setup` offers the same step. |
| Reset Computer | `omarchy-system-factory-reset` does nothing about Secure Boot (C6): on a machine that is set up, the factory root it starts is unsigned and the firmware keeps trusting this machine's certificate. The request: while `omarchy-pkg-present omasecboot` holds, say first to turn Secure Boot off, run `omarchy-remove-security-secure-boot` and restore the factory keys, or refuse. |

## Beside the maintainers' own plan

OmaSecBoot is a route for installed systems that needs nothing from Microsoft: the user's own keys in the firmware, with Limine and the snapshot entries kept. The maintainers' plan (C6) aims at the same machines by another route, a Microsoft-signed shim and a Machine Owner Key, and covers the installer ISO, which this tool does not. Both need a signing key that lives on the machine. What C1 and C10 record about Limine, the sealed `limine.conf`, the signed UKIs and the snapshot entries bears on two of that plan's open questions, on the one machine recorded, and the spec's D1 names the condition under which the certificate would move from the firmware to a shim.
