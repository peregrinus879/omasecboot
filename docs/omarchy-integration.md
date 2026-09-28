# Omarchy integration

What OmaSecBoot needs on Omarchy's side when it is delivered through Omarchy: what the package ships today, what must close before that delivery, what Omarchy's side would add, and the requests about the installer. The package is complete without Omarchy's part.

## What the package ships

- The `omasecboot` command with its hook, its watchers and `omasecboot.install`, the one scriptlet, which only prints: a warning before removal from a machine that is set up, and one after an upgrade on a machine that is set up whose ESP fails the mount rule. `arch=any`, no patched upstream packages, no version pins.
- `omarchy-menu.jsonc` beside the documentation: a "Reboot to Windows" row whose guard is the silent, unprivileged `omasecboot windows available` and whose action runs `sudo omasecboot windows bootnext` and restarts only when that succeeded; `bootnext` refuses while an ESP incident stands.
- The documentation under `/usr/share/doc/omasecboot`, with the [recovery guide](recovery.md) that the tool's messages name.

## Before delivery through Omarchy

Three items of [maintenance.md](maintenance.md#open-work) close before the package is offered through Omarchy; that page owns each with what closes it:

- the firmware's boot entry for the Limine loader, judged by partition identity and `BootOrder` membership;
- sbctl's firmware quirks, shown in `status`;
- a BootNext that another tool set, kept by `windows bootnext`.

## What Omarchy's side would add

| Piece | Shape |
| --- | --- |
| Package recipe | One recipe in omarchy-pkgs for the tagged release, pinning the archive checksum and carrying `omasecboot.install`. A watch, as omarchy-pkgs asks of every new package (its `docs/upstream-sources.md`): `github` `peregrinus879/omasecboot` with the pattern `v(?P<version>[0-9]+(?:\.[0-9]+)*)`, so every published release, drafts and prereleases excepted, becomes a new version of the recipe. |
| Offline package list | `omasecboot` and `sbctl` in the list the ISO builder reads (`install/omarchy-other.packages`), once the package resolves from a repository. Every machine then has the package before anyone opts in, so its presence says nothing about Secure Boot (below). |
| Setup command | `omarchy-setup-security-secure-boot`: installs the package, then runs `sudo omasecboot setup`, which the user runs again after each firmware step it asks for; the menu row starts it again. Follows the `omarchy-setup-security-fido2` pattern. |
| Remove command | `omarchy-remove-security-secure-boot`: runs `sudo omasecboot remove`, which refuses while Secure Boot is on and reminds of Windows' recovery key there, and removes the package only when `remove` succeeded, keeping `remove`'s closing note in view, the only place left to say when Secure Boot must stay off. While an ESP incident stands `remove` does its work and exits 1, which keeps the package that reports and acknowledges the incident. |
| Menu rows | Setup > Security > Secure Boot, on x86_64 alone, because `setup` refuses any other architecture; Remove > Security > Secure Boot, by the lifecycle below. The Windows row shows on x86_64 alone as well. |
| Update check | A step in `omarchy-update` right after `omarchy-update-status`, inside the phase the update's one authorisation covers, that runs `sudo omasecboot status --quiet` whenever the package is installed and, on a non-zero exit, tells the user to run `sudo omasecboot status`, whose last lines say what to do and whether a restart is at risk. A machine that is not set up passes unless `status` names a problem there, such as a setup or removal stopped half way, an ESP incident, or firmware variables it cannot read. The reboot phase after it does no privileged work, and AUR builds run after the authorisation ends (C6), so the hook's red line alone covers what they change. Until the step exists, that red line is the only signal. |
| Manual page | One page: what it does, the firmware steps, the recovery guide, within the claim limits of [spec.md](spec.md) section 3. |

### The lifecycle the wrappers judge

Package presence is not a state of Secure Boot. The wrappers tell these states apart; they combine, and a standing incident adds its restrictions to whichever state the machine is in. `sudo omasecboot status` judges them all; the files `enabled`, `settings-originals` and `needs-attention` under `/var/lib/omasecboot` are readable without root.

| State | Shows as | What the wrappers keep reachable |
| --- | --- | --- |
| Not set up, never or after `remove` | None of the three files, or `needs-attention` alone | Setup |
| Set up | `enabled` | Setup, Remove, Reset Computer's safeguard |
| Setup or removal stopped half way | `settings-originals` without `enabled`, which `status` names; `remove` deletes `enabled` first, so that flag alone would hide the way to finish | Setup, Remove |
| ESP incident standing | `status` exits 1 on it, set up or not; in `needs-attention`, a line that begins "the ESP reported a write error", or a record `status` cannot tell | The package, `status` and `acknowledge`; no removal of the package and no restart until the recovery guide's procedure has ended |
| Firmware still trusts this machine's key | sbctl's keys stay under `/var/lib/sbctl` after `remove`, and the firmware's db holds their certificate until the factory keys are restored; on a machine that is not set up, `remove`'s closing note says it once, and `status` only while the loader carries the local signature and no seal ([maintenance.md](maintenance.md#open-work)) | Reset Computer's safeguard |

## Requests about the installer

| Subject | Request |
| --- | --- |
| Installer hook | `99-omarchy-limine.hook` (C6 of [upstream-contracts.md](upstream-contracts.md)) undoes `ENABLE_ENROLL_LIMINE_CONFIG` for every user of that upstream feature. The request to the maintainers, also reported as omacom/omarchy#10945: drop the hook, or run `limine-install` in its place. The tool's watcher rebuilds the loader either way. Not the fix #10945 also offers, `sbctl sign` on the copied loader: a signed loader that is not sealed starts under Secure Boot without checking `limine.conf` ([spec.md](spec.md), D4). |
| Fallback on installs beside another system | The installer writes `ENABLE_LIMINE_FALLBACK=no` there (C6), so such a machine starts without a fallback loader. The request: deploy the fallback when the ESP is Omarchy's own and holds no `BOOTX64.EFI`. Until then `setup` offers the same step. |
| Reset Computer | `omarchy-system-factory-reset` does nothing about Secure Boot (C6): on a machine that is set up, the factory root it starts is unsigned, and the firmware keeps trusting this machine's certificate, also after `remove`. The request: while the machine is set up or partly so, or the firmware still trusts this machine's key, say first to turn Secure Boot off, run `omarchy-remove-security-secure-boot` and restore the factory keys, or refuse; while an ESP incident stands, the recovery guide's procedure and `acknowledge` come first. Package presence alone is none of these. |

## Beside the maintainers' own plan

OmaSecBoot is a route for installed systems that needs nothing from Microsoft: the user's own keys in the firmware, with Limine and the snapshot entries kept. The maintainers' plan (C6) aims at the same machines by another route, a Microsoft-signed shim and a Machine Owner Key, and covers the installer ISO, which this tool does not. Both need a signing key that lives on the machine. What C1 and C10 record about Limine, the sealed `limine.conf`, the signed UKIs and the snapshot entries bears on two of that plan's open questions, on the one machine recorded, and the spec's D1 names the condition under which the certificate would move from the firmware to a shim.
