#!/bin/bash
# shellcheck disable=SC2154 # Assertions read globals set by lifecycle functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init lifecycle

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/lifecycle.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/records.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/software.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/status.sh"

[[ $(windows_bootnext_variable_path) == \
  /sys/firmware/efi/efivars/BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c ]] \
  || fail_test "lifecycle does not own the canonical BootNext variable path"
[[ $(limine_lock_path) == /run/lock/boot-partition.lock ]] \
  || fail_test "lifecycle does not use the boot-partition lock shared with the Limine tools"
[[ $(snapshot_restore_lock_path) == /run/lock/limine-snapper-restore.lock ]] \
  || fail_test "lifecycle does not watch the limine-snapper-restore marker pathname"

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

FAILPOINT=""
FAILPOINT_USED=false
FAILPOINT_KILL=false
PACKAGE_LOCK_FAILPOINT=""

lifecycle_failpoint() {
  if [[ -n "$PACKAGE_LOCK_FAILPOINT" && "$PACKAGE_LOCK_FAILPOINT" == "$1" ]]; then
    : > "$(pacman_database_lock_path)"
    PACKAGE_LOCK_FAILPOINT=""
  fi
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
  rm -f "$(pacman_database_lock_path)"
  PACKAGE_LOCK_FAILPOINT=""
  SYNC_FAIL_PATH=""
  SYNC_FAIL_REQUIRE_PATH=""
  rm -f "$SYNC_FAIL_MARKER"
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
  _recovery_root_reference=""
  _recovery_root_manifest_json=""
  _recovery_previous_reference="null"
  _recovery_previous_manifest_json=""
  _recovery_attempt_count=0
  _recovery_target_state=""
  _recovery_producer_reference="null"
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

# The second backup's manifest write fails after the rename, so the manifest on
# disk references a copy whose publication was uncertain.
manifest_read_failure_transaction() {
  transaction_phase_start "backup-files"
  transaction_backup_file "$PRESENT_FILE"
  printf 'changed before manifest publication\n' > "$PRESENT_FILE"
  arm_sync_failure "$(dirname "$(lifecycle_manifest_path "$_transaction_id")")"
  transaction_backup_file "$SECOND_FILE"
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
  preserve_transaction_files_on_failure || return 1
  return 30
}

firmware_ledger_manifest() {
  local manifest="$1" writes="$2" id digest
  id=$(jq -r '.id' <<< "$manifest") || return 1
  digest=$(printf '0%.0s' {1..64})
  jq -c --arg id "$id" --arg digest "$digest" --argjson writes "$writes" '
    .file_rollback_policy = "preserve" |
    .firmware_backup = {
      id: $id,
      path: ("/firmware-backup/" + $id),
      status: "complete",
      manifest_sha256: $digest
    } |
    .enrollment_plan = {
      backup_id: $id,
      path: ("/firmware-backup/" + $id + "/plan"),
      manifest_sha256: $digest,
      variables: {
        PK: {esl_sha256: $digest, entries_sha256: $digest},
        KEK: {esl_sha256: $digest, entries_sha256: $digest},
        db: {esl_sha256: $digest, entries_sha256: $digest}
      },
      dbx: {present: true, raw_sha256: $digest}
    } |
    .firmware_writes = $writes
  ' <<< "$manifest"
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

create_test_attempt_seal() {
  local root_reference="$1" previous_reference="$2" ordinal="$3"
  local status="${4:-failed}" transaction_id transaction_dir manifest incident
  local prior_backup prior_hash timestamp failure rollback document hash
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
    --argjson failure "$failure" \
    --argjson rollback "$rollback" \
    --argjson current_phase "$current_phase" \
    --argjson completed_phases "$completed_phases" '{
      schema_version: $schema,
      writer_version: $version,
      id: $id,
      kind: "recovery-attempt",
      operation: "firmware-recovery",
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
      file_rollback_policy: "preserve",
      firmware_backup: null,
      enrollment_plan: null,
      firmware_writes: [],
      domain_records: {
        bootnext: null,
        final_proof: null,
        firmware: null,
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
      operation: "firmware-recovery",
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
  "no" "unknown" "yes" "unset" "absent" "unknown" "absent" "unknown" \
  > "${TEST_DIR}/rejected-preflight.out" 2>&1; then
  fail_test "rejected adoption preflight succeeded"
fi
grep -Fq 'Operation adopt preflight failed; no transaction was started' \
  "${TEST_DIR}/rejected-preflight.out" \
  || fail_test "rejected adoption preflight gave no reason"
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
jq -e '.schema_version == 2 and .writer_version == "1.0.0" and .managed_settings != null' \
  "$state_file" >/dev/null || fail_test "adoption did not record managed settings"
adoption_record=$(jq -r '.managed_settings.path' "$state_file")
jq -e '
  .source == "adoption" and
  .settings == [
    {"path": "/etc/default/limine", "key": "ENABLE_VERIFICATION", "managed": "no",
      "original": "unknown"},
    {"path": "/etc/default/limine", "key": "ENABLE_ENROLL_LIMINE_CONFIG", "managed": "yes",
      "original": "unset"},
    {"path": "/etc/default/limine", "key": "COMMANDS_BEFORE_SAVE", "token": "limine-reset-enroll",
      "managed": "absent", "original": "unknown"},
    {"path": "/etc/default/limine", "key": "COMMANDS_AFTER_SAVE", "token": "limine-enroll-config",
      "managed": "absent", "original": "unknown"}
  ]
' "$adoption_record" >/dev/null || fail_test "adoption record is incomplete"

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
  }]
' "$adoption_manifest" >/dev/null || fail_test "adoption manifest is incomplete"

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
SECOND_FILE="${file_fixture_dir}/second"
export PRESENT_FILE ABSENT_FILE SECOND_FILE
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

ledger_id=$_lifecycle_transaction_id
ledger_base=$(jq -c . "$(lifecycle_manifest_path "$ledger_id")")
ledger_timestamp=$(jq -r '.created_at' <<< "$ledger_base")
legal_retries=$(jq -cn --arg timestamp "$ledger_timestamp" '[
  {hierarchy:"db",started_at:$timestamp,command_exit_code:null,
    readback_status:"unchanged",completed_at:$timestamp},
  {hierarchy:"db",started_at:$timestamp,command_exit_code:0,
    readback_status:"verified",completed_at:$timestamp},
  {hierarchy:"KEK",started_at:$timestamp,command_exit_code:null,
    readback_status:"unchanged",completed_at:$timestamp},
  {hierarchy:"KEK",started_at:$timestamp,command_exit_code:0,
    readback_status:"verified",completed_at:$timestamp},
  {hierarchy:"PK",started_at:$timestamp,command_exit_code:null,
    readback_status:"unchanged",completed_at:$timestamp},
  {hierarchy:"PK",started_at:$timestamp,command_exit_code:0,
    readback_status:"verified",completed_at:$timestamp}
]')
ledger_document=$(firmware_ledger_manifest "$ledger_base" "$legal_retries")
validate_transaction_manifest_json "$ledger_id" "$ledger_document" false \
  || fail_test "legal firmware retry ledger was rejected"
known_result_pending=$(jq -cn --arg timestamp "$ledger_timestamp" '[{
  hierarchy:"db",started_at:$timestamp,command_exit_code:31,
  readback_status:"pending",completed_at:null
}]')
ledger_document=$(firmware_ledger_manifest "$ledger_base" "$known_result_pending")
validate_transaction_manifest_json "$ledger_id" "$ledger_document" false \
  || fail_test "known firmware command result with pending readback was rejected"
null_result_reconciled=$(jq -cn --arg timestamp "$ledger_timestamp" '[{
  hierarchy:"db",started_at:$timestamp,command_exit_code:null,
  readback_status:"verified",completed_at:$timestamp
}]')
ledger_document=$(firmware_ledger_manifest "$ledger_base" "$null_result_reconciled")
validate_transaction_manifest_json "$ledger_id" "$ledger_document" false \
  || fail_test "reconciled unknown firmware command result was rejected"
