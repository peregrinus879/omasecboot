#!/bin/bash
# OmaSecBoot: durable lifecycle, transaction, and hook ownership protocol

readonly LIFECYCLE_SCHEMA_VERSION=2
readonly LEGACY_LIFECYCLE_SCHEMA_VERSION=1
readonly PRODUCER_RECORD_SCHEMA_VERSION=1
readonly PRODUCER_BASELINE_SCHEMA_VERSION=1
readonly LEGACY_FINAL_PROOF_SCHEMA_VERSION=1
readonly FINAL_PROOF_SCHEMA_VERSION=2
readonly FIRMWARE_PROOF_SCHEMA_VERSION=1
readonly MAX_RECOVERY_ATTEMPT_SEALS=32
readonly MAX_TRANSACTION_BACKUPS=4096
readonly MAX_CONTROL_DOCUMENT_BYTES=1048576
readonly MAX_PRODUCER_TARGETS=16384
# shellcheck disable=SC2034 # Consumed by the producer module.
readonly MAX_PRODUCER_TARGET_BYTES=491520
readonly MAX_EXPECTED_EFI_ARTIFACTS=4096
readonly MAX_FIRMWARE_WRITE_ATTEMPTS=6
readonly MAX_FIRMWARE_HIERARCHY_ATTEMPTS=2
readonly TRANSACTION_SERVICE_UNIT="limine-snapper-sync.service"

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
_recovery_root_reference=""
_recovery_root_manifest_json=""
_recovery_previous_reference="null"
_recovery_attempt_count=0
_recovery_target_state=""
_recovery_producer_reference="null"
_transaction_active=false
_transaction_id=""
_transaction_token=""
_transaction_operation=""
_transaction_target_state=""
_recovery_incident_json=""
_OMASECBOOT_FULL_RESTORE_POST=false
_transaction_previous_exit=""
_transaction_previous_int=""
_transaction_previous_term=""
_transaction_previous_hup=""

lifecycle_failpoint() {
  return 0
}

lifecycle_repair_is_available() {
  return 1
}

producer_recovery_is_available() {
  return 0
}

firmware_recovery_is_available() {
  return 1
}

lifecycle_file_path() {
  printf '%s/lifecycle.json\n' "$(state_dir_path)"
}

transactions_dir_path() {
  printf '%s/transactions\n' "$(state_dir_path)"
}

snapshot_restore_lock_path() {
  printf '/run/lock/limine-snapper-restore.lock\n'
}

pacman_database_lock_path() {
  printf '/var/lib/pacman/db.lck\n'
}

lifecycle_package_boundary_is_clear() {
  local path
  path=$(pacman_database_lock_path) || return 1
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  validate_control_file "$path" || {
    fail "Lifecycle mutation blocked by an unsafe package-manager lock"
    return 1
  }
  fail "Lifecycle mutation blocked while a package transaction is running"
  return 1
}

lifecycle_manifest_path() {
  local transaction_id="$1"
  [[ "$transaction_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || return 1
  printf '%s/%s/manifest.json\n' "$(transactions_dir_path)" "$transaction_id"
}

lifecycle_incident_path() {
  local transaction_id="$1" manifest
  manifest=$(lifecycle_manifest_path "$transaction_id") || return 1
  printf '%s/incident.json\n' "$(dirname "$manifest")"
}

transaction_artifact_reference() {
  local path="$1" schema_version="${2:-1}" hash
  [[ "$schema_version" =~ ^[1-9][0-9]*$ ]] || return 1
  validate_private_control_file "$path" || return 1
  hash=$(sha256_file "$path") || return 1
  jq -cn --arg path "$path" --arg hash "$hash" \
    --argjson schema "$schema_version" '{
      path: $path,
      schema_version: $schema,
      sha256: $hash
    }'
}

validate_producer_baseline_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" \
    --argjson schema "$PRODUCER_BASELINE_SCHEMA_VERSION" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def identity: type == "string" and test("^[0-9]+:[0-9]+$");
    type == "object" and
    keys == ["artifacts","captured_at","schema_version","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.captured_at | timestamp) and
    (.artifacts | type == "array" and length >= 2 and length <= 4096) and
    (all(.artifacts[];
      type == "object" and keys == ["identity","kind","path","presence","sha256"] and
      (.kind == "config" or .kind == "defaults" or .kind == "efi" or
        .kind == "tracking") and
      (.path | absolute_path) and
      (if .presence == "present" then (.identity | identity) and (.sha256 | digest)
       elif .presence == "absent" then .identity == null and .sha256 == null
       else false end))) and
    ([.artifacts[].path] == ([.artifacts[].path] | sort | unique)) and
    ([.artifacts[] | select(.kind == "config")] | length) == 1 and
    ([.artifacts[] | select(.kind == "defaults")] | length) == 1
  ' <<< "$document" >/dev/null
}

validate_producer_record_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson owner_uid "$(control_owner_uid)" \
    --argjson schema "$PRODUCER_RECORD_SCHEMA_VERSION" \
    --argjson max_targets "$MAX_PRODUCER_TARGETS" \
    --arg restore_marker_path "$(snapshot_restore_lock_path)" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def operation:
      type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9-]*$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    def artifact_reference:
      type == "object" and keys == ["path","schema_version","sha256"] and
      (.path | absolute_path) and .schema_version == 1 and (.sha256 | digest);
    def process_identity:
      type == "object" and
      keys == ["boot_id","identity","identity_kind","pid","start_time","uid"] and
      (.boot_id | uuid) and (.identity | absolute_path) and
      (.identity_kind == "executable" or .identity_kind == "script") and
      (.pid | type == "number" and . > 0 and floor == .) and
      (.start_time | type == "string" and test("^[0-9]+$") and length <= 32) and
      .uid == $owner_uid;
    def restore_marker_reference:
      type == "object" and keys == ["identity","path"] and
      .path == $restore_marker_path and
      (.identity | type == "string" and test("^[0-9]+:[0-9]+$") and length <= 64);
    def target:
      type == "string" and length > 0 and length <= 4096 and
      (startswith("/") | not) and (explode | all(.[]; . >= 32 and . != 127));
    type == "object" and
    keys == ["baseline","created_at","invocation","lock_policy","operation","owner",
      "producer_class","restore_marker","schema_version","service_owner","service_policy",
      "subtype","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.created_at | timestamp) and (.operation | operation) and
    (.baseline | artifact_reference) and (.owner | process_identity) and
    (.service_owner == null or (.service_owner | process_identity)) and
    (.service_policy == "quiesce" or .service_policy == "preserve-owner") and
    (.lock_policy == "coordinator-lease" or .lock_policy == "inherited" or
      .lock_policy == "restore-window") and
    (.invocation | type == "object" and
      keys == ["caller","no_mutex","restore","targets"] and
      (.caller | type == "string" and length > 0 and length <= 64 and
        test("^[a-z0-9][a-z0-9-]*$")) and
      (.no_mutex | type == "boolean") and (.restore | type == "boolean") and
      (.targets | type == "array" and length <= $max_targets and all(.[]; target)) and
      (.targets == (.targets | sort | unique))) and
    if .producer_class == "package" then
      .operation == "producer-package" and .subtype == "package-transaction" and
      .owner.identity_kind == "executable" and .owner.identity == "/usr/bin/pacman" and
      .invocation.caller == "pacman" and .invocation.restore == false and
      .invocation.no_mutex == false and (.invocation.targets | length) > 0 and
      .lock_policy == "coordinator-lease" and .service_policy == "quiesce" and
      .service_owner == null and .restore_marker == null
    elif .producer_class == "limine" then
      ((.subtype == "entry-tool" and .owner.identity == "/usr/bin/limine-entry-tool" and
          .invocation.caller == "limine-entry-tool") or
       (.subtype == "uki-build" and
          .owner.identity == "/usr/share/libalpm/scripts/limine-mkinitcpio-install" and
          .invocation.caller == "limine-mkinitcpio-install")) and
      .operation == "producer-limine" and .owner.identity_kind == "script" and
      .invocation.restore == false and .invocation.no_mutex == false and
      .invocation.targets == [] and .lock_policy == "inherited" and
      .service_policy == "quiesce" and .service_owner == null and .restore_marker == null
    elif .producer_class == "snapshot" then
      .operation == "producer-snapshot" and .subtype == "snapshot-sync" and
      .owner.identity_kind == "script" and .owner.identity == "/usr/bin/limine-snapper-sync" and
      .invocation.caller == "limine-snapper-sync" and .invocation.restore == false and
      .invocation.no_mutex == false and .invocation.targets == [] and
      .lock_policy == "inherited" and
      (if .service_policy == "preserve-owner" then
        .service_owner != null and .service_owner.identity_kind == "script" and
        .service_owner.identity == "/usr/bin/limine-snapper-watcher"
       else .service_owner == null end)
      and .restore_marker == null
    elif .producer_class == "restore" then
      .operation == "producer-restore" and .subtype == "full-restore" and
      .owner.identity_kind == "script" and .owner.identity == "/usr/bin/limine-snapper-sync" and
      (.invocation.caller == "limine-snapper-sync" or
        .invocation.caller == "limine-snapper-restore") and
      .invocation.restore == true and .invocation.no_mutex == true and
      .invocation.targets == [] and .lock_policy == "restore-window" and
      .service_policy == "quiesce" and .service_owner == null and
      (.restore_marker | restore_marker_reference)
    else false end
  ' <<< "$document" >/dev/null
}

validate_efi_obligations_json() {
  local document="$1"
  jq -e --argjson maximum "$MAX_EXPECTED_EFI_ARTIFACTS" '
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    type == "object" and keys == ["kind","paths"] and
    (.kind == "not-applicable" or .kind == "snapshot-manifest" or
      .kind == "uki-inventory") and
    (.paths | type == "array" and length <= $maximum and all(.[]; absolute_path)) and
    (.paths == (.paths | sort | unique)) and
    ((.paths | map(ascii_downcase)) == (.paths | map(ascii_downcase) | sort | unique)) and
    (if .kind == "not-applicable" then (.paths | length) == 0 else true end)
  ' <<< "$document" >/dev/null
}

validate_final_proof_json() {
  local transaction_id="$1" document="$2" schema obligations
  schema=$(jq -r '.schema_version // "invalid"' <<< "$document") || return 1
  if [[ "$schema" == "$LEGACY_FINAL_PROOF_SCHEMA_VERSION" ]]; then
    jq -e --arg id "$transaction_id" --argjson schema "$LEGACY_FINAL_PROOF_SCHEMA_VERSION" '
      def uuid:
        type == "string" and
        test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
      def digest: type == "string" and test("^[0-9a-f]{64}$");
      def checksum: type == "string" and test("^[0-9a-f]{128}$");
      def timestamp:
        type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def absolute_path:
        type == "string" and length > 1 and length <= 4096 and startswith("/") and
        (explode | all(.[]; . >= 32 and . != 127));
      def identity: type == "string" and test("^[0-9]+:[0-9]+$");
      type == "object" and
      keys == ["artifacts","config","proved_at","schema_version","transaction_id",
        "writer_version"] and
      .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
      (.writer_version | type == "string" and length > 0 and length <= 128) and
      (.proved_at | timestamp) and
      (.config | type == "object" and keys == ["checksum","identity","path","sha256"] and
        (.checksum | checksum) and (.identity | identity) and (.path | absolute_path) and
        (.sha256 | digest)) and
      (.artifacts | type == "array" and length > 0 and length <= 4096) and
      (all(.artifacts[];
        type == "object" and keys == ["identity","path","sha256","signature","tracking"] and
        (.identity | identity) and (.path | absolute_path) and (.sha256 | digest) and
        .signature == "local" and .tracking == "tracked")) and
      ([.artifacts[].path] == ([.artifacts[].path] | sort | unique))
    ' <<< "$document" >/dev/null
    return
  fi
  [[ "$schema" == "$FINAL_PROOF_SCHEMA_VERSION" ]] || return 1
  obligations=$(jq -c '.obligations' <<< "$document") || return 1
  validate_efi_obligations_json "$obligations" || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$FINAL_PROOF_SCHEMA_VERSION" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def checksum: type == "string" and test("^[0-9a-f]{128}$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    def identity: type == "string" and test("^[0-9]+:[0-9]+$");
    type == "object" and
    keys == ["artifacts","config","obligations","proved_at","schema_version","transaction_id",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.proved_at | timestamp) and
    (.config | type == "object" and keys == ["checksum","identity","path","sha256"] and
      (.checksum | checksum) and (.identity | identity) and (.path | absolute_path) and
      (.sha256 | digest)) and
    (.artifacts | type == "array" and length > 0 and length <= 4096) and
    (all(.artifacts[];
      type == "object" and keys == ["identity","path","sha256","signature","tracking"] and
      (.identity | identity) and (.path | absolute_path) and (.sha256 | digest) and
      .signature == "local" and .tracking == "tracked")) and
    ([.artifacts[].path] == ([.artifacts[].path] | sort | unique)) and
    ([.artifacts[].path] as $artifact_paths |
      all(.obligations.paths[]; . as $path | $artifact_paths | index($path) != null))
  ' <<< "$document" >/dev/null
}

validate_producer_record_reference() {
  local transaction_id="$1" reference="$2" transaction_dir path document baseline
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  [[ $(jq -r '.schema_version' <<< "$reference") == "$PRODUCER_RECORD_SCHEMA_VERSION" \
    && "$path" == "${transaction_dir}/producer.json" ]] || return 1
  validate_artifact_reference_file "$reference" "$transaction_dir" || return 1
  document=$(read_control_document "$path") || return 1
  validate_producer_record_json "$transaction_id" "$document" || return 1
  baseline=$(jq -c '.baseline' <<< "$document") || return 1
  path=$(jq -r '.path' <<< "$baseline") || return 1
  [[ $(jq -r '.schema_version' <<< "$baseline") == "$PRODUCER_BASELINE_SCHEMA_VERSION" \
    && "$path" == "${transaction_dir}/producer-baseline.json" ]] || return 1
  validate_artifact_reference_file "$baseline" "$transaction_dir" || return 1
  document=$(read_control_document "$path") || return 1
  validate_producer_baseline_json "$transaction_id" "$document"
}

validate_final_proof_reference() {
  local transaction_id="$1" reference="$2" transaction_dir path document schema
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  schema=$(jq -r '.schema_version' <<< "$reference") || return 1
  [[ ( "$schema" == "$LEGACY_FINAL_PROOF_SCHEMA_VERSION" \
      || "$schema" == "$FINAL_PROOF_SCHEMA_VERSION" ) \
    && "$path" == "${transaction_dir}/final-proof.json" ]] || return 1
  validate_artifact_reference_file "$reference" "$transaction_dir" || return 1
  document=$(read_control_document "$path") || return 1
  [[ $(jq -r '.schema_version' <<< "$document") == "$schema" ]] || return 1
  validate_final_proof_json "$transaction_id" "$document"
}

validate_firmware_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" writes writes_hash
  writes=$(jq -cS '.firmware_writes' <<< "$manifest") || return 1
  writes_hash=$(sha256_text "$writes") || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$FIRMWARE_PROOF_SCHEMA_VERSION" \
    --arg writes_hash "$writes_hash" --argjson manifest "$manifest" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    def artifact_reference:
      type == "object" and keys == ["path","schema_version","sha256"] and
      (.path | absolute_path) and .schema_version == 2 and (.sha256 | digest);
    type == "object" and
    keys == ["artifact_proof","enrollment_plan","firmware_backup","firmware_writes_sha256",
      "modes","proved_at","schema_version","transaction_id","variables","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.proved_at | timestamp) and
    (.firmware_backup | type == "object" and keys == ["id","manifest_sha256","path"] and
      (.id | uuid) and (.manifest_sha256 | digest) and (.path | absolute_path)) and
    (.enrollment_plan | type == "object" and
      keys == ["backup_id","manifest_sha256","path"] and
      (.backup_id | uuid) and (.manifest_sha256 | digest) and (.path | absolute_path)) and
    (.variables | type == "object" and keys == ["KEK","PK","db","dbx"] and
      (all(.PK,.KEK,.db;
        type == "object" and keys == ["entries_sha256"] and (.entries_sha256 | digest))) and
      (.dbx | type == "object" and keys == ["present","raw_sha256"] and
        (.present | type == "boolean") and
        (if .present then (.raw_sha256 | digest) else .raw_sha256 == null end))) and
    (.modes | type == "object" and
      keys == ["AuditMode","DeployedMode","SecureBoot","SetupMode"] and
      .AuditMode == 0 and .DeployedMode == 0 and .SecureBoot == 0 and .SetupMode == 0) and
    .firmware_writes_sha256 == $writes_hash and
    (.artifact_proof | artifact_reference) and
    .firmware_backup == {
      id: $manifest.firmware_backup.id,
      manifest_sha256: $manifest.firmware_backup.manifest_sha256,
      path: $manifest.firmware_backup.path
    } and
    .enrollment_plan == {
      backup_id: $manifest.enrollment_plan.backup_id,
      manifest_sha256: $manifest.enrollment_plan.manifest_sha256,
      path: $manifest.enrollment_plan.path
    } and
    .variables == {
      PK: {entries_sha256: $manifest.enrollment_plan.variables.PK.entries_sha256},
      KEK: {entries_sha256: $manifest.enrollment_plan.variables.KEK.entries_sha256},
      db: {entries_sha256: $manifest.enrollment_plan.variables.db.entries_sha256},
      dbx: $manifest.enrollment_plan.dbx
    } and
    .artifact_proof == $manifest.domain_records.final_proof
  ' <<< "$document" >/dev/null
}

validate_firmware_proof_reference() {
  local transaction_id="$1" reference="$2" manifest="$3" transaction_dir path document
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  [[ $(jq -r '.schema_version' <<< "$reference") == "$FIRMWARE_PROOF_SCHEMA_VERSION" \
    && "$path" == "${transaction_dir}/firmware-proof.json" ]] || return 1
  validate_artifact_reference_file "$reference" "$transaction_dir" || return 1
  document=$(read_control_document "$path") || return 1
  validate_firmware_proof_json "$transaction_id" "$document" "$manifest"
}

incident_reference_from_json() {
  local document="$1" path="$2" hash
  hash=$(sha256_file "$path") || return 1
  jq -cn --argjson seal "$document" --arg path "$path" --arg hash "$hash" '{
    id: $seal.id,
    kind: $seal.kind,
    operation: $seal.operation,
    ordinal: $seal.ordinal,
    path: $path,
    sha256: $hash,
    status: $seal.incident_status
  }'
}

utc_timestamp() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

boot_id_value() {
  local boot_id
  IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || return 1
  [[ "$boot_id" =~ ^[0-9a-f-]{36}$ ]] || return 1
  printf '%s\n' "$boot_id"
}

process_stat_fields() {
  local pid="$1" stat_line
  IFS= read -r stat_line < "/proc/${pid}/stat" || return 1
  [[ "$stat_line" == *') '* ]] || return 1
  printf '%s\n' "${stat_line##*) }"
}

