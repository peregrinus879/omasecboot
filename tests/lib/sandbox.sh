#!/bin/bash
# Shared by the real-tool contract suites: the bubblewrap sandbox they run in
# and their case runner. A suite sets ROOT_DIR and SUITE_NAME, sources this
# file and, unless in_sandbox says it is already there, names what it needs
# with require_command and require_file and calls enter_sandbox, which runs
# the suite again inside.
#
# The sandbox's root is an empty tmpfs that holds the machine's /usr, its
# package database and this repository, all read-only, and fixtures for
# everything the tools under test read or write: the firmware's variables,
# /var/lib/sbctl, /etc, /run, /tmp and an ESP at /boot. /usr/share is an
# overlay, so a settings layer can be laid beside the packages' files. The
# machine's own keys, firmware variables, settings and ESP are not there,
# wherever they are mounted, and nothing outside the scratch directory is
# written. The environment is cleared and every capability dropped, so a run
# as root, as in CI, is the same run as a user's.
#
# A missing requirement skips the suite with exit 0, because a contributor's
# machine need not carry Omarchy's boot stack. CONTRACT_REQUIRED=1 turns the
# skip into a failure, which is how CI runs the suites.

# The suites test the packaged tools, outside the sandbox and inside it.
export PATH=/usr/local/bin:/usr/bin
CASES_RUN=0

skip() {
  printf 'SKIP: %s: %s\n' "$SUITE_NAME" "$*"
  if [[ ${CONTRACT_REQUIRED:-0} == 1 ]]; then
    exit 1
  else
    exit 0
  fi
}

require_command() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || skip "${tool} is not installed"
  done
}

# require_file PATH PACKAGE
require_file() { [[ -f $1 ]] || skip "the ${2} package is not installed"; }

sandbox_token_file() { printf '/tmp/sandbox\n'; }
filesystem_type() { stat -f -c %T "$1" 2>/dev/null; }

# The cases delete and write firmware variables, keys, settings and boot
# files, so they run only where those are fixtures: enter_sandbox leaves a
# token in the sandbox's /tmp and names it in the environment, and inside the
# sandbox the variables' directory is a plain one, never efivarfs.
in_sandbox() {
  local token
  token=$(sandbox_token_file)
  [[ -n ${OMASECBOOT_SANDBOX:-} && $(cat -- "$token" 2>/dev/null) == "$OMASECBOOT_SANDBOX" &&
    $(filesystem_type /sys/firmware/efi/efivars) != efivarfs ]]
}

# enter_sandbox SUITE-SCRIPT: runs the suite again inside; does not return.
enter_sandbox() {
  local scratch link reason
  local -a sandbox
  [[ -z ${OMASECBOOT_SANDBOX:-} ]] || {
    printf 'FAIL: %s: the sandbox did not take effect\n' "$SUITE_NAME" >&2
    exit 1
  }
  require_command bwrap
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-${SUITE_NAME}.XXXXXX") || {
    printf 'FAIL: %s: no scratch directory\n' "$SUITE_NAME" >&2
    exit 1
  }
  # shellcheck disable=SC2064 # The path is fixed now; the variable is local.
  trap "rm -rf '$scratch'" EXIT
  mkdir -p "$scratch"/{efivars,sbctl,esp,tmp}
  printf '%s\n' "${scratch##*.}" >"$scratch/tmp/sandbox"
  sandbox=(bwrap --unshare-all --die-with-parent --cap-drop ALL --clearenv
    --setenv PATH "$PATH" --setenv LANG C.UTF-8 --setenv OMASECBOOT_SANDBOX "${scratch##*.}"
    --tmpfs / --ro-bind /usr /usr --overlay-src /usr/share --tmp-overlay /usr/share
    --dev /dev --proc /proc --dir /etc --dir /run
    --ro-bind /var/lib/pacman /var/lib/pacman
    --bind "$scratch/efivars" /sys/firmware/efi/efivars
    --bind "$scratch/sbctl" /var/lib/sbctl --bind "$scratch/esp" /boot --bind "$scratch/tmp" /tmp
    --ro-bind "$ROOT_DIR" "$ROOT_DIR")
  # /bin, /lib and their kind are links into /usr on a merged-usr system.
  for link in /bin /sbin /lib /lib64; do
    [[ ! -L $link ]] || sandbox+=(--symlink "$(readlink "$link")" "$link")
  done
  # Root needs no user namespace to be root inside, and may not get one.
  (( EUID == 0 )) || sandbox+=(--uid 0 --gid 0)
  reason=$("${sandbox[@]}" true 2>&1) || skip "bubblewrap cannot create the sandbox here: ${reason}"
  "${sandbox[@]}" bash "$1"
  exit
}

# The settings every case starts from: the ESP is found the way the tool finds
# it on a machine. sandbox_settings [MORE-LINES]
sandbox_settings() {
  mkdir -p /etc/default
  printf 'ESP_PATH=/boot\n%s' "${1:-}" >/etc/default/limine
}

fail_test() {
  printf 'FAIL: %s/%s: %s\n' "$SUITE_NAME" "${CASE_NAME:-}" "$*" >&2
  exit 1
}

# Each case runs in a subshell, so overrides and shell state never leak
# between cases. The sandbox's files do, so a case sets up what it reads.
run_case() {
  local errors
  CASE_NAME=$1
  in_sandbox || fail_test "refusing to run a case outside the sandbox"
  # A helper the suite never sourced would turn an assertion into one that
  # matches anything, so the case's stderr is kept and read for bash's word
  # on it before the case can pass.
  errors=$(mktemp) || fail_test "scratch"
  ("$2") 2>"$errors" || { cat "$errors" >&2; fail_test "case failed"; }
  cat "$errors" >&2
  ! grep -q 'command not found' "$errors" || fail_test "the case calls a command that is not defined here"
  rm -f "$errors"
  printf 'PASS: %s/%s\n' "$SUITE_NAME" "$1"
  CASES_RUN=$((CASES_RUN + 1))
}

# finish_suite VERSIONS: the versions that were checked belong in the record.
finish_suite() {
  (( CASES_RUN > 0 )) || fail_test "no case ran"
  printf '%s tests passed (%s cases, %s)\n' "$SUITE_NAME" "$CASES_RUN" "$1"
}