second_pending=$(jq -c '. + [.[0]]' <<< "$known_result_pending")
ledger_document=$(firmware_ledger_manifest "$ledger_base" "$second_pending")
if validate_transaction_manifest_json "$ledger_id" "$ledger_document" false; then
  fail_test "firmware ledger accepted a record after pending readback"
fi
skipped_hierarchy=$(jq -cn --arg timestamp "$ledger_timestamp" '[{
  hierarchy:"KEK",started_at:$timestamp,command_exit_code:0,
  readback_status:"verified",completed_at:$timestamp
}]')
ledger_document=$(firmware_ledger_manifest "$ledger_base" "$skipped_hierarchy")
if validate_transaction_manifest_json "$ledger_id" "$ledger_document" false; then
  fail_test "firmware ledger accepted a skipped hierarchy"
fi
failed_then_retry=$(jq -cn --arg timestamp "$ledger_timestamp" '[
  {hierarchy:"db",started_at:$timestamp,command_exit_code:1,
    readback_status:"failed",completed_at:$timestamp},
  {hierarchy:"db",started_at:$timestamp,command_exit_code:0,
    readback_status:"verified",completed_at:$timestamp}
]')
ledger_document=$(firmware_ledger_manifest "$ledger_base" "$failed_then_retry")
if validate_transaction_manifest_json "$ledger_id" "$ledger_document" false; then
  fail_test "firmware ledger accepted a record after terminal failure"
