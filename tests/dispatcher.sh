#!/bin/bash
# shellcheck disable=SC2154,SC2329 # Tests read globals and override sourced functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-dispatcher.XXXXXX")

cleanup() {
  release_boot_repair_lock 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"

state_dir_path() {
  printf '%s/state\n' "$TEST_DIR"
}

limine_lock_path() {
  printf '%s/boot-partition.lock\n' "$TEST_DIR"
}

snapshot_restore_lock_path() {
  printf '%s/limine-snapper-restore.lock\n' "$TEST_DIR"
}

pacman_database_lock_path() {
  printf '%s/pacman-db.lck\n' "$TEST_DIR"
}

control_owner_uid() {
  id -u
}

require_control_root() {
  :
}

durable_sync() {
  :
}

PREFLIGHT_ROOT_CHECKED=false
PREFLIGHT_CALLED=false
check_root() {
  [[ "$1" == "windows preflight" ]] || return 1
  PREFLIGHT_ROOT_CHECKED=true
}

windows_encryption_gate() {
  PREFLIGHT_CALLED=true
  _windows_preflight_result=prepared
}

capture_service_state() {
  printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"inactive","unit_file_state":"disabled"}}'
}

systemctl() {
  [[ "$*" == "show --property=ActiveState --value ${TRANSACTION_SERVICE_UNIT}" ]] \
    || return 1
  printf 'inactive\n'
}

noop_transaction() {
  transaction_phase_start "noop"
  transaction_phase_complete "noop"
}

settings_fixture="${TEST_DIR}/limine-defaults"
cat > "$settings_fixture" <<'EOF'
  ENABLE_VERIFICATION = no
ENABLE_VERIFICATION=yes
 COMMANDS_BEFORE_SAVE = "other limine-reset-enroll"
UNRELATED=value
EOF
mapfile -t verification_entries \
  < <(list_limine_default_entries "$settings_fixture" "ENABLE_VERIFICATION")
[[ ${verification_entries[*]} == 'ENABLE_VERIFICATION=no ENABLE_VERIFICATION=yes' ]] \
  || fail_test "Limine setting parser rejected whitespace around equals"
replace_limine_default_entry_in_file "$settings_fixture" \
  "ENABLE_VERIFICATION" "ENABLE_VERIFICATION=no" \
  || fail_test "Limine setting replacement failed"
[[ $(grep -Fc 'ENABLE_VERIFICATION=' "$settings_fixture") -eq 1 ]] \
  || fail_test "Limine setting replacement retained duplicates"
grep -Fxq 'UNRELATED=value' "$settings_fixture" \
  || fail_test "Limine setting replacement changed an unrelated entry"

for command in setup adopt enroll sign cleanup; do
  if "cmd_${command}" > "${TEST_DIR}/${command}.out" 2>&1; then
    fail_test "blocked ${command} command succeeded"
  fi
done
main windows preflight > "${TEST_DIR}/windows-preflight.out" \
  || fail_test "public Windows preflight route failed"
[[ "$PREFLIGHT_ROOT_CHECKED" == true && "$PREFLIGHT_CALLED" == true \
  && "$_windows_preflight_result" == prepared ]] \
  || fail_test "public Windows preflight route was not a thin caller-visible gate"
grep -Fq 'Windows Encryption Preflight' "${TEST_DIR}/windows-preflight.out" \
  || fail_test "public Windows preflight route omitted its heading"
if cmd_windows preflight unexpected >/dev/null 2>&1; then
  fail_test "Windows preflight accepted an extra argument"
fi
for command in setup bootnext reboot; do
  if cmd_windows "$command" > "${TEST_DIR}/windows-${command}.out" 2>&1; then
    fail_test "blocked Windows ${command} command succeeded"
  fi
done
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "blocked public mutation created lifecycle state"

cmd_help > "${TEST_DIR}/help.out"
if grep -Eq 'Setup Mode|clear keys|enable Secure Boot' "${TEST_DIR}/help.out"; then
  fail_test "help exposed firmware mutation instructions"
fi
grep -Fq 'Do not change firmware keys' "${TEST_DIR}/help.out" \
  || fail_test "help omitted the firmware safety boundary"
if grep -Eq 'sudo omasecboot (sign|cleanup)' "${ROOT_DIR}/lib/status.sh"; then
  fail_test "status recommends a blocked repair command"
