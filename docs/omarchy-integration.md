# Omarchy integration

What OmaSecBoot needs on Omarchy's side when it is delivered through Omarchy. The package itself is complete without any of it.

## What Omarchy adds

| Piece | Shape |
| --- | --- |
| Package recipe | One recipe in omarchy-pkgs for the tagged release, pinning the archive checksum and carrying `omasecboot.install`, which only prints a warning before removal from a machine that is set up. `arch=any`, no patched upstream packages, no version pins. |
| Offline package list | `omasecboot` and `sbctl` in the list the ISO builder reads (`install/omarchy-other.packages`), once the package resolves from a repository. |
| Setup command | `omarchy-setup-security-secure-boot`: installs the package, then runs `sudo omasecboot setup`. Follows the `omarchy-setup-security-fido2` pattern. |
| Remove command | `omarchy-remove-security-secure-boot`: refuses while Secure Boot is on, runs `sudo omasecboot remove`, then removes the package. |
| Menu rows | Setup > Security > Secure Boot and Remove > Security > Secure Boot; the remove row's guard is `omarchy-pkg-present omasecboot`. |
| Menu row for Windows | The package ships `omarchy-menu.jsonc` beside its documentation: a "Reboot to Windows" row whose guard is the silent, unprivileged `omasecboot windows available` and whose action runs `sudo omasecboot windows bootnext` and reboots only when that succeeded. |
| Update check | A step in `omarchy-update` before the restart prompt that runs `sudo omasecboot status --quiet` when the package is set up and, on a non-zero exit, tells the user to run `sudo omasecboot status` and not to reboot until that report is clean. Until it exists, the tool's own red line during the update is the only signal. |
| Manual page | One page: what it does, the firmware steps, the rescue procedure, within the claim limits of [spec.md](spec.md) section 3. |

## Requests about the installer

| Subject | Request |
| --- | --- |
| Installer hook | `99-omarchy-limine.hook` (C6 of [upstream-contracts.md](upstream-contracts.md)) undoes `ENABLE_ENROLL_LIMINE_CONFIG` for every user of that upstream feature. The request to the maintainers: drop the hook, or run `limine-install` in its place. The tool's watcher rebuilds the loader either way. |
| Fallback on installs beside another system | The installer writes `ENABLE_LIMINE_FALLBACK=no` there (C6), so such a machine starts without a fallback loader. The request: deploy the fallback when the ESP is Omarchy's own and holds no `BOOTX64.EFI`. Until then `setup` offers the same step. |

## Beside the maintainers' own plan

OmaSecBoot is a route for installed systems that needs nothing from Microsoft: the user's own keys in the firmware, with Limine and the snapshot entries kept. The maintainers' plan (C6) aims at the same machines by another route, a Microsoft-signed shim and a Machine Owner Key, and covers the installer ISO, which this tool does not. Both need a signing key that lives on the machine. What C1 and C10 record about Limine, the sealed `limine.conf`, the signed UKIs and the snapshot entries bears on two of that plan's open questions, on the one machine recorded, and the spec's D1 names the condition under which the certificate would move from the firmware to a shim.
