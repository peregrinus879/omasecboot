# Contributing to OmaSecBoot

OmaSecBoot is opt-in Secure Boot for installed Omarchy systems with the user's own keys. `OmaSecBoot` is the product name; `omasecboot` is the command, the package and every machine-facing name.

## Read first

- [docs/spec.md](docs/spec.md) owns the design: decisions, non-goals, commands, integration points, the failure table, tests and acceptance.
- [docs/upstream-contracts.md](docs/upstream-contracts.md) owns the upstream and hardware facts the design relies on (sections C1 to C8), each with its source.
- [README.md](README.md) is the operator page and states only what exists. [docs/maintenance.md](docs/maintenance.md) owns open work, evidence still owed and recheck triggers; [docs/release-checklist.md](docs/release-checklist.md) owns what a release needs and [docs/field-testing.md](docs/field-testing.md) how anyone adds to that evidence; [docs/omarchy-integration.md](docs/omarchy-integration.md) owns what lives on Omarchy's side.

## Principles

- Delegate to sbctl and the Limine tools, then verify independently: they hide their own failures.
- Converge and verify instead of transactions. Every command is idempotent, and an interrupted step is finished by running it again. State is derived from observation; the files under `/var/lib/omasecboot` are the only memory.
- Every behaviour cites a row of the spec's failure table or an upstream contract. A change that can cite neither does not belong in the tool. That is what keeps it small; the spec's non-goals name what stays out.
- Never modify limine-snapper-sync's history files or the fallback loader's raw copy, never add rows to sbctl's file list, never fail a Limine tool from the hook, never block pacman.
- `limine.conf` changes only together with the loader's seal over it, under the boot lock, or while the loader carries no seal at all.

## Layout

- `bin/omasecboot`: the dispatcher and the commands (`setup` with its one firmware step per run, `sign`, `status`, `remove`, `windows`, `version`).
- `lib/common.sh`: output, file safety, the settings lookup as upstream parses it, the boot lock. `lib/checks.sh`: preconditions and prompts. `lib/files.sh`: the EFI files on the ESP, history and fallback classification, signature state, sbctl's file list. `lib/firmware.sh`: the firmware's mode variables, the signature-list reader, the backup, the enrollment plan with its proofs and the per-variable enrollment. `lib/windows.sh`: the Windows target read from the firmware's boot entries, the managed entry in `limine.conf`, the BootNext request, the encryption acknowledgment. `lib/limine.sh`: managed settings and originals, `limine.conf` facts, the loader proof and staged rebuild, the fallback, the watchers, the way back to stock. `lib/sign.sh`: the converge-and-verify pass. `lib/status.sh`: the report.
- `limine/90-omasecboot-sign`: the only hook, which the Limine tools run; the tool ships no Limine configuration. `systemd/omasecboot-watch@.path` and `.service`: the watcher templates; `setup` enables one instance for `limine.conf` and one for the primary loader. `omarchy/omarchy-menu.jsonc`: the reference menu row for "Reboot to Windows". `PKGBUILD`, `Makefile`.
- `tests/lib/harness.sh`: the fixture machine and the stub tools; `tests/lib/esl.sh`: signature-list builders shared with the sbctl stub; `tests/lib/transcript.sh`: what the recorder keeps out of a record. `tests/*.sh`: the hermetic suites `common`, `limine`, `sign`, `status`, `firmware`, `windows`, `commands`, `records`, `install` and `package`; `tests/contract-sbctl.sh` and `tests/contract-limine.sh` run the installed tools in the sandbox of `tests/lib/sandbox.sh`; `tests/container.sh` runs as root in a disposable container only; `tests/acceptance-record.sh` records hardware acceptance rows, and `tests/acceptance-share.sh` makes the copies of them that are fit for a public issue.
- `.github/workflows/ci.yml`: lint, the hermetic suites, the package build and `tests/container.sh`; `contracts.yml`: the scheduled contract run, daily, which does its work only when a package under test or the contract code has changed. `.github/ISSUE_TEMPLATE/field-report.yml`: the report form of `docs/field-testing.md`; the two change together. `bug-report.yml`: the form for everything else.
- `CHANGELOG.md`: what changed for someone who runs the tool, one section per release. `SECURITY.md`: what to report in private, and how.

## Conventions

- Bash, `#!/bin/bash`, two-space indentation, `[[ ]]` and `(( ))`, a full `if`/`else` for two-path flow, ShellCheck clean. One coherent style, no dead or speculative code, comments that say why, documents as lean and as explanatory as they can be.
- Locations are functions, so the suites can point them at a fixture. Libraries return a status; the commands decide to exit.
- Output goes through `header`, `pass`, `note`, `act`, `warn`, `fail` and `die`; the `q`-prefixed forms drop in quiet mode. Progress goes to stdout, warnings and failures to stderr. The spec's Commands section owns the exit codes and the command grammar.
- Prompts need a terminal and say what was cancelled.
- Commands in the documents are pasted into Omarchy's interactive shell, which aliases `ls` to `eza` and `cd` to a function of its own. Where an option means something else there, as `ls -t` does, write `command ls`; try a documented command in that shell, not in a script.
- Stubs in the harness cite the contract section they model, or are marked as an assumption. Results are asserted independently of the function under test. A safety predicate has a case that fails when the predicate is disabled.

## Verification

Run `make lint` and `make test` after every change; together they take about a minute and need `base-devel`, `git`, `shellcheck` and `jq`. `make test` builds the package from the files on disk that git does not ignore, and CI also runs `tests/container.sh` in a container.

`make test-contract` checks the upstream contracts against the sbctl and Limine packages installed on your machine, inside a bubblewrap sandbox (package `bubblewrap`) that hides the machine's own keys, firmware, settings and ESP; a suite whose tools are missing says so and is skipped. Run it after changing anything that calls sbctl or the Limine tools, or a stub that models them. A scheduled CI job runs it when one of those packages has a new version, and at least once a week, and opens an issue when it fails.

Hermetic tests share assumptions with the code, so anything that touches boot behaviour or firmware is only proven by the staged hardware rows in [docs/release-checklist.md](docs/release-checklist.md). Never run the tool against the real ESP, firmware or package state of a machine you cannot afford to recover, and never claim more than the machines recorded.