fi
third_db_attempt=$(jq -cn --arg timestamp "$ledger_timestamp" '[
  {hierarchy:"db",started_at:$timestamp,command_exit_code:1,
    readback_status:"unchanged",completed_at:$timestamp},
  {hierarchy:"db",started_at:$timestamp,command_exit_code:1,
    readback_status:"unchanged",completed_at:$timestamp},
  {hierarchy:"db",started_at:$timestamp,command_exit_code:null,
    readback_status:"pending",completed_at:null}
]')
ledger_document=$(firmware_ledger_manifest "$ledger_base" "$third_db_attempt")
if validate_transaction_manifest_json "$ledger_id" "$ledger_document" false; then
  fail_test "firmware ledger accepted a third command attempt"
fi

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

# When the confirming read after an uncertain manifest write also fails, the
# copy stays: only a successful re-read proving it unreferenced may delete it.
reset_state
printf 'original\n' > "$PRESENT_FILE"
printf 'second original\n' > "$SECOND_FILE"
adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent" \
  || fail_test "manifest-read fixture adoption failed"
read_manifest_definition=$(declare -f read_transaction_manifest)
eval "original_${read_manifest_definition}"
READ_FAIL_ARMED=true
read_transaction_manifest() {
  if [[ "$READ_FAIL_ARMED" == true && -e "$SYNC_FAIL_MARKER" ]]; then
    READ_FAIL_ARMED=false
    return 1
  fi
  original_read_transaction_manifest "$@"
}
if run_lifecycle_transaction "manifest-read-failure" "active" "active" \
  manifest_read_failure_transaction; then
  fail_test "manifest write with a failed confirming read reported success"
fi
eval "$read_manifest_definition"
unset -f original_read_transaction_manifest
SYNC_FAIL_PATH=""
rm -f "$SYNC_FAIL_MARKER"
[[ "$READ_FAIL_ARMED" == false ]] || fail_test "the confirming read was never exercised"
read_lifecycle || fail_test "manifest-read failure left the lifecycle unreadable"
[[ "$_lifecycle_state" == recovery-required ]] \
  || fail_test "manifest-read failure did not require recovery"
