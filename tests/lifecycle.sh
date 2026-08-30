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

SYNC_FAIL_PATH=""
SYNC_FAIL_MARKER="${TEST_DIR}/durable-sync-failed"

durable_sync() {
  local path="$1"
  if [[ -n "$SYNC_FAIL_PATH" && "$path" == "$SYNC_FAIL_PATH" \
    && ! -e "$SYNC_FAIL_MARKER" ]]; then
    : > "$SYNC_FAIL_MARKER"
    return 1
  fi
}

arm_sync_failure() {
  SYNC_FAIL_PATH="$1"
  rm -f "$SYNC_FAIL_MARKER"
}

SERVICE_LOAD_FILE="${TEST_DIR}/service-load"
SERVICE_ACTIVE_FILE="${TEST_DIR}/service-active"
SERVICE_UNIT_FILE="${TEST_DIR}/service-unit-file"
SERVICE_ACTION_LOG="${TEST_DIR}/service-actions"
SERVICE_LOCK_VIOLATION="${TEST_DIR}/service-lock-violation"
SERVICE_SHOW_FAIL=false
SERVICE_STOP_FAIL_AFTER=false
SERVICE_START_FAIL=false
SERVICE_ACTIVATE_AFTER_CAPTURE=false

systemctl() {
  local unit="$TRANSACTION_SERVICE_UNIT"
  case "$*" in
    "show --property=LoadState --property=ActiveState --property=UnitFileState ${unit}")
      [[ "$SERVICE_SHOW_FAIL" == false ]] || return 41
      printf 'LoadState=%s\n' "$(<"$SERVICE_LOAD_FILE")"
      printf 'ActiveState=%s\n' "$(<"$SERVICE_ACTIVE_FILE")"
      printf 'UnitFileState=%s\n' "$(<"$SERVICE_UNIT_FILE")"
      if [[ "$SERVICE_ACTIVATE_AFTER_CAPTURE" == true ]]; then
        printf 'active\n' > "$SERVICE_ACTIVE_FILE"
        SERVICE_ACTIVATE_AFTER_CAPTURE=false
      fi
      ;;
    "show --property=ActiveState --value ${unit}")
      [[ "$SERVICE_SHOW_FAIL" == false ]] || return 41
      printf '%s\n' "$(<"$SERVICE_ACTIVE_FILE")"
      ;;
    "stop ${unit}")
      if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
        || "$_OMASECBOOT_REPAIR_LOCK_OWNED" != true ]]; then
        : > "$SERVICE_LOCK_VIOLATION"
        return 91
      fi
      printf 'stop\n' >> "$SERVICE_ACTION_LOG"
      printf 'inactive\n' > "$SERVICE_ACTIVE_FILE"
      [[ "$SERVICE_STOP_FAIL_AFTER" == false ]] || return 42
      ;;
    "start ${unit}")
      if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
        || "$_OMASECBOOT_REPAIR_LOCK_OWNED" != true ]]; then
        : > "$SERVICE_LOCK_VIOLATION"
        return 92
      fi
      printf 'start\n' >> "$SERVICE_ACTION_LOG"
      [[ "$SERVICE_START_FAIL" == false ]] || return 43
      printf 'active\n' > "$SERVICE_ACTIVE_FILE"
      ;;
    *) return 97 ;;
  esac
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
  SYNC_FAIL_PATH=""
  rm -f "$SYNC_FAIL_MARKER"
  printf 'loaded\n' > "$SERVICE_LOAD_FILE"
  printf 'inactive\n' > "$SERVICE_ACTIVE_FILE"
  printf 'disabled\n' > "$SERVICE_UNIT_FILE"
  : > "$SERVICE_ACTION_LOG"
  rm -f "$SERVICE_LOCK_VIOLATION"
  SERVICE_SHOW_FAIL=false
  SERVICE_STOP_FAIL_AFTER=false
  SERVICE_START_FAIL=false
  SERVICE_ACTIVATE_AFTER_CAPTURE=false
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

failed_file_transaction() {
  transaction_phase_start "backup-files"
  transaction_backup_file "$PRESENT_FILE"
  transaction_backup_file "$PRESENT_FILE"
  transaction_backup_file "$ABSENT_FILE" true
  transaction_phase_complete "backup-files"
  transaction_phase_start "mutate-files"
  printf 'changed\n' > "$PRESENT_FILE"
  printf 'created\n' > "$ABSENT_FILE"
  return 29
}

