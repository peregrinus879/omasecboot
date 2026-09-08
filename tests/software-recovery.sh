#!/bin/bash
# shellcheck disable=SC1091,SC2154 # Tests source modules and read their globals.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init software-recovery

# shellcheck source=../lib/common.sh
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=../lib/lifecycle.sh
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=../lib/records.sh
source "${ROOT_DIR}/lib/records.sh"
# shellcheck source=../lib/software.sh
source "${ROOT_DIR}/lib/software.sh"

state_dir_path() { printf '%s/state\n' "$CASE_DIR"; }
limine_lock_path() { printf '%s/boot-partition.lock\n' "$CASE_DIR"; }
snapshot_restore_lock_path() { printf '%s/restore.lock\n' "$CASE_DIR"; }
pacman_database_lock_path() { printf '%s/pacman-db.lck\n' "$CASE_DIR"; }
esp_path() { printf '%s/boot\n' "$CASE_DIR"; }
control_owner_uid() { id -u; }
require_control_root() { :; }
durable_sync() { :; }
esp_is_mounted_vfat() { [[ "$ESP_MOUNTED" == true ]]; }
lifecycle_package_boundary_is_clear() { [[ "$PACKAGE_BOUNDARY_CLEAR" == true ]]; }

FAILPOINT=""
FAILPOINT_USED=false
lifecycle_failpoint() {
  if [[ -n "$FAILPOINT" && "$FAILPOINT" == "$1" && "$FAILPOINT_USED" == false ]]; then
    FAILPOINT_USED=true
    return 1
  fi
}

reset_case() {
  local name="$1"
  release_boot_repair_lock 2>/dev/null || true
  CASE_DIR="${TEST_DIR}/${name}"
  mkdir -p "$CASE_DIR"
  FAILPOINT=""
  FAILPOINT_USED=false
  ESP_MOUNTED=true
  PACKAGE_BOUNDARY_CLEAR=true
  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

seed_active() {
  adopt_lifecycle : no no yes yes absent absent absent absent \
    || fail_test "could not seed active lifecycle"
}

failed_cleanup() {
  transaction_phase_start clean-tracking || return 1
  transaction_backup_file "$MUTATED_FILE" || return 1
  printf 'changed\n' > "$MUTATED_FILE"
  return 23
}

completed_cleanup() {
  transaction_phase_start clean-tracking || return 1
  transaction_phase_complete clean-tracking
}

failed_adoption() {
  transaction_phase_start record-adoption || return 1
  transaction_backup_file "$MUTATED_FILE" true || return 1
  printf 'created\n' > "$MUTATED_FILE"
  return 24
}

run_software_recovery() {
  local rc=0
  with_boot_repair_lock || return 1
  run_software_recovery_locked || rc=$?
  release_boot_repair_lock
  return "$rc"
}

reset_case handled-rollback
MUTATED_FILE="${CASE_DIR}/managed-file"
printf 'original\n' > "$MUTATED_FILE"
seed_active
if run_lifecycle_transaction cleanup active active failed_cleanup; then
  fail_test "failed cleanup reported success"
fi
[[ "$(<"$MUTATED_FILE")" == original ]] \
  || fail_test "handled failure did not restore its file"
run_software_recovery || fail_test "handled cleanup recovery failed"
read_lifecycle || fail_test "handled cleanup recovery lifecycle is unreadable"
[[ "$_lifecycle_state" == active \
  && $(jq -r '.last_transaction.operation' <<< "$_lifecycle_json") == software-recovery ]] \
  || fail_test "handled cleanup recovery did not publish active"
jq -e '.resolution == "rolled-back" and .terminal_state == "active"' \
  "$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")" >/dev/null \
  || fail_test "handled cleanup recovery proof is incomplete"

reset_case stale-owner
MUTATED_FILE="${CASE_DIR}/managed-file"
printf 'original\n' > "$MUTATED_FILE"
seed_active
with_boot_repair_lock || fail_test "could not lock stale cleanup fixture"
begin_lifecycle_transaction cleanup active || fail_test "could not begin stale cleanup"
transaction_phase_start clean-tracking || fail_test "could not start stale cleanup"
transaction_backup_file "$MUTATED_FILE" || fail_test "could not back up stale cleanup file"
printf 'changed\n' > "$MUTATED_FILE"
stale_manifest=$(lifecycle_manifest_path "$_transaction_id")
stale_document=$(jq -c '.owner.start_time = "0"' "$stale_manifest")
printf '%s\n' "$stale_document" | atomic_write_control_file "$stale_manifest" 600
_transaction_active=false
unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
release_boot_repair_lock
with_boot_repair_lock || fail_test "could not relock stale cleanup fixture"
reconcile_stale_lifecycle || fail_test "could not seal stale cleanup"
release_boot_repair_lock
[[ "$(<"$MUTATED_FILE")" == changed ]] \
  || fail_test "stale reconciliation unexpectedly changed the file"
