#!/bin/bash
# shellcheck disable=SC2329 # Overrides are invoked indirectly by the code under test.
# Hermetic checks for lib/checks.sh: each environment check dies with its
# message when its precondition is missing and is silent otherwise. Every
# case runs in a subshell with only the shims on PATH.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init checks
BIN_DIR="${TEST_DIR}/bin"
mkdir -p "$BIN_DIR" "${TEST_DIR}/esp/EFI" "${TEST_DIR}/firmware/efi/efivars"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/checks.sh"

esp_path() { printf '%s/esp\n' "$TEST_DIR"; }
efivars_path() { printf '%s/firmware/efi/efivars\n' "$TEST_DIR"; }

shim() {
  local name="$1" body="${2:-exit 0}"
  printf '#!/bin/bash\n%s\n' "$body" > "${BIN_DIR}/${name}"
  chmod 755 "${BIN_DIR}/${name}"
}

# Runs one check with only the shims on PATH; prints its status then its output.
run_check() {
  local rc=0 output
  output=$(PATH="$BIN_DIR" "$@" 2>&1) || rc=$?
  printf '%s\n%s\n' "$rc" "$output"
}

expect_pass() {
  local description="$1" result
  shift
  result=$(run_check "$@")
  [[ "${result%%$'\n'*}" == 0 ]] || fail_test "${description}: ${result#*$'\n'}"
}

expect_die() {
  local description="$1" message="$2" result
  shift 2
  result=$(run_check "$@")
  [[ "${result%%$'\n'*}" == 1 ]] || fail_test "${description} did not die"
  [[ "${result#*$'\n'}" == *"$message"* ]] \
    || fail_test "${description} died without its message: ${result#*$'\n'}"
}

for tool in sbctl jq limine b2sum openssl gum flock sha256sum stat mountpoint; do
  shim "$tool"
done
shim findmnt 'printf "vfat\n"'

[[ $EUID -ne 0 ]] || fail_test "run the checks suite as an unprivileged user"
expect_die "check_root as an unprivileged user" "Root required" check_root setup

expect_pass "core dependencies present" check_core_deps
rm -f "${BIN_DIR}/sbctl"
expect_die "check_core_deps without sbctl" "sbctl not installed" check_core_deps
shim sbctl
rm -f "${BIN_DIR}/jq"
expect_die "check_core_deps without jq" "jq not installed" check_core_deps
shim jq

expect_pass "recovery dependencies present" check_recovery_deps
rm -f "${BIN_DIR}/flock"
expect_die "check_recovery_deps without flock" "Recovery dependency not installed: flock" \
  check_recovery_deps
shim flock

expect_pass "mutation dependencies and ESP present" check_deps
for tool in limine b2sum openssl; do
  rm -f "${BIN_DIR}/${tool}"
  expect_die "check_deps without ${tool}" "${tool} not installed" check_deps
  shim "$tool"
done

expect_pass "ESP mounted as vfat" check_esp_mount
shim findmnt 'printf "ext4\n"'
expect_die "check_esp_mount on a non-FAT mount" "is not mounted as the FAT32 ESP" check_esp_mount
shim findmnt 'printf "vfat\n"'
shim mountpoint 'exit 1'
expect_die "check_esp_mount on a plain directory" "is not mounted as the FAT32 ESP" check_esp_mount
shim mountpoint
rmdir "${TEST_DIR}/esp/EFI"
expect_die "check_esp_mount without an EFI directory" "EFI not found" check_esp_mount
mkdir "${TEST_DIR}/esp/EFI"
rm -f "${BIN_DIR}/findmnt"
expect_die "check_esp_mount without findmnt" "util-linux" check_esp_mount
shim findmnt 'printf "vfat\n"'

expect_pass "UEFI firmware directory present" check_efi_mode
rm -rf "${TEST_DIR}/firmware"
expect_die "check_efi_mode without firmware" "did not boot in UEFI mode" check_efi_mode
mkdir -p "${TEST_DIR}/firmware/efi/efivars"

expect_die "gum present without a terminal" "interactive terminal is required" require_gum
rm -f "${BIN_DIR}/gum"
expect_die "require_gum without gum" "gum not installed" require_gum
shim gum

# Helpers own their output stream and print backslashes literally. Optional
# quiet output may disappear, but diagnostics and required guidance remain.
literal='EFI/Windows\new\test\x1b[31m%name.efi'
{
  pass "$literal"
  act "$literal"
  fail "$literal"
  warn "$literal"
} > "${TEST_DIR}/messages.out" 2> "${TEST_DIR}/messages.err"
[[ $(<"${TEST_DIR}/messages.out") == "  ✓ ${literal}"$'\n'"  → ${literal}" ]] \
  || fail_test "routine helpers changed literal text or wrote diagnostics to stdout"
[[ $(<"${TEST_DIR}/messages.err") == "  ✗ ${literal}"$'\n'"  ! ${literal}" ]] \
  || fail_test "diagnostic helpers changed literal text or lost stderr ownership"
