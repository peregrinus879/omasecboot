# Contributing to OmaSecBoot

OmaSecBoot is opt-in Secure Boot for installed Omarchy systems with the user's own keys. `OmaSecBoot` is the product name; `omasecboot` is the command, the package and every machine-facing name.

## Read first

- [docs/spec.md](docs/spec.md) owns the design: decisions, non-goals, commands, integration points, the failure table, tests and acceptance.
- [docs/upstream-contracts.md](docs/upstream-contracts.md) owns the upstream and hardware facts the design relies on (sections C1 to C8), each with its source.
- [README.md](README.md) is the operator page and states only what exists. [docs/maintenance.md](docs/maintenance.md) owns open work, evidence still owed and recheck triggers; [docs/release-checklist.md](docs/release-checklist.md) owns what a release needs; [docs/omarchy-integration.md](docs/omarchy-integration.md) owns what lives on Omarchy's side and the claims never made.

## Principles

- Delegate to sbctl and the Limine tools, then verify independently: they hide their own failures.
- Converge and verify instead of transactions. Every command is idempotent, and an interrupted step is finished by running it again. State is derived from observation; the files under `/var/lib/omasecboot` are the only memory.
- Every behaviour cites a row of the spec's failure table or an upstream contract. A change that can cite neither does not belong in the tool. That is what keeps it small: no state machine, journal, recovery chain, ownership proof, version pin, pacman hook or patched upstream package.
- Never modify limine-snapper-sync's history files or the fallback loader's raw copy, never add rows to sbctl's file list, never fail a Limine tool from the hook, never block pacman.

## Layout

- `bin/omasecboot`: the dispatcher and the commands (`setup` with its one firmware step per run, `sign`, `status`, `remove`).
- `lib/common.sh`: output, file safety, the settings lookup as upstream parses it, the boot lock. `lib/checks.sh`: preconditions and prompts. `lib/files.sh`: the EFI files on the ESP, history and fallback classification, signature state, sbctl's file list. `lib/firmware.sh`: the firmware's mode variables, the signature-list reader, the backup, the enrollment plan with its proofs and the per-variable enrollment. `lib/limine.sh`: managed settings and originals, `limine.conf` facts, the loader proof and staged rebuild, the fallback, the watcher, the way back to stock. `lib/sign.sh`: the converge-and-verify pass. `lib/status.sh`: the report.
- `limine-hooks/90-omasecboot-sign`: the only hook. `systemd/omasecboot-watch@.path` and `.service`: the `limine.conf` watcher templates. `PKGBUILD`, `Makefile`.
- `tests/lib/harness.sh`: the fixture machine and the stub tools; `tests/lib/esl.sh`: signature-list builders shared with the sbctl stub. `tests/*.sh`: the suites `common`, `limine`, `sign`, `status`, `firmware`, `commands`, `install` and `package`; `tests/container.sh` runs as root in a disposable container only; `tests/acceptance-record.sh` records hardware acceptance rows.

## Conventions

- Bash, `#!/bin/bash`, two-space indentation, `[[ ]]` and `(( ))`, a full `if`/`else` for two-path flow, ShellCheck clean. One coherent style, no dead or speculative code, comments that say why, documents as lean and as explanatory as they can be.
- Locations are functions, so the suites can point them at a fixture. Libraries return a status; the commands decide to exit.
- Output goes through `header`, `pass`, `note`, `act`, `warn`, `fail` and `die`; the `q`-prefixed forms drop in quiet mode. Progress goes to stdout, warnings and failures to stderr. Exit 0 success, 1 failure or attention needed, 2 usage, 75 boot files busy.
- Subcommands carry no `--` prefix. Prompts need a terminal and say what was cancelled.
- Stubs in the harness cite the contract section they model, or are marked as an assumption. Results are asserted independently of the function under test. A safety predicate has a case that fails when the predicate is disabled.

## Verification

Run `make lint` and `make test` after every change; together they take about a minute. `make test` builds the package from the files on disk that git does not ignore, and CI also runs `tests/container.sh` in a container.

Hermetic tests share assumptions with the code, so anything that touches boot behaviour or firmware is only proven by the staged hardware rows in [docs/release-checklist.md](docs/release-checklist.md). Never run the tool against the real ESP, firmware or package state of a machine you cannot afford to recover, and never claim more than the machines recorded.