run_software_recovery || fail_test "stale cleanup recovery failed"
[[ "$(<"$MUTATED_FILE")" == original ]] \
  || fail_test "stale cleanup recovery did not restore the file"

reset_case completed-publication
MUTATED_FILE="${CASE_DIR}/unused"
seed_active
FAILPOINT=before-stable-state-write
if run_lifecycle_transaction cleanup active active completed_cleanup; then
  fail_test "uncertain cleanup publication reported success"
fi
read_lifecycle || fail_test "uncertain cleanup lifecycle is unreadable"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "uncertain cleanup did not require recovery"
FAILPOINT=""
run_software_recovery || fail_test "completed cleanup publication recovery failed"
read_lifecycle || fail_test "completed cleanup recovery lifecycle is unreadable"
jq -e '.state == "active"' <<< "$_lifecycle_json" >/dev/null \
  || fail_test "completed cleanup recovery did not publish active"
jq -e '.resolution == "completed" and .restored_backups == []' \
  "$(jq -r '.last_recovery.proof.path' <<< "$_lifecycle_json")" >/dev/null \
  || fail_test "completed cleanup recovery proof is incomplete"

reset_case unmanaged-rollback
MUTATED_FILE="${CASE_DIR}/created-file"
if run_lifecycle_transaction adopt active unmanaged failed_adoption; then
  fail_test "failed unmanaged adoption reported success"
fi
[[ ! -e "$MUTATED_FILE" ]] || fail_test "failed adoption retained a created file"
run_software_recovery || fail_test "unmanaged adoption recovery failed"
read_lifecycle || fail_test "unmanaged state could not be read"
[[ "$_lifecycle_state" == unmanaged && ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "software recovery did not restore true unmanaged state"

reset_case unregistered-operation
MUTATED_FILE="${CASE_DIR}/managed-file"
printf 'original\n' > "$MUTATED_FILE"
seed_active
if run_lifecycle_transaction arbitrary-repair active active failed_cleanup; then
  fail_test "unregistered operation failure reported success"
fi
with_boot_repair_lock || fail_test "could not lock unregistered operation fixture"
if load_software_recovery_context >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "unregistered root operation acquired software recovery authority"
fi
release_boot_repair_lock

reset_case esp-boundary
mkdir -p "$(esp_path)/EFI/Linux"
MUTATED_FILE="$(esp_path)/EFI/Linux/test.efi"
printf 'original\n' > "$MUTATED_FILE"
seed_active
if run_lifecycle_transaction cleanup active active failed_cleanup; then
  fail_test "ESP rollback fixture unexpectedly succeeded"
fi
ESP_MOUNTED=false
if run_software_recovery; then
  fail_test "software recovery accepted an unmounted ESP backup target"
fi
read_lifecycle || fail_test "unmounted-ESP rejection damaged lifecycle state"
[[ "$_lifecycle_state" == recovery-required \
  && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 0 ]] \
  || fail_test "unmounted-ESP rejection consumed a recovery attempt"
ESP_MOUNTED=true
PACKAGE_BOUNDARY_CLEAR=false
if run_software_recovery; then
  fail_test "software recovery crossed a newly active package boundary"
fi
read_lifecycle || fail_test "package-boundary rejection damaged lifecycle state"
[[ "$_lifecycle_state" == recovery-required \
  && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 0 ]] \
  || fail_test "package-boundary rejection published a recovery transition"
PACKAGE_BOUNDARY_CLEAR=true
run_software_recovery || fail_test "ESP software recovery did not resume safely"

# A failed preparation from disabled recovers back to disabled, and the
# lineage through that recovery keeps the package removable.
reset_case disabled-lineage
MUTATED_FILE="${CASE_DIR}/managed-file"
printf 'original\n' > "$MUTATED_FILE"
noop_preparation() { :; }
failed_preparation() {
  transaction_phase_start backup-firmware || return 1
  transaction_backup_file "$MUTATED_FILE" || return 1
  printf 'changed\n' > "$MUTATED_FILE"
  return 25
}
run_lifecycle_transaction prepare-secure-boot disabled unmanaged noop_preparation \
  || fail_test "preparation from pristine state failed"
lifecycle_removal_is_allowed || fail_test "prepared pristine state blocked removal"
if run_lifecycle_transaction prepare-secure-boot disabled disabled failed_preparation; then
  fail_test "failed preparation reported success"
fi
read_lifecycle || fail_test "failed preparation left the lifecycle unreadable"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "failed preparation did not require recovery"
if lifecycle_removal_is_allowed; then
  fail_test "a preparation incident allowed removal"
fi
run_software_recovery || fail_test "preparation recovery failed"
read_lifecycle || fail_test "recovered preparation left the lifecycle unreadable"
[[ "$_lifecycle_state" == disabled ]] \
  || fail_test "preparation recovery did not restore disabled state"
grep -Fxq original "$MUTATED_FILE" \
  || fail_test "preparation recovery did not restore the file"
lifecycle_removal_is_allowed \
  || fail_test "the recovered disabled lineage blocked removal"

printf 'software recovery tests passed\n'
