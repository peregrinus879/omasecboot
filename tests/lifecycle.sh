#!/bin/bash
# shellcheck disable=SC2154 # Assertions read globals set by lifecycle functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-lifecycle.XXXXXX")

cleanup() {
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

FAILPOINT=""
FAILPOINT_USED=false

lifecycle_failpoint() {
  if [[ -n "$FAILPOINT" && "$FAILPOINT" == "$1" && "$FAILPOINT_USED" == false ]]; then
    FAILPOINT_USED=true
    return 1
  fi
  return 0
}

reset_state() {
  release_boot_repair_lock
  rm -rf "$(state_dir_path)"
  rm -f "$(limine_lock_path)"
}

noop_transaction() {
  transaction_phase_start "verify"
  transaction_phase_complete "verify"
}

failed_transaction() {
  transaction_phase_start "prepared"
  transaction_phase_complete "prepared"
  transaction_phase_start "mutate"
  return 23
}

signalled_transaction() {
  transaction_phase_start "signal-test"
  kill -TERM "$BASHPID"
}

exiting_transaction() {
  transaction_phase_start "exit-test"
  exit 37
}

zero_exit_transaction() {
  transaction_phase_start "zero-exit-test"
  exit 0
}

reject_adoption_preflight() {
  return 1
}

reset_state
read_lifecycle || fail_test "unmanaged lifecycle could not be read"
[[ $_lifecycle_state == unmanaged ]] || fail_test "missing state was not unmanaged"
if adopt_lifecycle : "no" "invalid" "yes" "unset" \
  "absent" "unknown" "absent" "unknown"; then
  fail_test "invalid adoption input succeeded"
fi
read_lifecycle || fail_test "invalid adoption damaged lifecycle readability"
[[ $_lifecycle_state == unmanaged ]] || fail_test "invalid adoption created lifecycle state"
if adopt_lifecycle reject_adoption_preflight \
  "no" "unknown" "yes" "unset" "absent" "unknown" "absent" "unknown"; then
  fail_test "rejected adoption preflight succeeded"
fi
read_lifecycle || fail_test "rejected adoption damaged lifecycle readability"
[[ $_lifecycle_state == unmanaged ]] || fail_test "rejected adoption created lifecycle state"

adopt_lifecycle : "no" "unknown" "yes" "unset" \
  "absent" "unknown" "absent" "unknown" \
  || fail_test "explicit adoption failed"
read_lifecycle || fail_test "adopted lifecycle could not be read"
[[ $_lifecycle_state == active ]] || fail_test "adoption did not commit active state"
[[ $_lifecycle_generation -eq 2 ]] || fail_test "adoption did not commit state last"

state_file=$(lifecycle_file_path)
[[ $(stat -Lc '%a' "$state_file") == 644 ]] \
  || fail_test "lifecycle state is not safely readable"
jq -e '
  .schema_version == 1 and
  .writer_version == "1.0.0" and
  .adoption.source == "explicit" and
  .adoption.managed_settings == [
    {
      "path": "/etc/default/limine",
      "key": "ENABLE_VERIFICATION",
      "observed": "no",
      "original": "unknown"
    },
    {
      "path": "/etc/default/limine",
      "key": "ENABLE_ENROLL_LIMINE_CONFIG",
      "observed": "yes",
      "original": "unset"
    },
    {
      "path": "/etc/default/limine",
      "key": "COMMANDS_BEFORE_SAVE",
      "token": "limine-reset-enroll",
      "observed": "absent",
      "original": "unknown"
    },
    {
      "path": "/etc/default/limine",
      "key": "COMMANDS_AFTER_SAVE",
      "token": "limine-enroll-config",
      "observed": "absent",
      "original": "unknown"
    }
  ]
' "$state_file" >/dev/null || fail_test "adoption record is incomplete"

adoption_id=$(jq -r '.last_transaction.id' "$state_file")
adoption_manifest="$(transactions_dir_path)/${adoption_id}/manifest.json"
jq -e '
  .status == "completed" and
  .prior_state == "unmanaged" and
  .operation == "adopt" and
  .owner.pid > 0 and
  (.owner.start_time | length > 0) and
  (.completed_phases | index("record-adoption") != null) and
  .backups == [{"path": null, "sha256": null, "kind": "absent-lifecycle"}] and
  .service_state["limine-snapper-sync.service"].active_state == "inactive"
' "$adoption_manifest" >/dev/null || fail_test "adoption manifest is incomplete"

: > "$(snapshot_restore_lock_path)"
if run_lifecycle_transaction "repair" "active" "active" noop_transaction \
  >/dev/null 2>&1; then
  fail_test "mutation entered while full snapshot restore was running"
fi
rm -f "$(snapshot_restore_lock_path)"
read_lifecycle || fail_test "restore guard damaged lifecycle readability"
[[ $_lifecycle_state == active ]] || fail_test "restore guard changed stable lifecycle state"

reset_state
FAILPOINT=after-manifest-write
FAILPOINT_USED=false
if adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent"; then
  fail_test "manifest-write failpoint succeeded"
fi
FAILPOINT=""
read_lifecycle || fail_test "manifest-write failure damaged lifecycle readability"
[[ $_lifecycle_state == unmanaged ]] \
  || fail_test "pre-publication failure created durable lifecycle state"

for FAILPOINT in after-transition-write before-adoption-state-write \
  after-completed-manifest-write before-stable-state-write; do
  reset_state
  FAILPOINT_USED=false
  if adopt_lifecycle : "no" "no" "yes" "yes" \
    "absent" "absent" "absent" "absent"; then
    fail_test "${FAILPOINT} failpoint succeeded"
  fi
  read_lifecycle || fail_test "${FAILPOINT} damaged lifecycle readability"
  [[ $_lifecycle_state == recovery-required ]] \
    || fail_test "${FAILPOINT} did not require recovery"
done
FAILPOINT=""

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "recovery-write fixture adoption failed"
FAILPOINT=before-recovery-state-write
FAILPOINT_USED=false
if run_lifecycle_transaction "repair" "active" "active" failed_transaction; then
  fail_test "recovery-state failpoint succeeded"
fi
FAILPOINT=""
read_lifecycle || fail_test "recovery-state retry damaged lifecycle readability"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "recovery-state write was not retried"

reset_state
adopt_lifecycle : "no" "unknown" "yes" "unset" \
  "absent" "unknown" "absent" "unknown" \
  || fail_test "failure fixture adoption failed"
if run_lifecycle_transaction "repair" "active" "active" failed_transaction; then
  fail_test "injected transaction failure succeeded"
else
  failure_rc=$?
fi
[[ $failure_rc -eq 23 ]] || fail_test "transaction failure status was lost"
read_lifecycle || fail_test "failed lifecycle could not be read"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "failed mutation did not require recovery"
failure_manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
jq -e '
  .status == "failed" and
  .failure.exit_code == 23 and
  .failure.phase == "mutate" and
  (.completed_phases | index("prepared") != null)
' "$failure_manifest" >/dev/null || fail_test "failed phase was not durable"
if run_lifecycle_transaction "repair" "active" "active" noop_transaction >/dev/null 2>&1; then
  fail_test "normal mutation ran during recovery-required"
fi
failure_backup=$(jq -r '.backups[0].path' "$failure_manifest")
printf 'tampered\n' > "$failure_backup"
if read_transaction_manifest "$_lifecycle_transaction_id" >/dev/null 2>&1; then
  fail_test "transaction manifest trusted a tampered lifecycle backup"
fi

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "exit fixture adoption failed"
exit_marker="${TEST_DIR}/previous-exit-trap"
if (
  trap 'printf previous > "$exit_marker"' EXIT
  run_lifecycle_transaction "repair" "active" "active" exiting_transaction
); then
  fail_test "exiting transaction succeeded"
else
  exit_rc=$?
fi
[[ $exit_rc -eq 37 ]] || fail_test "callback exit status was lost"
grep -Fxq previous "$exit_marker" || fail_test "transaction discarded a prior EXIT trap"
read_lifecycle || fail_test "exiting transaction state became unreadable"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "callback exit did not require recovery"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "zero-exit fixture adoption failed"
if (trap - EXIT; run_lifecycle_transaction \
  "repair" "active" "active" zero_exit_transaction); then
  fail_test "callback exit zero reported transaction success"
else
  zero_exit_rc=$?
fi
[[ $zero_exit_rc -eq 1 ]] || fail_test "callback exit zero was not normalized"
read_lifecycle || fail_test "zero-exit transaction state became unreadable"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "callback exit zero did not require recovery"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "signal fixture adoption failed"
if (trap - EXIT; run_lifecycle_transaction "repair" "active" "active" signalled_transaction); then
  fail_test "signalled transaction succeeded"
else
  signal_rc=$?
fi
[[ $signal_rc -eq 143 ]] || fail_test "TERM did not return its conventional status"
read_lifecycle || fail_test "signalled lifecycle could not be read"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "signal did not leave recovery-required"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "stale fixture adoption failed"
with_boot_repair_lock
begin_lifecycle_transaction "repair" "active" || fail_test "stale transaction did not start"
stale_manifest=$(lifecycle_manifest_path "$_transaction_id")
stale_tmp="${TEST_DIR}/stale-manifest.json"
jq '.owner.start_time = "0"' "$stale_manifest" > "$stale_tmp"
atomic_write_control_file "$stale_manifest" 600 < "$stale_tmp"
release_boot_repair_lock
if show_lifecycle_status > "${TEST_DIR}/stale-status.out" 2>&1; then
  fail_test "status reported a stale transition as healthy"
fi
grep -Fq 'recovery-required (stale transaction' "${TEST_DIR}/stale-status.out" \
  || fail_test "status did not classify the stale owner"

with_boot_repair_lock
reconcile_stale_lifecycle || fail_test "stale transition was not reconciled"
release_boot_repair_lock
read_lifecycle || fail_test "reconciled lifecycle could not be read"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "stale transition did not require recovery"
jq -e '.status == "stale" and .failure.reason == "transaction owner is no longer valid"' \
  "$stale_manifest" >/dev/null || fail_test "stale owner was not recorded"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "permission fixture adoption failed"
chmod 666 "$(lifecycle_file_path)"
if read_lifecycle >/dev/null 2>&1; then
  fail_test "writable lifecycle state was trusted"
fi

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "schema fixture adoption failed"
schema_tmp="${TEST_DIR}/newer-schema.json"
jq '.schema_version = 2' "$(lifecycle_file_path)" > "$schema_tmp"
atomic_write_control_file "$(lifecycle_file_path)" 644 < "$schema_tmp"
if read_lifecycle >/dev/null 2>&1; then
  fail_test "unknown lifecycle schema was trusted"
fi

printf 'lifecycle tests passed\n'