stable_sync_failure_transaction() {
  transaction_phase_start "backup-files"
  transaction_backup_file "$PRESENT_FILE"
  transaction_phase_complete "backup-files"
  printf 'changed before stable publication\n' > "$PRESENT_FILE"
  arm_sync_failure "$(state_dir_path)"
}

manifest_sync_failure_transaction() {
  transaction_phase_start "backup-files"
  transaction_backup_file "$PRESENT_FILE"
  printf 'changed before manifest publication\n' > "$PRESENT_FILE"
  arm_sync_failure "$(dirname "$(lifecycle_manifest_path "$_transaction_id")")"
  transaction_backup_file "$ABSENT_FILE" true
}

recovery_sync_failure_transaction() {
  transaction_phase_start "recovery-sync" || return 1
  arm_sync_failure "$(state_dir_path)"
  return 24
}

preserved_file_transaction() {
  transaction_phase_start "preserve-files" || return 1
  transaction_backup_file "$PRESENT_FILE" || return 1
  printf 'proved replacement\n' > "$PRESENT_FILE"
  preserve_transaction_files_on_failure || return 1
  return 30
}

missing_firmware_attachment_transaction() {
  local backup_id path document
  backup_id=$_transaction_id
  path="$(state_dir_path)/firmware-backup/${backup_id}"
  read_transaction_manifest "$_transaction_id" || return 1
  document=$(jq -c --arg id "$backup_id" --arg path "$path" \
    --arg hash "$(printf '0%.0s' {1..64})" '
      .firmware_backup = {
        id: $id,
        path: $path,
        status: "complete",
        manifest_sha256: $hash
      }
    ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document" || return 1
  return 31
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

service_observation_transaction() {
  [[ "$(<"$SERVICE_ACTIVE_FILE")" == inactive ]] || return 1
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
    .service_state[$unit].quiesce_status == "completed" and
    .service_state[$unit].restore_status == "pending"
  ' <<< "$_manifest_json" >/dev/null || return 1
  transaction_phase_start "observe-service" || return 1
  transaction_phase_complete "observe-service"
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
  .backups == [{
    "path": null,
    "sha256": null,
    "kind": "absent-lifecycle",
    "target": null
  }] and
  .service_state["limine-snapper-sync.service"].active_state == "inactive" and
  .service_state["limine-snapper-sync.service"].quiesce_status == "completed" and
  .service_state["limine-snapper-sync.service"].restore_status == "completed"
' "$adoption_manifest" >/dev/null || fail_test "adoption manifest is incomplete"

reset_state
SERVICE_SHOW_FAIL=true
if adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent"; then
  fail_test "failed service capture published a transaction"
fi
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "failed service capture changed lifecycle state"
[[ ! -s "$SERVICE_ACTION_LOG" ]] \
  || fail_test "failed service capture acted on the service"

reset_state
printf 'activating\n' > "$SERVICE_ACTIVE_FILE"
if adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent"; then
  fail_test "transitional service state published a transaction"
fi
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "transitional service state changed lifecycle state"

reset_state
printf 'invented\n' > "$SERVICE_UNIT_FILE"
if adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent"; then
  fail_test "unknown unit-file state published a transaction"
fi
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "unknown unit-file state changed lifecycle state"

reset_state
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
printf 'masked\n' > "$SERVICE_UNIT_FILE"
if adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent"; then
  fail_test "active masked service published a transaction"
fi
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "active masked service changed lifecycle state"

reset_state
SERVICE_ACTIVATE_AFTER_CAPTURE=true
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "inactive-to-active service race was not contained"
[[ "$(<"$SERVICE_ACTIVE_FILE")" == inactive ]] \
  || fail_test "inactive-to-active race did not restore the captured state"
mapfile -t service_actions < "$SERVICE_ACTION_LOG"
[[ "${service_actions[*]}" == stop ]] \
  || fail_test "inactive-to-active race did not stop exactly once"
inactive_race_manifest=$(lifecycle_manifest_path \
  "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
  .service_state[$unit].active_state == "inactive" and
  .service_state[$unit].quiesce_status == "completed" and
  .service_state[$unit].restore_status == "completed"
' "$inactive_race_manifest" >/dev/null \
  || fail_test "inactive-to-active service outcomes were not durable"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "service success fixture adoption failed"
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
: > "$SERVICE_ACTION_LOG"
run_lifecycle_transaction "service-success" "active" "active" \
  service_observation_transaction || fail_test "active service transaction failed"
[[ "$(<"$SERVICE_ACTIVE_FILE")" == active ]] \
  || fail_test "successful transaction did not restore the active service"
mapfile -t service_actions < "$SERVICE_ACTION_LOG"
[[ "${service_actions[*]}" == 'stop start' ]] \
  || fail_test "successful transaction service actions were not stop then start"
read_lifecycle || fail_test "service success lifecycle became unreadable"
service_success_manifest=$(lifecycle_manifest_path \
  "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
  .status == "completed" and
  .service_state[$unit].quiesce_status == "completed" and
  .service_state[$unit].restore_status == "completed" and
  (.completed_phases | index("observe-service") != null)
' "$service_success_manifest" >/dev/null \
  || fail_test "successful service outcomes were not durable"
[[ ! -e "$SERVICE_LOCK_VIOLATION" ]] \
  || fail_test "service action ran without both transaction locks"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "stop-failure fixture adoption failed"
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
SERVICE_STOP_FAIL_AFTER=true
if run_lifecycle_transaction "service-stop-failure" "active" "active" \
  noop_transaction; then
  fail_test "stop-after-effect failure reported success"
fi
[[ "$(<"$SERVICE_ACTIVE_FILE")" == active ]] \
  || fail_test "stop failure did not restore the service"
read_lifecycle || fail_test "stop-failure lifecycle became unreadable"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "post-transition stop failure did not require recovery"
jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
  .service_state[$unit].quiesce_status == "failed" and
  .service_state[$unit].restore_status == "completed" and
  (.completed_phases | index("verify") == null)
' "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "stop failure outcomes were not durable"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "callback-service fixture adoption failed"
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
if run_lifecycle_transaction "service-callback-failure" "active" "active" \
  failed_transaction; then
  fail_test "active-service callback failure reported success"
else
  service_callback_rc=$?
fi
[[ $service_callback_rc -eq 23 ]] \
  || fail_test "active-service callback lost its status"
[[ "$(<"$SERVICE_ACTIVE_FILE")" == active ]] \
  || fail_test "callback failure did not restore the service"
read_lifecycle || fail_test "callback-service lifecycle became unreadable"
jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
  .service_state[$unit].quiesce_status == "completed" and
  .service_state[$unit].restore_status == "completed"
' "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "callback failure service outcomes were not durable"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "restore-failure fixture adoption failed"
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
SERVICE_START_FAIL=true
if run_lifecycle_transaction "service-restore-failure" "active" "active" \
  noop_transaction; then
  fail_test "service restoration failure reported success"
fi
read_lifecycle || fail_test "restore-failure lifecycle became unreadable"
[[ "$_lifecycle_state" == recovery-required \
  && "$(<"$SERVICE_ACTIVE_FILE")" == inactive ]] \
  || fail_test "service restoration failure did not require recovery"
jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
  .service_state[$unit].quiesce_status == "completed" and
  .service_state[$unit].restore_status == "failed" and
  (.failure.reason | contains("service restoration failed"))
' "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "service restoration failure was not durable"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "post-service fixture adoption failed"

: > "$(snapshot_restore_lock_path)"
if run_lifecycle_transaction "repair" "active" "active" noop_transaction \
  >/dev/null 2>&1; then
  fail_test "mutation entered while full snapshot restore was running"
fi
rm -f "$(snapshot_restore_lock_path)"
read_lifecycle || fail_test "restore guard damaged lifecycle readability"
[[ $_lifecycle_state == active ]] || fail_test "restore guard changed stable lifecycle state"

file_fixture_dir="${TEST_DIR}/files"
mkdir -m 755 "$file_fixture_dir"
PRESENT_FILE="${file_fixture_dir}/present"
ABSENT_FILE="${file_fixture_dir}/absent"
export PRESENT_FILE ABSENT_FILE
printf 'original\n' > "$PRESENT_FILE"
if run_lifecycle_transaction "file-rollback" "active" "active" \
  failed_file_transaction; then
  fail_test "failed file transaction succeeded"
else
  file_failure_rc=$?
fi
[[ $file_failure_rc -eq 29 ]] || fail_test "file transaction lost its failure status"
grep -Fxq original "$PRESENT_FILE" || fail_test "file rollback did not restore content"
[[ ! -e "$ABSENT_FILE" ]] || fail_test "file rollback retained a created target"
read_lifecycle || fail_test "file rollback lifecycle became unreadable"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "failed file transaction did not require recovery"
file_failure_manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
jq -e --arg present "$PRESENT_FILE" --arg absent "$ABSENT_FILE" '
  .rollback.status == "completed" and
  .rollback.failures == [] and
  ([.backups[] | select(.target == $present and .kind == "file")] | length) == 1 and
  ([.backups[] | select(.target == $absent and .kind == "absent-file")] | length) == 1
' "$file_failure_manifest" >/dev/null || fail_test "file rollback record is incomplete"
unsafe_manifest="${TEST_DIR}/unsafe-file-manifest.json"
jq '(.backups[] | select(.kind == "file") | .mode) = "666"' \
  "$file_failure_manifest" > "$unsafe_manifest"
atomic_write_control_file "$file_failure_manifest" 600 < "$unsafe_manifest"
if read_transaction_manifest "$_lifecycle_transaction_id" >/dev/null 2>&1; then
  fail_test "transaction manifest trusted unsafe restore metadata"
fi

reset_state
printf 'original\n' > "$PRESENT_FILE"
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "preserved-file fixture adoption failed"
if run_lifecycle_transaction "preserved-file-failure" "active" "active" \
  preserved_file_transaction; then
  fail_test "preserved-file failure reported success"
fi
grep -Fxq 'proved replacement' "$PRESENT_FILE" \
  || fail_test "preserve policy restored the prior file"
read_lifecycle || fail_test "preserved-file lifecycle unreadable"
jq -e '.file_rollback_policy == "preserve" and
  .rollback.status == "preserved" and .rollback.failures == []' \
  "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "preserved-file outcome was not durable"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "firmware-attachment fixture adoption failed"
if run_lifecycle_transaction "missing-firmware-attachment" "active" "active" \
  missing_firmware_attachment_transaction; then
  fail_test "missing firmware attachment failure reported success"
fi
read_lifecycle || fail_test "missing firmware attachment blocked recovery"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "missing firmware attachment did not require recovery"
jq -e '.firmware_backup.status == "complete" and
  .rollback.status == "completed"' \
  "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "generic recovery depended on the firmware attachment"

reset_state
printf 'original\n' > "$PRESENT_FILE"
rm -f "$ABSENT_FILE"
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "stable-sync fixture adoption failed"
if run_lifecycle_transaction "stable-sync-failure" "active" "active" \
  stable_sync_failure_transaction; then
  fail_test "post-rename stable-state sync failure reported success"
fi
SYNC_FAIL_PATH=""
rm -f "$SYNC_FAIL_MARKER"
grep -Fxq original "$PRESENT_FILE" \
  || fail_test "post-rename stable-state failure did not roll back files"
read_lifecycle || fail_test "post-rename stable-state failure damaged lifecycle"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "published stable state was not forced to recovery-required"
jq -e '.status == "failed" and .rollback.status == "completed"' \
  "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "post-rename stable-state failure was not durably rolled back"

reset_state
printf 'original\n' > "$PRESENT_FILE"
rm -f "$ABSENT_FILE"
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "manifest-sync fixture adoption failed"
if run_lifecycle_transaction "manifest-sync-failure" "active" "active" \
  manifest_sync_failure_transaction; then
  fail_test "post-rename manifest sync failure reported success"
fi
SYNC_FAIL_PATH=""
rm -f "$SYNC_FAIL_MARKER"
grep -Fxq original "$PRESENT_FILE" \
  || fail_test "published backup manifest did not restore an earlier mutation"
read_lifecycle || fail_test "manifest-sync failure damaged lifecycle"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "manifest-sync failure did not require recovery"
jq -e '.status == "failed" and .rollback.status == "completed" and
  ([.backups[] | select(.target != null)] | length) == 2' \
  "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "published backup was deleted after ambiguous manifest write"

reset_state
arm_sync_failure "$(transactions_dir_path)"
if adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent"; then
  fail_test "transaction-directory publication failure reported success"
fi
[[ -e "$SYNC_FAIL_MARKER" ]] \
  || fail_test "new transaction directory was not durably published"
SYNC_FAIL_PATH=""
rm -f "$SYNC_FAIL_MARKER"
read_lifecycle || fail_test "transaction-directory sync failure damaged lifecycle"
[[ "$_lifecycle_state" == unmanaged ]] \
  || fail_test "transaction-directory sync failure published lifecycle state"

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
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "recovery-sync fixture adoption failed"
if run_lifecycle_transaction "recovery-sync-failure" "active" "active" \
  recovery_sync_failure_transaction; then
  fail_test "post-rename recovery sync failure reported success"
fi
[[ -e "$SYNC_FAIL_MARKER" ]] \
  || fail_test "recovery state did not reach the post-rename sync"
SYNC_FAIL_PATH=""
rm -f "$SYNC_FAIL_MARKER"
read_lifecycle || fail_test "recovery sync retry damaged lifecycle readability"
[[ "$_lifecycle_state" == recovery-required && "$_transaction_active" == false ]] \
  || fail_test "recovery sync retry did not confirm durable recovery"

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
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
exit_marker="${TEST_DIR}/previous-exit-trap"
if (
  trap 'printf "%s\n" "$?" > "$exit_marker"' EXIT
  run_lifecycle_transaction "repair" "active" "active" exiting_transaction
); then
  fail_test "exiting transaction succeeded"
else
  exit_rc=$?
fi
[[ $exit_rc -eq 37 ]] || fail_test "callback exit status was lost"
grep -Fxq 37 "$exit_marker" || fail_test "prior EXIT trap received the wrong status"
read_lifecycle || fail_test "exiting transaction state became unreadable"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "callback exit did not require recovery"
[[ "$(<"$SERVICE_ACTIVE_FILE")" == active ]] \
  || fail_test "callback exit did not restore the active service"
jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
  .service_state[$unit].restore_status == "completed"
' "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" >/dev/null \
  || fail_test "callback exit service restoration was not durable"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "zero-exit fixture adoption failed"
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
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
[[ "$(<"$SERVICE_ACTIVE_FILE")" == active ]] \
  || fail_test "callback exit zero did not restore the active service"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "signal fixture adoption failed"
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
signal_marker="${TEST_DIR}/previous-signal-trap"
if (
  trap - EXIT
  trap 'printf previous > "$signal_marker"' TERM
  run_lifecycle_transaction "repair" "active" "active" signalled_transaction
); then
  fail_test "signalled transaction succeeded"
else
  signal_rc=$?
fi
[[ $signal_rc -eq 143 ]] || fail_test "TERM did not return its conventional status"
grep -Fxq previous "$signal_marker" || fail_test "transaction discarded a prior TERM trap"
read_lifecycle || fail_test "signalled lifecycle could not be read"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "signal did not leave recovery-required"
[[ "$(<"$SERVICE_ACTIVE_FILE")" == active ]] \
  || fail_test "signal did not restore the active service"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "stale fixture adoption failed"
printf 'active\n' > "$SERVICE_ACTIVE_FILE"
with_boot_repair_lock
begin_lifecycle_transaction "repair" "active" || fail_test "stale transaction did not start"
[[ "$(<"$SERVICE_ACTIVE_FILE")" == inactive ]] \
  || fail_test "stale fixture did not quiesce the active service"
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
jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
  .status == "stale" and
  .failure.reason == "transaction owner is no longer valid" and
  .service_state[$unit].restore_status == "completed"
' \
  "$stale_manifest" >/dev/null || fail_test "stale owner was not recorded"
[[ "$(<"$SERVICE_ACTIVE_FILE")" == active ]] \
  || fail_test "stale reconciliation did not restore the active service"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "service-schema fixture adoption failed"
service_schema_manifest=$(lifecycle_manifest_path \
  "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
service_schema_tmp="${TEST_DIR}/service-schema.json"
jq --arg unit "$TRANSACTION_SERVICE_UNIT" \
  '.service_state[$unit].restore_status = "invented"' \
  "$service_schema_manifest" > "$service_schema_tmp"
atomic_write_control_file "$service_schema_manifest" 600 < "$service_schema_tmp"
if read_transaction_manifest \
  "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")" >/dev/null 2>&1; then
  fail_test "transaction manifest trusted an unsupported service outcome"
fi

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