(
  # shellcheck disable=SC2034 # Read by the sourced optional-output helpers.
  QUIET=true
  qpass optional
  qact optional
  qheader optional
  warn 'Required next action'
) > "${TEST_DIR}/quiet.out" 2> "${TEST_DIR}/quiet.err"
[[ ! -s "${TEST_DIR}/quiet.out" \
  && $(<"${TEST_DIR}/quiet.err") == '  ! Required next action' ]] \
  || fail_test "quiet mode hid required guidance or emitted optional progress"
die_rc=0
(die "$literal") > "${TEST_DIR}/die.out" 2> "${TEST_DIR}/die.err" || die_rc=$?
[[ $die_rc -eq 1 && ! -s "${TEST_DIR}/die.out" \
  && $(<"${TEST_DIR}/die.err") == "  ✗ ${literal}" ]] \
  || fail_test "die lost its status, literal text, or stderr ownership"

# util-linux script supplies a real PTY without adding a test dependency.
# The child uses a disposable HOME/XDG tree and never invokes an actual prompt.
pty_probe="${TEST_DIR}/terminal-probe"
mkdir -p "${TEST_DIR}/home" "${TEST_DIR}/xdg-config" "${TEST_DIR}/xdg-cache" \
  "${TEST_DIR}/xdg-data"
cat > "$pty_probe" <<'EOF'
#!/bin/bash
set -euo pipefail
# shellcheck source=/dev/null
source "$1/lib/common.sh"
# shellcheck source=/dev/null
source "$1/lib/checks.sh"
case "$3" in
  gum) PATH="$2" require_gum ;;
  capture)
    selection=$(PATH="$2" require_gum; printf 'selected')
    [[ "$selection" == selected ]]
    ;;
  colors)
    pass "${BOLD}literal\\new${NC}"
    fail "${BOLD}literal\\new${NC}"
    pass "${BOLD}redirected\\new${NC}" > "$4/redirected.out"
    fail "${BOLD}redirected\\new${NC}" 2> "$4/redirected.err"
    ;;
  *) exit 2 ;;
esac
EOF
run_pty_probe() {
  local mode="$1" command
  printf -v command '%q ' /bin/bash --noprofile --norc \
    "$pty_probe" "$ROOT_DIR" "$BIN_DIR" "$mode" "$TEST_DIR"
  HOME="${TEST_DIR}/home" XDG_CONFIG_HOME="${TEST_DIR}/xdg-config" \
    XDG_CACHE_HOME="${TEST_DIR}/xdg-cache" XDG_DATA_HOME="${TEST_DIR}/xdg-data" \
    HISTFILE=/dev/null SHELL=/bin/bash \
    timeout 10 script -q -e -c "$command" /dev/null </dev/null \
    > "${TEST_DIR}/pty.out" 2>&1
}
run_pty_probe gum || fail_test "gum with terminal input and stderr was rejected"
run_pty_probe capture || fail_test "capturing gum's result hid its terminal"
TERM=xterm NO_COLOR='' run_pty_probe colors || fail_test "TTY output probe failed"
grep -Fq $'\033[' "${TEST_DIR}/pty.out" \
  || fail_test "TTY output omitted real color escapes"
if grep -Fq $'\033' "${TEST_DIR}/redirected.out" "${TEST_DIR}/redirected.err"; then
  fail_test "helpers redirected after initialization leaked color escapes"
fi
[[ $(<"${TEST_DIR}/redirected.out") == '  ✓ redirected\new' \
  && $(<"${TEST_DIR}/redirected.err") == '  ✗ redirected\new' ]] \
  || fail_test "redirected decorated arguments were not printed literally"
TERM=xterm NO_COLOR=1 run_pty_probe colors || fail_test "NO_COLOR probe failed"
if grep -Fq $'\033' "${TEST_DIR}/pty.out"; then
  fail_test "NO_COLOR output contained escapes"
fi
TERM=dumb NO_COLOR='' run_pty_probe colors || fail_test "dumb-terminal probe failed"
if grep -Fq $'\033' "${TEST_DIR}/pty.out"; then
  fail_test "dumb-terminal output contained escapes"
fi
TERM='' NO_COLOR='' run_pty_probe colors || fail_test "empty-TERM probe failed"
if grep -Fq $'\033' "${TEST_DIR}/pty.out"; then
  fail_test "empty-TERM output contained escapes"
fi

