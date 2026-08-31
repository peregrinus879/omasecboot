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
SYNC_FAIL_REQUIRE_PATH=""
SYNC_FAIL_MARKER="${TEST_DIR}/durable-sync-failed"

durable_sync() {
  local path="$1"
  if [[ -n "$SYNC_FAIL_PATH" && "$path" == "$SYNC_FAIL_PATH" \
    && ( -z "$SYNC_FAIL_REQUIRE_PATH" || -e "$SYNC_FAIL_REQUIRE_PATH" ) \
    && ! -e "$SYNC_FAIL_MARKER" ]]; then
    : > "$SYNC_FAIL_MARKER"
    return 1
  fi
}

arm_sync_failure() {
  SYNC_FAIL_PATH="$1"
  SYNC_FAIL_REQUIRE_PATH="${2:-}"
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
TEST_ATTEMPT_SERVICE_STATE=""

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
FAILPOINT_KILL=false

lifecycle_failpoint() {
  if [[ -n "$FAILPOINT" && "$FAILPOINT" == "$1" && "$FAILPOINT_USED" == false ]]; then
    FAILPOINT_USED=true
    if [[ "$FAILPOINT_KILL" == true ]]; then
      kill -KILL "$BASHPID"
    fi
    return 1
  fi
  return 0
}

reset_state() {
  release_boot_repair_lock
  rm -rf "$(state_dir_path)"
  rm -f "$(limine_lock_path)"
  SYNC_FAIL_PATH=""
  SYNC_FAIL_REQUIRE_PATH=""
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
  TEST_ATTEMPT_SERVICE_STATE=""
  _lifecycle_state=unmanaged
  _lifecycle_generation=0
  _lifecycle_transaction_id=""
  _lifecycle_json=""
  _lifecycle_read_status=absent
  _manifest_json=""
  _manifest_id=""
  _manifest_sha256=""
  _incident_json=""
  _incident_read_status=absent
  _recovery_root_service_json=""
  _recovery_incident_json=""
  _transaction_active=false
  _transaction_id=""
  _transaction_token=""
  _transaction_operation=""
  _transaction_target_state=""
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
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

incident_sync_failure_transaction() {
  transaction_phase_start "incident-sync" || return 1
  arm_sync_failure "$(dirname "$(lifecycle_incident_path "$_transaction_id")")" \
    "$(lifecycle_incident_path "$_transaction_id")"
  return 25
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

create_test_attempt_seal() {
  local root_reference="$1" previous_reference="$2" ordinal="$3"
  local status="${4:-failed}" transaction_id transaction_dir manifest incident
  local prior_backup prior_hash timestamp service_state failure rollback document hash
  local current_phase completed_phases
  [[ "$ordinal" =~ ^[1-9][0-9]*$ \
    && ( "$status" == failed || "$status" == stale || "$status" == completed ) ]] \
    && (( ordinal <= MAX_RECOVERY_ATTEMPT_SEALS )) || return 1
  transaction_id=$(new_transaction_id) || return 1
  transaction_dir="$(transactions_dir_path)/${transaction_id}"
  manifest="${transaction_dir}/manifest.json"
  incident="${transaction_dir}/incident.json"
  install -d -m 700 "$transaction_dir" || return 1
  prior_backup="${transaction_dir}/prior-lifecycle.json"
  cp -p "$(lifecycle_file_path)" "$prior_backup" || return 1
  chmod 600 "$prior_backup" || return 1
  prior_hash=$(sha256_file "$prior_backup") || return 1
  [[ -n "$TEST_ATTEMPT_SERVICE_STATE" ]] || return 1
  service_state="$TEST_ATTEMPT_SERVICE_STATE"
  timestamp=$(utc_timestamp) || return 1
  if [[ "$status" == completed ]]; then
    failure=null
    rollback=null
    current_phase=null
    completed_phases='["recover"]'
  else
    failure=$(jq -cn --arg status "$status" --arg timestamp "$timestamp" '{
      exit_code: 47,
      phase: "recover",
      reason: ("test recovery attempt " + $status),
      recorded_at: $timestamp
    }') || return 1
    rollback=$(jq -cn --arg timestamp "$timestamp" '{
      status: "preserved",
      attempted_at: $timestamp,
      failures: []
    }') || return 1
    current_phase='"recover"'
    completed_phases='[]'
  fi
  document=$(jq -cn \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg timestamp "$timestamp" \
    --arg boot_id "$(boot_id_value)" \
    --argjson owner_pid "$BASHPID" \
    --arg owner_start "$(process_start_time "$BASHPID")" \
    --argjson owner_uid "$(control_owner_uid)" \
    --arg status "$status" \
    --argjson ordinal "$ordinal" \
    --argjson root "$root_reference" \
    --argjson previous "$previous_reference" \
    --arg prior_backup "$prior_backup" \
    --arg prior_hash "$prior_hash" \
    --argjson service_state "$service_state" \
    --argjson failure "$failure" \
    --argjson rollback "$rollback" \
    --argjson current_phase "$current_phase" \
    --argjson completed_phases "$completed_phases" '{
      schema_version: $schema,
      writer_version: $version,
      id: $id,
      kind: "recovery-attempt",
      operation: "recover-test",
      target_state: "active",
      status: $status,
      created_at: $timestamp,
      completed_at: $timestamp,
      boot_id: $boot_id,
      token_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      owner: {pid: $owner_pid, start_time: $owner_start, uid: $owner_uid},
      prior_state: "recovery-required",
      recovery: {
        attempt_number: $ordinal,
        previous_attempt: $previous,
        root_incident: $root
      },
      current_phase: $current_phase,
      completed_phases: $completed_phases,
      backups: [{
        kind: "prior-lifecycle",
        path: $prior_backup,
        sha256: $prior_hash,
        target: null
      }],
      service_state: $service_state,
      file_rollback_policy: "preserve",
      firmware_backup: null,
      enrollment_plan: null,
      firmware_writes: [],
      domain_records: {
        bootnext: null,
        final_proof: null,
        managed_settings: null,
        producer: null,
        tracking_ownership: null,
        unconfigure: null,
        windows: null
      },
      failure: $failure,
      rollback: $rollback
    }') || return 1
  printf '%s\n' "$document" | atomic_write_control_file "$manifest" 600 || return 1
  hash=$(sha256_file "$manifest") || return 1
  document=$(jq -cn \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg manifest "$manifest" \
    --arg hash "$hash" \
    --arg status "$status" \
    --argjson ordinal "$ordinal" \
    --argjson root "$root_reference" \
    --argjson previous "$previous_reference" \
    --argjson failure "$failure" \
    --arg timestamp "$timestamp" '{
      schema_version: $schema,
      writer_version: $version,
      kind: "attempt",
      id: $id,
      operation: "recover-test",
      ordinal: $ordinal,
      manifest: $manifest,
      manifest_sha256: $hash,
      manifest_status: $status,
      incident_status: $status,
      failure: $failure,
      rollback_disposition: "manifest-recorded",
      root_incident: $root,
      previous_attempt: $previous,
      sealed_at: $timestamp
    }') || return 1
  printf '%s\n' "$document" | atomic_create_control_file "$incident" 600 || return 1
  incident_reference_from_json "$document" "$incident"
}

reset_state
read_lifecycle || fail_test "unmanaged lifecycle could not be read"
[[ $_lifecycle_state == unmanaged ]] || fail_test "missing state was not unmanaged"
[[ $_lifecycle_read_status == absent ]] || fail_test "missing state was not classified absent"
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
[[ $_lifecycle_read_status == supported ]] \
  || fail_test "schema-2 state was not classified supported"

state_file=$(lifecycle_file_path)
[[ $(stat -Lc '%a' "$state_file") == 644 ]] \
  || fail_test "lifecycle state is not safely readable"
jq -e '
  .schema_version == 2 and
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
grep -Fxq 'changed before stable publication' "$PRESENT_FILE" \
  || fail_test "post-completion stable-state failure did not preserve files"
read_lifecycle || fail_test "post-rename stable-state failure damaged lifecycle"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "published stable state was not forced to recovery-required"
stable_sync_manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
stable_sync_incident=$(lifecycle_incident_path "$_lifecycle_transaction_id")
jq -e '.status == "completed" and .rollback == null' \
  "$stable_sync_manifest" >/dev/null \
  || fail_test "publication uncertainty rewrote the completed manifest"
jq -e '
  .kind == "root" and .manifest_status == "completed" and
  .incident_status == "publication-uncertain" and
  .rollback_disposition == "not-attempted-stable-publication-ambiguous"
' "$stable_sync_incident" >/dev/null \
  || fail_test "post-completion publication uncertainty was not sealed"
jq -e --arg hash "$(sha256_file "$stable_sync_manifest")" '
  .last_transaction.manifest_sha256 == $hash and
  .transaction.root_incident.status == "publication-uncertain"
' "$(lifecycle_file_path)" >/dev/null \
  || fail_test "publication uncertainty retained a dangling manifest reference"

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
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "incident-sync fixture adoption failed"
if run_lifecycle_transaction "incident-sync-failure" "active" "active" \
  incident_sync_failure_transaction; then
  fail_test "incident parent-sync fixture reported success"
else
  incident_sync_rc=$?
fi
[[ $incident_sync_rc -eq 25 && -e "$SYNC_FAIL_MARKER" ]] \
  || fail_test "incident parent-sync failure was not exercised"
read_lifecycle || fail_test "incident parent-sync retry damaged lifecycle readability"
[[ "$_lifecycle_state" == recovery-required && "$_transaction_active" == false ]] \
  || fail_test "incident parent-sync retry did not publish durable recovery"
SYNC_FAIL_PATH=""
SYNC_FAIL_REQUIRE_PATH=""
rm -f "$SYNC_FAIL_MARKER"

reset_state
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "active-backup-tamper fixture adoption failed"
with_boot_repair_lock || fail_test "could not lock active-backup-tamper fixture"
begin_lifecycle_transaction "backup-tamper" "active" \
  || fail_test "active-backup-tamper transaction did not start"
transaction_phase_start "backup-files" \
  || fail_test "active-backup-tamper phase did not start"
transaction_backup_file "$PRESENT_FILE" \
  || fail_test "active-backup-tamper file was not registered"
transaction_phase_complete "backup-files" \
  || fail_test "active-backup-tamper phase did not complete"
read_transaction_manifest "$_transaction_id" \
  || fail_test "active-backup-tamper manifest was not readable"
active_backup=$(jq -r '.backups[1].path' <<< "$_manifest_json")
printf 'tampered\n' > "$active_backup"
if transaction_phase_start "after-tamper" >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "active transaction trusted a tampered registered backup"
fi
if commit_lifecycle_transaction >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "active transaction committed with a tampered registered backup"
fi
release_boot_repair_lock

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
FAILPOINT=""
FAILPOINT_KILL=false
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "incident fixture adoption failed"
if run_lifecycle_transaction "repair" "active" "active" failed_transaction; then
  fail_test "root incident transaction succeeded"
fi
read_lifecycle || fail_test "root incident lifecycle unreadable"
root_incident_id="$_lifecycle_transaction_id"
root_incident_manifest=$(lifecycle_manifest_path "$root_incident_id")
root_incident_path=$(lifecycle_incident_path "$root_incident_id")
root_manifest_hash=$(sha256_file "$root_incident_manifest")
root_seal_hash=$(sha256_file "$root_incident_path")
root_incident_reference=$(jq -c '.transaction.root_incident' "$(lifecycle_file_path)")
jq -e --arg manifest "$root_incident_manifest" --arg hash "$root_manifest_hash" '
  .kind == "root" and .ordinal == 0 and .manifest == $manifest and
  .manifest_sha256 == $hash and .manifest_status == "failed" and
  .incident_status == "failed" and .root_incident == null and
  .previous_attempt == null
' "$root_incident_path" >/dev/null || fail_test "root incident seal is incomplete"
[[ $(stat -Lc '%a' "$root_incident_path") == 600 ]] \
  || fail_test "root incident seal is not private"
jq -e --arg path "$root_incident_path" --arg hash "$root_seal_hash" '
  .transaction.kind == "incident" and .transaction.attempt_count == 0 and
  .transaction.last_recovery_attempt == null and
  .transaction.root_incident.path == $path and
  .transaction.root_incident.sha256 == $hash
' "$(lifecycle_file_path)" >/dev/null \
  || fail_test "lifecycle did not bind the root seal"
read_recovery_incident || fail_test "sealed root incident did not validate"
[[ $(jq -r '.kind' <<< "$_recovery_incident_json") == root ]] \
  || fail_test "recovery reader did not return the root seal"
if printf '%s\n' "$_recovery_incident_json" \
  | atomic_create_control_file "$root_incident_path" 600; then
  fail_test "create-once writer replaced an incident seal"
fi
[[ $(sha256_file "$root_incident_path") == "$root_seal_hash" ]] \
  || fail_test "rejected seal replacement changed the root"

create_once_probe="$(dirname "$root_incident_path")/create-once-probe.json"
arm_sync_failure "$(dirname "$create_once_probe")"
if printf '{"value":"first"}\n' \
  | atomic_create_control_file "$create_once_probe" 600; then
  fail_test "create-once writer ignored a parent sync failure"
fi
[[ -e "$SYNC_FAIL_MARKER" && $(stat -Lc '%h' "$create_once_probe") -eq 1 ]] \
  || fail_test "create-once sync failure left an invalid destination link"
if printf '{"value":"replacement"}\n' \
  | atomic_create_control_file "$create_once_probe" 600 >/dev/null 2>&1; then
  fail_test "create-once writer replaced a destination after sync uncertainty"
fi
grep -Fxq '{"value":"first"}' "$create_once_probe" \
  || fail_test "create-once retry changed uncertain durable bytes"
durable_sync "$(dirname "$create_once_probe")" \
  || fail_test "create-once parent sync did not recover"
SYNC_FAIL_PATH=""
rm -f "$SYNC_FAIL_MARKER" "$create_once_probe"

with_boot_repair_lock || fail_test "could not lock sealed-writer check"
_transaction_active=true
_transaction_id="$root_incident_id"
_transaction_operation=repair
_transaction_target_state=active
read_transaction_manifest "$root_incident_id" || fail_test "sealed manifest unreadable"
sealed_manifest="$_manifest_json"
if write_transaction_manifest_json "$sealed_manifest" >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "general manifest writer modified a sealed root incident"
fi
_transaction_active=false
release_boot_repair_lock
[[ $(sha256_file "$root_incident_manifest") == "$root_manifest_hash" ]] \
  || fail_test "rejected root write changed the manifest"
if declare -F run_lifecycle_recovery_attempt >/dev/null \
  || declare -F run_lifecycle_recovery_attempt_with_preflight >/dev/null; then
  fail_test "T-6.1 exposed a generic stable-state recovery runner"
fi

TEST_ATTEMPT_SERVICE_STATE=$(jq -c '.service_state' "$root_incident_manifest")
previous_attempt=null
first_attempt_reference=""
for ((attempt_number = 1; attempt_number <= MAX_RECOVERY_ATTEMPT_SEALS; attempt_number++)); do
  previous_attempt=$(create_test_attempt_seal "$root_incident_reference" \
    "$previous_attempt" "$attempt_number") \
    || fail_test "could not create attempt seal ${attempt_number}"
  if [[ $attempt_number -eq 1 ]]; then
    first_attempt_reference="$previous_attempt"
  fi
done
validate_incident_chain "$root_incident_reference" "$first_attempt_reference" 1 false \
  || fail_test "attempt 1 did not validate independently"
valid_attempt_lifecycle=$(jq -c \
  --argjson latest "$previous_attempt" \
  --argjson count "$MAX_RECOVERY_ATTEMPT_SEALS" '
    .transaction.last_recovery_attempt = $latest |
    .transaction.attempt_count = $count
  ' "$(lifecycle_file_path)")
printf '%s\n' "$valid_attempt_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
read_lifecycle || fail_test "bounded attempt chain did not validate"
[[ "$_lifecycle_state" == recovery-required \
  && $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") -eq 32 ]] \
  || fail_test "bounded attempt chain replaced the root incident"
transaction_dirs=("$(transactions_dir_path)"/*)
attempt_dir_count=${#transaction_dirs[@]}
attempt_limit_state_hash=$(sha256_file "$(lifecycle_file_path)")
if recovery_attempt_capacity_available; then
  fail_test "attempt 33 was admitted"
fi
if validate_incident_chain "$root_incident_reference" "$previous_attempt" \
  "$((MAX_RECOVERY_ATTEMPT_SEALS + 1))" false; then
  fail_test "chain validator admitted attempt 33"
else
  [[ $? -eq 2 && "$_incident_read_status" == attempt-limit ]] \
    || fail_test "chain limit did not return its fixed classification"
fi
if create_test_attempt_seal "$root_incident_reference" "$previous_attempt" \
  "$((MAX_RECOVERY_ATTEMPT_SEALS + 1))" >/dev/null 2>&1; then
  fail_test "test attempt writer admitted attempt 33"
fi
transaction_dirs=("$(transactions_dir_path)"/*)
[[ ${#transaction_dirs[@]} -eq $attempt_dir_count ]] \
  || fail_test "attempt-limit check mutated transaction storage"
[[ $(sha256_file "$(lifecycle_file_path)") == "$attempt_limit_state_hash" ]] \
  || fail_test "attempt-limit check mutated lifecycle state"

attempt_limit_lifecycle=$(jq -c '.transaction.attempt_count = 33' \
  <<< "$valid_attempt_lifecycle")
printf '%s\n' "$attempt_limit_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "attempt count above the fixed bound was trusted"
fi
[[ "$_lifecycle_read_status" == attempt-limit ]] \
  || fail_test "attempt-limit state was not classified"
printf '%s\n' "$valid_attempt_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
read_lifecycle || fail_test "valid attempt chain did not recover after bound test"

latest_attempt_id=$(jq -r '.id' <<< "$previous_attempt")
latest_attempt_path=$(lifecycle_incident_path "$latest_attempt_id")
latest_attempt_original=$(jq -c . "$latest_attempt_path")
latest_attempt_tampered=$(jq -c --argjson self "$previous_attempt" \
  '.previous_attempt = $self' <<< "$latest_attempt_original")
printf '%s\n' "$latest_attempt_tampered" \
  | atomic_write_control_file "$latest_attempt_path" 600
tampered_attempt_lifecycle=$(jq -c \
  --arg hash "$(sha256_file "$latest_attempt_path")" \
  '.transaction.last_recovery_attempt.sha256 = $hash' \
  <<< "$valid_attempt_lifecycle")
printf '%s\n' "$tampered_attempt_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "attempt chain trusted a cycle or skipped ordinal"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "invalid attempt chain was not classified as ambiguous"
printf '%s\n' "$latest_attempt_original" \
  | atomic_write_control_file "$latest_attempt_path" 600
printf '%s\n' "$valid_attempt_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
read_lifecycle || fail_test "attempt chain did not recover after test restore"

latest_attempt_manifest=$(lifecycle_manifest_path "$latest_attempt_id")
latest_manifest_original=$(jq -c . "$latest_attempt_manifest")
root_service_active=$(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
  '.service_state[$unit].active_state' "$root_incident_manifest")
if [[ "$root_service_active" == active ]]; then
  mismatched_service_active=inactive
else
  mismatched_service_active=active
fi
latest_manifest_tampered=$(jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" \
  --arg active "$mismatched_service_active" \
  '.service_state[$unit].active_state = $active' <<< "$latest_manifest_original")
printf '%s\n' "$latest_manifest_tampered" \
  | atomic_write_control_file "$latest_attempt_manifest" 600
latest_seal_service_tamper=$(jq -c \
  --arg hash "$(sha256_file "$latest_attempt_manifest")" \
  '.manifest_sha256 = $hash' <<< "$latest_attempt_original")
printf '%s\n' "$latest_seal_service_tamper" \
  | atomic_write_control_file "$latest_attempt_path" 600
service_tamper_lifecycle=$(jq -c \
  --arg hash "$(sha256_file "$latest_attempt_path")" \
  '.transaction.last_recovery_attempt.sha256 = $hash' \
  <<< "$valid_attempt_lifecycle")
printf '%s\n' "$service_tamper_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "attempt chain trusted a changed root-captured service state"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "changed attempt service state was not classified as ambiguous"
printf '%s\n' "$latest_manifest_original" \
  | atomic_write_control_file "$latest_attempt_manifest" 600
printf '%s\n' "$latest_attempt_original" \
  | atomic_write_control_file "$latest_attempt_path" 600
printf '%s\n' "$valid_attempt_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
read_lifecycle || fail_test "attempt chain did not recover after service-state restore"

root_incident_original=$(jq -c . "$root_incident_path")
if read_incident_seal 00000000-0000-0000-0000-000000000001 >/dev/null 2>&1; then
  fail_test "incident reader found an absent seal"
fi
[[ "$_incident_read_status" == absent ]] \
  || fail_test "absent incident was not classified"
root_incident_newer=$(jq -c '.schema_version = 3' <<< "$root_incident_original")
printf '%s\n' "$root_incident_newer" \
  | atomic_write_control_file "$root_incident_path" 600
if read_incident_seal "$root_incident_id" >/dev/null 2>&1; then
  fail_test "incident reader accepted an unsupported schema"
fi
[[ "$_incident_read_status" == unsupported-schema ]] \
  || fail_test "unsupported incident schema was not classified"
root_incident_malformed=$(jq -c '.unexpected = null' <<< "$root_incident_original")
printf '%s\n' "$root_incident_malformed" \
  | atomic_write_control_file "$root_incident_path" 600
if read_incident_seal "$root_incident_id" >/dev/null 2>&1; then
  fail_test "incident reader accepted a malformed seal"
fi
[[ "$_incident_read_status" == malformed ]] \
  || fail_test "malformed incident was not classified"
printf '%s\n' "$root_incident_original" \
  | atomic_write_control_file "$root_incident_path" 600
latest_attempt_limit=$(jq -c \
  --argjson ordinal "$((MAX_RECOVERY_ATTEMPT_SEALS + 1))" \
  '.ordinal = $ordinal' <<< "$latest_attempt_original")
printf '%s\n' "$latest_attempt_limit" \
  | atomic_write_control_file "$latest_attempt_path" 600
if read_incident_seal "$latest_attempt_id" >/dev/null 2>&1; then
  fail_test "incident reader accepted an over-limit attempt"
fi
[[ "$_incident_read_status" == attempt-limit ]] \
  || fail_test "over-limit incident was not classified"
printf '%s\n' "$latest_attempt_original" \
  | atomic_write_control_file "$latest_attempt_path" 600
read_incident_seal "$latest_attempt_id" \
  || fail_test "attempt seal did not restore after classification tests"

root_incident_tampered=$(jq -c '.failure.reason = "tampered"' \
  <<< "$root_incident_original")
printf '%s\n' "$root_incident_tampered" \
  | atomic_write_control_file "$root_incident_path" 600
if read_recovery_incident >/dev/null 2>&1; then
  fail_test "recovery trusted a tampered root seal"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "tampered root seal was not classified as ambiguous"
printf '%s\n' "$root_incident_original" \
  | atomic_write_control_file "$root_incident_path" 600
read_recovery_incident || fail_test "root seal did not recover after test restore"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "writer-validation fixture adoption failed"
with_boot_repair_lock || fail_test "could not lock writer-validation fixture"
begin_lifecycle_transaction "writer-validation" "active" \
  || fail_test "writer-validation transaction did not start"
writer_manifest=$(lifecycle_manifest_path "$_transaction_id")
writer_hash=$(sha256_file "$writer_manifest")
read_transaction_manifest "$_transaction_id" || fail_test "writer manifest unreadable"
identity_tamper=$(jq -c '.operation = "redirected"' <<< "$_manifest_json")
if write_transaction_manifest_json "$identity_tamper" >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "manifest writer accepted an identity change"
fi
extra_field_tamper=$(jq -c '.unexpected = null' <<< "$_manifest_json")
if write_transaction_manifest_json "$extra_field_tamper" >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "manifest writer accepted an extra field"
fi
fabricated_phase=$(jq -c '.completed_phases += ["fabricated"]' <<< "$_manifest_json")
if write_transaction_manifest_json "$fabricated_phase" >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "manifest writer accepted a phase that was never started"
fi
[[ $(sha256_file "$writer_manifest") == "$writer_hash" ]] \
  || fail_test "rejected manifest candidates changed durable bytes"
transaction_phase_start "one-shot" || fail_test "one-shot phase did not start"
transaction_phase_complete "one-shot" || fail_test "one-shot phase did not complete"
completed_phase_hash=$(sha256_file "$writer_manifest")
if transaction_phase_start "one-shot" >/dev/null 2>&1; then
  release_boot_repair_lock
  fail_test "completed phase was restarted"
fi
[[ $(sha256_file "$writer_manifest") == "$completed_phase_hash" ]] \
  || fail_test "rejected phase restart changed durable bytes"
rollback_and_mark_recovery 19 "writer validation complete" failed \
  || fail_test "writer-validation transaction did not seal"
release_boot_repair_lock

reset_state
FAILPOINT=""
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "SIGKILL transition fixture adoption failed"
FAILPOINT=after-transition-write
FAILPOINT_USED=false
FAILPOINT_KILL=true
(run_lifecycle_transaction "sigkill-transition" "active" "active" noop_transaction) \
  >/dev/null 2>&1 &
kill_child=$!
if wait "$kill_child" 2>/dev/null; then
  fail_test "SIGKILL transition child reported success"
else
  kill_rc=$?
fi
[[ $kill_rc -eq 137 ]] || fail_test "SIGKILL transition child returned ${kill_rc}"
FAILPOINT=""
FAILPOINT_KILL=false
read_lifecycle || fail_test "SIGKILL transition lifecycle unreadable"
[[ "$_lifecycle_state" == transition ]] \
  || fail_test "SIGKILL before quiescing did not leave a transition"
with_boot_repair_lock || fail_test "could not lock SIGKILL transition recovery"
reconcile_stale_lifecycle || {
  release_boot_repair_lock
  fail_test "SIGKILL transition did not reconcile"
}
release_boot_repair_lock
read_lifecycle || fail_test "reconciled SIGKILL transition unreadable"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "SIGKILL transition did not publish a root incident"
sigkill_manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
sigkill_incident=$(lifecycle_incident_path "$_lifecycle_transaction_id")
jq -e '.status == "stale"' "$sigkill_manifest" >/dev/null \
  || fail_test "SIGKILL transition was not finalized stale"
jq -e --arg hash "$(sha256_file "$sigkill_manifest")" '
  .kind == "root" and .incident_status == "stale" and .manifest_sha256 == $hash
' "$sigkill_incident" >/dev/null \
  || fail_test "SIGKILL transition incident was not sealed"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "SIGKILL seal fixture adoption failed"
FAILPOINT=after-incident-write
FAILPOINT_USED=false
FAILPOINT_KILL=true
(run_lifecycle_transaction "sigkill-seal" "active" "active" failed_transaction) \
  >/dev/null 2>&1 &
kill_child=$!
if wait "$kill_child" 2>/dev/null; then
  fail_test "SIGKILL seal child reported success"
else
  kill_rc=$?
fi
[[ $kill_rc -eq 137 ]] || fail_test "SIGKILL seal child returned ${kill_rc}"
FAILPOINT=""
FAILPOINT_KILL=false
read_lifecycle || fail_test "SIGKILL seal lifecycle unreadable"
[[ "$_lifecycle_state" == transition ]] \
  || fail_test "SIGKILL seal unexpectedly published lifecycle recovery"
sealed_id="$_lifecycle_transaction_id"
sealed_manifest_path=$(lifecycle_manifest_path "$sealed_id")
sealed_incident_path=$(lifecycle_incident_path "$sealed_id")
sealed_manifest_hash=$(sha256_file "$sealed_manifest_path")
sealed_incident_hash=$(sha256_file "$sealed_incident_path")
jq -e '.status == "failed"' "$sealed_manifest_path" >/dev/null \
  || fail_test "SIGKILL seal did not finalize the manifest first"
jq -e '.kind == "root" and .incident_status == "failed"' \
  "$sealed_incident_path" >/dev/null \
  || fail_test "SIGKILL did not leave a complete incident seal"
with_boot_repair_lock || fail_test "could not lock sealed incident recovery"
reconcile_stale_lifecycle || {
  release_boot_repair_lock
  fail_test "sealed incident did not reconcile"
}
release_boot_repair_lock
read_lifecycle || fail_test "sealed incident lifecycle unreadable"
[[ "$_lifecycle_state" == recovery-required \
  && "$_lifecycle_transaction_id" == "$sealed_id" ]] \
  || fail_test "sealed incident reconciliation replaced the root"
[[ $(sha256_file "$sealed_manifest_path") == "$sealed_manifest_hash" \
  && $(sha256_file "$sealed_incident_path") == "$sealed_incident_hash" \
  && $(jq -r '.transaction.root_incident.sha256' "$(lifecycle_file_path)") == \
    "$sealed_incident_hash" ]] || fail_test "sealed incident was rewritten during publication"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "legacy-disabled fixture adoption failed"
run_lifecycle_transaction "disable-test" "disabled" "active" noop_transaction \
  || fail_test "schema-2 disabled fixture failed"
lifecycle_removal_is_allowed || fail_test "schema-2 disabled state blocked removal"
legacy_state_file=$(lifecycle_file_path)
legacy_transaction_id=$(jq -r '.last_transaction.id' "$legacy_state_file")
legacy_manifest=$(lifecycle_manifest_path "$legacy_transaction_id")
schema2_disabled_state=$(jq -c . "$legacy_state_file")
schema2_disabled_manifest=$(jq -c . "$legacy_manifest")
schema2_wrong_target=$(jq -c '.target_state = "active"' \
  <<< "$schema2_disabled_manifest")
printf '%s\n' "$schema2_wrong_target" \
  | atomic_write_control_file "$legacy_manifest" 600
schema2_wrong_target_state=$(jq -c \
  --arg hash "$(sha256_file "$legacy_manifest")" \
  '.last_transaction.manifest_sha256 = $hash' <<< "$schema2_disabled_state")
printf '%s\n' "$schema2_wrong_target_state" \
  | atomic_write_control_file "$legacy_state_file" 644
if lifecycle_removal_is_allowed; then
  fail_test "schema-2 active-target transaction authorized disabled removal"
fi
schema2_failed_rollback=$(jq -c '
  .rollback = {
    status: "failed",
    attempted_at: .completed_at,
    failures: ["/boot"]
  }
' <<< "$schema2_disabled_manifest")
printf '%s\n' "$schema2_failed_rollback" \
  | atomic_write_control_file "$legacy_manifest" 600
schema2_failed_rollback_state=$(jq -c \
  --arg hash "$(sha256_file "$legacy_manifest")" \
  '.last_transaction.manifest_sha256 = $hash' <<< "$schema2_disabled_state")
printf '%s\n' "$schema2_failed_rollback_state" \
  | atomic_write_control_file "$legacy_state_file" 644
if lifecycle_removal_is_allowed; then
  fail_test "completed transaction with failed rollback authorized removal"
fi
printf '%s\n' "$schema2_disabled_manifest" \
  | atomic_write_control_file "$legacy_manifest" 600
printf '%s\n' "$schema2_disabled_state" \
  | atomic_write_control_file "$legacy_state_file" 644
lifecycle_removal_is_allowed \
  || fail_test "schema-2 disabled state did not restore after rejection tests"
legacy_manifest_document=$(jq -c '
  del(.kind, .recovery, .domain_records) | .schema_version = 1
' "$legacy_manifest")
printf '%s\n' "$legacy_manifest_document" \
  | atomic_write_control_file "$legacy_manifest" 600
legacy_lifecycle_document=$(jq -c '{
  schema_version: 1,
  writer_version,
  generation,
  state,
  transaction: null,
  last_transaction: {
    id: .last_transaction.id,
    operation: .last_transaction.operation,
    manifest: .last_transaction.manifest,
    completed_at: .last_transaction.completed_at
  },
  adoption,
  updated_at
}' "$legacy_state_file")
printf '%s\n' "$legacy_lifecycle_document" \
  | atomic_write_control_file "$legacy_state_file" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "normal lifecycle reader accepted legacy schema 1"
fi
[[ "$_lifecycle_read_status" == unsupported-schema ]] \
  || fail_test "legacy schema was not classified as unsupported"
lifecycle_removal_is_allowed \
  || fail_test "exact legacy schema-1 disabled state blocked removal"
chmod 644 "$legacy_manifest"
if lifecycle_removal_is_allowed; then
  fail_test "publicly readable legacy manifest authorized removal"
fi
chmod 600 "$legacy_manifest"
legacy_failed_rollback_manifest=$(jq -c '
  .rollback = {
    status: "failed",
    attempted_at: .completed_at,
    failures: ["/boot"]
  }
' <<< "$legacy_manifest_document")
printf '%s\n' "$legacy_failed_rollback_manifest" \
  | atomic_write_control_file "$legacy_manifest" 600
if lifecycle_removal_is_allowed; then
  fail_test "legacy completed transaction with failed rollback authorized removal"
fi
printf '%s\n' "$legacy_manifest_document" \
  | atomic_write_control_file "$legacy_manifest" 600
legacy_active_document=$(jq -c '.state = "active"' <<< "$legacy_lifecycle_document")
printf '%s\n' "$legacy_active_document" \
  | atomic_write_control_file "$legacy_state_file" 644
if lifecycle_removal_is_allowed; then
  fail_test "legacy active state authorized removal"
fi
legacy_extra_document=$(jq -c '.unexpected = null' <<< "$legacy_lifecycle_document")
printf '%s\n' "$legacy_extra_document" \
  | atomic_write_control_file "$legacy_state_file" 644
if lifecycle_removal_is_allowed; then
  fail_test "legacy disabled state with an extra field authorized removal"
fi
legacy_value_document=$(jq -c \
  '.adoption.managed_settings[0].observed = "invented"' \
  <<< "$legacy_lifecycle_document")
printf '%s\n' "$legacy_value_document" \
  | atomic_write_control_file "$legacy_state_file" 644
if lifecycle_removal_is_allowed; then
  fail_test "legacy disabled state with an invalid setting authorized removal"
fi
legacy_null_transaction=$(jq -c '.last_transaction = null' \
  <<< "$legacy_lifecycle_document")
printf '%s\n' "$legacy_null_transaction" \
  | atomic_write_control_file "$legacy_state_file" 644
if lifecycle_removal_is_allowed; then
  fail_test "legacy disabled state without completion proof authorized removal"
fi
reset_state
lifecycle_removal_is_allowed || fail_test "pristine state blocked removal"

reset_state
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "strict-schema fixture adoption failed"
strict_state_file=$(lifecycle_file_path)
strict_state=$(jq -c . "$strict_state_file")
strict_extra=$(jq -c '.unexpected = null' <<< "$strict_state")
printf '%s\n' "$strict_extra" | atomic_write_control_file "$strict_state_file" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "lifecycle reader accepted an extra field"
fi
[[ "$_lifecycle_read_status" == malformed ]] \
  || fail_test "extra lifecycle field was not classified malformed"
strict_false=$(jq -c '.managed_settings = false' <<< "$strict_state")
printf '%s\n' "$strict_false" | atomic_write_control_file "$strict_state_file" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "lifecycle reader treated false as a nullable field"
fi
[[ "$_lifecycle_read_status" == malformed ]] \
  || fail_test "false nullable field was not classified malformed"
strict_missing=$(jq -c 'del(.tracking_ownership)' <<< "$strict_state")
printf '%s\n' "$strict_missing" | atomic_write_control_file "$strict_state_file" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "lifecycle reader accepted a missing field"
fi
[[ "$_lifecycle_read_status" == malformed ]] \
  || fail_test "missing lifecycle field was not classified malformed"
strict_reference=$(jq -c '.last_transaction.operation = "redirected"' \
  <<< "$strict_state")
printf '%s\n' "$strict_reference" \
  | atomic_write_control_file "$strict_state_file" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "lifecycle reader accepted a mismatched completed reference"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "mismatched completed reference was not classified ambiguous"
printf '%s\n' "$strict_state" | atomic_write_control_file "$strict_state_file" 644
read_lifecycle || fail_test "strict lifecycle fixture did not restore"
strict_manifest_id=$(jq -r '.last_transaction.id' <<< "$strict_state")
strict_manifest_path=$(lifecycle_manifest_path "$strict_manifest_id")
strict_manifest=$(jq -c . "$strict_manifest_path")
strict_manifest_extra=$(jq -c '.unexpected = null' <<< "$strict_manifest")
printf '%s\n' "$strict_manifest_extra" \
  | atomic_write_control_file "$strict_manifest_path" 600
if read_transaction_manifest "$strict_manifest_id" >/dev/null 2>&1; then
  fail_test "manifest reader accepted an extra field"
fi
strict_manifest_extra_state=$(jq -c \
  --arg hash "$(sha256_file "$strict_manifest_path")" \
  '.last_transaction.manifest_sha256 = $hash' <<< "$strict_state")
printf '%s\n' "$strict_manifest_extra_state" \
  | atomic_write_control_file "$strict_state_file" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "stable lifecycle reader accepted a malformed completed manifest"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "malformed completed manifest was not classified ambiguous"
printf '%s\n' "$strict_state" | atomic_write_control_file "$strict_state_file" 644
strict_manifest_false=$(jq -c '.recovery = false' <<< "$strict_manifest")
printf '%s\n' "$strict_manifest_false" \
  | atomic_write_control_file "$strict_manifest_path" 600
if read_transaction_manifest "$strict_manifest_id" >/dev/null 2>&1; then
  fail_test "manifest reader treated false as a nullable field"
fi
printf '%s\n%s\n' "$strict_manifest" "$strict_manifest" \
  | atomic_write_control_file "$strict_manifest_path" 600
if read_transaction_manifest "$strict_manifest_id" >/dev/null 2>&1; then
  fail_test "manifest reader accepted a JSON stream"
fi
printf '%s\n' "$strict_manifest" \
  | atomic_write_control_file "$strict_manifest_path" 600

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
schema_state=$(jq -c . "$(lifecycle_file_path)")
jq '.schema_version = 3' "$(lifecycle_file_path)" > "$schema_tmp"
atomic_write_control_file "$(lifecycle_file_path)" 644 < "$schema_tmp"
if read_lifecycle >/dev/null 2>&1; then
  fail_test "unknown lifecycle schema was trusted"
fi
[[ "$_lifecycle_read_status" == unsupported-schema ]] \
  || fail_test "unknown lifecycle schema was not classified"
printf '%s\n' "$schema_state" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
read_lifecycle || fail_test "schema fixture did not restore"

read_lifecycle_definition=$(declare -f read_lifecycle)
full_restore_definition=$(declare -f is_full_snapshot_restore_hook)
# shellcheck disable=SC2329 # Invoked through lifecycle state consumers.
read_lifecycle() {
  _lifecycle_read_status=supported
  _lifecycle_state=invented
  return 0
}
if lifecycle_hook_pre >/dev/null 2>&1; then
  fail_test "pre-hook accepted an unrecognized lifecycle state"
else
  [[ $? -eq 100 ]] || fail_test "pre-hook used a non-blocking unknown-state code"
fi
if lifecycle_hook_post : >/dev/null 2>&1; then
  fail_test "post-hook accepted an unrecognized lifecycle state"
else
  [[ $? -eq 100 ]] || fail_test "post-hook used a non-blocking unknown-state code"
fi
if guard_boot_transaction >/dev/null 2>&1; then
  fail_test "package guard accepted an unrecognized lifecycle state"
else
  [[ $? -eq 1 ]] || fail_test "package guard used an unexpected unknown-state code"
fi
if lifecycle_automation_is_active >/dev/null 2>&1; then
  fail_test "automation accepted an unrecognized lifecycle state"
else
  [[ $? -eq 2 ]] || fail_test "automation did not classify unknown state as unsafe"
fi
if show_lifecycle_status >/dev/null 2>&1; then
  fail_test "status accepted an unrecognized lifecycle state"
fi
is_full_snapshot_restore_hook() {
  return 0
}
if lifecycle_hook_pre >/dev/null 2>&1; then
  fail_test "full-restore admission accepted an unrecognized lifecycle state"
else
  [[ $? -eq 100 ]] || fail_test "full-restore unknown state was not blocking"
fi
full_restore_read_count=0
# shellcheck disable=SC2329 # Invoked through lifecycle_hook_pre.
read_lifecycle() {
  full_restore_read_count=$((full_restore_read_count + 1))
  _lifecycle_read_status=supported
  if [[ $full_restore_read_count -eq 1 ]]; then
    _lifecycle_state=disabled
  else
    _lifecycle_state=active
  fi
  return 0
}
if lifecycle_hook_pre >/dev/null 2>&1; then
  fail_test "full-restore admission ignored a concurrent active state"
else
  [[ $? -eq 100 ]] || fail_test "full-restore race was not blocking"
fi
eval "$read_lifecycle_definition"
eval "$full_restore_definition"
read_lifecycle || fail_test "lifecycle reader did not restore after state-default tests"

printf 'lifecycle tests passed\n'