read_failure_manifest=$(lifecycle_manifest_path "$_lifecycle_transaction_id")
[[ -e "$(dirname "$read_failure_manifest")/file-2.backup" ]] \
  || fail_test "uncertain manifest write deleted a backup the manifest references"
jq -e '.status == "failed" and .rollback.status == "completed" and
  ([.backups[] | select(.kind == "file")] | length) == 2' \
  "$read_failure_manifest" >/dev/null \
  || fail_test "manifest with a kept backup did not validate and roll back"
grep -Fxq original "$PRESENT_FILE" \
  || fail_test "rollback with a kept backup did not restore the first file"
grep -Fxq 'second original' "$SECOND_FILE" \
  || fail_test "rollback with a kept backup changed the second file"

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

reset_state
PACKAGE_LOCK_FAILPOINT=after-manifest-write
if adopt_lifecycle : "no" "no" "yes" "yes" \
  "absent" "absent" "absent" "absent"; then
  fail_test "late package boundary succeeded"
fi
read_lifecycle || fail_test "late package boundary damaged lifecycle readability"
[[ $_lifecycle_state == unmanaged ]] \
  || fail_test "late package boundary published transition state"
rm -f "$(pacman_database_lock_path)"

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
: > "$(snapshot_restore_lock_path)"
if reconcile_stale_lifecycle > "${TEST_DIR}/stale-marker.out" 2>&1; then
  fail_test "stale transition was reconciled while the full-restore marker existed"
fi
grep -Fq 'blocked while full snapshot restore is running' "${TEST_DIR}/stale-marker.out" \
  || fail_test "marker refusal omitted its reason"
read_lifecycle || fail_test "marker-blocked lifecycle could not be read"
[[ $_lifecycle_state == transition ]] \
  || fail_test "marker refusal changed durable state"
rm -f "$(snapshot_restore_lock_path)"
reconcile_stale_lifecycle || fail_test "stale transition was not reconciled"
release_boot_repair_lock
read_lifecycle || fail_test "reconciled lifecycle could not be read"
[[ $_lifecycle_state == recovery-required ]] \
  || fail_test "stale transition did not require recovery"
jq -e '.status == "stale" and
  .failure.reason == "transaction owner is no longer valid"' \
  "$stale_manifest" >/dev/null || fail_test "stale owner was not recorded"

reset_state
FAILPOINT=""
FAILPOINT_KILL=false
adopt_lifecycle : "no" "no" "yes" "no" "absent" "absent" "absent" "absent" \
  || fail_test "incident fixture adoption failed"
if run_lifecycle_transaction "enroll-secure-boot" "active" "active" failed_transaction; then
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
with_boot_repair_lock
load_recovery_context || fail_test "sealed root incident did not validate"
release_boot_repair_lock
[[ $(jq -r '.kind' <<< "$_recovery_root_manifest_json") == root ]] \
  || fail_test "recovery context did not load the root manifest"
if printf '%s\n' "$(<"$root_incident_path")" \
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
  fail_test "a generic stable-state recovery runner must not exist"
fi

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
with_boot_repair_lock
capacity_rc=0
load_recovery_context || capacity_rc=$?
release_boot_repair_lock
[[ $capacity_rc -eq 2 && "$_incident_read_status" == attempt-limit ]] \
  || fail_test "attempt 33 was admitted"
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
latest_manifest_tampered=$(jq -c '.operation = "producer-recovery"' \
  <<< "$latest_manifest_original")
printf '%s\n' "$latest_manifest_tampered" \
  | atomic_write_control_file "$latest_attempt_manifest" 600