fi
[[ $(cmd_version) == 'omasecboot 1.0.0' ]] || fail_test "version contract changed"

cmd_hook package-cleanup || fail_test "unmanaged package automation did not no-op"
cmd_guard removal || fail_test "pristine lifecycle blocked dependency removal"
REAL_REQUIRE_CONTROL_ROOT=$(declare -f require_control_root)
require_control_root() { return 1; }
if cmd_guard removal >/dev/null 2>&1; then
  fail_test "dependency removal guard did not require root"
fi
eval "$REAL_REQUIRE_CONTROL_ROOT"
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "unmanaged automation created lifecycle state"

adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "active fixture adoption failed"
if cmd_sign >/dev/null 2>&1; then
  fail_test "public sign succeeded in active state"
fi
read_lifecycle || fail_test "active state became unreadable after blocked sign"
[[ $_lifecycle_state == active ]] || fail_test "blocked sign changed active state"
if cmd_guard removal > "${TEST_DIR}/removal-active.out" 2>&1; then
  fail_test "active lifecycle permitted dependency removal"
fi
grep -Fq 'requires verified disabled or pristine lifecycle state' \
  "${TEST_DIR}/removal-active.out" \
  || fail_test "dependency removal guard omitted its lifecycle reason"

active_generation=$_lifecycle_generation
active_lifecycle_hash=$(sha256_file "$(lifecycle_file_path)")
if cmd_hook package-cleanup > "${TEST_DIR}/external.out" 2>&1; then
  fail_test "unrepaired external package mutation reported success"
else
  external_rc=$?
fi
[[ $external_rc -eq 1 ]] || fail_test "external package mutation lost its failure status"
if cmd_hook package-sign >/dev/null 2>&1; then
  fail_test "closed production gate admitted package signing"
fi
if printf 'usr/lib/modules/6.18.0/modules.builtin\n' \
  | cmd_guard transaction >/dev/null 2>&1; then
  fail_test "closed production gate admitted the package guard"
fi
read_lifecycle || fail_test "blocked producer state became unreadable"
[[ $_lifecycle_state == active && $_lifecycle_generation -eq active_generation \
  && $(sha256_file "$(lifecycle_file_path)") == "$active_lifecycle_hash" ]] \
  || fail_test "blocked producer automation changed lifecycle state"

release_boot_repair_lock
rm -rf "$(state_dir_path)"
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "disabled fixture adoption failed"
run_lifecycle_transaction "disable-test" "disabled" "active" noop_transaction \
  || fail_test "disabled fixture did not commit"
cmd_hook package-cleanup || fail_test "disabled package automation did not no-op"
cmd_guard removal || fail_test "disabled lifecycle blocked dependency removal"
read_lifecycle || fail_test "disabled state became unreadable"
[[ $_lifecycle_state == disabled ]] || fail_test "disabled automation changed lifecycle state"

route_log="${TEST_DIR}/routes"
producer_limine_hook_pre() { printf 'limine-pre\n' >> "$route_log"; }
producer_limine_hook_post() { printf 'limine-post\n' >> "$route_log"; }
producer_package_checkpoint() { printf 'package-checkpoint\n' >> "$route_log"; }
producer_package_post() { printf 'package-post\n' >> "$route_log"; }
producer_package_pre() { printf 'package-pre\n' >> "$route_log"; }
lifecycle_removal_is_allowed() {
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  printf 'removal\n' >> "$route_log"
}
cmd_hook pre || fail_test "Limine pre-hook route failed"
cmd_hook post || fail_test "Limine post-hook route failed"
cmd_hook package-cleanup || fail_test "package checkpoint route failed"
cmd_hook package-sign || fail_test "package post route failed"
cmd_guard transaction || fail_test "package pre-guard route failed"
cmd_guard removal || fail_test "package removal guard route failed"
[[ $(<"$route_log") == $'limine-pre\nlimine-post\npackage-checkpoint\npackage-post\npackage-pre\nremoval' ]] \
  || fail_test "internal producer routes selected the wrong handlers"
if cmd_hook unknown >/dev/null 2>&1 || cmd_guard unknown >/dev/null 2>&1 \
  || cmd_guard removal extra >/dev/null 2>&1; then
  fail_test "internal dispatcher accepted an unknown phase"
fi

printf 'dispatcher tests passed\n'
