# Omarchy integration

What OmaSecBoot needs on Omarchy's side when it is delivered through Omarchy. The package itself is complete without any of it.

## Pieces on the Omarchy side

| Piece | Shape |
| --- | --- |
| Package recipe | One recipe in omarchy-pkgs for the tagged release, pinning the archive checksum. `arch=any`, no patched upstream packages, no version pins. |
| Setup command | `omarchy-setup-security-secure-boot`: installs the package, removes leftovers of an earlier install after asking, then runs `sudo omasecboot setup`. Follows the `omarchy-setup-security-fido2` pattern. |
| Remove command | `omarchy-remove-security-secure-boot`: refuses while Secure Boot is on, runs `sudo omasecboot remove`, then removes the package. |
| Menu rows | Setup > Security > Secure Boot and Remove > Security > Secure Boot; the remove row's guard is `omarchy-pkg-present omasecboot`. |
| Update check | A step in `omarchy-update` before the restart prompt that runs `sudo omasecboot status --quiet` when the package is set up and, on a non-zero exit, tells the user not to reboot with Secure Boot on. Until it exists, the tool's own red line during the update is the only signal. |
| Menu row for Windows | The package ships `omarchy-menu.jsonc` beside its documentation: a "Reboot to Windows" row whose guard is the silent, unprivileged `omasecboot windows available` and whose action runs `sudo omasecboot windows bootnext` and reboots only when that succeeded. |
| Installer hook | `99-omarchy-limine.hook` [C7] undoes `ENABLE_ENROLL_LIMINE_CONFIG` for every user of that upstream feature. The request to the maintainers: drop the hook, or run `limine-install` in its place. The tool's watcher rebuilds the loader either way. |
| Offline package list | `omasecboot` and `sbctl` in the list the ISO builder reads (`install/omarchy-other.packages`), once the package resolves from a repository. |
| Manual page | One page: what it does, the firmware steps, the rescue procedure, within the claim limits of [spec.md](spec.md) section 3. |

OmaSecBoot is the option for installed systems with the user's own keys. It does not make the installer ISO bootable under Secure Boot; the maintainers' signed-shim plan owns that.
