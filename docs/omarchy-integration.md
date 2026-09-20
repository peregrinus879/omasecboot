# Omarchy integration

What lives outside this repository when OmaSecBoot is delivered through Omarchy, and the claims those pages never make. The package itself is complete without any of it.

## Pieces on the Omarchy side

| Piece | Shape |
| --- | --- |
| Package recipe | One recipe in omarchy-pkgs for the tagged release, pinning the archive checksum. `arch=any`, no patched upstream packages, no version pins. |
| Setup command | `omarchy-setup-security-secure-boot`: installs the package, removes leftovers of a pre-package install after asking, then runs `sudo omasecboot setup`. Follows the `omarchy-setup-security-fido2` pattern. |
| Remove command | `omarchy-remove-security-secure-boot`: refuses while Secure Boot is on, runs `sudo omasecboot remove`, then removes the package. |
| Menu rows | Setup > Security > Secure Boot and Remove > Security > Secure Boot; the remove row's guard is `omarchy-pkg-present omasecboot`. |
| Update check | A step in `omarchy-update` before the restart prompt that runs `sudo omasecboot status --quiet` when the package is set up and, on a non-zero exit, tells the user not to reboot with Secure Boot on. Until it exists, the tool's own red line during the update is the only signal. |
| Menu row for Windows | The package ships `omarchy-menu.jsonc` beside its documentation: a "Reboot to Windows" row whose guard is the silent, unprivileged `omasecboot windows available` and whose action runs `sudo omasecboot windows bootnext` and reboots only when that succeeded. |
| Installer hook | `99-omarchy-limine.hook`, which the installer writes, copies the raw Limine executable over the primary loader after every Limine upgrade, after upstream's own deploy hook has done the same and then sealed and signed it. It undoes `ENABLE_ENROLL_LIMINE_CONFIG` for every user of that upstream feature, not only for this tool. Asked of the maintainers: drop the hook, or run `limine-install` in its place. The tool does not depend on the answer: its watcher rebuilds the loader. |
| Manual page | One page: what it does, the firmware steps, the rescue procedure, the limits below. |

OmaSecBoot is the option for installed systems with the user's own keys. It does not make the installer ISO bootable under Secure Boot; the maintainers' signed-shim plan owns that.

## Claims never made

- That the BootNext handoff keeps BitLocker quiet, preserves PCR7 or proves that Windows booted.
- That a signature proves the firmware will boot a file, or that a clean Windows preflight clears the firmware.
- That firmware keys, the OEM PK or dbx are restored by the tool; the firmware's own key menu does that.
- That hooks remove the need for user action in every case, or that anything holds beyond the machines recorded in the acceptance records.