process_start_time() {
  local pid="$1" fields
  local -a values
  fields=$(process_stat_fields "$pid") || return 1
  read -r -a values <<< "$fields"
  [[ ${#values[@]} -gt 19 && ${values[19]} =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${values[19]}"
}

process_state() {
  local pid="$1" fields
  local -a values
  fields=$(process_stat_fields "$pid") || return 1
  read -r -a values <<< "$fields"
  [[ ${#values[@]} -gt 0 && ${values[0]} =~ ^[A-Za-z]$ ]] || return 1
  printf '%s\n' "${values[0]}"
}

process_parent_pid() {
  local pid="$1" fields
  local -a values
  fields=$(process_stat_fields "$pid") || return 1
  read -r -a values <<< "$fields"
  [[ ${#values[@]} -gt 1 && ${values[1]} =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${values[1]}"
}

process_has_ancestor() {
  local ancestor="$1" current="$2" parent loops=0
  while [[ "$current" =~ ^[0-9]+$ && "$current" -gt 0 && $loops -lt 256 ]]; do
    [[ "$current" == "$ancestor" ]] && return 0
    parent=$(process_parent_pid "$current") || return 1
    [[ "$parent" != "$current" ]] || return 1
    current="$parent"
    loops=$((loops + 1))
  done
  return 1
}

process_runs_script() {
  local pid="$1" expected="$2" executable script
  local -a arguments
  validate_control_file "$expected" || return 1
  executable=$(readlink -f "/proc/${pid}/exe" 2>/dev/null) || return 1
  [[ "$executable" == /usr/bin/bash ]] || return 1
  mapfile -d '' -t arguments < "/proc/${pid}/cmdline" || return 1
  [[ ${#arguments[@]} -ge 2 ]] || return 1
  script=$(readlink -f "${arguments[1]}" 2>/dev/null) || return 1
  [[ "$script" == "$expected" ]]
}

process_runs_executable() {
  local pid="$1" expected="$2" executable
  validate_control_file "$expected" || return 1
  executable=$(readlink -f "/proc/${pid}/exe" 2>/dev/null) || return 1
  [[ "$executable" == "$expected" ]]
}

process_matches_identity() {
  local pid="$1" kind="$2" identity="$3"
  case "$kind" in
    executable) process_runs_executable "$pid" "$identity" ;;
    script) process_runs_script "$pid" "$identity" ;;
    *) return 1 ;;
  esac
}

process_cmdline_has_argument() {
  local pid="$1" expected="$2" argument
  local -a arguments
  mapfile -d '' -t arguments < "/proc/${pid}/cmdline" || return 1
  for argument in "${arguments[@]}"; do
    [[ "$argument" == "$expected" ]] && return 0
  done
  return 1
}

new_transaction_id() {
  local transaction_id
  IFS= read -r transaction_id < /proc/sys/kernel/random/uuid || return 1
  [[ "$transaction_id" =~ ^[0-9a-f-]{36}$ ]] || return 1
  printf '%s\n' "$transaction_id"
}

new_transaction_token() {
  local first second
  IFS= read -r first < /proc/sys/kernel/random/uuid || return 1
  IFS= read -r second < /proc/sys/kernel/random/uuid || return 1
  printf '%s%s\n' "${first//-/}" "${second//-/}"
}

sha256_text() {
  local output hash
  output=$(printf '%s' "$1" | sha256sum) || return 1
  hash=${output%% *}
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

sha256_file() {
  local output hash
  output=$(sha256sum "$1") || return 1
  hash=${output%% *}
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

capture_service_state() {
  local unit="$TRANSACTION_SERVICE_UNIT" output line key value
  local load_state="" active_state="" unit_file_state=""
  local load_count=0 active_count=0 unit_file_count=0
  command -v systemctl >/dev/null 2>&1 || return 1
  output=$(systemctl show --property=LoadState --property=ActiveState \
    --property=UnitFileState "$unit" 2>/dev/null) || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || return 1
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      LoadState)
        load_count=$((load_count + 1))
        load_state=$value
        ;;
      ActiveState)
        active_count=$((active_count + 1))
        active_state=$value
        ;;
      UnitFileState)
        unit_file_count=$((unit_file_count + 1))
        unit_file_state=$value
        ;;
      *) return 1 ;;
    esac
  done <<< "$output"

  [[ $load_count -eq 1 && $active_count -eq 1 && $unit_file_count -eq 1 ]] \
    || return 1
  if [[ "$load_state" == not-found && -z "$unit_file_state" ]]; then
    unit_file_state=not-found
  fi
  jq -cn --arg unit "$unit" --arg load "$load_state" --arg active "$active_state" \
    --arg enabled "$unit_file_state" '{
      ($unit): {
        load_state: $load,
        active_state: $active,
        unit_file_state: $enabled
      }
    }'
}

validate_captured_service_state() {
  local state="$1"
  jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
    type == "object" and keys == [$unit] and
    (.[$unit] | type == "object") and
    (.[$unit].load_state == "loaded" or
      .[$unit].load_state == "not-found" or
      .[$unit].load_state == "masked") and
    (.[$unit].active_state == "active" or
      .[$unit].active_state == "inactive") and
    (.[$unit].unit_file_state == "enabled" or
      .[$unit].unit_file_state == "enabled-runtime" or
      .[$unit].unit_file_state == "linked" or
      .[$unit].unit_file_state == "linked-runtime" or
      .[$unit].unit_file_state == "alias" or
      .[$unit].unit_file_state == "static" or
      .[$unit].unit_file_state == "disabled" or
      .[$unit].unit_file_state == "indirect" or
      .[$unit].unit_file_state == "generated" or
      .[$unit].unit_file_state == "masked" or
      .[$unit].unit_file_state == "masked-runtime" or
      .[$unit].unit_file_state == "not-found") and
    (if .[$unit].active_state == "active" then
      .[$unit].load_state == "loaded" and
      .[$unit].unit_file_state != "masked" and
      .[$unit].unit_file_state != "masked-runtime" and
      .[$unit].unit_file_state != "not-found"
    else true end) and
    (if .[$unit].load_state == "not-found" then
      .[$unit].active_state == "inactive" and
      .[$unit].unit_file_state == "not-found"
    elif .[$unit].load_state == "masked" then
      .[$unit].active_state == "inactive" and
      (.[$unit].unit_file_state == "masked" or
        .[$unit].unit_file_state == "masked-runtime")
    else true end)
  ' <<< "$state" >/dev/null
}

prepare_transaction_service_state() {
  local state="$1" load
  validate_captured_service_state "$state" || return 1
  load=$(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
    '.[$unit].load_state' <<< "$state") || return 1
  if [[ "$load" == loaded ]]; then
    jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" '
      .[$unit].quiesce_status = "pending" |
      .[$unit].restore_status = "pending"
    ' <<< "$state"
  else
    jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" '
      .[$unit].quiesce_status = "not-required" |
      .[$unit].restore_status = "not-required"
    ' <<< "$state"
  fi
}

validate_private_control_file() {
  local path="$1" mode
  validate_control_file "$path" || return 1
  mode=$(stat -Lc '%a' "$path" 2>/dev/null) || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

validate_private_control_directory() {
  local path="$1" mode
  validate_control_directory "$path" || return 1
  mode=$(stat -Lc '%a' "$path" 2>/dev/null) || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

ensure_state_layout() {
  require_control_root || return 1

  local state_dir transactions_dir parent
  state_dir=$(state_dir_path)
  transactions_dir=$(transactions_dir_path)
  parent=$(dirname "$state_dir")

  validate_control_directory "$parent" || {
    fail "Unsafe lifecycle parent directory: ${parent}"
    return 1
  }

  if [[ -e "$state_dir" || -L "$state_dir" ]]; then
    validate_control_directory "$state_dir" || {
      fail "Unsafe lifecycle directory: ${state_dir}"
      return 1
    }
    chmod 755 "$state_dir" || return 1
  else
    install -d -m 755 "$state_dir" || return 1
  fi
  validate_control_directory "$state_dir" || return 1

  if [[ -e "$transactions_dir" || -L "$transactions_dir" ]]; then
    validate_control_directory "$transactions_dir" || {
      fail "Unsafe transaction directory: ${transactions_dir}"
      return 1
    }
    chmod 700 "$transactions_dir" || return 1
  else
    install -d -m 700 "$transactions_dir" || return 1
  fi
  validate_control_directory "$transactions_dir"
}

atomic_write_control_file() {
  local destination="$1" mode="$2" parent temporary old_umask
  parent=$(dirname "$destination")
  validate_control_directory "$parent" || return 1

  if [[ -e "$destination" || -L "$destination" ]]; then
    validate_control_file "$destination" || return 1
  fi

  old_umask=$(umask)
  umask 077
  temporary=$(mktemp "${parent}/.$(basename "$destination").XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"

  if ! cat > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  chmod "$mode" "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  validate_control_file "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  durable_sync "$temporary" || {
    rm -f "$temporary"
    return 1
  }
  mv -f "$temporary" "$destination" || {
    rm -f "$temporary"
    return 1
  }
  durable_sync "$parent"
}

atomic_create_control_file() {
  local destination="$1" mode="$2" parent temporary old_umask
  parent=$(dirname "$destination")
  validate_control_directory "$parent" || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1

  old_umask=$(umask)
  umask 077
  temporary=$(mktemp "${parent}/.$(basename "$destination").XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"

  if ! cat > "$temporary" \
    || ! chmod "$mode" "$temporary" \
    || ! validate_control_file "$temporary" \
    || ! durable_sync "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if ! mv -T --no-copy --update=none-fail "$temporary" "$destination"; then
    rm -f "$temporary"
    return 1
  fi
  validate_control_file "$destination" || return 1
  durable_sync "$parent"
}

read_control_document() {
  local path="$1" maximum="${2:-$MAX_CONTROL_DOCUMENT_BYTES}" size document
  [[ "$maximum" =~ ^[1-9][0-9]*$ ]] || return 1
  validate_control_file "$path" || return 1
  size=$(stat -Lc '%s' "$path" 2>/dev/null) || return 1
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  (( size > 0 && size <= maximum )) || return 1
  document=$(jq -ces '
    if length == 1 then .[0] else error("expected one JSON value") end
  ' "$path") || return 1
  printf '%s\n' "$document"
}

validate_lifecycle_json() {
  local document="$1"
  jq -e --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def operation:
      type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9-]*$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    def artifact_reference:
      type == "object" and keys == ["path","schema_version","sha256"] and
      (.path | absolute_path) and (.schema_version | type == "number" and . >= 1 and floor == .) and
      (.sha256 | digest);
    def incident_reference:
      type == "object" and
      keys == ["id","kind","operation","ordinal","path","sha256","status"] and
      (.id | uuid) and (.operation | operation) and (.path | absolute_path) and
      (.sha256 | digest) and
      (if .kind == "root" then
        .ordinal == 0 and
        (.status == "failed" or .status == "stale" or
          .status == "publication-uncertain")
      elif .kind == "attempt" then
        (.ordinal | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
        (.status == "failed" or .status == "stale" or .status == "completed")
      else false end);
    def adoption:
      type == "object" and keys == ["managed_settings","recorded_at","source"] and
      .source == "explicit" and (.recorded_at | timestamp) and
      (.managed_settings | type == "array" and length == 4) and
      (.managed_settings[0] |
        keys == ["key","observed","original","path"] and
        .path == "/etc/default/limine" and .key == "ENABLE_VERIFICATION" and
        (.observed == "yes" or .observed == "no" or .observed == "unset") and
        (.original == "yes" or .original == "no" or .original == "unset" or
          .original == "unknown")) and
      (.managed_settings[1] |
        keys == ["key","observed","original","path"] and
        .path == "/etc/default/limine" and .key == "ENABLE_ENROLL_LIMINE_CONFIG" and
        (.observed == "yes" or .observed == "no" or .observed == "unset") and
        (.original == "yes" or .original == "no" or .original == "unset" or
          .original == "unknown")) and
      (.managed_settings[2] |
        keys == ["key","observed","original","path","token"] and
        .path == "/etc/default/limine" and .key == "COMMANDS_BEFORE_SAVE" and
        .token == "limine-reset-enroll" and
        (.observed == "present" or .observed == "absent") and
        (.original == "present" or .original == "absent" or .original == "unknown")) and
      (.managed_settings[3] |
        keys == ["key","observed","original","path","token"] and
        .path == "/etc/default/limine" and .key == "COMMANDS_AFTER_SAVE" and
        .token == "limine-enroll-config" and
        (.observed == "present" or .observed == "absent") and
        (.original == "present" or .original == "absent" or .original == "unknown"));
    def completed_transaction:
      type == "object" and
      keys == ["completed_at","id","manifest","manifest_sha256","operation"] and
      (.id | uuid) and (.operation | operation) and (.manifest | absolute_path) and
      (.manifest_sha256 | digest) and (.completed_at | timestamp);
    def transition_reference:
      type == "object" and
      keys == ["attempt_number","id","kind","manifest","operation","previous_attempt","root_incident"] and
      (.id | uuid) and (.operation | operation) and (.manifest | absolute_path) and
      (if .kind == "root" then
        .attempt_number == null and .root_incident == null and .previous_attempt == null
      elif .kind == "recovery-attempt" then
        (.attempt_number | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
        (.root_incident | incident_reference) and .root_incident.kind == "root" and
        (.previous_attempt == null or
          ((.previous_attempt | incident_reference) and .previous_attempt.kind == "attempt"))
      else false end);
    def incident_state:
      type == "object" and
      keys == ["attempt_count","id","kind","last_recovery_attempt","manifest","operation","root_incident"] and
      .kind == "incident" and (.id | uuid) and (.operation | operation) and
      (.manifest | absolute_path) and (.root_incident | incident_reference) and
      .root_incident.kind == "root" and .root_incident.id == .id and
      .root_incident.operation == .operation and
      (.attempt_count | type == "number" and . >= 0 and . <= $max_attempts and floor == .) and
      (if .attempt_count == 0 then .last_recovery_attempt == null
       else (.last_recovery_attempt | incident_reference) and
         .last_recovery_attempt.kind == "attempt" and
         .last_recovery_attempt.ordinal == .attempt_count and
         (.last_recovery_attempt.status == "failed" or
           .last_recovery_attempt.status == "stale")
       end);
    def resolved_recovery:
      type == "object" and
      keys == ["attempt_count","final_attempt","proof","resolved_at","root_incident"] and
      (.attempt_count | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
      (.root_incident | incident_reference) and .root_incident.kind == "root" and
      (.final_attempt | incident_reference) and .final_attempt.kind == "attempt" and
      .final_attempt.ordinal == .attempt_count and .final_attempt.status == "completed" and
      (.proof | artifact_reference) and (.resolved_at | timestamp);
    type == "object" and
    keys == ["adoption","generation","last_recovery","last_transaction","managed_settings",
      "schema_version","state","tracking_ownership","transaction","updated_at","writer_version"] and
    .schema_version == $schema and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.generation | type == "number" and . >= 1 and floor == .) and
    (.state == "disabled" or .state == "active" or
      .state == "transition" or .state == "recovery-required") and
    (.updated_at | timestamp) and
    (.adoption == null or (.adoption | adoption)) and
    (.last_transaction == null or (.last_transaction | completed_transaction)) and
    (.last_recovery == null or (.last_recovery | resolved_recovery)) and
    (.managed_settings == null or (.managed_settings | artifact_reference)) and
    (.tracking_ownership == null or (.tracking_ownership | artifact_reference)) and
    (if .state == "transition" then
      (.transaction | transition_reference)
    elif .state == "recovery-required" then
      (.transaction | incident_state)
    else .transaction == null and (.last_transaction | completed_transaction) end)
  ' <<< "$document" >/dev/null
}

validate_transaction_manifest_json() {
  local transaction_id="$1" document="$2" check_files="${3:-true}" transaction_dir
  local prior_state backup_entry backup_kind backup_path backup_hash backup_target
  local backup_mode backup_uid backup_gid firmware_backup_id firmware_backup_path
  local enrollment_backup_id enrollment_plan_path reference captured_service_state
  local -A backup_targets=()
  [[ "$check_files" == true || "$check_files" == false ]] || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1

  jq -e --arg id "$transaction_id" --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --argjson owner_uid "$(control_owner_uid)" --arg service_unit "$TRANSACTION_SERVICE_UNIT" \
    --arg transaction_dir "$transaction_dir" \
    --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" \
    --argjson max_backups "$MAX_TRANSACTION_BACKUPS" \
    --argjson max_firmware_writes "$MAX_FIRMWARE_WRITE_ATTEMPTS" \
    --argjson max_hierarchy_writes "$MAX_FIRMWARE_HIERARCHY_ATTEMPTS" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def operation:
      type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9-]*$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    def phase:
      type == "string" and length <= 128 and test("^[a-z0-9][a-z0-9-]*$");
    def artifact_reference:
      type == "object" and keys == ["path","schema_version","sha256"] and
      (.path | absolute_path) and (.schema_version | type == "number" and . >= 1 and floor == .) and
      (.sha256 | digest);
    def incident_reference:
      type == "object" and
      keys == ["id","kind","operation","ordinal","path","sha256","status"] and
      (.id | uuid) and (.operation | operation) and (.path | absolute_path) and
      (.sha256 | digest) and
      (if .kind == "root" then
        .ordinal == 0 and
        (.status == "failed" or .status == "stale" or
          .status == "publication-uncertain")
      elif .kind == "attempt" then
        (.ordinal | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
        (.status == "failed" or .status == "stale" or .status == "completed")
      else false end);
    def failure:
      type == "object" and keys == ["exit_code","phase","reason","recorded_at"] and
      (.exit_code | type == "number" and . >= 0 and . <= 255 and floor == .) and
      (.phase == null or (.phase | phase)) and
      (.reason | type == "string" and length > 0 and length <= 1024) and
      (.recorded_at | timestamp);
    type == "object" and
    keys == ["backups","boot_id","completed_at","completed_phases","created_at",
      "current_phase","domain_records","enrollment_plan","failure","file_rollback_policy",
      "firmware_backup","firmware_writes","id","kind","operation","owner","prior_state",
      "recovery","rollback","schema_version","service_state","status","target_state",
      "token_sha256","writer_version"] and
    .schema_version == $schema and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .id == $id and (.operation | operation) and
    (.target_state == "disabled" or .target_state == "active") and
    (.status == "transition" or .status == "completed" or
      .status == "failed" or .status == "stale") and
    (.created_at | timestamp) and
    (.boot_id | uuid) and (.token_sha256 | digest) and
    (.owner | type == "object" and keys == ["pid","start_time","uid"]) and
    (.owner.pid | type == "number" and . > 0 and floor == .) and
    (.owner.start_time | type == "string" and test("^[0-9]+$") and length <= 32) and
    .owner.uid == $owner_uid and
    (if .kind == "root" then
      (.prior_state == "unmanaged" or .prior_state == "disabled" or .prior_state == "active") and
      .recovery == null
    elif .kind == "recovery-attempt" then
      .prior_state == "recovery-required" and
      (.recovery | type == "object" and
        keys == ["attempt_number","previous_attempt","root_incident"]) and
      (.recovery.attempt_number | type == "number" and . >= 1 and
        . <= $max_attempts and floor == .) and
      (.recovery.root_incident | incident_reference) and
      .recovery.root_incident.kind == "root" and
      (if .recovery.attempt_number == 1 then .recovery.previous_attempt == null
       else (.recovery.previous_attempt | incident_reference) and
         .recovery.previous_attempt.kind == "attempt" and
         .recovery.previous_attempt.ordinal == (.recovery.attempt_number - 1)
       end)
    else false end) and
    (.current_phase == null or (.current_phase | phase)) and
    (.completed_phases | type == "array" and length <= 128 and
      all(.[]; phase) and length == (unique | length)) and
    (.backups | type == "array" and length >= 1 and length <= $max_backups) and
    (all(.backups[];
      type == "object" and
      if .kind == "absent-lifecycle" then
        keys == ["kind","path","sha256","target"] and
        .path == null and .sha256 == null and .target == null
      elif .kind == "prior-lifecycle" then
        keys == ["kind","path","sha256","target"] and
        (.path | absolute_path) and (.sha256 | digest) and .target == null
      elif .kind == "file" then
        keys == ["gid","kind","mode","path","sha256","target","uid"] and
        (.path | absolute_path) and (.sha256 | digest) and (.target | absolute_path) and
        (.mode | type == "string" and test("^[0-7]{3,4}$")) and
        (.uid | type == "number" and . >= 0 and floor == .) and
        (.gid | type == "number" and . >= 0 and floor == .)
      elif .kind == "absent-file" then
        keys == ["gid","kind","mode","path","sha256","target","uid"] and
        .path == null and .sha256 == null and (.target | absolute_path) and
        .mode == null and .uid == null and .gid == null
      else false end)) and
    (.backups[0].kind == "absent-lifecycle" or
      .backups[0].kind == "prior-lifecycle") and
    (all(.backups[1:][]; .kind == "file" or .kind == "absent-file")) and
    (all(.backups | to_entries[1:][];
      .value.kind == "absent-file" or
      .value.path == ($transaction_dir + "/file-" + (.key | tostring) + ".backup"))) and
    ([.backups[] | select(.target != null) | .target] as $targets |
      ($targets | length) == ($targets | unique | length)) and
    ([.backups[] | select(.path != null) | .path] as $paths |
      ($paths | length) == ($paths | unique | length)) and
    (.service_state | type == "object" and keys == [$service_unit]) and
    (.service_state[$service_unit] | type == "object" and
      keys == ["active_state","load_state","quiesce_status","restore_status","unit_file_state"]) and
    (.service_state[$service_unit].load_state == "loaded" or
      .service_state[$service_unit].load_state == "not-found" or
      .service_state[$service_unit].load_state == "masked") and
    (.service_state[$service_unit].active_state == "active" or
      .service_state[$service_unit].active_state == "inactive") and
    (.service_state[$service_unit].unit_file_state == "enabled" or
      .service_state[$service_unit].unit_file_state == "enabled-runtime" or
      .service_state[$service_unit].unit_file_state == "linked" or
      .service_state[$service_unit].unit_file_state == "linked-runtime" or
      .service_state[$service_unit].unit_file_state == "alias" or
      .service_state[$service_unit].unit_file_state == "static" or
      .service_state[$service_unit].unit_file_state == "disabled" or
      .service_state[$service_unit].unit_file_state == "indirect" or
      .service_state[$service_unit].unit_file_state == "generated" or
      .service_state[$service_unit].unit_file_state == "masked" or
      .service_state[$service_unit].unit_file_state == "masked-runtime" or
      .service_state[$service_unit].unit_file_state == "not-found") and
    (if .service_state[$service_unit].load_state == "loaded" then
      (.service_state[$service_unit].quiesce_status == "pending" or
        .service_state[$service_unit].quiesce_status == "completed" or
        .service_state[$service_unit].quiesce_status == "failed") and
      (.service_state[$service_unit].restore_status == "pending" or
        .service_state[$service_unit].restore_status == "completed" or
        .service_state[$service_unit].restore_status == "failed") and
      (if .status == "completed" then
        .service_state[$service_unit].quiesce_status == "completed" and
        .service_state[$service_unit].restore_status == "completed"
      else true end)
    else
      .service_state[$service_unit].quiesce_status == "not-required" and
      .service_state[$service_unit].restore_status == "not-required" and
      (if .service_state[$service_unit].load_state == "not-found" then
        .service_state[$service_unit].active_state == "inactive" and
        .service_state[$service_unit].unit_file_state == "not-found"
      elif .service_state[$service_unit].load_state == "masked" then
        .service_state[$service_unit].active_state == "inactive" and
        (.service_state[$service_unit].unit_file_state == "masked" or
          .service_state[$service_unit].unit_file_state == "masked-runtime")
      else true end)
    end) and
    (.file_rollback_policy == "restore" or .file_rollback_policy == "preserve") and
    (.firmware_backup == null or (
      (.firmware_backup | type == "object" and
        keys == ["id","manifest_sha256","path","status"]) and
      (.firmware_backup.id | uuid) and (.firmware_backup.path | absolute_path) and
      (.firmware_backup.status == "pending" or .firmware_backup.status == "complete") and
      (if .firmware_backup.status == "complete" then
        (.firmware_backup.manifest_sha256 | digest)
      else .firmware_backup.manifest_sha256 == null end))) and
    (.enrollment_plan == null or (
      (.enrollment_plan | type == "object" and
        keys == ["backup_id","dbx","manifest_sha256","path","variables"]) and
      (.enrollment_plan.backup_id | uuid) and (.enrollment_plan.path | absolute_path) and
      (.enrollment_plan.manifest_sha256 | digest) and
      (.enrollment_plan.variables | type == "object" and keys == ["KEK","PK","db"]) and
      (all(.enrollment_plan.variables[];
        type == "object" and keys == ["entries_sha256","esl_sha256"] and
        (.entries_sha256 | digest) and (.esl_sha256 | digest))) and
      (.enrollment_plan.dbx | type == "object" and keys == ["present","raw_sha256"]) and
      (.enrollment_plan.dbx.present | type == "boolean") and
      (if .enrollment_plan.dbx.present then (.enrollment_plan.dbx.raw_sha256 | digest)
       else .enrollment_plan.dbx.raw_sha256 == null end) and
      .firmware_backup != null and .firmware_backup.status == "complete" and
      .firmware_backup.id == .enrollment_plan.backup_id)) and
    (.firmware_writes as $writes |
      ($writes | type) == "array" and ($writes | length) <= $max_firmware_writes and
      all($writes[];
        type == "object" and
        keys == ["command_exit_code","completed_at","hierarchy","readback_status","started_at"] and
        (.hierarchy == "db" or .hierarchy == "KEK" or .hierarchy == "PK") and
        (.started_at | timestamp) and
        (.command_exit_code == null or
          (.command_exit_code | type == "number" and . >= 0 and . <= 255 and floor == .)) and
        (.readback_status == "pending" or .readback_status == "unchanged" or
          .readback_status == "verified" or .readback_status == "failed") and
        (if .readback_status == "pending" then .completed_at == null
         else (.completed_at | timestamp) end)) and
      ([$writes[] | select(.hierarchy == "db")] | length) <= $max_hierarchy_writes and
      ([$writes[] | select(.hierarchy == "KEK")] | length) <= $max_hierarchy_writes and
      ([$writes[] | select(.hierarchy == "PK")] | length) <= $max_hierarchy_writes and
      (reduce $writes[] as $write (
        {ok: true, next: "db", terminal: false};
        if ((.ok | not) or .terminal or $write.hierarchy != .next) then
          .ok = false
        elif $write.readback_status == "pending" then
          .terminal = true
        elif $write.readback_status == "failed" then
          .terminal = true
        elif $write.readback_status == "unchanged" then
          .
        elif $write.readback_status == "verified" then
          .next = (if .next == "db" then "KEK"
                   elif .next == "KEK" then "PK"
                   else "complete" end)
        else
          .ok = false
        end
      ) | .ok)) and
    (if (.firmware_writes | length) > 0 then
      .file_rollback_policy == "preserve" and .enrollment_plan != null
    else true end) and
    (.domain_records | type == "object" and
      keys == ["bootnext","final_proof","firmware","managed_settings","producer",
        "tracking_ownership","unconfigure","windows"]) and
    (all(.domain_records[]; . == null or artifact_reference)) and
    (if .status == "transition" then
      .completed_at == null and .failure == null
    elif .status == "completed" then
      (.completed_at | timestamp) and .failure == null and .current_phase == null and
      .rollback == null
    else
      (.completed_at | timestamp) and (.failure | failure) and
      .failure.phase == .current_phase
    end) and
    (.rollback == null or (
      (.rollback | type == "object" and keys == ["attempted_at","failures","status"]) and
      (.rollback.status == "completed" or .rollback.status == "failed" or
        .rollback.status == "preserved") and
      (.rollback.attempted_at | timestamp) and
      (.rollback.failures | type == "array" and length <= 128 and
        all(.[]; type == "string" and length <= 4096))))
  ' <<< "$document" >/dev/null || return 1
  captured_service_state=$(jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" '{
    ($unit): {
      load_state: .service_state[$unit].load_state,
      active_state: .service_state[$unit].active_state,
      unit_file_state: .service_state[$unit].unit_file_state
    }
  }' <<< "$document") || return 1
  validate_captured_service_state "$captured_service_state" || return 1
  [[ "$check_files" == true ]] || return 0

  prior_state=$(jq -r '.prior_state' <<< "$document") || return 1
  backup_kind=$(jq -r '.backups[0].kind' <<< "$document") || return 1
  if [[ "$prior_state" == unmanaged ]]; then
    [[ "$backup_kind" == absent-lifecycle ]] || return 1
  else
    backup_path=$(jq -r '.backups[0].path' <<< "$document") || return 1
    backup_hash=$(jq -r '.backups[0].sha256' <<< "$document") || return 1
    [[ "$backup_kind" == prior-lifecycle \
      && "$backup_path" == "${transaction_dir}/prior-lifecycle.json" ]] || return 1
    validate_private_control_file "$backup_path" || return 1
    [[ "$(sha256_file "$backup_path")" == "$backup_hash" ]] || return 1
  fi

  while IFS= read -r backup_entry; do
    [[ -n "$backup_entry" ]] || continue
    backup_kind=$(jq -r '.kind' <<< "$backup_entry") || return 1
    backup_path=$(jq -r 'if .path == null then "" else .path end' \
      <<< "$backup_entry") || return 1
    backup_hash=$(jq -r 'if .sha256 == null then "" else .sha256 end' \
      <<< "$backup_entry") || return 1
    backup_target=$(jq -r '.target' <<< "$backup_entry") || return 1
    backup_mode=$(jq -r 'if .mode == null then "" else .mode end' \
      <<< "$backup_entry") || return 1
    backup_uid=$(jq -r 'if .uid == null then "" else .uid end' \
      <<< "$backup_entry") || return 1
    backup_gid=$(jq -r 'if .gid == null then "" else .gid end' \
      <<< "$backup_entry") || return 1
    [[ "$backup_target" =~ ^/[^[:cntrl:]]+$ ]] || return 1
    path_has_no_symlink_components "$backup_target" || return 1
    [[ -z "${backup_targets[$backup_target]:-}" ]] || return 1
    backup_targets["$backup_target"]=1
    if [[ "$backup_kind" == file ]]; then
      [[ "$(dirname "$backup_path")" == "$transaction_dir" \
        && "$(basename "$backup_path")" =~ ^file-[1-9][0-9]*\.backup$ ]] \
        || return 1
      [[ "$backup_mode" =~ ^[0-7]{3,4}$ \
        && "$backup_uid" =~ ^[0-9]+$ && "$backup_gid" =~ ^[0-9]+$ ]] || return 1
      [[ "$backup_uid" == "$(control_owner_uid)" ]] || return 1
      mode_is_control_safe "$backup_mode" || return 1
      validate_private_control_file "$backup_path" || return 1
      [[ "$(sha256_file "$backup_path")" == "$backup_hash" ]] || return 1
    fi
  done < <(jq -c '.backups[] |
    select(.kind == "file" or .kind == "absent-file")' <<< "$document")

  if [[ $(jq -r '.firmware_backup == null' <<< "$document") == false ]]; then
    firmware_backup_id=$(jq -r '.firmware_backup.id' <<< "$document") || return 1
    firmware_backup_path=$(jq -r '.firmware_backup.path' <<< "$document") || return 1
    [[ "$firmware_backup_path" == \
      "$(state_dir_path)/firmware-backup/${firmware_backup_id}" ]] || return 1
  fi
  if [[ $(jq -r '.enrollment_plan == null' <<< "$document") == false ]]; then
    enrollment_backup_id=$(jq -r '.enrollment_plan.backup_id' <<< "$document") \
      || return 1
    enrollment_plan_path=$(jq -r '.enrollment_plan.path' <<< "$document") || return 1
    [[ "$enrollment_plan_path" == \
      "$(state_dir_path)/firmware-backup/${enrollment_backup_id}/plan" ]] || return 1
  fi
  while IFS= read -r reference; do
    [[ -z "$reference" ]] || validate_artifact_reference_file "$reference" "$transaction_dir" \
      || return 1
  done < <(jq -c '.domain_records[] | select(. != null)' <<< "$document")
  validate_transaction_domain_records "$transaction_id" "$document"
}

validate_artifact_reference_file() {
  local reference="$1" owner_dir="${2:-$(state_dir_path)}" path hash
  path=$(jq -r '.path' <<< "$reference") || return 1
  hash=$(jq -r '.sha256' <<< "$reference") || return 1
  [[ "$path" == "${owner_dir}/"* && "$path" != *'/../'* ]] || return 1
  path_has_no_symlink_components "$path" || return 1
  validate_private_control_file "$path" || return 1
  [[ "$(sha256_file "$path")" == "$hash" ]]
}

validate_transaction_domain_records() {
  local transaction_id="$1" document="$2" producer proof firmware path producer_document
  local kind status operation
  local extracted
  local -a fields
  extracted=$(jq -er '
    (.domain_records.producer | tojson),
    (.domain_records.final_proof | tojson),
    (.domain_records.firmware | tojson),
    .kind, .status, .operation
  ' <<< "$document") || return 1
  mapfile -t fields <<< "$extracted"
  [[ ${#fields[@]} -eq 6 ]] || return 1
  producer=${fields[0]}
  proof=${fields[1]}
  firmware=${fields[2]}
  kind=${fields[3]}
  status=${fields[4]}
  operation=${fields[5]}

  if [[ "$producer" != null ]]; then
    [[ "$kind" == root ]] || return 1
    validate_producer_record_reference "$transaction_id" "$producer" || return 1
    path=$(jq -r '.path' <<< "$producer") || return 1
    producer_document=$(read_control_document "$path") || return 1
    jq -en --argjson manifest "$document" --argjson producer "$producer_document" \
      --argjson final_schema "$FINAL_PROOF_SCHEMA_VERSION" '
      $manifest.operation == $producer.operation and
      $manifest.target_state == "active" and $manifest.prior_state == "active" and
      $manifest.file_rollback_policy == "preserve" and
      $manifest.boot_id == $producer.owner.boot_id and
      $manifest.owner.pid == $producer.owner.pid and
      $manifest.owner.start_time == $producer.owner.start_time and
       $manifest.owner.uid == $producer.owner.uid and
       $manifest.firmware_backup == null and $manifest.enrollment_plan == null and
       $manifest.firmware_writes == [] and
       $manifest.domain_records.bootnext == null and
       $manifest.domain_records.firmware == null and
       $manifest.domain_records.managed_settings == null and
      $manifest.domain_records.tracking_ownership == null and
      $manifest.domain_records.unconfigure == null and
      $manifest.domain_records.windows == null and
      (if $manifest.status == "completed" then
        $manifest.domain_records.final_proof != null and
        $manifest.domain_records.final_proof.schema_version == $final_schema
       else true end)
    ' >/dev/null || return 1
  fi

  if [[ "$proof" != null ]]; then
    validate_final_proof_reference "$transaction_id" "$proof" || return 1
  fi
  if [[ "$firmware" != null ]]; then
    [[ "$kind" == root && "$operation" == enroll-secure-boot && "$producer" == null \
      && "$proof" != null ]] || return 1
    validate_firmware_proof_reference "$transaction_id" "$firmware" "$document" || return 1
  elif [[ "$operation" == enroll-secure-boot && "$status" == completed ]]; then
    return 1
  fi
  if [[ "$operation" == enroll-secure-boot ]]; then
    [[ "$kind" == root && "$producer" == null ]] || return 1
    jq -e --argjson final_schema "$FINAL_PROOF_SCHEMA_VERSION" '
      .target_state == "active" and .prior_state == "active" and
      .domain_records.bootnext == null and
      .domain_records.managed_settings == null and
      .domain_records.tracking_ownership == null and
      .domain_records.unconfigure == null and .domain_records.windows == null and
      (if .firmware_backup == null then
        .enrollment_plan == null and .firmware_writes == [] and
        .domain_records.firmware == null and .file_rollback_policy == "restore"
       else
        .firmware_backup.status == "complete" and .enrollment_plan != null
       end) and
      (if .status == "completed" then
        .firmware_backup != null and .enrollment_plan != null and
        .file_rollback_policy == "preserve" and
        .domain_records.final_proof != null and
        .domain_records.final_proof.schema_version == $final_schema and
        .domain_records.firmware != null and
        (.completed_phases | index("prove-enrolled-trust") != null) and
        (all(.firmware_writes[];
          .readback_status == "verified" or .readback_status == "unchanged")) and
        [.firmware_writes[] | select(.readback_status == "verified") | .hierarchy] ==
          ["db","KEK","PK"]
       else true end)
    ' <<< "$document" >/dev/null || return 1
  fi
  if [[ "$kind" == recovery-attempt ]]; then
    [[ "$producer" == null && "$firmware" == null ]] || return 1
    if [[ "$proof" != null ]]; then
      [[ $(jq -r '.schema_version' <<< "$proof") == "$FINAL_PROOF_SCHEMA_VERSION" ]] \
        || return 1
    fi
    [[ "$status" != completed || "$proof" != null ]] || return 1
  fi
}

read_transaction_manifest() {
  local transaction_id="$1" manifest transaction_dir document schema manifest_hash
  manifest=$(lifecycle_manifest_path "$transaction_id") || return 1
  transaction_dir=$(dirname "$manifest")
  validate_private_control_directory "$transaction_dir" || return 1
  validate_private_control_file "$manifest" || return 1
  manifest_hash=$(sha256_file "$manifest") || return 1
  _manifest_json=""
  _manifest_id=""
  _manifest_sha256=""
  document=$(read_control_document "$manifest") || return 1
  schema=$(jq -r 'if (.schema_version | type) == "number" and
    (.schema_version | floor) == .schema_version then .schema_version else "invalid" end' \
    <<< "$document") || return 1
  [[ "$schema" == "$LIFECYCLE_SCHEMA_VERSION" ]] || return 1
  validate_transaction_manifest_json "$transaction_id" "$document" || return 1
  _manifest_json="$document"
  _manifest_id="$transaction_id"
  _manifest_sha256="$manifest_hash"
}

validate_incident_seal_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def operation:
      type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9-]*$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def absolute_path:
      type == "string" and length > 1 and length <= 4096 and startswith("/") and
      (explode | all(.[]; . >= 32 and . != 127));
    def incident_reference:
      type == "object" and
      keys == ["id","kind","operation","ordinal","path","sha256","status"] and
      (.id | uuid) and (.operation | operation) and (.path | absolute_path) and
      (.sha256 | digest) and
      (if .kind == "root" then
        .ordinal == 0 and
        (.status == "failed" or .status == "stale" or
          .status == "publication-uncertain")
      elif .kind == "attempt" then
        (.ordinal | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
        (.status == "failed" or .status == "stale" or .status == "completed")
      else false end);
    def phase:
      type == "string" and length <= 128 and test("^[a-z0-9][a-z0-9-]*$");
    def failure:
      type == "object" and keys == ["exit_code","phase","reason","recorded_at"] and
      (.exit_code | type == "number" and . >= 0 and . <= 255 and floor == .) and
      (.phase == null or (.phase | phase)) and
      (.reason | type == "string" and length > 0 and length <= 1024) and
      (.recorded_at | timestamp);
    type == "object" and
    keys == ["failure","id","incident_status","kind","manifest","manifest_sha256",
      "manifest_status","operation","ordinal","previous_attempt","rollback_disposition",
      "root_incident","schema_version","sealed_at","writer_version"] and
    .schema_version == $schema and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .id == $id and (.operation | operation) and (.manifest | absolute_path) and
    (.manifest_sha256 | digest) and (.sealed_at | timestamp) and
    (.manifest_status == "completed" or .manifest_status == "failed" or
      .manifest_status == "stale") and
    (.incident_status == "completed" or .incident_status == "failed" or
      .incident_status == "stale" or .incident_status == "publication-uncertain") and
    (.failure == null or (.failure | failure)) and
    (.rollback_disposition == "manifest-recorded" or
      .rollback_disposition == "not-attempted-stable-publication-ambiguous") and
    (if .kind == "root" then
      .ordinal == 0 and .root_incident == null and .previous_attempt == null and
      .incident_status != "completed"
    elif .kind == "attempt" then
      (.ordinal | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
      (.root_incident | incident_reference) and .root_incident.kind == "root" and
      (if .ordinal == 1 then .previous_attempt == null
       else (.previous_attempt | incident_reference) and
         .previous_attempt.kind == "attempt" and
         .previous_attempt.ordinal == (.ordinal - 1)
       end)
    else false end) and
    (if .incident_status == "publication-uncertain" then
      .kind == "root" and .manifest_status == "completed" and .failure != null and
      .rollback_disposition == "not-attempted-stable-publication-ambiguous"
    elif .incident_status == "completed" then
      .kind == "attempt" and .manifest_status == "completed" and .failure == null and
      .rollback_disposition == "manifest-recorded"
    else
      .manifest_status == .incident_status and .failure != null and
      .rollback_disposition == "manifest-recorded"
    end)
  ' <<< "$document" >/dev/null
}

read_incident_seal() {
  local transaction_id="$1" path document saved manifest_hash manifest_status
  local manifest_operation manifest_kind manifest_recovery schema kind ordinal
  _incident_json=""
  _incident_read_status=absent
  path=$(lifecycle_incident_path "$transaction_id") || {
    _incident_read_status=malformed
    return 1
  }
  [[ -e "$path" || -L "$path" ]] || return 1
  if ! validate_private_control_file "$path"; then
    _incident_read_status=control-state-ambiguous
    return 1
  fi
  if ! document=$(read_control_document "$path"); then
    _incident_read_status=malformed
    return 1
  fi
  schema=$(jq -r 'if (.schema_version | type) == "number" and
    (.schema_version | floor) == .schema_version then .schema_version else "invalid" end' \
    <<< "$document") || {
      _incident_read_status=malformed
      return 1
    }
  if [[ "$schema" == invalid ]]; then
    _incident_read_status=malformed
    return 1
  fi
  if [[ "$schema" != "$LIFECYCLE_SCHEMA_VERSION" ]]; then
    _incident_read_status=unsupported-schema
    return 1
  fi
  kind=$(jq -r '.kind // ""' <<< "$document") || return 1
  ordinal=$(jq -r '.ordinal // ""' <<< "$document") || return 1
  if [[ "$kind" == attempt && "$ordinal" =~ ^[0-9]+$ ]] \
    && (( ordinal > MAX_RECOVERY_ATTEMPT_SEALS )); then
    _incident_read_status=attempt-limit
    return 2
  fi
  if ! validate_incident_seal_json "$transaction_id" "$document"; then
    _incident_read_status=malformed
    return 1
  fi
  [[ "$(jq -r '.manifest' <<< "$document")" == \
    "$(lifecycle_manifest_path "$transaction_id")" ]] || {
      _incident_read_status=control-state-ambiguous
      return 1
    }
  manifest_hash=$(jq -r '.manifest_sha256' <<< "$document") || return 1
  [[ "$(sha256_file "$(lifecycle_manifest_path "$transaction_id")")" == \
    "$manifest_hash" ]] || {
      _incident_read_status=control-state-ambiguous
      return 1
    }

  saved="$document"
  if ! read_transaction_manifest "$transaction_id"; then
    _incident_read_status=control-state-ambiguous
    return 1
  fi
  manifest_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  manifest_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  manifest_kind=$(jq -r '.kind' <<< "$_manifest_json") || return 1
  [[ "$manifest_status" == "$(jq -r '.manifest_status' <<< "$saved")" \
    && "$manifest_operation" == "$(jq -r '.operation' <<< "$saved")" ]] || {
      _incident_read_status=control-state-ambiguous
      return 1
    }
  if [[ $(jq -r '.kind' <<< "$saved") == root ]]; then
    [[ "$manifest_kind" == root \
      && $(jq -r '.recovery == null' <<< "$_manifest_json") == true ]] || {
        _incident_read_status=control-state-ambiguous
        return 1
      }
  else
    [[ "$manifest_kind" == recovery-attempt ]] || {
      _incident_read_status=control-state-ambiguous
      return 1
    }
    manifest_recovery=$(jq -c '.recovery' <<< "$_manifest_json") || return 1
    [[ "$(jq -r '.attempt_number' <<< "$manifest_recovery")" == \
      "$(jq -r '.ordinal' <<< "$saved")" \
      && "$(jq -Sc '.root_incident' <<< "$manifest_recovery")" == \
        "$(jq -Sc '.root_incident' <<< "$saved")" \
      && "$(jq -Sc '.previous_attempt' <<< "$manifest_recovery")" == \
          "$(jq -Sc '.previous_attempt' <<< "$saved")" ]] || {
        _incident_read_status=control-state-ambiguous
        return 1
      }
  fi
  if [[ $(jq -r '.incident_status' <<< "$saved") == failed \
    || $(jq -r '.incident_status' <<< "$saved") == stale ]]; then
    [[ "$(jq -Sc '.failure' <<< "$_manifest_json")" == \
      "$(jq -Sc '.failure' <<< "$saved")" ]] || {
        _incident_read_status=control-state-ambiguous
        return 1
      }
  fi
  _incident_json="$saved"
  _incident_read_status=supported
}

validate_incident_reference() {
  local reference="$1" id path hash saved
  _incident_read_status=malformed
  jq -e --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def operation:
      type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9-]*$");
    def digest: type == "string" and test("^[0-9a-f]{64}$");
    type == "object" and
    keys == ["id","kind","operation","ordinal","path","sha256","status"] and
    (.id | uuid) and (.operation | operation) and (.sha256 | digest) and
    (if .kind == "root" then
      .ordinal == 0 and
      (.status == "failed" or .status == "stale" or .status == "publication-uncertain")
    elif .kind == "attempt" then
      (.ordinal | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
      (.status == "failed" or .status == "stale" or .status == "completed")
    else false end)
  ' <<< "$reference" >/dev/null || return 1
  id=$(jq -r '.id' <<< "$reference") || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  hash=$(jq -r '.sha256' <<< "$reference") || return 1
  [[ "$path" == "$(lifecycle_incident_path "$id")" ]] || return 1
  if ! validate_private_control_file "$path" \
    || [[ "$(sha256_file "$path")" != "$hash" ]]; then
    _incident_read_status=control-state-ambiguous
    return 1
  fi
  read_incident_seal "$id" || return 1
  saved="$_incident_json"
  jq -e --argjson reference "$reference" '
    .id == $reference.id and .kind == $reference.kind and
    .operation == $reference.operation and .ordinal == $reference.ordinal and
    .incident_status == $reference.status
  ' <<< "$saved" >/dev/null || return 1
  _incident_json="$saved"
}

validate_incident_chain() {
  local root_reference="$1" latest_reference="$2" attempt_count="$3"
  local resolved="${4:-false}" expected current seal root_document root_service
  local current_id current_status attempt_service root_producer
  local -A seen=()
  _recovery_root_service_json=""
  [[ "$attempt_count" =~ ^[0-9]+$ ]] || return 1
  if (( attempt_count > MAX_RECOVERY_ATTEMPT_SEALS )); then
    _incident_read_status=attempt-limit
    return 2
  fi
  validate_incident_reference "$root_reference" || return 1
  root_document="$_incident_json"
  [[ $(jq -r '.kind' <<< "$root_document") == root ]] || return 1
  root_service=$(jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" '{
    ($unit): {
      load_state: .service_state[$unit].load_state,
      active_state: .service_state[$unit].active_state,
      unit_file_state: .service_state[$unit].unit_file_state
    }
  }' <<< "$_manifest_json") || return 1
  _recovery_root_service_json="$root_service"
  root_producer=$(jq -c '.domain_records.producer' <<< "$_manifest_json") || return 1
  current="$latest_reference"
  if (( attempt_count == 0 )); then
    [[ "$current" == null && "$resolved" == false ]] || return 1
    _incident_json="$root_document"
    return 0
  fi
  [[ "$current" != null ]] || return 1

  expected=$attempt_count
  while (( expected > 0 )); do
    validate_incident_reference "$current" || return 1
    seal="$_incident_json"
    current_id=$(jq -r '.id' <<< "$seal") || return 1
    [[ -z "${seen[$current_id]:-}" ]] || return 1
    seen["$current_id"]=1
    [[ "$current_id" != "$(jq -r '.id' <<< "$root_reference")" \
      && $(jq -r '.kind' <<< "$seal") == attempt \
      && $(jq -r '.ordinal' <<< "$seal") == "$expected" \
      && "$(jq -Sc '.root_incident' <<< "$seal")" == \
        "$(jq -Sc . <<< "$root_reference")" ]] || return 1
    if [[ "$root_producer" != null ]]; then
      [[ $(jq -r '.operation' <<< "$seal") == producer-recovery ]] || return 1
    fi
    current_status=$(jq -r '.incident_status' <<< "$seal") || return 1
    attempt_service=$(jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" '{
      ($unit): {
        load_state: .service_state[$unit].load_state,
        active_state: .service_state[$unit].active_state,
        unit_file_state: .service_state[$unit].unit_file_state
      }
    }' <<< "$_manifest_json") || return 1
    [[ "$attempt_service" == "$root_service" ]] || return 1
    if (( expected == attempt_count )) && [[ "$resolved" == true ]]; then
      [[ "$current_status" == completed ]] || return 1
    else
      [[ "$current_status" == failed || "$current_status" == stale ]] || return 1
    fi
    current=$(jq -c '.previous_attempt' <<< "$seal") || return 1
    expected=$((expected - 1))
  done
  [[ "$current" == null ]] || return 1
  _incident_json="$root_document"
}

validate_lifecycle_document_references() {
  local document="$1" state transaction_id manifest operation kind root latest count
  local reference saved_manifest saved_manifest_id saved_manifest_hash rc
  local attempt_service attempt_number final_attempt_id final_attempt_manifest final_proof
  state=$(jq -r '.state' <<< "$document") || return 1

  while IFS= read -r reference; do
    [[ -z "$reference" ]] || validate_artifact_reference_file "$reference" || return 1
  done < <(jq -c '.managed_settings, .tracking_ownership | select(. != null)' \
    <<< "$document")

  if [[ $(jq -r '.last_transaction != null' <<< "$document") == true ]]; then
    transaction_id=$(jq -r '.last_transaction.id' <<< "$document") || return 1
    manifest=$(jq -r '.last_transaction.manifest' <<< "$document") || return 1
    [[ "$manifest" == "$(lifecycle_manifest_path "$transaction_id")" \
      && "$(sha256_file "$manifest")" == \
        "$(jq -r '.last_transaction.manifest_sha256' <<< "$document")" ]] || return 1
    validate_completed_transaction_reference "$document" || return 1
  fi

  if [[ "$state" == transition ]]; then
    transaction_id=$(jq -r '.transaction.id' <<< "$document") || return 1
    manifest=$(jq -r '.transaction.manifest' <<< "$document") || return 1
    operation=$(jq -r '.transaction.operation' <<< "$document") || return 1
    kind=$(jq -r '.transaction.kind' <<< "$document") || return 1
    [[ "$manifest" == "$(lifecycle_manifest_path "$transaction_id")" ]] || return 1
    read_transaction_manifest "$transaction_id" || return 1
    [[ $(jq -r '.operation' <<< "$_manifest_json") == "$operation" \
      && $(jq -r '.kind' <<< "$_manifest_json") == "$kind" ]] || return 1
    if [[ "$kind" == root ]]; then
      [[ $(jq -r '.recovery == null' <<< "$_manifest_json") == true ]] || return 1
    else
      saved_manifest="$_manifest_json"
      saved_manifest_id="$_manifest_id"
      saved_manifest_hash="$_manifest_sha256"
      [[ "$(jq -r '.recovery.attempt_number' <<< "$_manifest_json")" == \
        "$(jq -r '.transaction.attempt_number' <<< "$document")" \
        && "$(jq -Sc '.recovery.root_incident' <<< "$_manifest_json")" == \
          "$(jq -Sc '.transaction.root_incident' <<< "$document")" \
        && "$(jq -Sc '.recovery.previous_attempt' <<< "$_manifest_json")" == \
          "$(jq -Sc '.transaction.previous_attempt' <<< "$document")" ]] || return 1
      root=$(jq -c '.transaction.root_incident' <<< "$document") || return 1
      latest=$(jq -c '.transaction.previous_attempt' <<< "$document") || return 1
      attempt_number=$(jq -r '.transaction.attempt_number' <<< "$document") || return 1
      validate_incident_chain "$root" "$latest" "$((attempt_number - 1))" false \
        || return $?
      attempt_service=$(jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" '{
        ($unit): {
          load_state: .service_state[$unit].load_state,
          active_state: .service_state[$unit].active_state,
          unit_file_state: .service_state[$unit].unit_file_state
        }
      }' <<< "$saved_manifest") || return 1
      [[ "$attempt_service" == "$_recovery_root_service_json" ]] || return 1
      _manifest_json="$saved_manifest"
      _manifest_id="$saved_manifest_id"
      _manifest_sha256="$saved_manifest_hash"
    fi
  elif [[ "$state" == recovery-required ]]; then
    root=$(jq -c '.transaction.root_incident' <<< "$document") || return 1
    latest=$(jq -c '.transaction.last_recovery_attempt' <<< "$document") || return 1
    count=$(jq -r '.transaction.attempt_count' <<< "$document") || return 1
    validate_incident_chain "$root" "$latest" "$count" false || return $?
    saved_manifest="$_incident_json"
    transaction_id=$(jq -r '.transaction.id' <<< "$document") || return 1
    [[ "$transaction_id" == "$(jq -r '.id' <<< "$saved_manifest")" \
      && $(jq -r '.transaction.operation' <<< "$document") == \
        "$(jq -r '.operation' <<< "$saved_manifest")" \
      && $(jq -r '.transaction.manifest' <<< "$document") == \
        "$(jq -r '.manifest' <<< "$saved_manifest")" ]] || return 1
  fi

  if [[ $(jq -r '.last_recovery != null' <<< "$document") == true ]]; then
    saved_manifest="$_manifest_json"
    saved_manifest_id="$_manifest_id"
    saved_manifest_hash="$_manifest_sha256"
    root=$(jq -c '.last_recovery.root_incident' <<< "$document") || return 1
    latest=$(jq -c '.last_recovery.final_attempt' <<< "$document") || return 1
    count=$(jq -r '.last_recovery.attempt_count' <<< "$document") || return 1
    validate_incident_chain "$root" "$latest" "$count" true || {
      rc=$?
      return "$rc"
    }
    reference=$(jq -c '.last_recovery.proof' <<< "$document") || return 1
    validate_artifact_reference_file "$reference" || return 1
    final_attempt_id=$(jq -r '.last_recovery.final_attempt.id' <<< "$document") || return 1
    final_attempt_manifest=$(jq -r '.last_recovery.final_attempt.path' <<< "$document") \
      || return 1
    read_incident_seal "$final_attempt_id" || return 1
    [[ $(jq -r '.kind' <<< "$_incident_json") == attempt \
      && $(jq -r '.incident_status' <<< "$_incident_json") == completed ]] || return 1
    read_transaction_manifest "$final_attempt_id" || return 1
    final_proof=$(jq -c '.domain_records.final_proof' <<< "$_manifest_json") || return 1
    [[ "$final_proof" != null \
      && "$(jq -Sc . <<< "$final_proof")" == "$(jq -Sc . <<< "$reference")" \
      && "$final_attempt_manifest" == "$(lifecycle_incident_path "$final_attempt_id")" ]] \
      || return 1
    jq -e --arg id "$final_attempt_id" \
      --arg manifest "$(lifecycle_manifest_path "$final_attempt_id")" '
        if .last_transaction.id == $id then
          .last_transaction.manifest == $manifest and
          .last_transaction.operation == .last_recovery.final_attempt.operation
        else
          .last_transaction.completed_at >= .last_recovery.resolved_at
        end
      ' <<< "$document" >/dev/null || return 1
    _manifest_json="$saved_manifest"
    _manifest_id="$saved_manifest_id"
    _manifest_sha256="$saved_manifest_hash"
  fi
}

validate_completed_transaction_reference() {
  local document="$1" transaction_id state
  [[ $(jq -r '.last_transaction != null' <<< "$document") == true ]] || return 0
  state=$(jq -r '.state' <<< "$document") || return 1
  transaction_id=$(jq -r '.last_transaction.id' <<< "$document") || return 1
  read_transaction_manifest "$transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == completed \
    && $(jq -r '.operation' <<< "$_manifest_json") == \
      "$(jq -r '.last_transaction.operation' <<< "$document")" \
    && $(jq -r '.completed_at' <<< "$_manifest_json") == \
      "$(jq -r '.last_transaction.completed_at' <<< "$document")" ]] || return 1
  if [[ "$state" == active || "$state" == disabled ]]; then
    [[ $(jq -r '.target_state' <<< "$_manifest_json") == "$state" ]] || return 1
  fi
}

read_lifecycle() {
  local state_dir state_file document schema references_rc attempt_count
  state_dir=$(state_dir_path)
  state_file=$(lifecycle_file_path)
  _lifecycle_state=unmanaged
  _lifecycle_generation=0
  _lifecycle_transaction_id=""
  _lifecycle_json=""
  _lifecycle_read_status=absent

  if [[ ! -e "$state_dir" && ! -L "$state_dir" ]]; then
    return 0
  fi
  if ! validate_control_directory "$state_dir"; then
    _lifecycle_read_status=control-state-ambiguous
    return 1
  fi
  if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
    return 0
  fi
  if ! validate_control_file "$state_file"; then
    _lifecycle_read_status=control-state-ambiguous
    return 1
  fi
  if ! document=$(read_control_document "$state_file"); then
    _lifecycle_read_status=malformed
    return 1
  fi
  schema=$(jq -r 'if (.schema_version | type) == "number" and
    (.schema_version | floor) == .schema_version then .schema_version else "invalid" end' \
    <<< "$document") || {
      _lifecycle_read_status=malformed
      return 1
    }
  if [[ "$schema" == invalid ]]; then
    _lifecycle_read_status=malformed
    return 1
  fi
  if [[ "$schema" != "$LIFECYCLE_SCHEMA_VERSION" ]]; then
    _lifecycle_read_status=unsupported-schema
    return 1
  fi
  attempt_count=$(jq -r 'if .state == "recovery-required" and
    (.transaction.attempt_count | type) == "number" then .transaction.attempt_count
    elif .last_recovery != null and (.last_recovery.attempt_count | type) == "number"
    then .last_recovery.attempt_count else 0 end' <<< "$document") || {
      _lifecycle_read_status=malformed
      return 1
    }
  if [[ "$attempt_count" =~ ^[0-9]+$ ]] \
    && (( attempt_count > MAX_RECOVERY_ATTEMPT_SEALS )); then
    _lifecycle_read_status=attempt-limit
    return 1
  fi
  if ! validate_lifecycle_json "$document"; then
    _lifecycle_read_status=malformed
    return 1
  fi
  validate_lifecycle_document_references "$document"
  references_rc=$?
  if [[ $references_rc -ne 0 ]]; then
    if [[ $references_rc -eq 2 ]]; then
      _lifecycle_read_status=attempt-limit
    else
      _lifecycle_read_status=control-state-ambiguous
    fi
    return 1
  fi

  _lifecycle_json="$document"
  _lifecycle_state=$(jq -r '.state' <<< "$document") || return 1
  _lifecycle_generation=$(jq -r '.generation' <<< "$document") || return 1
  if [[ "$_lifecycle_state" == transition || "$_lifecycle_state" == recovery-required ]]; then
    _lifecycle_transaction_id=$(jq -r '.transaction.id' <<< "$document") || return 1
  fi
  _lifecycle_read_status=supported
}

validate_legacy_disabled_manifest() {
  local transaction_id="$1" document="$2" converted
  jq -e --arg id "$transaction_id" '
    type == "object" and
    keys == ["backups","boot_id","completed_at","completed_phases","created_at",
      "current_phase","enrollment_plan","failure","file_rollback_policy","firmware_backup",
      "firmware_writes","id","operation","owner","prior_state","rollback","schema_version",
      "service_state","status","target_state","token_sha256","writer_version"] and
    .schema_version == 1 and .id == $id and .status == "completed" and
    .target_state == "disabled"
  ' <<< "$document" >/dev/null || return 1
  converted=$(jq -c --argjson schema "$LIFECYCLE_SCHEMA_VERSION" '
    .schema_version = $schema |
    .kind = "root" |
    .recovery = null |
    .domain_records = {
      bootnext: null,
      final_proof: null,
      firmware: null,
      managed_settings: null,
      producer: null,
      tracking_ownership: null,
      unconfigure: null,
      windows: null
    }
  ' <<< "$document") || return 1
  validate_transaction_manifest_json "$transaction_id" "$converted"
}

validate_legacy_disabled_lifecycle() {
  local document="$1" transaction_id manifest manifest_document
  jq -e '
    def uuid:
      type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
    def operation:
      type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9-]*$");
    def timestamp:
      type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def adoption:
      type == "object" and keys == ["managed_settings","recorded_at","source"] and
      .source == "explicit" and (.recorded_at | timestamp) and
      (.managed_settings | type == "array" and length == 4) and
      (.managed_settings[0] | keys == ["key","observed","original","path"] and
        .path == "/etc/default/limine" and .key == "ENABLE_VERIFICATION" and
        (.observed == "yes" or .observed == "no" or .observed == "unset") and
        (.original == "yes" or .original == "no" or .original == "unset" or
          .original == "unknown")) and
      (.managed_settings[1] | keys == ["key","observed","original","path"] and
        .path == "/etc/default/limine" and .key == "ENABLE_ENROLL_LIMINE_CONFIG" and
        (.observed == "yes" or .observed == "no" or .observed == "unset") and
        (.original == "yes" or .original == "no" or .original == "unset" or
          .original == "unknown")) and
      (.managed_settings[2] | keys == ["key","observed","original","path","token"] and
        .path == "/etc/default/limine" and .key == "COMMANDS_BEFORE_SAVE" and
        .token == "limine-reset-enroll" and
        (.observed == "present" or .observed == "absent") and
        (.original == "present" or .original == "absent" or .original == "unknown")) and
      (.managed_settings[3] | keys == ["key","observed","original","path","token"] and
        .path == "/etc/default/limine" and .key == "COMMANDS_AFTER_SAVE" and
        .token == "limine-enroll-config" and
        (.observed == "present" or .observed == "absent") and
        (.original == "present" or .original == "absent" or .original == "unknown"));
    def completed_transaction:
      type == "object" and keys == ["completed_at","id","manifest","operation"] and
      (.id | uuid) and (.operation | operation) and
      (.manifest | type == "string" and startswith("/")) and (.completed_at | timestamp);
    type == "object" and
    keys == ["adoption","generation","last_transaction","schema_version","state",
      "transaction","updated_at","writer_version"] and
    .schema_version == 1 and .state == "disabled" and .transaction == null and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.generation | type == "number" and . >= 1 and floor == .) and
    (.updated_at | timestamp) and (.adoption == null or (.adoption | adoption)) and
    (.last_transaction | completed_transaction)
  ' <<< "$document" >/dev/null || return 1
  transaction_id=$(jq -r '.last_transaction.id' <<< "$document") || return 1
  manifest=$(jq -r '.last_transaction.manifest' <<< "$document") || return 1
  [[ "$manifest" == "$(lifecycle_manifest_path "$transaction_id")" ]] || return 1
  validate_private_control_directory "$(dirname "$manifest")" || return 1
  validate_private_control_file "$manifest" || return 1
  manifest_document=$(read_control_document "$manifest") || return 1
  validate_legacy_disabled_manifest "$transaction_id" "$manifest_document" || return 1
  [[ $(jq -r '.operation' <<< "$manifest_document") == \
      "$(jq -r '.last_transaction.operation' <<< "$document")" \
    && $(jq -r '.completed_at' <<< "$manifest_document") == \
      "$(jq -r '.last_transaction.completed_at' <<< "$document")" ]]
}

lifecycle_removal_is_allowed() {
  local state_dir state_file document schema result=1
  local saved_manifest="$_manifest_json"
  local saved_id="$_manifest_id" saved_hash="$_manifest_sha256"
  state_dir=$(state_dir_path)
  state_file=$(lifecycle_file_path)
  if [[ ! -e "$state_dir" && ! -L "$state_dir" ]]; then
    return 0
  fi
  validate_control_directory "$state_dir" || return 1
  if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
    return 0
  fi
  document=$(read_control_document "$state_file") || return 1
  schema=$(jq -r 'if (.schema_version | type) == "number" and
    (.schema_version | floor) == .schema_version then .schema_version else "invalid" end' \
    <<< "$document") || return 1
  if [[ "$schema" == "$LIFECYCLE_SCHEMA_VERSION" ]]; then
    if validate_lifecycle_json "$document" \
      && [[ $(jq -r '.state' <<< "$document") == disabled ]] \
      && validate_lifecycle_document_references "$document"; then
      result=0
    fi
  elif [[ "$schema" == "$LEGACY_LIFECYCLE_SCHEMA_VERSION" ]]; then
    if validate_legacy_disabled_lifecycle "$document"; then
      result=0
    fi
  fi
  _manifest_json="$saved_manifest"
  _manifest_id="$saved_id"
  _manifest_sha256="$saved_hash"
  return "$result"
}

read_recovery_incident() {
  local root
  _recovery_incident_json=""
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == recovery-required ]] || return 1
  root=$(jq -c '.transaction.root_incident' <<< "$_lifecycle_json") || return 1
  validate_incident_reference "$root" || return 1
  _recovery_incident_json="$_incident_json"
}

recovery_attempt_capacity_available() {
  read_recovery_incident || return 1
  (( $(jq -r '.transaction.attempt_count' <<< "$_lifecycle_json") <
    MAX_RECOVERY_ATTEMPT_SEALS ))
}

reset_recovery_context() {
  _recovery_root_reference=""
  _recovery_root_manifest_json=""
  _recovery_previous_reference="null"
  _recovery_attempt_count=0
  _recovery_target_state=""
  _recovery_producer_reference="null"
}

load_producer_recovery_context() {
  local root_id producer_path producer_document
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  reset_recovery_context
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == recovery-required ]] || return 1
  _recovery_root_reference=$(jq -c '.transaction.root_incident' \
    <<< "$_lifecycle_json") || return 1
  _recovery_previous_reference=$(jq -c '.transaction.last_recovery_attempt' \
    <<< "$_lifecycle_json") || return 1
  _recovery_attempt_count=$(jq -r '.transaction.attempt_count' \
    <<< "$_lifecycle_json") || return 1
  (( _recovery_attempt_count < MAX_RECOVERY_ATTEMPT_SEALS )) || {
    _incident_read_status=attempt-limit
    return 2
  }
  validate_incident_chain "$_recovery_root_reference" "$_recovery_previous_reference" \
    "$_recovery_attempt_count" false || return $?
  root_id=$(jq -r '.id' <<< "$_recovery_root_reference") || return 1
  validate_incident_reference "$_recovery_root_reference" || return 1
  read_transaction_manifest "$root_id" || return 1
  _recovery_root_manifest_json="$_manifest_json"
  _recovery_target_state=$(jq -r '.target_state' <<< "$_recovery_root_manifest_json") \
    || return 1
  _recovery_producer_reference=$(jq -c '.domain_records.producer' \
    <<< "$_recovery_root_manifest_json") || return 1
  [[ "$_recovery_target_state" == active && "$_recovery_producer_reference" != null ]] \
    || return 1
  jq -e '
    .kind == "root" and .prior_state == "active" and
    .file_rollback_policy == "preserve" and
    .firmware_backup == null and .enrollment_plan == null and .firmware_writes == [] and
    .domain_records.bootnext == null and .domain_records.firmware == null and
    .domain_records.managed_settings == null and
    .domain_records.tracking_ownership == null and .domain_records.unconfigure == null and
    .domain_records.windows == null
  ' <<< "$_recovery_root_manifest_json" >/dev/null || return 1
  validate_producer_record_reference "$root_id" "$_recovery_producer_reference" || return 1
  producer_path=$(jq -r '.path' <<< "$_recovery_producer_reference") || return 1
  producer_document=$(read_control_document "$producer_path") || return 1
  [[ $(jq -r '.operation' <<< "$_recovery_root_manifest_json") == \
    "$(jq -r '.operation' <<< "$producer_document")" ]] || return 1
}

manifest_owner_is_alive() {
  local boot_id owner_pid owner_start current_start owner_uid owner_state
  boot_id=$(jq -r '.boot_id' <<< "$_manifest_json") || return 1
  [[ "$boot_id" == "$(boot_id_value)" ]] || return 1
  owner_pid=$(jq -r '.owner.pid' <<< "$_manifest_json") || return 1
  owner_start=$(jq -r '.owner.start_time' <<< "$_manifest_json") || return 1
  owner_uid=$(process_effective_uid "$owner_pid") || return 1
  [[ "$owner_uid" == "$(control_owner_uid)" ]] || return 1
  current_start=$(process_start_time "$owner_pid") || return 1
  [[ "$current_start" == "$owner_start" ]] || return 1
  owner_state=$(process_state "$owner_pid") || return 1
  [[ "$owner_state" != Z && "$owner_state" != X && "$owner_state" != x ]]
}

write_transition_lifecycle() {
  local transaction_id="$1" operation="$2" manifest="$3" timestamp="$4"
  local base generation document

  if [[ "$_lifecycle_state" == unmanaged ]]; then
    base=$(jq -cn --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
      --arg version "$OMASECBOOT_VERSION" '{
      schema_version: $schema,
      writer_version: $version,
      generation: 0,
      state: "unmanaged",
      transaction: null,
      last_transaction: null,
      last_recovery: null,
      adoption: null,
      managed_settings: null,
      tracking_ownership: null,
      updated_at: null
    }') || return 1
  else
    base="$_lifecycle_json"
  fi
  generation=$((_lifecycle_generation + 1))

  document=$(jq -cn \
    --argjson base "$base" \
    --arg version "$OMASECBOOT_VERSION" \
    --argjson generation "$generation" \
    --arg id "$transaction_id" \
    --arg operation "$operation" \
    --arg manifest "$manifest" \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg timestamp "$timestamp" '
      $base |
      .schema_version = $schema |
      .writer_version = $version |
      .generation = $generation |
      .state = "transition" |
      .transaction = {
        attempt_number: null,
        id: $id,
        kind: "root",
        operation: $operation,
        manifest: $manifest,
        previous_attempt: null,
        root_incident: null
      } |
      .updated_at = $timestamp
    ') || return 1
  validate_lifecycle_json "$document" || return 1
  validate_lifecycle_document_references "$document" || return 1
  printf '%s\n' "$document" | atomic_write_control_file "$(lifecycle_file_path)" 644
}

begin_lifecycle_transaction() {
  local operation="$1" target_state="$2"
  local transaction_id token token_hash boot_id owner_pid owner_start timestamp
  local transaction_dir manifest prior_backup prior_hash backups service_state
  local manifest_document

  [[ "$operation" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [[ "$target_state" == active || "$target_state" == disabled ]] || return 1
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == unmanaged || "$_lifecycle_state" == active \
    || "$_lifecycle_state" == disabled ]] || return 1

  transaction_id=$(new_transaction_id) || return 1
  token=$(new_transaction_token) || return 1
  token_hash=$(sha256_text "$token") || return 1
  boot_id=$(boot_id_value) || return 1
  owner_pid=$BASHPID
  [[ "$(process_effective_uid "$owner_pid")" == "$(control_owner_uid)" ]] \
    || return 1
  process_has_ancestor "$owner_pid" "$BASHPID" || return 1
  owner_start=$(process_start_time "$owner_pid") || return 1
  timestamp=$(utc_timestamp) || return 1
  service_state=$(capture_service_state) || return 1
  service_state=$(prepare_transaction_service_state "$service_state") || return 1
  transaction_dir="$(transactions_dir_path)/${transaction_id}"
  manifest="${transaction_dir}/manifest.json"

  install -d -m 700 "$transaction_dir" || return 1
  validate_control_directory "$transaction_dir" || return 1
  durable_sync "$(transactions_dir_path)" || return 1

  if [[ "$_lifecycle_state" == unmanaged ]]; then
    backups='[{"path":null,"sha256":null,"kind":"absent-lifecycle","target":null}]'
  else
    prior_backup="${transaction_dir}/prior-lifecycle.json"
    cp -p "$(lifecycle_file_path)" "$prior_backup" || return 1
    chmod 600 "$prior_backup" || return 1
    validate_private_control_file "$prior_backup" || return 1
    durable_sync "$prior_backup" || return 1
    prior_hash=$(sha256_file "$prior_backup") || return 1
    backups=$(jq -cn --arg path "$prior_backup" --arg hash "$prior_hash" \
      '[{path: $path, sha256: $hash, kind: "prior-lifecycle", target: null}]') || return 1
  fi

  manifest_document=$(jq -cn \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg operation "$operation" \
    --arg target "$target_state" \
    --arg timestamp "$timestamp" \
    --arg boot_id "$boot_id" \
    --arg token_hash "$token_hash" \
    --argjson owner_pid "$owner_pid" \
    --arg owner_start "$owner_start" \
    --argjson owner_uid "$(control_owner_uid)" \
    --arg prior_state "$_lifecycle_state" \
    --argjson backups "$backups" \
    --argjson service_state "$service_state" '{
      schema_version: $schema,
      writer_version: $version,
      id: $id,
      kind: "root",
      operation: $operation,
      target_state: $target,
      status: "transition",
      created_at: $timestamp,
      completed_at: null,
      boot_id: $boot_id,
      token_sha256: $token_hash,
      owner: {
        pid: $owner_pid,
        start_time: $owner_start,
        uid: $owner_uid
      },
      prior_state: $prior_state,
      recovery: null,
      current_phase: null,
      completed_phases: [],
      backups: $backups,
      service_state: $service_state,
      file_rollback_policy: "restore",
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
      failure: null,
      rollback: null
    }') || return 1
  validate_transaction_manifest_json "$transaction_id" "$manifest_document" || return 1
  printf '%s\n' "$manifest_document" | atomic_write_control_file "$manifest" 600 \
    || return 1
  _manifest_json="$manifest_document"
  _manifest_id="$transaction_id"
  _manifest_sha256=$(sha256_file "$manifest") || return 1
  lifecycle_failpoint "after-manifest-write" || return 1
  _transaction_active=true
  _transaction_id="$transaction_id"
  _transaction_token="$token"
  _transaction_operation="$operation"
  _transaction_target_state="$target_state"
  OMASECBOOT_TRANSACTION_ID="$transaction_id"
  OMASECBOOT_TRANSACTION_TOKEN="$token"
  export OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
  write_transition_lifecycle "$transaction_id" "$operation" "$manifest" "$timestamp" \
    || return 1
  lifecycle_failpoint "after-transition-write" || return 1
  quiesce_transaction_service
}

begin_producer_lifecycle_transaction() {
  local transaction_id="$1" producer_reference="$2" captured_service_state="$3"
  local backups="$4" transaction_dir manifest producer_path producer_document
  local operation owner_pid owner_start owner_uid boot_id token token_hash timestamp
  local service_state manifest_document

  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == active ]] || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  manifest="${transaction_dir}/manifest.json"
  validate_private_control_directory "$transaction_dir" || return 1
  [[ ! -e "$manifest" && ! -L "$manifest" ]] || return 1
  validate_producer_record_reference "$transaction_id" "$producer_reference" || return 1
  producer_path=$(jq -r '.path' <<< "$producer_reference") || return 1
  producer_document=$(read_control_document "$producer_path") || return 1
  operation=$(jq -r '.operation' <<< "$producer_document") || return 1
  owner_pid=$(jq -r '.owner.pid' <<< "$producer_document") || return 1
  owner_start=$(jq -r '.owner.start_time' <<< "$producer_document") || return 1
  owner_uid=$(jq -r '.owner.uid' <<< "$producer_document") || return 1
  boot_id=$(jq -r '.owner.boot_id' <<< "$producer_document") || return 1
  [[ "$boot_id" == "$(boot_id_value)" \
    && "$owner_uid" == "$(control_owner_uid)" \
    && "$(process_effective_uid "$owner_pid")" == "$owner_uid" \
    && "$(process_start_time "$owner_pid")" == "$owner_start" ]] || return 1
  process_matches_identity "$owner_pid" \
    "$(jq -r '.owner.identity_kind' <<< "$producer_document")" \
    "$(jq -r '.owner.identity' <<< "$producer_document")" || return 1
  process_has_ancestor "$owner_pid" "$BASHPID" || return 1
  validate_captured_service_state "$captured_service_state" || return 1
  service_state=$(prepare_transaction_service_state "$captured_service_state") || return 1
  token=$(new_transaction_token) || return 1
  token_hash=$(sha256_text "$token") || return 1
  timestamp=$(utc_timestamp) || return 1

  manifest_document=$(jq -cn \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg operation "$operation" \
    --arg timestamp "$timestamp" \
    --arg boot_id "$boot_id" \
    --arg token_hash "$token_hash" \
    --argjson owner_pid "$owner_pid" \
    --arg owner_start "$owner_start" \
    --argjson owner_uid "$owner_uid" \
    --argjson backups "$backups" \
    --argjson service_state "$service_state" \
    --argjson producer "$producer_reference" '{
      schema_version: $schema,
      writer_version: $version,
      id: $id,
      kind: "root",
      operation: $operation,
      target_state: "active",
      status: "transition",
      created_at: $timestamp,
      completed_at: null,
      boot_id: $boot_id,
      token_sha256: $token_hash,
      owner: {pid: $owner_pid, start_time: $owner_start, uid: $owner_uid},
      prior_state: "active",
      recovery: null,
      current_phase: null,
      completed_phases: [],
      backups: $backups,
      service_state: $service_state,
      file_rollback_policy: "preserve",
      firmware_backup: null,
      enrollment_plan: null,
      firmware_writes: [],
      domain_records: {
        bootnext: null,
        final_proof: null,
        firmware: null,
        managed_settings: null,
        producer: $producer,
        tracking_ownership: null,
        unconfigure: null,
        windows: null
      },
      failure: null,
      rollback: null
    }') || return 1
  validate_transaction_manifest_json "$transaction_id" "$manifest_document" || return 1
  printf '%s\n' "$manifest_document" | atomic_write_control_file "$manifest" 600 \
    || return 1
  _manifest_json="$manifest_document"
  _manifest_id="$transaction_id"
  _manifest_sha256=$(sha256_file "$manifest") || return 1
  lifecycle_failpoint "after-producer-manifest-write" || return 1
  _transaction_active=true
  _transaction_id="$transaction_id"
  _transaction_token="$token"
  _transaction_operation="$operation"
  _transaction_target_state=active
  OMASECBOOT_TRANSACTION_ID="$transaction_id"
  OMASECBOOT_TRANSACTION_TOKEN="$token"
  export OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
  write_transition_lifecycle "$transaction_id" "$operation" "$manifest" "$timestamp" \
    || return 1
  lifecycle_failpoint "after-producer-transition-write" || return 1
  apply_transaction_service_policy
}

write_recovery_attempt_transition_lifecycle() {
  local transaction_id="$1" manifest="$2" timestamp="$3" attempt_number
  local generation document
  [[ "$_lifecycle_state" == recovery-required ]] || return 1
  attempt_number=$((_recovery_attempt_count + 1))
  (( attempt_number <= MAX_RECOVERY_ATTEMPT_SEALS )) || return 2
  generation=$((_lifecycle_generation + 1))
  document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --argjson generation "$generation" \
    --arg id "$transaction_id" \
    --arg manifest "$manifest" \
    --arg timestamp "$timestamp" \
    --argjson attempt "$attempt_number" \
    --argjson root "$_recovery_root_reference" \
    --argjson previous "$_recovery_previous_reference" '
      .writer_version = $version |
      .generation = $generation |
      .state = "transition" |
      .transaction = {
        attempt_number: $attempt,
        id: $id,
        kind: "recovery-attempt",
        operation: "producer-recovery",
        manifest: $manifest,
        previous_attempt: $previous,
        root_incident: $root
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$document" || return 1
  validate_lifecycle_document_references "$document" || return 1
  printf '%s\n' "$document" | atomic_write_control_file "$(lifecycle_file_path)" 644
}

begin_lifecycle_recovery_attempt() {
  local transaction_id transaction_dir manifest prior_backup prior_hash backups
  local token token_hash boot_id owner_pid owner_start timestamp captured service_state
  local attempt_number manifest_document
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  load_producer_recovery_context || return $?
  attempt_number=$((_recovery_attempt_count + 1))
  (( attempt_number <= MAX_RECOVERY_ATTEMPT_SEALS )) || return 2

  transaction_id=$(new_transaction_id) || return 1
  token=$(new_transaction_token) || return 1
  token_hash=$(sha256_text "$token") || return 1
  boot_id=$(boot_id_value) || return 1
  owner_pid=$BASHPID
  [[ "$(process_effective_uid "$owner_pid")" == "$(control_owner_uid)" ]] \
    || return 1
  owner_start=$(process_start_time "$owner_pid") || return 1
  timestamp=$(utc_timestamp) || return 1
  captured=$(jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" '{
    ($unit): {
      load_state: .service_state[$unit].load_state,
      active_state: .service_state[$unit].active_state,
      unit_file_state: .service_state[$unit].unit_file_state
    }
  }' <<< "$_recovery_root_manifest_json") || return 1
  service_state=$(prepare_transaction_service_state "$captured") || return 1
  transaction_dir="$(transactions_dir_path)/${transaction_id}"
  manifest="${transaction_dir}/manifest.json"
  install -d -m 700 "$transaction_dir" || return 1
  validate_private_control_directory "$transaction_dir" || return 1
  durable_sync "$(transactions_dir_path)" || return 1
  prior_backup="${transaction_dir}/prior-lifecycle.json"
  cp -p "$(lifecycle_file_path)" "$prior_backup" || return 1
  chmod 600 "$prior_backup" || return 1
  validate_private_control_file "$prior_backup" || return 1
  durable_sync "$prior_backup" || return 1
  prior_hash=$(sha256_file "$prior_backup") || return 1
  backups=$(jq -cn --arg path "$prior_backup" --arg hash "$prior_hash" \
    '[{path: $path, sha256: $hash, kind: "prior-lifecycle", target: null}]') \
    || return 1

  manifest_document=$(jq -cn \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg timestamp "$timestamp" \
    --arg boot_id "$boot_id" \
    --arg token_hash "$token_hash" \
    --argjson owner_pid "$owner_pid" \
    --arg owner_start "$owner_start" \
    --argjson owner_uid "$(control_owner_uid)" \
    --argjson attempt "$attempt_number" \
    --argjson root "$_recovery_root_reference" \
    --argjson previous "$_recovery_previous_reference" \
    --argjson backups "$backups" \
    --argjson service_state "$service_state" '{
      schema_version: $schema,
      writer_version: $version,
      id: $id,
      kind: "recovery-attempt",
      operation: "producer-recovery",
      target_state: "active",
      status: "transition",
      created_at: $timestamp,
      completed_at: null,
      boot_id: $boot_id,
      token_sha256: $token_hash,
      owner: {pid: $owner_pid, start_time: $owner_start, uid: $owner_uid},
      prior_state: "recovery-required",
      recovery: {
        attempt_number: $attempt,
        previous_attempt: $previous,
        root_incident: $root
      },
      current_phase: null,
      completed_phases: [],
      backups: $backups,
      service_state: $service_state,
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
      failure: null,
      rollback: null
    }') || return 1
  validate_transaction_manifest_json "$transaction_id" "$manifest_document" || return 1
  printf '%s\n' "$manifest_document" | atomic_write_control_file "$manifest" 600 \
    || return 1
  _manifest_json="$manifest_document"
  _manifest_id="$transaction_id"
  _manifest_sha256=$(sha256_file "$manifest") || return 1
  lifecycle_failpoint "after-attempt-manifest-write" || return 1
  _transaction_active=true
  _transaction_id="$transaction_id"
  _transaction_token="$token"
  _transaction_operation="producer-recovery"
  _transaction_target_state=active
  OMASECBOOT_TRANSACTION_ID="$transaction_id"
  OMASECBOOT_TRANSACTION_TOKEN="$token"
  export OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
  write_recovery_attempt_transition_lifecycle "$transaction_id" "$manifest" "$timestamp" \
    || return $?
  lifecycle_failpoint "after-attempt-transition-write" || return 1
  apply_recovery_transaction_service_policy
}

validate_transaction_manifest_candidate_files() {
  local current="$1" candidate="$2" transaction_dir current_count candidate_count
  local entry kind path hash target mode uid gid firmware_id firmware_path plan_id plan_path
  local reference
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  current_count=$(jq -r '.backups | length' <<< "$current") || return 1
  candidate_count=$(jq -r '.backups | length' <<< "$candidate") || return 1
  (( candidate_count == current_count || candidate_count == current_count + 1 )) || return 1
  jq -e --argjson current "$current" --argjson count "$current_count" \
    '.backups[0:$count] == $current.backups' <<< "$candidate" >/dev/null || return 1

  if (( candidate_count == current_count + 1 )); then
    entry=$(jq -c '.backups[-1]' <<< "$candidate") || return 1
    kind=$(jq -r '.kind' <<< "$entry") || return 1
    target=$(jq -r '.target' <<< "$entry") || return 1
    [[ "$kind" == file || "$kind" == absent-file ]] || return 1
    [[ "$target" =~ ^/[^[:cntrl:]]+$ ]] || return 1
    path_has_no_symlink_components "$target" || return 1
    if [[ "$kind" == file ]]; then
      path=$(jq -r '.path' <<< "$entry") || return 1
      hash=$(jq -r '.sha256' <<< "$entry") || return 1
      mode=$(jq -r '.mode' <<< "$entry") || return 1
      uid=$(jq -r '.uid' <<< "$entry") || return 1
      gid=$(jq -r '.gid' <<< "$entry") || return 1
      [[ "$path" == "${transaction_dir}/file-${current_count}.backup" \
        && "$uid" == "$(control_owner_uid)" ]] || return 1
      mode_is_control_safe "$mode" || return 1
      validate_private_control_file "$path" || return 1
      [[ "$(sha256_file "$path")" == "$hash" \
        && "$gid" =~ ^[0-9]+$ ]] || return 1
    fi
  fi

  if [[ $(jq -r '.firmware_backup != null' <<< "$candidate") == true ]]; then
    firmware_id=$(jq -r '.firmware_backup.id' <<< "$candidate") || return 1
    firmware_path=$(jq -r '.firmware_backup.path' <<< "$candidate") || return 1
    [[ "$firmware_path" == \
      "$(state_dir_path)/firmware-backup/${firmware_id}" ]] || return 1
  fi
  if [[ $(jq -r '.enrollment_plan != null' <<< "$candidate") == true ]]; then
    plan_id=$(jq -r '.enrollment_plan.backup_id' <<< "$candidate") || return 1
    plan_path=$(jq -r '.enrollment_plan.path' <<< "$candidate") || return 1
    [[ "$plan_path" == "$(state_dir_path)/firmware-backup/${plan_id}/plan" ]] \
      || return 1
  fi
  while IFS= read -r reference; do
    [[ -z "$reference" ]] || validate_artifact_reference_file "$reference" "$transaction_dir" \
      || return 1
  done < <(jq -c '.domain_records[] | select(. != null)' <<< "$candidate")
}

write_transaction_manifest_json() {
  local document="$1" manifest incident current current_status next_status candidate
  [[ "$_transaction_active" == true \
    && "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  incident=$(lifecycle_incident_path "$_transaction_id") || return 1
  [[ ! -e "$incident" && ! -L "$incident" ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  current="$_manifest_json"
  candidate=$(jq -c . <<< "$document") || return 1
  validate_transaction_manifest_json "$_transaction_id" "$candidate" || return 1
  current_status=$(jq -r '.status' <<< "$current") || return 1
  next_status=$(jq -r '.status' <<< "$candidate") || return 1
  [[ "$current_status" == transition && "$next_status" == transition ]] || return 1
  jq -en --argjson current "$current" --argjson candidate "$candidate" \
    --arg unit "$TRANSACTION_SERVICE_UNIT" '
      def outcome_forward($old; $new):
        $old == $new or
        ($old == "pending" and ($new == "completed" or $new == "failed"));
      def firmware_writes_forward($old; $new):
        if $new == $old then true
        elif (($new | length) == (($old | length) + 1) and
          $new[0:($old | length)] == $old and
          $new[-1].command_exit_code == null and
          $new[-1].readback_status == "pending") then true
        elif (($new | length) == ($old | length) and ($old | length) > 0 and
          $new[0:-1] == $old[0:-1] and $old[-1].readback_status == "pending") then
          (($old[-1].command_exit_code == null and
            $new[-1].command_exit_code != null and
            ($old[-1] | .command_exit_code = $new[-1].command_exit_code) == $new[-1]) or
           ($new[-1].hierarchy == $old[-1].hierarchy and
            $new[-1].started_at == $old[-1].started_at and
            $new[-1].command_exit_code == $old[-1].command_exit_code and
            ($new[-1].readback_status == "unchanged" or
              $new[-1].readback_status == "verified" or
              $new[-1].readback_status == "failed") and
            $new[-1].completed_at != null))
        else false end;
      def envelope:
        del(.backups, .completed_phases, .current_phase, .domain_records,
          .enrollment_plan, .file_rollback_policy, .firmware_backup, .firmware_writes,
          .rollback, .service_state[$unit].quiesce_status,
          .service_state[$unit].restore_status);
      ($current | envelope) == ($candidate | envelope) and
      (($candidate.completed_phases == $current.completed_phases and
        ($candidate.current_phase == $current.current_phase or
          ($current.current_phase == null and $candidate.current_phase != null))) or
       ($current.current_phase != null and $candidate.current_phase == null and
        $candidate.completed_phases ==
          ($current.completed_phases + [$current.current_phase]))) and
      outcome_forward($current.service_state[$unit].quiesce_status;
        $candidate.service_state[$unit].quiesce_status) and
      outcome_forward($current.service_state[$unit].restore_status;
        $candidate.service_state[$unit].restore_status) and
      ($current.file_rollback_policy == $candidate.file_rollback_policy or
        ($current.file_rollback_policy == "restore" and
          $candidate.file_rollback_policy == "preserve")) and
      ($current.firmware_backup == $candidate.firmware_backup or
        $current.firmware_backup == null or
        ($current.firmware_backup.status == "pending" and
          $candidate.firmware_backup.status == "complete" and
          $current.firmware_backup.id == $candidate.firmware_backup.id and
          $current.firmware_backup.path == $candidate.firmware_backup.path)) and
      ($current.enrollment_plan == null or
        $current.enrollment_plan == $candidate.enrollment_plan) and
      firmware_writes_forward($current.firmware_writes; $candidate.firmware_writes) and
      ($current.rollback == null or $current.rollback == $candidate.rollback) and
      all($current.domain_records | to_entries[];
        .value == null or .value == $candidate.domain_records[.key])
    ' >/dev/null || return 1
  validate_transaction_manifest_candidate_files "$current" "$candidate" || return 1
  printf '%s\n' "$candidate" | atomic_write_control_file "$manifest" 600 || return 1
  _manifest_json="$candidate"
  _manifest_id="$_transaction_id"
  _manifest_sha256=$(sha256_file "$manifest") || return 1
}

write_transaction_manifest_status_json() {
  local expected_status="$1" next_status="$2" document="$3"
  local manifest incident current current_status document_status candidate
  [[ "$_transaction_active" == true \
    && "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  case "${expected_status}:${next_status}" in
    transition:completed|transition:failed|transition:stale) ;;
    *) return 1 ;;
  esac
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  incident=$(lifecycle_incident_path "$_transaction_id") || return 1
  [[ ! -e "$incident" && ! -L "$incident" ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  current="$_manifest_json"
  candidate=$(jq -c . <<< "$document") || return 1
  validate_transaction_manifest_json "$_transaction_id" "$candidate" || return 1
  current_status=$(jq -r '.status' <<< "$current") || return 1
  document_status=$(jq -r '.status' <<< "$candidate") || return 1
  [[ "$current_status" == "$expected_status" && "$document_status" == "$next_status" ]] \
    || return 1
  jq -en --argjson current "$current" --argjson candidate "$candidate" '
      def envelope:
        del(.completed_at, .failure, .status);
      ($current | envelope) == ($candidate | envelope)
    ' >/dev/null || return 1
  printf '%s\n' "$candidate" | atomic_write_control_file "$manifest" 600 || return 1
  _manifest_json="$candidate"
  _manifest_id="$_transaction_id"
  _manifest_sha256=$(sha256_file "$manifest") || return 1
}

transaction_service_active_state() {
  local output
  command -v systemctl >/dev/null 2>&1 || return 1
  output=$(systemctl show --property=ActiveState --value \
    "$TRANSACTION_SERVICE_UNIT" 2>/dev/null) || return 1
  [[ "$output" == active || "$output" == inactive ]] || return 1
  printf '%s\n' "$output"
}

record_transaction_service_outcome() {
  local action="$1" status="$2" field document
  [[ "$action" == quiesce || "$action" == restore ]] || return 1
  [[ "$status" == completed || "$status" == failed ]] || return 1
  [[ "$_transaction_active" == true ]] || return 1
  field="${action}_status"
  read_transaction_manifest "$_transaction_id" || return 1
  document=$(jq -c --arg unit "$TRANSACTION_SERVICE_UNIT" \
    --arg field "$field" --arg status "$status" \
    '.service_state[$unit][$field] = $status' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

quiesce_transaction_service() {
  local captured_load current
  [[ "$_transaction_active" == true \
    && "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  captured_load=$(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
    '.service_state[$unit].load_state' <<< "$_manifest_json") || return 1
  [[ "$captured_load" == loaded ]] || return 0

  current=$(transaction_service_active_state) || {
    record_transaction_service_outcome quiesce failed || true
    return 1
  }
  if [[ "$current" == active ]] \
    && ! systemctl stop "$TRANSACTION_SERVICE_UNIT"; then
    record_transaction_service_outcome quiesce failed || true
    return 1
  fi
  current=$(transaction_service_active_state) || {
    record_transaction_service_outcome quiesce failed || true
    return 1
  }
  if [[ "$current" != inactive ]]; then
    record_transaction_service_outcome quiesce failed || true
    return 1
  fi
  record_transaction_service_outcome quiesce completed
}

restore_transaction_service() {
  local captured_load captured_active current restore_status
  [[ "$_transaction_active" == true \
    && "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  captured_load=$(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
    '.service_state[$unit].load_state' <<< "$_manifest_json") || return 1
  [[ "$captured_load" == loaded ]] || return 0
  captured_active=$(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
    '.service_state[$unit].active_state' <<< "$_manifest_json") || return 1
  restore_status=$(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
    '.service_state[$unit].restore_status' <<< "$_manifest_json") || return 1
  if [[ "$restore_status" == completed ]]; then
    current=$(transaction_service_active_state) || return 1
    [[ "$current" == "$captured_active" ]]
    return
  fi

  current=$(transaction_service_active_state) || {
    record_transaction_service_outcome restore failed || true
    return 1
  }
  if [[ "$captured_active" == active && "$current" == inactive ]]; then
    if ! systemctl start "$TRANSACTION_SERVICE_UNIT"; then
      record_transaction_service_outcome restore failed || true
      return 1
    fi
    current=$(transaction_service_active_state) || {
      record_transaction_service_outcome restore failed || true
      return 1
    }
  elif [[ "$captured_active" == inactive && "$current" == active ]]; then
    if ! systemctl stop "$TRANSACTION_SERVICE_UNIT"; then
      record_transaction_service_outcome restore failed || true
      return 1
    fi
    current=$(transaction_service_active_state) || {
      record_transaction_service_outcome restore failed || true
      return 1
    }
  fi
  if [[ "$current" != "$captured_active" ]]; then
    record_transaction_service_outcome restore failed || true
    return 1
  fi
  record_transaction_service_outcome restore completed
}

preserve_transaction_service_owner_record() {
  local producer_document="$1" service_owner current main_pid
  [[ "$_transaction_active" == true \
    && "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.service_policy' <<< "$producer_document") == preserve-owner \
    && $(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
      '.service_state[$unit].load_state' <<< "$_manifest_json") == loaded \
    && $(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
      '.service_state[$unit].active_state' <<< "$_manifest_json") == active ]] || return 1
  service_owner=$(jq -c '.service_owner' <<< "$producer_document") || return 1
  [[ "$service_owner" != null ]] || return 1
  main_pid=$(transaction_service_main_pid) || return 1
  [[ "$main_pid" == "$(jq -r '.pid' <<< "$service_owner")" \
    && "$(boot_id_value)" == "$(jq -r '.boot_id' <<< "$service_owner")" \
    && "$(process_effective_uid "$main_pid")" == "$(jq -r '.uid' <<< "$service_owner")" \
    && "$(process_start_time "$main_pid")" == \
      "$(jq -r '.start_time' <<< "$service_owner")" ]] || return 1
  process_matches_identity "$main_pid" \
    "$(jq -r '.identity_kind' <<< "$service_owner")" \
    "$(jq -r '.identity' <<< "$service_owner")" || return 1
  current=$(transaction_service_active_state) || return 1
  [[ "$current" == active ]] || return 1
  record_transaction_service_outcome quiesce completed
}

preserve_transaction_service_owner() {
  local producer_path producer_document
  read_transaction_manifest "$_transaction_id" || return 1
  producer_path=$(jq -r '.domain_records.producer.path // ""' <<< "$_manifest_json") \
    || return 1
  [[ -n "$producer_path" ]] || return 1
  producer_document=$(read_control_document "$producer_path") || return 1
  validate_producer_record_json "$_transaction_id" "$producer_document" || return 1
  preserve_transaction_service_owner_record "$producer_document"
}

transaction_service_main_pid() {
  local output
  command -v systemctl >/dev/null 2>&1 || return 1
  output=$(systemctl show --property=MainPID --value \
    "$TRANSACTION_SERVICE_UNIT" 2>/dev/null) || return 1
  [[ "$output" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$output"
}

apply_transaction_service_policy() {
  local producer_path producer_document policy
  read_transaction_manifest "$_transaction_id" || return 1
  producer_path=$(jq -r '.domain_records.producer.path // ""' <<< "$_manifest_json") \
    || return 1
  if [[ -z "$producer_path" ]]; then
    quiesce_transaction_service
    return
  fi
  producer_document=$(read_control_document "$producer_path") || return 1
  policy=$(jq -r '.service_policy' <<< "$producer_document") || return 1
  case "$policy" in
    quiesce) quiesce_transaction_service ;;
    preserve-owner) preserve_transaction_service_owner ;;
    *) return 1 ;;
  esac
}

apply_recovery_transaction_service_policy() {
  local producer_path producer_document root_id
  [[ "$_recovery_producer_reference" != null ]] || return 1
  root_id=$(jq -r '.id' <<< "$_recovery_root_reference") || return 1
  validate_producer_record_reference "$root_id" "$_recovery_producer_reference" || return 1
  producer_path=$(jq -r '.path' <<< "$_recovery_producer_reference") || return 1
  producer_document=$(read_control_document "$producer_path") || return 1
  validate_producer_record_json "$root_id" "$producer_document" || return 1
  quiesce_transaction_service
}

transaction_service_outcomes_are_complete() {
  read_transaction_manifest "$_transaction_id" || return 1
  jq -e --arg unit "$TRANSACTION_SERVICE_UNIT" '
    if .service_state[$unit].load_state == "loaded" then
      .service_state[$unit].quiesce_status == "completed" and
      .service_state[$unit].restore_status == "completed"
    else
      .service_state[$unit].quiesce_status == "not-required" and
      .service_state[$unit].restore_status == "not-required"
    end
  ' <<< "$_manifest_json" >/dev/null
}

preserve_transaction_files_on_failure() {
  local document
  [[ "$_transaction_active" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
  if [[ $(jq -r '.file_rollback_policy' <<< "$_manifest_json") == preserve ]]; then
    return 0
  fi
  [[ $(jq -r '.file_rollback_policy' <<< "$_manifest_json") == restore ]] || return 1
  document=$(jq -c '.file_rollback_policy = "preserve"' <<< "$_manifest_json") \
    || return 1
  write_transaction_manifest_json "$document"
}

transaction_backup_file() {
  local target="$1" allow_absent="${2:-false}"
  local transaction_dir backup_path backup_hash target_hash mode uid gid document index policy
  local device inode current_device current_inode
  [[ "$allow_absent" == true || "$allow_absent" == false ]] || return 1
  [[ "$_transaction_active" == true && "$target" =~ ^/[^[:cntrl:]]+$ ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
  policy=$(jq -r '.file_rollback_policy' <<< "$_manifest_json") || return 1
  if [[ "$policy" == preserve ]]; then
    validate_control_directory "$(dirname "$target")" || return 1
    if [[ -e "$target" || -L "$target" ]]; then
      validate_control_file "$target"
    else
      [[ "$allow_absent" == true ]]
    fi
    return
  fi
  [[ "$policy" == restore ]] || return 1
  if jq -e --arg target "$target" \
    '.backups[] | select(.target == $target)' <<< "$_manifest_json" >/dev/null; then
    return 0
  fi

  validate_control_directory "$(dirname "$target")" || return 1
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    [[ "$allow_absent" == true ]] || return 1
    document=$(jq -c --arg target "$target" '
      .backups += [{
        kind: "absent-file",
        target: $target,
        path: null,
        sha256: null,
        mode: null,
        uid: null,
        gid: null
      }]
    ' <<< "$_manifest_json") || return 1
    write_transaction_manifest_json "$document"
    return
  fi

  validate_control_file "$target" || return 1
  read -r uid gid mode device inode \
    < <(stat -Lc '%u %g %a %d %i' "$target" 2>/dev/null) || return 1
  [[ "$uid" =~ ^[0-9]+$ && "$gid" =~ ^[0-9]+$ && "$mode" =~ ^[0-7]{3,4}$ ]] \
    || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  index=$(jq -r '.backups | length' <<< "$_manifest_json") || return 1
  backup_path="${transaction_dir}/file-${index}.backup"
  [[ ! -e "$backup_path" && ! -L "$backup_path" ]] || return 1
  cp -p "$target" "$backup_path" || return 1
  chmod 600 "$backup_path" || {
    rm -f "$backup_path"
    return 1
  }
  validate_private_control_file "$backup_path" || {
    rm -f "$backup_path"
    return 1
  }
  durable_sync "$backup_path" || {
    rm -f "$backup_path"
    return 1
  }
  backup_hash=$(sha256_file "$backup_path") || {
    rm -f "$backup_path"
    return 1
  }
  read -r current_device current_inode \
    < <(stat -Lc '%d %i' "$target" 2>/dev/null) || {
    rm -f "$backup_path"
    return 1
  }
  target_hash=$(sha256_file "$target") || {
    rm -f "$backup_path"
    return 1
  }
  [[ "$current_device" == "$device" && "$current_inode" == "$inode" \
    && "$target_hash" == "$backup_hash" ]] || {
    rm -f "$backup_path"
    return 1
  }
  document=$(jq -c \
    --arg target "$target" \
    --arg path "$backup_path" \
    --arg hash "$backup_hash" \
    --arg mode "$mode" \
    --argjson uid "$uid" \
    --argjson gid "$gid" '
      .backups += [{
        kind: "file",
        target: $target,
        path: $path,
        sha256: $hash,
        mode: $mode,
        uid: $uid,
        gid: $gid
      }]
    ' <<< "$_manifest_json") || {
    rm -f "$backup_path"
    return 1
  }
  if ! write_transaction_manifest_json "$document"; then
    if read_transaction_manifest "$_transaction_id" \
      && jq -e --arg path "$backup_path" \
        '.backups[] | select(.path == $path)' <<< "$_manifest_json" >/dev/null; then
      return 1
    fi
    rm -f "$backup_path"
    return 1
  fi
}

restore_transaction_backup_entry() {
  local entry="$1" kind target backup_path backup_hash mode uid gid
  local parent temporary old_umask
  kind=$(jq -r '.kind' <<< "$entry") || return 1
  target=$(jq -r '.target' <<< "$entry") || return 1
  [[ "$target" =~ ^/[^[:cntrl:]]+$ ]] || return 1
  parent=$(dirname "$target")
  validate_control_directory "$parent" || return 1

  if [[ "$kind" == absent-file ]]; then
    if [[ -e "$target" || -L "$target" ]]; then
      validate_control_file "$target" || return 1
      rm -f "$target" || return 1
    fi
    durable_sync "$parent" || return 1
    [[ ! -e "$target" && ! -L "$target" ]]
    return
  fi
  [[ "$kind" == file ]] || return 1
  backup_path=$(jq -r '.path' <<< "$entry") || return 1
  backup_hash=$(jq -r '.sha256' <<< "$entry") || return 1
  mode=$(jq -r '.mode' <<< "$entry") || return 1
  uid=$(jq -r '.uid' <<< "$entry") || return 1
  gid=$(jq -r '.gid' <<< "$entry") || return 1
  validate_private_control_file "$backup_path" || return 1
  [[ "$(sha256_file "$backup_path")" == "$backup_hash" ]] || return 1
  if [[ -e "$target" || -L "$target" ]]; then
    validate_control_file "$target" || return 1
  fi

  old_umask=$(umask)
  umask 077
  temporary=$(mktemp "${parent}/.omasecboot-restore.XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  if ! cp "$backup_path" "$temporary" \
    || ! chown "${uid}:${gid}" "$temporary" \
    || ! chmod "$mode" "$temporary" \
    || ! durable_sync "$temporary" \
    || ! mv -f "$temporary" "$target" \
    || ! durable_sync "$parent"; then
    rm -f "$temporary"
    return 1
  fi
  validate_control_file "$target" || return 1
  [[ "$(sha256_file "$target")" == "$backup_hash" ]]
}

rollback_transaction_files() {
  local entry timestamp status=completed document policy
  local -a entries failures=()
  [[ "$_transaction_active" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  policy=$(jq -r '.file_rollback_policy' <<< "$_manifest_json") || return 1
  if [[ "$policy" == preserve ]]; then
    timestamp=$(utc_timestamp) || return 1
    document=$(jq -c --arg timestamp "$timestamp" '
      .rollback = {
        status: "preserved",
        attempted_at: $timestamp,
        failures: []
      }
    ' <<< "$_manifest_json") || return 1
    write_transaction_manifest_json "$document"
    return
  fi
  [[ "$policy" == restore ]] || return 1
  mapfile -t entries < <(jq -c '.backups | reverse[] |
    select(.kind == "file" or .kind == "absent-file")' <<< "$_manifest_json")
  for entry in "${entries[@]}"; do
    if ! restore_transaction_backup_entry "$entry"; then
      failures+=("$(jq -r '.target' <<< "$entry")")
    fi
  done
  [[ ${#failures[@]} -eq 0 ]] || status=failed
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -c \
    --arg status "$status" \
    --arg timestamp "$timestamp" \
    --argjson failures "$(printf '%s\n' "${failures[@]}" | jq -Rsc '
      split("\n") | map(select(length > 0))')" '
      .rollback = {
        status: $status,
        attempted_at: $timestamp,
        failures: $failures
      }
    ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document" || return 1
  [[ "$status" == completed ]]
}

rollback_and_mark_recovery() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  local manifest_status manifest_kind rollback_rc=0 restore_rc=0
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  manifest_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  manifest_kind=$(jq -r '.kind' <<< "$_manifest_json") || return 1
  case "$manifest_status" in
    transition)
      rollback_transaction_files || rollback_rc=$?
      if [[ $rollback_rc -ne 0 ]]; then
        reason="${reason}; file rollback failed"
      fi
      restore_transaction_service || restore_rc=$?
      if [[ $restore_rc -ne 0 ]]; then
        reason="${reason}; service restoration failed"
      fi
      ;;
    completed|failed|stale) ;;
    *) return 1 ;;
  esac
  if [[ "$manifest_kind" == recovery-attempt ]]; then
    if [[ "$manifest_status" == completed ]]; then
      finalize_recovery_attempt_incident 0 "" completed || return 1
      publish_resolved_recovery_attempt
    else
      ensure_recovery_attempt_failure "$exit_code" "$reason" "$status"
    fi
  else
    [[ "$manifest_kind" == root ]] || return 1
    ensure_lifecycle_recovery "$exit_code" "$reason" "$status"
  fi
}

transaction_phase_start() {
  local phase="$1" document
  [[ "$_transaction_active" == true && "$phase" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition \
    && $(jq -r --arg phase "$phase" \
      '(.completed_phases | index($phase)) == null' <<< "$_manifest_json") == true ]] \
    || return 1
  document=$(jq -c --arg phase "$phase" '.current_phase = $phase' <<< "$_manifest_json") \
    || return 1
  write_transaction_manifest_json "$document"
}

transaction_phase_complete() {
  local phase="$1" document
  [[ "$_transaction_active" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.current_phase // ""' <<< "$_manifest_json") == "$phase" ]] || return 1
  document=$(jq -c --arg phase "$phase" '
    .completed_phases += [$phase] |
    .current_phase = null
  ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

transaction_set_domain_record() {
  local name="$1" reference="$2" document
  [[ "$_transaction_active" == true ]] || return 1
  case "$name" in
    bootnext|final_proof|firmware|managed_settings|producer|tracking_ownership|unconfigure|windows) ;;
    *) return 1 ;;
  esac
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r --arg name "$name" '.domain_records[$name] == null' \
    <<< "$_manifest_json") == true ]] || return 1
  document=$(jq -c --arg name "$name" --argjson reference "$reference" \
    '.domain_records[$name] = $reference' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

transaction_set_adoption() {
  local observed_verification="$1" original_verification="$2"
  local observed_enrollment="$3" original_enrollment="$4"
  local observed_before_save="$5" original_before_save="$6"
  local observed_after_save="$7" original_after_save="$8"
  local state_document timestamp
  [[ "$_transaction_active" == true ]] || return 1
  [[ "$original_verification" == yes || "$original_verification" == no \
    || "$original_verification" == unset || "$original_verification" == unknown ]] || return 1
  [[ "$original_enrollment" == yes || "$original_enrollment" == no \
    || "$original_enrollment" == unset || "$original_enrollment" == unknown ]] || return 1
  [[ "$original_before_save" == present || "$original_before_save" == absent \
    || "$original_before_save" == unknown ]] || return 1
  [[ "$original_after_save" == present || "$original_after_save" == absent \
    || "$original_after_save" == unknown ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  timestamp=$(utc_timestamp) || return 1

  state_document=$(jq -c \
    --arg timestamp "$timestamp" \
    --arg observed_verification "$observed_verification" \
    --arg original_verification "$original_verification" \
    --arg observed_enrollment "$observed_enrollment" \
    --arg original_enrollment "$original_enrollment" \
    --arg observed_before_save "$observed_before_save" \
    --arg original_before_save "$original_before_save" \
    --arg observed_after_save "$observed_after_save" \
    --arg original_after_save "$original_after_save" '
      .adoption = {
        source: "explicit",
        recorded_at: $timestamp,
        managed_settings: [
          {
            path: "/etc/default/limine",
            key: "ENABLE_VERIFICATION",
            observed: $observed_verification,
            original: $original_verification
          },
          {
            path: "/etc/default/limine",
            key: "ENABLE_ENROLL_LIMINE_CONFIG",
            observed: $observed_enrollment,
            original: $original_enrollment
          },
          {
            path: "/etc/default/limine",
            key: "COMMANDS_BEFORE_SAVE",
            token: "limine-reset-enroll",
            observed: $observed_before_save,
            original: $original_before_save
          },
          {
            path: "/etc/default/limine",
            key: "COMMANDS_AFTER_SAVE",
            token: "limine-enroll-config",
            observed: $observed_after_save,
            original: $original_after_save
          }
        ]
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$state_document" || return 1
  validate_lifecycle_document_references "$state_document" || return 1
  lifecycle_failpoint "before-adoption-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644
}

commit_lifecycle_transaction() {
  local manifest_document state_document timestamp manifest manifest_hash
  local manifest_operation manifest_target lifecycle_operation
  [[ "$_transaction_active" == true ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.current_phase == null' <<< "$_manifest_json") == true \
    && $(jq -r '.kind' <<< "$_manifest_json") == root \
    && $(jq -r '.recovery == null' <<< "$_manifest_json") == true ]] || return 1
  manifest_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  manifest_target=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
  lifecycle_operation=$(jq -r '.transaction.operation' <<< "$_lifecycle_json") || return 1
  [[ "$manifest_operation" == "$_transaction_operation" \
    && "$manifest_operation" == "$lifecycle_operation" \
    && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == root \
    && "$manifest_target" == "$_transaction_target_state" ]] || return 1
  restore_transaction_service || return 1
  transaction_service_outcomes_are_complete || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  timestamp=$(utc_timestamp) || return 1
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1

  manifest_document=$(jq -c --arg timestamp "$timestamp" '
    .status = "completed" |
    .completed_at = $timestamp |
    .failure = null
  ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_status_json transition completed "$manifest_document" || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  manifest_hash=$(sha256_file "$manifest") || return 1
  lifecycle_failpoint "after-completed-manifest-write" || return 1

  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg state "$manifest_target" \
    --arg id "$_transaction_id" \
    --arg operation "$manifest_operation" \
    --arg manifest "$manifest" \
    --arg manifest_hash "$manifest_hash" \
    --arg timestamp "$timestamp" '
      .writer_version = $version |
      .generation += 1 |
      .state = $state |
      .transaction = null |
      .last_transaction = {
        id: $id,
        operation: $operation,
        manifest: $manifest,
        manifest_sha256: $manifest_hash,
        completed_at: $timestamp
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$state_document" || return 1
  validate_lifecycle_document_references "$state_document" || return 1
  lifecycle_failpoint "before-stable-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1

  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

finalize_transaction_incident() {
  local exit_code="$1" reason="$2" status="$3"
  local current_status current_phase timestamp manifest manifest_hash incident_path
  local manifest_document manifest_operation seal_document incident_status failure
  local rollback_disposition
  [[ "$_transaction_active" == true \
    && "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -le 255 \
    && ${#reason} -gt 0 && ${#reason} -le 1024 \
    && ( "$status" == failed || "$status" == stale ) ]] || return 1
  incident_path=$(lifecycle_incident_path "$_transaction_id") || return 1
  if [[ -e "$incident_path" || -L "$incident_path" ]]; then
    read_incident_seal "$_transaction_id" || return 1
    [[ $(jq -r '.kind' <<< "$_incident_json") == root ]] || return 1
    durable_sync "$incident_path" || return 1
    durable_sync "$(dirname "$incident_path")" || return 1
    lifecycle_failpoint "after-incident-write" || return 1
    return 0
  fi
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.kind' <<< "$_manifest_json") == root ]] || return 1
  current_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  timestamp=$(utc_timestamp) || return 1
  case "$current_status" in
    transition)
      current_phase=$(jq -r 'if .current_phase == null then "" else .current_phase end' \
        <<< "$_manifest_json") || return 1
      manifest_document=$(jq -c \
        --arg status "$status" \
        --arg timestamp "$timestamp" \
        --arg reason "$reason" \
        --arg phase "$current_phase" \
        --argjson exit_code "$exit_code" '
        .status = $status |
        .completed_at = $timestamp |
        .failure = {
          exit_code: $exit_code,
          reason: $reason,
          phase: (if $phase == "" then null else $phase end),
          recorded_at: $timestamp
        }
      ' <<< "$_manifest_json") || return 1
      write_transaction_manifest_status_json transition "$status" "$manifest_document" \
        || return 1
      read_transaction_manifest "$_transaction_id" || return 1
      incident_status="$status"
      failure=$(jq -c '.failure' <<< "$_manifest_json") || return 1
      rollback_disposition="manifest-recorded"
      ;;
    failed|stale)
      incident_status="$current_status"
      failure=$(jq -c '.failure' <<< "$_manifest_json") || return 1
      rollback_disposition="manifest-recorded"
      ;;
    completed)
      incident_status=publication-uncertain
      failure=$(jq -cn \
        --arg timestamp "$timestamp" \
        --arg reason "$reason" \
        --argjson exit_code "$exit_code" '{
          exit_code: $exit_code,
          reason: $reason,
          phase: null,
          recorded_at: $timestamp
        }') || return 1
      rollback_disposition=not-attempted-stable-publication-ambiguous
      ;;
    *) return 1 ;;
  esac
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  manifest_hash=$(sha256_file "$manifest") || return 1
  current_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  manifest_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  seal_document=$(jq -cn \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg operation "$manifest_operation" \
    --arg manifest "$manifest" \
    --arg manifest_hash "$manifest_hash" \
    --arg manifest_status "$current_status" \
    --arg incident_status "$incident_status" \
    --argjson failure "$failure" \
    --arg rollback_disposition "$rollback_disposition" \
    --arg timestamp "$timestamp" '{
      schema_version: $schema,
      writer_version: $version,
      kind: "root",
      id: $id,
      operation: $operation,
      ordinal: 0,
      manifest: $manifest,
      manifest_sha256: $manifest_hash,
      manifest_status: $manifest_status,
      incident_status: $incident_status,
      failure: $failure,
      rollback_disposition: $rollback_disposition,
      root_incident: null,
      previous_attempt: null,
      sealed_at: $timestamp
    }') || return 1
  validate_incident_seal_json "$_transaction_id" "$seal_document" || return 1
  if ! printf '%s\n' "$seal_document" | atomic_create_control_file "$incident_path" 600; then
    read_incident_seal "$_transaction_id" || return 1
    [[ "$(jq -Sc . <<< "$_incident_json")" == \
      "$(jq -Sc . <<< "$seal_document")" ]] || return 1
    durable_sync "$incident_path" || return 1
    durable_sync "$(dirname "$incident_path")" || return 1
  fi
  lifecycle_failpoint "after-incident-write" || return 1
  read_incident_seal "$_transaction_id"
}

publish_lifecycle_recovery() {
  local current_manifest current_operation current_target root_incident seal_document
  local incident_path
  local timestamp state_document
  local lifecycle_owns_transaction=false
  [[ "$_transaction_active" == true ]] || return 1
  read_incident_seal "$_transaction_id" || return 1
  seal_document="$_incident_json"
  incident_path=$(lifecycle_incident_path "$_transaction_id") || return 1
  root_incident=$(incident_reference_from_json "$seal_document" "$incident_path") || return 1
  [[ $(jq -r '.kind' <<< "$seal_document") == root ]] || return 1
  current_manifest=$(jq -r '.manifest' <<< "$seal_document") || return 1
  current_operation=$(jq -r '.operation' <<< "$seal_document") || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  current_target=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
  [[ "$current_operation" == "$(jq -r '.operation' <<< "$_manifest_json")" ]] \
    || return 1

  read_lifecycle || return 1
  if [[ "$_lifecycle_state" == recovery-required ]]; then
    jq -e --argjson root "$root_incident" '
      .transaction.id == $root.id and .transaction.operation == $root.operation and
      .transaction.root_incident == $root and .transaction.attempt_count == 0 and
      .transaction.last_recovery_attempt == null
    ' <<< "$_lifecycle_json" >/dev/null || return 1
    durable_sync "$(lifecycle_file_path)" || return 1
    durable_sync "$(dirname "$(lifecycle_file_path)")" || return 1
    _transaction_active=false
    unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
    return 0
  fi
  if [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" \
    && $(jq -r '.transaction.operation' <<< "$_lifecycle_json") == \
      "$current_operation" \
    && $(jq -r '.transaction.manifest' <<< "$_lifecycle_json") == \
      "$current_manifest" \
    && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == root ]]; then
    lifecycle_owns_transaction=true
  elif [[ "$_lifecycle_state" == "$current_target" \
    && $(jq -r '.last_transaction.id // ""' <<< "$_lifecycle_json") == \
      "$_transaction_id" \
    && $(jq -r '.last_transaction.manifest // ""' <<< "$_lifecycle_json") == \
      "$current_manifest" ]]; then
    lifecycle_owns_transaction=true
  fi
  [[ "$lifecycle_owns_transaction" == true ]] || return 1

  timestamp=$(utc_timestamp) || return 1
  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg timestamp "$timestamp" \
    --argjson root "$root_incident" \
    --arg manifest "$current_manifest" '
      .writer_version = $version |
      .generation += 1 |
      .state = "recovery-required" |
      .transaction = {
        attempt_count: 0,
        id: $root.id,
        kind: "incident",
        last_recovery_attempt: null,
        manifest: $manifest,
        operation: $root.operation,
        root_incident: $root
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$state_document" || return 1
  validate_lifecycle_document_references "$state_document" || return 1
  lifecycle_failpoint "before-recovery-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1

  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

finalize_recovery_attempt_incident() {
  local exit_code="$1" reason="$2" status="$3" incident_path current_status
  local current_phase timestamp manifest manifest_hash manifest_document failure
  local recovery operation seal_document ordinal root previous
  [[ "$_transaction_active" == true \
    && "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -le 255 ]] || return 1
  case "$status" in
    completed) [[ "$exit_code" -eq 0 && -z "$reason" ]] || return 1 ;;
    failed|stale) [[ ${#reason} -gt 0 && ${#reason} -le 1024 ]] || return 1 ;;
    *) return 1 ;;
  esac
  incident_path=$(lifecycle_incident_path "$_transaction_id") || return 1
  if [[ -e "$incident_path" || -L "$incident_path" ]]; then
    read_incident_seal "$_transaction_id" || return 1
    [[ $(jq -r '.kind' <<< "$_incident_json") == attempt \
      && $(jq -r '.incident_status' <<< "$_incident_json") == "$status" ]] || return 1
    durable_sync "$incident_path" || return 1
    durable_sync "$(dirname "$incident_path")" || return 1
    return 0
  fi

  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.kind' <<< "$_manifest_json") == recovery-attempt ]] || return 1
  current_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  timestamp=$(utc_timestamp) || return 1
  if [[ "$current_status" == transition ]]; then
    if [[ "$status" == completed ]]; then
      [[ $(jq -r '.current_phase == null' <<< "$_manifest_json") == true \
        && $(jq -r '.domain_records.final_proof != null' <<< "$_manifest_json") == true ]] \
        || return 1
      transaction_service_outcomes_are_complete || return 1
      manifest_document=$(jq -c --arg timestamp "$timestamp" '
        .status = "completed" | .completed_at = $timestamp | .failure = null
      ' <<< "$_manifest_json") || return 1
    else
      current_phase=$(jq -r 'if .current_phase == null then "" else .current_phase end' \
        <<< "$_manifest_json") || return 1
      manifest_document=$(jq -c \
        --arg status "$status" \
        --arg timestamp "$timestamp" \
        --arg reason "$reason" \
        --arg phase "$current_phase" \
        --argjson exit_code "$exit_code" '
          .status = $status |
          .completed_at = $timestamp |
          .failure = {
            exit_code: $exit_code,
            reason: $reason,
            phase: (if $phase == "" then null else $phase end),
            recorded_at: $timestamp
          }
        ' <<< "$_manifest_json") || return 1
    fi
    write_transaction_manifest_status_json transition "$status" "$manifest_document" \
      || return 1
    read_transaction_manifest "$_transaction_id" || return 1
    [[ "$status" != completed ]] \
      || lifecycle_failpoint "after-attempt-completed-manifest-write" || return 1
  else
    [[ "$current_status" == "$status" ]] || return 1
  fi

  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  manifest_hash=$(sha256_file "$manifest") || return 1
  operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  recovery=$(jq -c '.recovery' <<< "$_manifest_json") || return 1
  ordinal=$(jq -r '.attempt_number' <<< "$recovery") || return 1
  root=$(jq -c '.root_incident' <<< "$recovery") || return 1
  previous=$(jq -c '.previous_attempt' <<< "$recovery") || return 1
  failure=$(jq -c '.failure' <<< "$_manifest_json") || return 1
  seal_document=$(jq -cn \
    --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg operation "$operation" \
    --arg manifest "$manifest" \
    --arg manifest_hash "$manifest_hash" \
    --arg status "$status" \
    --argjson ordinal "$ordinal" \
    --argjson root "$root" \
    --argjson previous "$previous" \
    --argjson failure "$failure" \
    --arg timestamp "$timestamp" '{
      schema_version: $schema,
      writer_version: $version,
      kind: "attempt",
      id: $id,
      operation: $operation,
      ordinal: $ordinal,
      manifest: $manifest,
      manifest_sha256: $manifest_hash,
      manifest_status: $status,
      incident_status: $status,
      failure: $failure,
      rollback_disposition: "manifest-recorded",
      root_incident: $root,
      previous_attempt: $previous,
      sealed_at: $timestamp
    }') || return 1
  validate_incident_seal_json "$_transaction_id" "$seal_document" || return 1
  if ! printf '%s\n' "$seal_document" \
    | atomic_create_control_file "$incident_path" 600; then
    read_incident_seal "$_transaction_id" || return 1
    [[ "$(jq -Sc . <<< "$_incident_json")" == \
      "$(jq -Sc . <<< "$seal_document")" ]] || return 1
    durable_sync "$incident_path" || return 1
    durable_sync "$(dirname "$incident_path")" || return 1
  fi
  lifecycle_failpoint "after-attempt-incident-write" || return 1
  read_incident_seal "$_transaction_id"
}

publish_failed_recovery_attempt() {
  local seal reference root root_manifest timestamp state_document ordinal
  [[ "$_transaction_active" == true ]] || return 1
  read_incident_seal "$_transaction_id" || return 1
  seal="$_incident_json"
  [[ $(jq -r '.kind' <<< "$seal") == attempt \
    && ( $(jq -r '.incident_status' <<< "$seal") == failed \
      || $(jq -r '.incident_status' <<< "$seal") == stale ) ]] || return 1
  reference=$(incident_reference_from_json "$seal" \
    "$(lifecycle_incident_path "$_transaction_id")") || return 1
  root=$(jq -c '.root_incident' <<< "$seal") || return 1
  ordinal=$(jq -r '.ordinal' <<< "$seal") || return 1
  validate_incident_reference "$root" || return 1
  root_manifest=$(jq -r '.manifest' <<< "$_incident_json") || return 1
  read_lifecycle || return 1
  if [[ "$_lifecycle_state" == recovery-required ]]; then
    jq -e --argjson root "$root" --argjson reference "$reference" \
      --argjson ordinal "$ordinal" '
        .transaction.root_incident == $root and
        .transaction.last_recovery_attempt == $reference and
        .transaction.attempt_count == $ordinal
      ' <<< "$_lifecycle_json" >/dev/null || return 1
    _transaction_active=false
    unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
    return 0
  fi
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" \
    && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == recovery-attempt ]] \
    || return 1
  timestamp=$(utc_timestamp) || return 1
  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg timestamp "$timestamp" \
    --argjson root "$root" \
    --argjson reference "$reference" \
    --argjson ordinal "$ordinal" \
    --arg root_manifest "$root_manifest" '
      .writer_version = $version |
      .generation += 1 |
      .state = "recovery-required" |
      .transaction = {
        attempt_count: $ordinal,
        id: $root.id,
        kind: "incident",
        last_recovery_attempt: $reference,
        manifest: $root_manifest,
        operation: $root.operation,
        root_incident: $root
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$state_document" || return 1
  validate_lifecycle_document_references "$state_document" || return 1
  lifecycle_failpoint "before-recovery-attempt-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1
  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

publish_resolved_recovery_attempt() {
  local seal reference root proof manifest manifest_hash completed_at timestamp state_document
  local ordinal
  [[ "$_transaction_active" == true ]] || return 1
  read_incident_seal "$_transaction_id" || return 1
  seal="$_incident_json"
  [[ $(jq -r '.kind' <<< "$seal") == attempt \
    && $(jq -r '.incident_status' <<< "$seal") == completed ]] || return 1
  reference=$(incident_reference_from_json "$seal" \
    "$(lifecycle_incident_path "$_transaction_id")") || return 1
  root=$(jq -c '.root_incident' <<< "$seal") || return 1
  ordinal=$(jq -r '.ordinal' <<< "$seal") || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  proof=$(jq -c '.domain_records.final_proof' <<< "$_manifest_json") || return 1
  [[ "$proof" != null ]] || return 1
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  manifest_hash=$(sha256_file "$manifest") || return 1
  completed_at=$(jq -r '.completed_at' <<< "$_manifest_json") || return 1
  read_lifecycle || return 1
  if [[ "$_lifecycle_state" == active \
    && $(jq -r '.last_recovery.final_attempt.id // ""' <<< "$_lifecycle_json") == \
      "$_transaction_id" ]]; then
    _transaction_active=false
    unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
    return 0
  fi
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" \
    && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == recovery-attempt ]] \
    || return 1
  timestamp=$(utc_timestamp) || return 1
  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg timestamp "$timestamp" \
    --arg id "$_transaction_id" \
    --arg operation "$(jq -r '.operation' <<< "$_manifest_json")" \
    --arg manifest "$manifest" \
    --arg manifest_hash "$manifest_hash" \
    --arg completed_at "$completed_at" \
    --argjson root "$root" \
    --argjson reference "$reference" \
    --argjson ordinal "$ordinal" \
    --argjson proof "$proof" '
      .writer_version = $version |
      .generation += 1 |
      .state = "active" |
      .transaction = null |
      .last_transaction = {
        id: $id,
        operation: $operation,
        manifest: $manifest,
        manifest_sha256: $manifest_hash,
        completed_at: $completed_at
      } |
      .last_recovery = {
        attempt_count: $ordinal,
        final_attempt: $reference,
        proof: $proof,
        resolved_at: $timestamp,
        root_incident: $root
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$state_document" || return 1
  validate_lifecycle_document_references "$state_document" || return 1
  lifecycle_failpoint "before-recovery-resolved-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1
  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

mark_recovery_attempt_failure() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  finalize_recovery_attempt_incident "$exit_code" "$reason" "$status" || return 1
  publish_failed_recovery_attempt
}

ensure_recovery_attempt_failure() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  mark_recovery_attempt_failure "$exit_code" "$reason" "$status" \
    || mark_recovery_attempt_failure "$exit_code" "$reason" "$status"
}

commit_lifecycle_recovery_attempt() {
  [[ "$_transaction_active" == true ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.kind' <<< "$_manifest_json") == recovery-attempt \
    && $(jq -r '.current_phase == null' <<< "$_manifest_json") == true ]] || return 1
  restore_transaction_service || return 1
  transaction_service_outcomes_are_complete || return 1
  finalize_recovery_attempt_incident 0 "" completed || return 1
  publish_resolved_recovery_attempt
}

mark_lifecycle_recovery() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  finalize_transaction_incident "$exit_code" "$reason" "$status" || return 1
  publish_lifecycle_recovery
}

ensure_lifecycle_recovery() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  mark_lifecycle_recovery "$exit_code" "$reason" "$status" \
    || mark_lifecycle_recovery "$exit_code" "$reason" "$status"
}

reconcile_stale_lifecycle() {
  local transaction_id manifest_status manifest_kind incident_status
  local reason="transaction owner is no longer valid" restore_rc=0
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition ]] || return 0
  transaction_id="$_lifecycle_transaction_id"
  read_transaction_manifest "$transaction_id" || return 1
  manifest_owner_is_alive && return 0

  _transaction_active=true
  _transaction_id="$transaction_id"
  _transaction_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  _transaction_target_state=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
  manifest_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  manifest_kind=$(jq -r '.kind' <<< "$_manifest_json") || return 1
  if [[ "$manifest_kind" == recovery-attempt ]]; then
    case "$manifest_status" in
      transition)
        rollback_transaction_files || true
        restore_transaction_service || restore_rc=$?
        if [[ $restore_rc -ne 0 ]]; then
          reason="${reason}; service restoration failed"
        fi
        ensure_recovery_attempt_failure 1 "$reason" stale
        ;;
      completed)
        finalize_recovery_attempt_incident 0 "" completed || return 1
        publish_resolved_recovery_attempt
        ;;
      failed|stale)
        incident_status="$manifest_status"
        ensure_recovery_attempt_failure 1 "$reason" "$incident_status"
        ;;
      *) return 1 ;;
    esac
    return
  fi
  [[ "$manifest_kind" == root ]] || return 1
  case "$manifest_status" in
    transition)
      restore_transaction_service || restore_rc=$?
      if [[ $restore_rc -ne 0 ]]; then
        reason="${reason}; service restoration failed"
      fi
      ;;
    completed|failed|stale) ;;
    *) return 1 ;;
  esac
  ensure_lifecycle_recovery 1 "$reason" stale
}

transaction_exit_handler() {
  local exit_code=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [[ "$_transaction_active" == true ]]; then
    [[ $exit_code -ne 0 ]] || exit_code=1
    if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
      || "$_OMASECBOOT_REPAIR_LOCK_OWNED" != true ]]; then
      with_boot_repair_lock || true
    fi
    rollback_and_mark_recovery "$exit_code" "command exited before transaction commit" failed \
      || true
  fi
  release_boot_repair_lock
  run_previous_exit_trap "$exit_code"
  return "$exit_code"
}

transaction_signal_handler() {
  local signal="$1" exit_code="$2"
  trap - EXIT
  trap '' INT TERM HUP
  if [[ "$_transaction_active" == true ]]; then
    if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false \
      || "$_OMASECBOOT_REPAIR_LOCK_OWNED" != true ]]; then
      with_boot_repair_lock || true
    fi
    rollback_and_mark_recovery "$exit_code" "transaction interrupted by ${signal}" failed \
      || true
  fi
  release_boot_repair_lock
  restore_transaction_traps
  kill -s "$signal" "$BASHPID"
  exit "$exit_code"
}

run_previous_exit_trap() {
  local exit_code="$1" declaration="$_transaction_previous_exit" command
  local trap_rc errexit=false
  [[ -n "$declaration" ]] || return 0
  if [[ "$declaration" =~ ^trap\ --\ \'(.*)\'\ EXIT$ ]]; then
    command=${BASH_REMATCH[1]}
    [[ $- == *e* ]] && errexit=true
    set +e
    return_status "$exit_code"
    eval "$command"
    trap_rc=$?
    [[ "$errexit" == false ]] || set -e
    return "$trap_rc"
  fi
}

return_status() {
  return "$1"
}

restore_transaction_traps() {
  trap - EXIT INT TERM HUP
  [[ -z "$_transaction_previous_exit" ]] || eval "$_transaction_previous_exit"
  [[ -z "$_transaction_previous_int" ]] || eval "$_transaction_previous_int"
  [[ -z "$_transaction_previous_term" ]] || eval "$_transaction_previous_term"
  [[ -z "$_transaction_previous_hup" ]] || eval "$_transaction_previous_hup"
  _transaction_previous_exit=""
  _transaction_previous_int=""
  _transaction_previous_term=""
  _transaction_previous_hup=""
}

arm_transaction_traps() {
  _transaction_previous_exit=$(trap -p EXIT || true)
  _transaction_previous_int=$(trap -p INT || true)
  _transaction_previous_term=$(trap -p TERM || true)
  _transaction_previous_hup=$(trap -p HUP || true)
  trap transaction_exit_handler EXIT
  trap 'transaction_signal_handler INT 130' INT
  trap 'transaction_signal_handler TERM 143' TERM
  trap 'transaction_signal_handler HUP 129' HUP
}

run_lifecycle_transaction_with_preflight() {
  local operation="$1" target_state="$2" allowed_states="$3"
  local preflight="$4" callback="$5"
  shift 5
  local callback_rc=0 commit_rc=0 begin_rc=0

  require_control_root || return 1
  with_boot_repair_lock || return 1
  lifecycle_package_boundary_is_clear || {
    release_boot_repair_lock
    return 1
  }
  reconcile_stale_lifecycle || {
    release_boot_repair_lock
    return 1
  }
  read_lifecycle || {
    release_boot_repair_lock
    fail "Lifecycle state is invalid or unsafe"
    return 1
  }
  if [[ ( -e "$(snapshot_restore_lock_path)" || -L "$(snapshot_restore_lock_path)" ) \
    && "$_OMASECBOOT_FULL_RESTORE_POST" != true ]]; then
    fail "Operation ${operation} blocked while full snapshot restore is running"
    release_boot_repair_lock
    return 1
  fi
  if [[ ",${allowed_states}," != *",${_lifecycle_state},"* ]]; then
    if [[ "$_lifecycle_state" == recovery-required || "$_lifecycle_state" == transition ]]; then
      fail "Lifecycle is ${_lifecycle_state} for transaction ${_lifecycle_transaction_id}; recovery is required"
    else
      fail "Operation ${operation} requires lifecycle state ${allowed_states}; current state is ${_lifecycle_state}"
    fi
    release_boot_repair_lock
    return 1
  fi
  "$preflight" "$@" || {
    release_boot_repair_lock
    return 1
  }
  lifecycle_package_boundary_is_clear || {
    release_boot_repair_lock
    return 1
  }

  arm_transaction_traps

  begin_lifecycle_transaction "$operation" "$target_state" || begin_rc=$?
  if [[ $begin_rc -ne 0 ]]; then
    if [[ "$_transaction_active" == true ]]; then
      if read_lifecycle && [[ "$_lifecycle_state" == transition \
        && "$_lifecycle_transaction_id" == "$_transaction_id" ]]; then
        rollback_and_mark_recovery "$begin_rc" "transaction initialization failed" failed \
          || true
      else
        _transaction_active=false
        unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
      fi
    fi
    restore_transaction_traps
    release_boot_repair_lock
    return "$begin_rc"
  fi

  "$callback" "$@" || callback_rc=$?
  if [[ $callback_rc -eq 0 ]]; then
    commit_lifecycle_transaction || commit_rc=$?
    if [[ $commit_rc -ne 0 ]]; then
      rollback_and_mark_recovery "$commit_rc" "stable lifecycle commit failed" failed || true
      callback_rc=$commit_rc
    fi
  else
    rollback_and_mark_recovery "$callback_rc" "operation ${operation} failed" failed || true
  fi

  restore_transaction_traps
  release_boot_repair_lock
  return "$callback_rc"
}

run_lifecycle_transaction() {
  local operation="$1" target_state="$2" allowed_states="$3" callback="$4"
  shift 4
  run_lifecycle_transaction_with_preflight "$operation" "$target_state" \
    "$allowed_states" : "$callback" "$@"
}

record_adoption_transaction() {
  transaction_phase_start "record-adoption" || return 1
  transaction_set_adoption "$@" || return 1
  transaction_phase_complete "record-adoption"
}

adopt_lifecycle() {
  [[ $# -eq 9 ]] || return 1
  local preflight="$1"
  shift
  [[ "$2" == yes || "$2" == no || "$2" == unset || "$2" == unknown ]] \
    || return 1
  [[ "$4" == yes || "$4" == no || "$4" == unset || "$4" == unknown ]] \
    || return 1
  [[ "$6" == present || "$6" == absent || "$6" == unknown ]] || return 1
  [[ "$8" == present || "$8" == absent || "$8" == unknown ]] || return 1
  run_lifecycle_transaction_with_preflight "adopt" "active" "unmanaged" \
    "$preflight" record_adoption_transaction "$@"
}

current_transition_is_owned() {
  local transaction_id token expected_hash owner_pid
  transaction_id=${OMASECBOOT_TRANSACTION_ID:-}
  token=${OMASECBOOT_TRANSACTION_TOKEN:-}
  [[ -n "$transaction_id" && -n "$token" ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$transaction_id" ]] || return 1
  read_transaction_manifest "$transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
  expected_hash=$(sha256_text "$token") || return 1
  [[ "$expected_hash" == "$(jq -r '.token_sha256' <<< "$_manifest_json")" ]] || return 1
  manifest_owner_is_alive || return 1
  owner_pid=$(jq -r '.owner.pid' <<< "$_manifest_json") || return 1
  process_has_ancestor "$owner_pid" "$BASHPID"
}

adopt_transaction_context() {
  local transaction_id="$1"
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$transaction_id" ]] || return 1
  read_transaction_manifest "$transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
  _transaction_active=true
  _transaction_id="$transaction_id"
  _transaction_token=""
  _transaction_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  _transaction_target_state=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
}

detach_transaction_context() {
  _transaction_active=false
  _transaction_id=""
  _transaction_token=""
  _transaction_operation=""
  _transaction_target_state=""
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

full_snapshot_restore_caller_is_valid() {
  local caller=${HOOK_CALLER:-} wrapper_pid
  full_restore_sync_process_is_valid "$PPID" || return 1

  case "$caller" in
    limine-snapper-sync)
      return 0
      ;;
    limine-snapper-restore)
      wrapper_pid=$(process_parent_pid "$PPID") || return 1
      full_restore_wrapper_process_is_valid "$wrapper_pid"
      ;;
    *)
      return 1
      ;;
  esac
}

full_restore_sync_process_is_valid() {
  local pid="$1" parent_uid
  parent_uid=$(process_effective_uid "$pid") || return 1
  [[ "$parent_uid" == "$(control_owner_uid)" ]] || return 1
  process_runs_script "$pid" /usr/bin/limine-snapper-sync || return 1
  process_cmdline_has_argument "$pid" --restore || return 1
  process_cmdline_has_argument "$pid" --no-mutex
}

full_restore_wrapper_process_is_valid() {
  local pid="$1"
  [[ "$(process_effective_uid "$pid")" == "$(control_owner_uid)" ]] || return 1
  process_runs_script "$pid" /usr/bin/limine-snapper-restore
}

is_full_snapshot_restore_hook() {
  full_snapshot_restore_caller_is_valid
}

reconcile_stale_transition_from_hook() {
  [[ "$_lifecycle_state" == transition ]] || return 1
  read_transaction_manifest "$_lifecycle_transaction_id" || return 1
  manifest_owner_is_alive && return 1
  if ! lock_inherited_limine_fd; then
    with_limine_lock || return 1
  fi
  with_repair_lock || return 1
  reconcile_stale_lifecycle
  local reconcile_rc=$?
  release_repair_lock
  read_lifecycle || return 1
  return "$reconcile_rc"
}

full_restore_lifecycle_is_admissible() {
  case "$_lifecycle_state" in
    unmanaged|disabled) return 0 ;;
    active) lifecycle_repair_is_available ;;
    transition|recovery-required) return 1 ;;
    *) return 1 ;;
  esac
}

lifecycle_hook_pre() {
  require_control_root || return 100
  read_lifecycle || {
    fail "Lifecycle state is invalid or unsafe"
    return 100
  }

  if is_full_snapshot_restore_hook; then
    if [[ "$_lifecycle_state" == transition ]]; then
      reconcile_stale_transition_from_hook || true
    fi
    if ! full_restore_lifecycle_is_admissible; then
      fail "Full snapshot restore is allowed only in stable lifecycle state"
      return 100
    fi
    with_repair_lock || return 100
    if ! read_lifecycle; then
      release_repair_lock
      fail "Lifecycle state became invalid during full snapshot restore admission"
      return 100
    fi
    if ! full_restore_lifecycle_is_admissible; then
      release_repair_lock
      fail "Full snapshot restore is allowed only in stable lifecycle state"
      return 100
    fi
    release_repair_lock
    return 0
  fi

  case "$_lifecycle_state" in
    unmanaged|disabled)
      return 0
      ;;
    recovery-required)
      fail "Boot mutation blocked while lifecycle is recovery-required"
      return 100
      ;;
    transition)
      if current_transition_is_owned && lock_inherited_limine_fd; then
        return 0
      fi
      reconcile_stale_transition_from_hook || true
      fail "External boot mutation blocked during transaction ${_lifecycle_transaction_id}"
      return 100
      ;;
    active)
      if ! lifecycle_repair_is_available; then
        fail "Boot mutation is blocked until complete boot repair is available"
        return 100
      fi
      if lock_inherited_limine_fd; then
        return 0
      fi
      fail "Boot mutation lacks the validated inherited Limine lock"
      return 100
      ;;
    *)
      fail "Boot mutation blocked: lifecycle state is unsupported"
      return 100
      ;;
  esac
}

lifecycle_hook_post() {
  local repair_callback="$1"
  require_control_root || return 100
  read_lifecycle || {
    fail "Lifecycle state is invalid or unsafe"
    return 100
  }

  case "$_lifecycle_state" in
    unmanaged|disabled)
      return 0
      ;;
    recovery-required)
      fail "Boot repair blocked while lifecycle is recovery-required"
      return 100
      ;;
    transition)
      if is_full_snapshot_restore_hook; then
        fail "Full snapshot restore post-hook rejected outside stable lifecycle state"
        return 100
      fi
      if current_transition_is_owned && lock_inherited_limine_fd; then
        return 0
      fi
      reconcile_stale_transition_from_hook || true
      fail "External post-hook blocked during transaction ${_lifecycle_transaction_id}"
      return 100
      ;;
    active)
      if ! lock_inherited_limine_fd; then
        with_limine_lock || return 100
      fi
      if is_full_snapshot_restore_hook; then
        _OMASECBOOT_FULL_RESTORE_POST=true
      fi
      "$repair_callback" || {
        _OMASECBOOT_FULL_RESTORE_POST=false
        fail "Post-hook repair failed"
        return 100
      }
      _OMASECBOOT_FULL_RESTORE_POST=false
      ;;
    *)
      fail "Boot repair blocked: lifecycle state is unsupported"
      return 100
      ;;
  esac
}

guard_boot_transaction() {
  require_control_root || return 1
  read_lifecycle || {
    fail "Boot-mutating package transaction blocked: lifecycle state is invalid or unsafe"
    return 1
  }
  if [[ -e "$(snapshot_restore_lock_path)" || -L "$(snapshot_restore_lock_path)" ]]; then
    fail "Boot-mutating package transaction blocked: full snapshot restore is running"
    return 1
  fi

  case "$_lifecycle_state" in
    unmanaged|disabled)
      return 0
      ;;
    active)
      if lifecycle_repair_is_available; then
        return 0
      fi
      fail "Boot-mutating package transaction blocked: complete boot repair is unavailable"
      return 1
      ;;
    transition)
      if read_transaction_manifest "$_lifecycle_transaction_id" \
        && ! manifest_owner_is_alive \
        && with_boot_repair_lock; then
        reconcile_stale_lifecycle || true
        release_boot_repair_lock
        read_lifecycle || true
      fi
      fail "Boot-mutating package transaction blocked: lifecycle is ${_lifecycle_state} for transaction ${_lifecycle_transaction_id}"
      return 1
      ;;
    recovery-required)
      fail "Boot-mutating package transaction blocked: lifecycle is recovery-required for transaction ${_lifecycle_transaction_id}"
      return 1
      ;;
    *)
      fail "Boot-mutating package transaction blocked: lifecycle state is unsupported"
      return 1
      ;;
  esac
}

lifecycle_automation_is_active() {
  read_lifecycle || {
    fail "Lifecycle state is invalid or unsafe"
    return 2
  }
  case "$_lifecycle_state" in
    active) return 0 ;;
    unmanaged|disabled) return 1 ;;
    transition|recovery-required)
      fail "Automatic repair blocked while lifecycle is ${_lifecycle_state} for transaction ${_lifecycle_transaction_id}"
      return 2
      ;;
    *)
      fail "Automatic repair blocked: lifecycle state is unsupported"
      return 2
      ;;
  esac
}

show_lifecycle_status() {
  if ! read_lifecycle; then
    fail "Lifecycle state is invalid or unsafe"
    return 1
  fi
  case "$_lifecycle_state" in
    unmanaged)
      warn "Lifecycle: unmanaged (explicit setup or adoption required)"
      return 1
      ;;
    disabled) pass "Lifecycle: disabled" ;;
    active)
      if lifecycle_repair_is_available; then
        pass "Lifecycle: active"
      else
        warn "Lifecycle: active (boot producers blocked until interrupted recovery is available)"
        return 1
      fi
      ;;
    transition)
      if [[ "$EUID" == "$(control_owner_uid)" ]]; then
        if ! read_transaction_manifest "$_lifecycle_transaction_id"; then
          fail "Lifecycle: recovery-required (invalid transaction ${_lifecycle_transaction_id})"
          return 1
        fi
        if ! manifest_owner_is_alive; then
          fail "Lifecycle: recovery-required (stale transaction ${_lifecycle_transaction_id})"
          return 1
        fi
      fi
      warn "Lifecycle: transition (${_lifecycle_transaction_id})"
      return 1
      ;;
    recovery-required)
      fail "Lifecycle: recovery-required (${_lifecycle_transaction_id})"
      return 1
      ;;
    *)
      fail "Lifecycle: unsupported state"
      return 1
      ;;
  esac
}