# Real flock contention through separate open file descriptions, with only
# the wait shortened by the test adapter. Production must still ask for 30s
# and conflict status 75, and inherited contention must make one attempt.
lock_dir="${TEST_DIR}/locks"
mkdir -p "${lock_dir}/state"
check_lock_result() (
  local kind="$1" mode="$2" rc=0 lock_file expected
  control_owner_uid() { id -u; }
  limine_lock_path() { printf '%s/boot-partition.lock\n' "$lock_dir"; }
  state_dir_path() { printf '%s/state\n' "$lock_dir"; }
  ensure_state_layout() { validate_control_directory "$(state_dir_path)"; }
  inherited_limine_fd_is_valid() { [[ "$kind:$mode" == limine:inherited ]]; }
  inherited_repair_fd_is_valid() { [[ "$kind:$mode" == repair:inherited ]]; }
  if [[ "$kind" == limine ]]; then
    lock_file=$(limine_lock_path)
    expected='-E 75 -w 30 200'
  else
    lock_file="$(state_dir_path)/repair.lock"
    if [[ "$mode" == inherited ]]; then
      expected='-E 75 -n 201'
    else
      expected='-E 75 -w 30 201'
    fi
  fi
  : > "$lock_file"
  chmod 644 "$lock_file"
  exec 9>> "$lock_file"
  command flock -n 9 || fail_test "could not hold the contention fixture lock"
  if [[ "$mode" == inherited ]]; then
    if [[ "$kind" == limine ]]; then
      exec 200>> "$lock_file"
    else
      exec 201>> "$lock_file"
    fi
  elif [[ "$mode" == unsafe ]]; then
    chmod 666 "$lock_file"
  fi
  : > "${lock_dir}/attempts"
  flock() {
    [[ "$1" != -u ]] || { command flock "$@"; return; }
    printf '%s\n' "$*" >> "${lock_dir}/attempts"
    [[ "$1 $2" == '-E 75' ]] || fail_test "lock omitted conflict status 75"
    if [[ "$mode" == error && "$*" == "$expected" ]]; then
      return 74
    elif [[ "$3" == -w ]]; then
      [[ "$4" == 30 ]] || fail_test "production lock timeout changed"
      command flock -E 75 -w 0.05 "$5"
    else
      [[ "$3" == -n ]] || fail_test "unexpected locking options: $*"
      command flock "$@"
    fi
  }
  if [[ "$kind" == repair ]]; then
    # Pre-acquire the shared lock so the log isolates the repair attempt;
    # with_boot_repair_lock must release it after the failed second lock.
    with_limine_lock || fail_test "shared fixture lock could not be acquired"
    : > "${lock_dir}/attempts"
  fi
  with_boot_repair_lock > "${lock_dir}/out" 2> "${lock_dir}/err" || rc=$?
  if [[ "$mode" == unsafe ]]; then
    [[ $rc -eq 1 && ! -s "${lock_dir}/attempts" ]] \
      || fail_test "unsafe ${kind} lock path was treated as contention"
    grep -Fq 'Unsafe' "${lock_dir}/err" || fail_test "unsafe lock omitted its reason"
  elif [[ "$mode" == error ]]; then
    [[ $rc -eq 74 ]] || fail_test "${kind} lock lost the flock error status"
    if grep -Fq busy "${lock_dir}/err"; then
      fail_test "${kind} lock misreported a flock error as busy"
    fi
  else
    [[ $rc -eq 75 ]] || fail_test "${mode} ${kind} contention lost status 75"
    [[ $(<"${lock_dir}/attempts") == "$expected" ]] \
      || fail_test "${mode} ${kind} contention retried or changed its timeout"
    grep -Fq 'Boot state is busy' "${lock_dir}/err" \
      || fail_test "${mode} ${kind} contention omitted its diagnostic"
  fi
  [[ ! -s "${lock_dir}/out" ]] || fail_test "lock diagnostic went to stdout"
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == false ]] \
    || fail_test "failed lock admission retained ownership"
  chmod 644 "$lock_file"
)
for kind in limine repair; do
  for mode in local inherited unsafe error; do
    check_lock_result "$kind" "$mode"
  done
done

# A producer handoff relinquishes FD 200 before its child runs. If another
# open description takes the lock then, reacquisition gets one wait only.
(
  handoff_lock="${lock_dir}/handoff.lock"
  : > "$handoff_lock"
  exec 200>> "$handoff_lock"
  command flock -n 200 || fail_test "could not acquire the handoff fixture lock"
  limine_lock_path() { printf '%s\n' "$handoff_lock"; }
  inherited_limine_fd_is_valid() { fd_matches_path 200 "$handoff_lock"; }
  # shellcheck disable=SC2034 # Ownership is consumed by the sourced handoff.
  _OMASECBOOT_REPAIR_LOCK_OWNED=true
  _OMASECBOOT_LIMINE_LOCK_OWNED=inherited
  take_handoff_lock() {
    exec 9>> "$handoff_lock"
    command flock -n 9
  }
  flock() {
    [[ "$1" != -u ]] || { command flock "$@"; return; }
    printf '%s\n' "$*" >> "${lock_dir}/handoff-attempts"
    [[ "$*" == '-E 75 -w 30 200' ]] || fail_test "handoff changed its lock contract"
    command flock -E 75 -w 0.05 200
  }
  handoff_rc=0
  with_limine_lock_handoff take_handoff_lock \
    > "${lock_dir}/handoff.out" 2> "${lock_dir}/handoff.err" || handoff_rc=$?
  [[ $handoff_rc -eq 75 && "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
    && $(<"${lock_dir}/handoff-attempts") == '-E 75 -w 30 200' ]] \
    || fail_test "inherited handoff contention retried or lost its status"
)

printf 'checks tests passed\n'
