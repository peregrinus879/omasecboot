#!/bin/bash
# shellcheck disable=SC2154 # Assertions read globals set by lifecycle functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-guards.XXXXXX")

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
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/lifecycle.sh"

state_dir_path() {
  printf '%s/state\n' "$TEST_DIR"
}

limine_lock_path() {
  printf '%s/boot-partition.lock\n' "$TEST_DIR"
}

snapshot_restore_lock_path() {
  printf '%s/limine-snapper-restore.lock\n' "$TEST_DIR"
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

capture_service_state() {
  printf '%s\n' '{"limine-snapper-sync.service":{"load_state":"loaded","active_state":"inactive","unit_file_state":"disabled"}}'
}

REPAIR_AVAILABLE=false

lifecycle_repair_is_available() {
  [[ "$REPAIR_AVAILABLE" == true ]]
}

noop_transaction() {
  transaction_phase_start "noop"
  transaction_phase_complete "noop"
}

guard_boot_transaction || fail_test "unmanaged lifecycle blocked a package transaction"

adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "active fixture adoption failed"
if guard_boot_transaction >/dev/null 2>&1; then
  fail_test "active package mutation entered without complete repair"
fi
REPAIR_AVAILABLE=true
guard_boot_transaction || fail_test "repair-capable active lifecycle blocked a package transaction"
: > "$(snapshot_restore_lock_path)"
if guard_boot_transaction >/dev/null 2>&1; then
  fail_test "package transaction entered during full snapshot restore"
fi
rm -f "$(snapshot_restore_lock_path)"
REPAIR_AVAILABLE=false

with_boot_repair_lock
begin_lifecycle_transaction "repair" "active" || fail_test "transition fixture did not start"
if guard_boot_transaction > "${TEST_DIR}/transition.out" 2>&1; then
  fail_test "package transaction entered during lifecycle transition"
fi
grep -Fq "$_transaction_id" "${TEST_DIR}/transition.out" \
  || fail_test "transition guard omitted the transaction identifier"
mark_lifecycle_recovery 17 "injected guard failure" \
  || fail_test "recovery fixture could not be committed"
release_boot_repair_lock

if guard_boot_transaction > "${TEST_DIR}/recovery.out" 2>&1; then
  fail_test "package transaction entered during recovery-required"
fi
grep -Fq 'recovery-required' "${TEST_DIR}/recovery.out" \
  || fail_test "recovery guard omitted the lifecycle state"

rm -rf "$(state_dir_path)"
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "disabled fixture adoption failed"
run_lifecycle_transaction "disable-test" "disabled" "active" noop_transaction \
  || fail_test "disabled fixture did not commit"
guard_boot_transaction || fail_test "disabled lifecycle blocked a package transaction"

guard_hook="${ROOT_DIR}/pacman-hooks/00-omasecboot-transition-guard.hook"
cleanup_hook="${ROOT_DIR}/pacman-hooks/zz-omasecboot-cleanup.hook"
repair_hook="${ROOT_DIR}/pacman-hooks/zzz-omasecboot.hook"
grep -Fxq 'When = PreTransaction' "$guard_hook" \
  || fail_test "package guard is not a pre-transaction hook"
grep -Fxq 'AbortOnFail' "$guard_hook" \
  || fail_test "package guard cannot abort a transaction"
grep -Fxq 'Exec = @BINDIR@/omasecboot --quiet guard transaction' "$guard_hook" \
  || fail_test "package guard does not call the canonical transition check"
grep -Fxq 'Target = boot/*' "$guard_hook" \
  || fail_test "package guard does not cover boot artifacts"
grep -Fxq 'Target = efi/*' "$guard_hook" \
  || fail_test "package guard does not cover ESP artifacts"
for hook in "$guard_hook" "$cleanup_hook" "$repair_hook"; do
  grep -Fxq 'Operation = Remove' "$hook" \
    || fail_test "hook does not cover removal: ${hook##*/}"
  grep -Fxq 'Target = boot/*' "$hook" \
    || fail_test "hook does not cover boot artifacts: ${hook##*/}"
  for producer in 'linux*' 'limine*' 'snapper*' 'mkinitcpio*'; do
    grep -Fxq "Target = ${producer}" "$hook" \
      || fail_test "hook does not cover producer ${producer}: ${hook##*/}"
  done
  if grep -Fq 'Depends =' "$hook"; then
    fail_test "hook can be skipped when a dependency is unavailable: ${hook##*/}"
  fi
done

printf 'guard tests passed\n'
