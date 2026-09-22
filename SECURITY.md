# Security

OmaSecBoot signs and seals the files a machine boots from, so a defect here can weaken a boot chain or stop a machine from starting. Reports are welcome and are handled in private first.

## What counts

- The tool signs, seals or registers something it says it never touches, or reports a boot chain as proved that is not.
- An unprivileged user can make the tool, its hook or its watchers change a boot file, a setting or the firmware's variables.
- Key material, or the private details of a machine, leaves it through the tool, the recorder or the share step.
- A refusal can be bypassed: the guards around the Platform Key, the fallback loader, Microsoft's files and a loader at the fallback path that is not Limine's.

Defects in sbctl, Limine, the Limine tools, Omarchy or a firmware belong to those projects; a report here is still useful when the tool should detect or survive them.

## Supported versions

`main` and the latest release.

## Reporting

Use GitHub's private reporting: the repository's **Security and quality** tab, then **Report a vulnerability**. Do not open a public issue for something that could be abused before it is fixed.

Say what you ran, on which commit or version, what happened and what you expected. Records made with `tests/acceptance-record.sh` help; attach only the copies `tests/acceptance-share.sh` makes. Never send signing keys, recovery keys or anything from `/var/lib/sbctl` or `/var/lib/omasecboot/firmware-backup`.

One maintainer reads these reports. Expect an answer within a week, and a fix or a stated plan before anything is published.