latest_seal_operation_tamper=$(jq -c \
  --arg hash "$(sha256_file "$latest_attempt_manifest")" '
    .operation = "producer-recovery" | .manifest_sha256 = $hash
  ' <<< "$latest_attempt_original")
printf '%s\n' "$latest_seal_operation_tamper" \
  | atomic_write_control_file "$latest_attempt_path" 600
operation_tamper_lifecycle=$(jq -c \
  --arg hash "$(sha256_file "$latest_attempt_path")" '
    .transaction.last_recovery_attempt.operation = "producer-recovery" |
    .transaction.last_recovery_attempt.sha256 = $hash
  ' <<< "$valid_attempt_lifecycle")
printf '%s\n' "$operation_tamper_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "firmware root accepted a producer recovery attempt"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "cross-domain recovery was not classified as ambiguous"

latest_manifest_tampered=$(jq -c '.file_rollback_policy = "restore"' \
  <<< "$latest_manifest_original")
printf '%s\n' "$latest_manifest_tampered" \
  | atomic_write_control_file "$latest_attempt_manifest" 600
latest_seal_policy_tamper=$(jq -c \
  --arg hash "$(sha256_file "$latest_attempt_manifest")" \
  '.manifest_sha256 = $hash' <<< "$latest_attempt_original")
printf '%s\n' "$latest_seal_policy_tamper" \
  | atomic_write_control_file "$latest_attempt_path" 600
policy_tamper_lifecycle=$(jq -c \
  --arg hash "$(sha256_file "$latest_attempt_path")" \
  '.transaction.last_recovery_attempt.sha256 = $hash' \
  <<< "$valid_attempt_lifecycle")
printf '%s\n' "$policy_tamper_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
if read_lifecycle >/dev/null 2>&1; then
  fail_test "recovery chain accepted rollback-policy regression"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "rollback-policy regression was not classified as ambiguous"
printf '%s\n' "$latest_manifest_original" \
  | atomic_write_control_file "$latest_attempt_manifest" 600
printf '%s\n' "$latest_attempt_original" \
  | atomic_write_control_file "$latest_attempt_path" 600
printf '%s\n' "$valid_attempt_lifecycle" \
  | atomic_write_control_file "$(lifecycle_file_path)" 644
read_lifecycle || fail_test "attempt chain did not recover after domain tests"

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
if read_lifecycle >/dev/null 2>&1; then
  fail_test "lifecycle trusted a tampered root seal"
fi
[[ "$_lifecycle_read_status" == control-state-ambiguous ]] \
  || fail_test "tampered root seal was not classified as ambiguous"
printf '%s\n' "$root_incident_original" \
  | atomic_write_control_file "$root_incident_path" 600
read_lifecycle || fail_test "root seal did not recover after test restore"

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
writer_limine_lock_mode=$_OMASECBOOT_LIMINE_LOCK_OWNED
_OMASECBOOT_LIMINE_LOCK_OWNED=false
if rollback_and_mark_recovery 19 "unlocked writer validation" failed; then
  _OMASECBOOT_LIMINE_LOCK_OWNED=$writer_limine_lock_mode
  release_boot_repair_lock
  fail_test "rollback wrote state without the Limine lock"
fi
_OMASECBOOT_LIMINE_LOCK_OWNED=$writer_limine_lock_mode
[[ $(sha256_file "$writer_manifest") == "$completed_phase_hash" ]] \
  || fail_test "unlocked rollback changed durable bytes"
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
  || fail_test "active disable-refusal fixture adoption failed"
if run_lifecycle_transaction "disable-test" "disabled" "active" noop_transaction; then
  fail_test "generic active transaction committed disabled state"
fi
read_lifecycle || fail_test "blocked generic disable damaged lifecycle state"
[[ "$_lifecycle_state" == active ]] || fail_test "blocked generic disable changed stable state"

reset_state
run_lifecycle_transaction "disable-test" "disabled" "unmanaged" noop_transaction \
  || fail_test "schema-2 disabled fixture failed"
if lifecycle_removal_is_allowed; then
  fail_test "schema-2 disabled state without unconfiguration proof allowed removal"
fi
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
if lifecycle_removal_is_allowed; then
  fail_test "restored schema-2 disabled state bypassed unconfiguration proof"
fi

# Setup preparation leaves boot artifacts alone, so a preparation lineage from
# a pristine start keeps the package removable; a generic transaction in that
# lineage does not.
reset_state
run_lifecycle_transaction "prepare-secure-boot" "disabled" "unmanaged" noop_transaction \
  || fail_test "preparation from pristine state failed"
lifecycle_removal_is_allowed \
  || fail_test "preparation from pristine state blocked removal"
run_lifecycle_transaction "prepare-secure-boot" "disabled" "disabled" noop_transaction \
  || fail_test "repeated preparation failed"
lifecycle_removal_is_allowed \
  || fail_test "a preparation lineage from pristine state blocked removal"
run_lifecycle_transaction "disable-test" "disabled" "disabled" noop_transaction \
  || fail_test "generic disabled transaction failed"
if lifecycle_removal_is_allowed; then
  fail_test "a generic transaction in the disabled lineage allowed removal"
fi
run_lifecycle_transaction "prepare-secure-boot" "disabled" "disabled" noop_transaction \
  || fail_test "preparation after a generic transaction failed"
if lifecycle_removal_is_allowed; then
  fail_test "preparation laundered a generic transaction in the disabled lineage"
fi

# A prior hop's manifest rewritten in place under its own id no longer matches
# the hash the prior lifecycle document recorded, so the lineage is refused
# even when the rewritten content would qualify.
reset_state
run_lifecycle_transaction "disable-test" "disabled" "unmanaged" noop_transaction \
  || fail_test "generic transaction from pristine state failed"
generic_manifest=$(lifecycle_manifest_path \
  "$(jq -r '.last_transaction.id' "$(lifecycle_file_path)")")
run_lifecycle_transaction "prepare-secure-boot" "disabled" "disabled" noop_transaction \
  || fail_test "preparation after a pristine generic transaction failed"
if lifecycle_removal_is_allowed; then
  fail_test "a generic transaction at the start of the disabled lineage allowed removal"
fi
jq -c '.operation = "prepare-secure-boot"' "$generic_manifest" \
  | atomic_write_control_file "$generic_manifest" 600
if lifecycle_removal_is_allowed; then
  fail_test "a prior manifest rewritten under its own id was accepted without its recorded hash"
fi

reset_state
lifecycle_removal_is_allowed || fail_test "pristine state blocked removal"
package_lock=$(pacman_database_lock_path)
: > "$package_lock"
chmod 644 "$package_lock"
if adopt_lifecycle : "no" "no" "yes" "no" \
  "absent" "absent" "absent" "absent" >/dev/null 2>&1; then
  fail_test "active package transaction admitted lifecycle adoption"
fi
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "package-transaction rejection wrote lifecycle state"
rm -f "$package_lock"
create_package_lock_preflight() {
  : > "$package_lock"
  chmod 644 "$package_lock"
}
if adopt_lifecycle create_package_lock_preflight "no" "no" "yes" "no" \
  "absent" "absent" "absent" "absent" >/dev/null 2>&1; then
  fail_test "package transaction starting during adoption was not rechecked"
fi
[[ ! -e "$(lifecycle_file_path)" ]] \
  || fail_test "late package-transaction rejection wrote lifecycle state"
rm -f "$package_lock"

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
# shellcheck disable=SC2329 # Invoked through lifecycle state consumers.
read_lifecycle() {
  _lifecycle_read_status=supported
  _lifecycle_state=invented
  return 0
}
if show_lifecycle_status >/dev/null 2>&1; then
  fail_test "status accepted an unrecognized lifecycle state"
fi
eval "$read_lifecycle_definition"
read_lifecycle || fail_test "lifecycle reader did not restore after state-default tests"

printf 'lifecycle tests passed\n'
