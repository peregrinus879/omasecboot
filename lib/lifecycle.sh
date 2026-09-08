#!/bin/bash
# OmaSecBoot: durable lifecycle, transaction, and hook ownership protocol

readonly LIFECYCLE_SCHEMA_VERSION=2
# Phase sequence of every operation whose phases run in one fixed order; the
# validators and the executors agree through this table.
readonly OMASECBOOT_OPERATION_PHASES='{
  "adopt": ["record-adoption"],
  "prepare-secure-boot": ["backup-firmware","create-keys","build-enrollment-plan"],
  "activate-secure-boot-plan": ["confirm-enrollment-plan","bind-enrollment-plan",
    "backup-artifacts","configure-limine","enroll-config","verify-config",
    "clean-tracking","sign-efi","prove-artifacts"],
  "sign": ["backup-artifacts","configure-limine","enroll-config","verify-config",
    "clean-tracking","sign-efi","prove-artifacts"],
  "cleanup": ["clean-tracking"],
  "windows-setup": ["backup-windows","resolve-windows","persist-windows-target",
    "configure-windows-entry","backup-artifacts","configure-limine","enroll-config",
    "verify-config","clean-tracking","sign-efi","prove-artifacts","prove-windows"],
  "windows-suppress": ["backup-windows","suppress-windows-entry","backup-artifacts",
    "configure-limine","enroll-config","verify-config","clean-tracking","sign-efi",
    "prove-artifacts","prove-windows-suppression"],
  "unconfigure": ["record-unconfigure","backup-software-state","restore-managed-settings",
    "remove-windows-entry","remove-owned-tracking","reset-config-enrollment",
    "rebuild-stock-limine","prove-unconfigured"],
  "unconfigure-recovery": ["restore-managed-settings","remove-windows-entry",
    "remove-owned-tracking","reset-config-enrollment","rebuild-stock-limine",
    "prove-unconfigured"],
  "producer-package": ["reconstruct-producer","backup-artifacts","configure-limine",
    "enroll-config","verify-config","clean-tracking","sign-efi","prove-artifacts"],
  "producer-limine": ["reconstruct-producer","backup-artifacts","configure-limine",
    "enroll-config","verify-config","clean-tracking","sign-efi","prove-artifacts"],
  "producer-snapshot": ["reconstruct-producer","backup-artifacts","configure-limine",
    "enroll-config","verify-config","clean-tracking","sign-efi","prove-artifacts"],
  "producer-restore": ["reconstruct-producer","backup-artifacts","configure-limine",
    "enroll-config","verify-config","clean-tracking","sign-efi","prove-artifacts"],
  "producer-recovery": ["reconstruct-producer","backup-artifacts","configure-limine",
    "enroll-config","verify-config","clean-tracking","sign-efi","prove-artifacts"]
}'
readonly MAX_RECOVERY_ATTEMPT_SEALS=32
readonly MAX_TRANSACTION_BACKUPS=4096
readonly MAX_CONTROL_DOCUMENT_BYTES=1048576
readonly MAX_FIRMWARE_WRITE_ATTEMPTS=6
readonly MAX_FIRMWARE_HIERARCHY_ATTEMPTS=2
# jq definitions of the manifest's compound members and of the evidence
# predicates the rule functions share; appended to OMASECBOOT_JQ_DEFS.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
readonly MANIFEST_JQ_DEFS='
  def no_firmware_evidence:
    .firmware_backup == null and .enrollment_plan == null and .firmware_writes == [];
  def ownership_records_paired:
    (.domain_records.managed_settings == null) ==
      (.domain_records.tracking_ownership == null);
  def owner_identity:
    type == "object" and keys == ["pid","start_time","uid"] and
    (.pid | type == "number" and . > 0 and floor == .) and
    (.start_time | type == "string" and test("^[0-9]+$") and length <= 32);
  def recovery_lineage($max_attempts):
    type == "object" and keys == ["attempt_number","previous_attempt","root_incident"] and
    (.attempt_number | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
    (.root_incident | incident_reference($max_attempts)) and .root_incident.kind == "root" and
    (if .attempt_number == 1 then .previous_attempt == null
     else (.previous_attempt | incident_reference($max_attempts)) and
       .previous_attempt.kind == "attempt" and
       .previous_attempt.ordinal == (.attempt_number - 1)
     end);
  def backup_entry:
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
    else false end;
  def backup_list($transaction_dir; $max_backups):
    type == "array" and length >= 1 and length <= $max_backups and
    all(.[]; backup_entry) and
    (.[0].kind == "absent-lifecycle" or .[0].kind == "prior-lifecycle") and
    all(.[1:][]; .kind == "file" or .kind == "absent-file") and
    all(to_entries[1:][]; .value.kind == "absent-file" or
      .value.path == ($transaction_dir + "/file-" + (.key | tostring) + ".backup")) and
    ([.[] | select(.target != null) | .target] as $targets |
      ($targets | length) == ($targets | unique | length)) and
    ([.[] | select(.path != null) | .path] as $paths |
      ($paths | length) == ($paths | unique | length));
  def firmware_backup:
    type == "object" and keys == ["id","manifest_sha256","path","status"] and
    (.id | uuid) and (.path | absolute_path) and
    (.status == "pending" or .status == "complete") and
    (if .status == "complete" then (.manifest_sha256 | digest)
     else .manifest_sha256 == null end);
  def enrollment_plan:
    type == "object" and keys == ["backup_id","dbx","manifest_sha256","path","variables"] and
    (.backup_id | uuid) and (.path | absolute_path) and (.manifest_sha256 | digest) and
    (.variables | type == "object" and keys == ["KEK","PK","db"]) and
    all(.variables[]; type == "object" and keys == ["entries_sha256","esl_sha256"] and
      (.entries_sha256 | digest) and (.esl_sha256 | digest)) and
    (.dbx | type == "object" and keys == ["present","raw_sha256"]) and
    (.dbx.present | type == "boolean") and
    (if .dbx.present then (.dbx.raw_sha256 | digest) else .dbx.raw_sha256 == null end);
  def firmware_write:
    type == "object" and
    keys == ["command_exit_code","completed_at","hierarchy","readback_status","started_at"] and
    (.hierarchy == "db" or .hierarchy == "KEK" or .hierarchy == "PK") and
    (.started_at | timestamp) and
    (.command_exit_code == null or
      (.command_exit_code | type == "number" and . >= 0 and . <= 255 and floor == .)) and
    (.readback_status == "pending" or .readback_status == "unchanged" or
      .readback_status == "verified" or .readback_status == "failed") and
    (if .readback_status == "pending" then .completed_at == null
     else (.completed_at | timestamp) end);
  def firmware_write_sequence($max_writes; $max_hierarchy_writes):
    type == "array" and length <= $max_writes and all(.[]; firmware_write) and
    ([.[] | select(.hierarchy == "db")] | length) <= $max_hierarchy_writes and
    ([.[] | select(.hierarchy == "KEK")] | length) <= $max_hierarchy_writes and
    ([.[] | select(.hierarchy == "PK")] | length) <= $max_hierarchy_writes and
    (reduce .[] as $write ({ok: true, next: "db", terminal: false};
      if ((.ok | not) or .terminal or $write.hierarchy != .next) then .ok = false
      elif $write.readback_status == "pending" then .terminal = true
      elif $write.readback_status == "failed" then .terminal = true
      elif $write.readback_status == "unchanged" then .
      elif $write.readback_status == "verified" then
        .next = (if .next == "db" then "KEK" elif .next == "KEK" then "PK" else "complete" end)
      else .ok = false end) | .ok);
  def rollback_outcome:
    type == "object" and keys == ["attempted_at","failures","status"] and
    (.status == "completed" or .status == "failed" or .status == "preserved") and
    (.attempted_at | timestamp) and
    (.failures | type == "array" and length <= 128 and
      all(.[]; type == "string" and length <= 4096));
'

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
_recovery_terminal_state=""
_recovery_producer_reference="null"
_transaction_active=false
_transaction_id=""
_transaction_operation=""
_transaction_target_state=""
_lifecycle_recovery_performed=false
_transaction_previous_exit=""
_transaction_previous_int=""
_transaction_previous_term=""
_transaction_previous_hup=""

lifecycle_failpoint() {
  return 0
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

# A full restore leaves its marker for the whole restore. No producer lease,
# stale-transition reconciliation, or recovery runs while it exists, and
# OmaSecBoot never removes it: the marker lives under /run/lock and clears
# with the boot.
producer_runtime_is_clear() {
  local marker
  marker=$(snapshot_restore_lock_path) || return 1
  [[ ! -e "$marker" && ! -L "$marker" ]]
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

recovery_root_manifest_from_reference() {
  local reference="$1"
  validate_incident_reference "$reference" || return 1
  [[ $(jq -r '.kind' <<< "$_incident_json") == root ]] || return 1
  printf '%s\n' "$_manifest_json"
}

recovery_terminal_state_for_root_manifest() {
  local document="$1" recovery_operation="$2" root_status
  case "$recovery_operation" in
    producer-recovery|firmware-recovery|windows-recovery)
      printf 'active\n'
      ;;
    unconfigure-recovery)
      jq -e '.kind == "root" and .operation == "unconfigure" and
        .prior_state == "active" and .target_state == "disabled" and
        .file_rollback_policy == "preserve" and
        .domain_records.unconfigure != null' <<< "$document" >/dev/null || return 1
      printf 'disabled\n'
      ;;
    software-recovery)
      software_recovery_root_is_supported "$document" || return 1
      root_status=$(jq -r '.status' <<< "$document") || return 1
      if [[ "$root_status" == completed ]]; then
        jq -r '.target_state' <<< "$document"
      else
        jq -r '.prior_state' <<< "$document"
      fi
      ;;
    *) return 1 ;;
  esac
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

transaction_locks_are_held() {
  [[ "$_transaction_active" == true ]] && boot_locks_are_held
}

# Ends the active transaction window and drops the environment handoff; the
# identity fields stay readable until detach_transaction_context clears them.
end_transaction_context() {
  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

# Prints a document's integer schema_version, or "invalid".
document_schema_version() {
  jq -r 'if (.schema_version | type) == "number" and
    (.schema_version | floor) == .schema_version then .schema_version else "invalid" end' \
    <<< "$1"
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

# One field of /proc/<pid>/stat after the command name, matched against a
# pattern before it is trusted.
process_stat_field() {
  local pid="$1" index="$2" pattern="$3" fields
  local -a values
  fields=$(process_stat_fields "$pid") || return 1
  read -r -a values <<< "$fields"
  [[ ${#values[@]} -gt $index && ${values[$index]} =~ $pattern ]] || return 1
  printf '%s\n' "${values[$index]}"
}

process_start_time() {
  process_stat_field "$1" 19 '^[0-9]+$'
}

process_state() {
  process_stat_field "$1" 0 '^[A-Za-z]$'
}

process_parent_pid() {
  process_stat_field "$1" 1 '^[0-9]+$'
}

# Walks from a process up its ancestry and prints the first pid the predicate
# accepts; the walk is bounded and a self-parented pid ends it.
find_process_ancestor() {
  local current="$1" predicate="$2" parent loops=0
  shift 2
  while [[ "$current" =~ ^[0-9]+$ && "$current" -gt 0 && $loops -lt 256 ]]; do
    if "$predicate" "$current" "$@"; then
      printf '%s\n' "$current"
      return 0
    fi
    parent=$(process_parent_pid "$current") || return 1
    [[ "$parent" != "$current" ]] || return 1
    current="$parent"
    loops=$((loops + 1))
  done
  return 1
}

process_is_pid() {
  [[ "$1" == "$2" ]]
}

process_has_ancestor() {
  local ancestor="$1" current="$2"
  find_process_ancestor "$current" process_is_pid "$ancestor" >/dev/null
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
  mode_is_private "$mode"
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

# Writes stdin to destination through a private temporary file with fsync of the
# file and its directory. With "create", the destination must not exist and the
# rename refuses to replace anything (create-once publication).
atomic_write_control_file() {
  local destination="$1" mode="$2" create="${3:-}" parent temporary old_umask
  parent=$(dirname "$destination")
  validate_control_directory "$parent" || return 1
  if [[ -e "$destination" || -L "$destination" ]]; then
    [[ -z "$create" ]] && validate_control_file "$destination" || return 1
  fi
  old_umask=$(umask)
  umask 077
  temporary=$(mktemp "${parent}/.$(basename "$destination").XXXXXX")
  local rc=$?
  umask "$old_umask"
  [[ $rc -eq 0 ]] || return 1
  if ! cat > "$temporary" \
    || ! chmod "$mode" "$temporary" \
    || ! validate_control_file "$temporary" \
    || ! durable_sync "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if [[ -n "$create" ]]; then
    mv -T --no-copy --update=none-fail "$temporary" "$destination" || {
      rm -f "$temporary"
      return 1
    }
    validate_control_file "$destination" || return 1
  else
    mv -f "$temporary" "$destination" || {
      rm -f "$temporary"
      return 1
    }
  fi
  durable_sync "$parent"
}

atomic_create_control_file() {
  atomic_write_control_file "$1" "$2" create
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
    --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" "$OMASECBOOT_JQ_DEFS"'
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
        (.root_incident | incident_reference($max_attempts)) and .root_incident.kind == "root" and
        (.previous_attempt == null or
          ((.previous_attempt | incident_reference($max_attempts)) and .previous_attempt.kind == "attempt"))
      else false end);
    def incident_state:
      type == "object" and
      keys == ["attempt_count","id","kind","last_recovery_attempt","manifest","operation","root_incident"] and
      .kind == "incident" and (.id | uuid) and (.operation | operation) and
      (.manifest | absolute_path) and (.root_incident | incident_reference($max_attempts)) and
      .root_incident.kind == "root" and .root_incident.id == .id and
      .root_incident.operation == .operation and
      (.attempt_count | type == "number" and . >= 0 and . <= $max_attempts and floor == .) and
      (if .attempt_count == 0 then .last_recovery_attempt == null
       else (.last_recovery_attempt | incident_reference($max_attempts)) and
         .last_recovery_attempt.kind == "attempt" and
         .last_recovery_attempt.ordinal == .attempt_count and
         (.last_recovery_attempt.status == "failed" or
           .last_recovery_attempt.status == "stale")
       end);
    def resolved_recovery:
      type == "object" and
      keys == ["attempt_count","final_attempt","proof","resolved_at","root_incident"] and
      (.attempt_count | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
      (.root_incident | incident_reference($max_attempts)) and .root_incident.kind == "root" and
      (.final_attempt | incident_reference($max_attempts)) and .final_attempt.kind == "attempt" and
      .final_attempt.ordinal == .attempt_count and .final_attempt.status == "completed" and
      (.proof | artifact_reference) and (.resolved_at | timestamp);
    type == "object" and
    keys == ["generation","last_recovery","last_transaction","managed_settings",
      "schema_version","state","tracking_ownership","transaction","updated_at","writer_version"] and
    .schema_version == $schema and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.generation | type == "number" and . >= 1 and floor == .) and
    (.state == "disabled" or .state == "active" or
      .state == "transition" or .state == "recovery-required") and
    (.updated_at | timestamp) and
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

# The manifest schema: identity, kind-specific lineage, phases, backups,
# firmware evidence, domain-record references, and the status envelope.
validate_manifest_schema() {
  local transaction_id="$1" document="$2" transaction_dir="$3"
  jq -e --arg id "$transaction_id" --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --argjson owner_uid "$(control_owner_uid)" \
    --arg transaction_dir "$transaction_dir" \
    --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" \
    --argjson max_backups "$MAX_TRANSACTION_BACKUPS" \
    --argjson max_firmware_writes "$MAX_FIRMWARE_WRITE_ATTEMPTS" \
    --argjson max_hierarchy_writes "$MAX_FIRMWARE_HIERARCHY_ATTEMPTS" \
    --argjson phases "$OMASECBOOT_OPERATION_PHASES" \
    "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    type == "object" and
    keys == ["backups","boot_id","completed_at","completed_phases","created_at",
      "current_phase","domain_records","enrollment_plan","failure","file_rollback_policy",
      "firmware_backup","firmware_writes","id","kind","operation","owner","prior_state",
      "recovery","rollback","schema_version","status","target_state",
      "token_sha256","writer_version"] and
    .schema_version == $schema and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .id == $id and (.operation | operation) and
    (.status == "transition" or .status == "completed" or
      .status == "failed" or .status == "stale") and
    (.created_at | timestamp) and
    (.boot_id | uuid) and (.token_sha256 | digest) and
    (.owner | owner_identity) and .owner.uid == $owner_uid and
    (if .kind == "root" then
      (.target_state == "disabled" or .target_state == "active") and
      (.prior_state == "unmanaged" or .prior_state == "disabled" or .prior_state == "active") and
      .recovery == null
     elif .kind == "recovery-attempt" then
      (.target_state == "disabled" or .target_state == "active" or
        (.operation == "software-recovery" and .target_state == "unmanaged")) and
      .prior_state == "recovery-required" and
      (.recovery | recovery_lineage($max_attempts))
     else false end) and
    (.current_phase == null or (.current_phase | phase)) and
    (.completed_phases | type == "array" and length <= 128 and
      all(.[]; phase) and length == (unique | length)) and
    (if (.operation | startswith("producer-")) then
       phase_sequence_valid($phases[.operation]) else true end) and
    (.backups | backup_list($transaction_dir; $max_backups)) and
    (.file_rollback_policy == "restore" or .file_rollback_policy == "preserve") and
    (.firmware_backup == null or (.firmware_backup | firmware_backup)) and
    (.enrollment_plan == null or (
      (.enrollment_plan | enrollment_plan) and
      .firmware_backup != null and .firmware_backup.status == "complete" and
      .firmware_backup.id == .enrollment_plan.backup_id)) and
    (.firmware_writes | firmware_write_sequence($max_firmware_writes; $max_hierarchy_writes)) and
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
    (.rollback == null or (.rollback | rollback_outcome))
  ' <<< "$document" >/dev/null
}

# The first backup entry is the prior lifecycle document, or its absence when
# the transaction started unmanaged.
validate_manifest_lifecycle_backup() {
  local document="$1" transaction_dir="$2" prior_state backup_kind backup_path backup_hash
  prior_state=$(jq -r '.prior_state' <<< "$document") || return 1
  backup_kind=$(jq -r '.backups[0].kind' <<< "$document") || return 1
  if [[ "$prior_state" == unmanaged ]]; then
    [[ "$backup_kind" == absent-lifecycle ]] || return 1
    return 0
  fi
  backup_path=$(jq -r '.backups[0].path' <<< "$document") || return 1
  backup_hash=$(jq -r '.backups[0].sha256' <<< "$document") || return 1
  [[ "$backup_kind" == prior-lifecycle \
    && "$backup_path" == "${transaction_dir}/prior-lifecycle.json" ]] || return 1
  validate_private_control_file "$backup_path" || return 1
  [[ "$(sha256_file "$backup_path")" == "$backup_hash" ]]
}

# Every file backup targets a distinct symlink-free path; a taken copy is a
# private control file in the transaction directory with the recorded hash,
# mode, and owner.
validate_manifest_file_backups() {
  local document="$1" transaction_dir="$2" backup_entry backup_kind backup_path
  local backup_hash backup_target backup_mode backup_uid backup_gid
  local -A backup_targets=()
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
    [[ "$backup_kind" == file ]] || continue
    [[ "$(dirname "$backup_path")" == "$transaction_dir" \
      && "$(basename "$backup_path")" =~ ^file-[1-9][0-9]*\.backup$ ]] \
      || return 1
    [[ "$backup_mode" =~ ^[0-7]{3,4}$ \
      && "$backup_uid" =~ ^[0-9]+$ && "$backup_gid" =~ ^[0-9]+$ ]] || return 1
    [[ "$backup_uid" == "$(control_owner_uid)" ]] || return 1
    mode_is_control_safe "$backup_mode" || return 1
    validate_private_control_file "$backup_path" || return 1
    [[ "$(sha256_file "$backup_path")" == "$backup_hash" ]] || return 1
  done < <(jq -c '.backups[] |
    select(.kind == "file" or .kind == "absent-file")' <<< "$document")
}

# The firmware backup and enrollment plan live under the state directory at
# the paths their identifiers imply.
validate_manifest_firmware_paths() {
  local document="$1" backup_id path
  if json_is '.firmware_backup != null' "$document"; then
    backup_id=$(jq -r '.firmware_backup.id' <<< "$document") || return 1
    path=$(jq -r '.firmware_backup.path' <<< "$document") || return 1
    [[ "$path" == "$(state_dir_path)/firmware-backup/${backup_id}" ]] || return 1
  fi
  if json_is '.enrollment_plan != null' "$document"; then
    backup_id=$(jq -r '.enrollment_plan.backup_id' <<< "$document") || return 1
    path=$(jq -r '.enrollment_plan.path' <<< "$document") || return 1
    [[ "$path" == "$(state_dir_path)/firmware-backup/${backup_id}/plan" ]] || return 1
  fi
}

# A manifest is valid when its schema holds and, unless check_files is false,
# every backup, firmware path, and domain record it references proves on disk.
validate_transaction_manifest_json() {
  local transaction_id="$1" document="$2" check_files="${3:-true}" transaction_dir reference
  [[ "$check_files" == true || "$check_files" == false ]] || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  validate_manifest_schema "$transaction_id" "$document" "$transaction_dir" \
    || return 1
  [[ "$check_files" == true ]] || return 0
  validate_manifest_lifecycle_backup "$document" "$transaction_dir" || return 1
  validate_manifest_file_backups "$document" "$transaction_dir" || return 1
  validate_manifest_firmware_paths "$document" || return 1
  while IFS= read -r reference; do
    [[ -z "$reference" ]] || validate_artifact_reference_file "$reference" "$transaction_dir" \
      || return 1
  done < <(jq -c '.domain_records[] | select(. != null)' <<< "$document")
  validate_transaction_domain_records "$transaction_id" "$document"
}

# Managed settings and tracking ownership are recorded together: tracking
# ownership requires managed settings, and a completed transaction carries both
# or neither.
validate_ownership_record_rules() {
  local transaction_id="$1" status="$2" managed_settings="$3" tracking_ownership="$4"
  if [[ "$managed_settings" != null ]]; then
    validate_managed_settings_record_reference "$transaction_id" "$managed_settings" \
      || return 1
  fi
  if [[ "$tracking_ownership" != null ]]; then
    validate_tracking_ownership_record_reference "$transaction_id" "$tracking_ownership" \
      || return 1
    [[ "$managed_settings" != null ]] || return 1
  fi
  [[ "$status" == completed ]] || return 0
  [[ ( "$managed_settings" == null && "$tracking_ownership" == null ) \
    || ( "$managed_settings" != null && "$tracking_ownership" != null ) ]]
}

# A producer root binds the immutable producer record to its own identity and
# carries no firmware, Windows, or unconfigure evidence.
validate_producer_record_rules() {
  local transaction_id="$1" document="$2" producer="$3" path producer_document
  validate_producer_record_reference "$transaction_id" "$producer" || return 1
  path=$(jq -r '.path' <<< "$producer") || return 1
  producer_document=$(read_control_document "$path") || return 1
  jq -en --argjson manifest "$document" --argjson producer "$producer_document" \
    --argjson final_schema "$FINAL_PROOF_SCHEMA_VERSION" "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    $manifest.operation == $producer.operation and
    $manifest.target_state == "active" and $manifest.prior_state == "active" and
    $manifest.file_rollback_policy == "preserve" and
    $manifest.boot_id == $producer.owner.boot_id and
    $manifest.owner.pid == $producer.owner.pid and
    $manifest.owner.start_time == $producer.owner.start_time and
    $manifest.owner.uid == $producer.owner.uid and
    ($manifest | no_firmware_evidence) and
    $manifest.domain_records.bootnext == null and
    $manifest.domain_records.firmware == null and
    $manifest.domain_records.unconfigure == null and
    $manifest.domain_records.windows == null and
    (if $manifest.status == "completed" then
      ($manifest | ownership_records_paired) and
      $manifest.domain_records.final_proof != null and
      $manifest.domain_records.final_proof.schema_version == $final_schema
     else true end)
  ' >/dev/null
}

# The proof document a manifest's final proof must be, by kind and operation.
validate_proof_record_reference() {
  local transaction_id="$1" document="$2" kind="$3" operation="$4" proof="$5"
  case "${kind}/${operation}" in
    recovery-attempt/windows-recovery)
      validate_windows_recovery_proof_reference "$transaction_id" "$proof" "$document"
      ;;
    recovery-attempt/software-recovery)
      validate_software_recovery_proof_reference "$transaction_id" "$proof" "$document"
      ;;
    root/unconfigure|recovery-attempt/unconfigure-recovery)
      validate_unconfigure_proof_reference "$transaction_id" "$proof" "$document"
      ;;
    *)
      validate_final_proof_reference "$transaction_id" "$proof"
      ;;
  esac
}

# Enrollment evidence of a root enrollment (prior state active) or a firmware
# recovery attempt (prior state recovery-required): the backup precedes the
# plan, a root without a backup still restores files, and completion proves
# db, KEK, and PK in order.
validate_enrollment_manifest_rules() {
  local document="$1" prior_state="$2"
  jq -e --arg prior "$prior_state" --argjson final_schema "$FINAL_PROOF_SCHEMA_VERSION" \
    "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    .target_state == "active" and .prior_state == $prior and
    .domain_records.bootnext == null and
    (if .status == "completed" then ownership_records_paired else true end) and
    .domain_records.unconfigure == null and .domain_records.windows == null and
    (if .firmware_backup == null then
      .enrollment_plan == null and .firmware_writes == [] and
      (if $prior == "active" then
        .domain_records.firmware == null and .file_rollback_policy == "restore"
       else true end)
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
  ' <<< "$document" >/dev/null
}

# A BootNext root records the variable before its single write and carries no
# other evidence.
validate_bootnext_manifest_rules() {
  local document="$1"
  jq -e "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    .target_state == "active" and .prior_state == "active" and
    .file_rollback_policy == "restore" and no_firmware_evidence and
    .domain_records.final_proof == null and .domain_records.firmware == null and
    .domain_records.managed_settings == null and
    .domain_records.tracking_ownership == null and
    .domain_records.unconfigure == null and .domain_records.windows == null and
    (if .domain_records.bootnext == null then
      .completed_phases == [] and
      (.current_phase == null or .current_phase == "record-bootnext")
     else
      ((.completed_phases == [] and .current_phase == "record-bootnext") or
       (.completed_phases == ["record-bootnext"] and
         (.current_phase == null or .current_phase == "set-bootnext")) or
       (.completed_phases == ["record-bootnext","set-bootnext"] and
         .current_phase == null))
     end) and
    (if .status == "completed" then
      .domain_records.bootnext != null and
      .completed_phases == ["record-bootnext","set-bootnext"]
     else true end)
  ' <<< "$document" >/dev/null
}

# An unconfigure root restores files until config enrollment is reset and
# preserves them afterwards; completion requires the intent and the proof.
validate_unconfigure_manifest_rules() {
  local document="$1"
  jq -e --argjson intent_schema "$UNCONFIGURE_INTENT_SCHEMA_VERSION" \
    --argjson proof_schema "$UNCONFIGURE_PROOF_SCHEMA_VERSION" \
    --argjson phases "$OMASECBOOT_OPERATION_PHASES" "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    $phases["unconfigure"] as $phases |
    .target_state == "disabled" and .prior_state == "active" and
    no_firmware_evidence and
    .domain_records.bootnext == null and
    .domain_records.firmware == null and .domain_records.managed_settings == null and
    .domain_records.producer == null and .domain_records.tracking_ownership == null and
    .domain_records.windows == null and
    phase_sequence_valid($phases) and
    (if .domain_records.unconfigure == null then
      .completed_phases == [] and
      (.current_phase == null or .current_phase == "record-unconfigure")
     else .domain_records.unconfigure.schema_version == $intent_schema end) and
    (if .domain_records.final_proof == null then true
     else .current_phase == "prove-unconfigured" or
       (.completed_phases == $phases and .current_phase == null) end) and
    ((.completed_phases | length) as $done |
     if $done < 5 or ($done == 5 and .current_phase == null) then
       .file_rollback_policy == "restore"
     elif $done == 5 and .current_phase == "reset-config-enrollment" then
       (.file_rollback_policy == "restore" or .file_rollback_policy == "preserve")
     else .file_rollback_policy == "preserve" end) and
    (if .status == "completed" then
      .file_rollback_policy == "preserve" and .domain_records.unconfigure != null and
      .domain_records.final_proof != null and
      .domain_records.final_proof.schema_version == $proof_schema and
      .completed_phases == $phases and .current_phase == null
     else true end)
  ' <<< "$document" >/dev/null
}

# A Windows recovery attempt classifies, restores, and proves BootNext in order
# and records nothing else.
validate_windows_recovery_manifest_rules() {
  local document="$1"
  jq -e "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    .target_state == "active" and .prior_state == "recovery-required" and
    .file_rollback_policy == "restore" and no_firmware_evidence and
    .domain_records.bootnext == null and .domain_records.firmware == null and
    .domain_records.managed_settings == null and .domain_records.producer == null and
    .domain_records.tracking_ownership == null and .domain_records.unconfigure == null and
    (if .domain_records.windows == null then
      .domain_records.final_proof == null and .completed_phases == [] and
      (.current_phase == null or .current_phase == "classify-bootnext")
     elif .domain_records.final_proof == null then
      ((.completed_phases == [] and .current_phase == "classify-bootnext") or
       (.completed_phases == ["classify-bootnext"] and
         (.current_phase == null or .current_phase == "restore-bootnext")) or
       (.completed_phases == ["classify-bootnext","restore-bootnext"] and
         (.current_phase == null or .current_phase == "prove-bootnext")))
     else
      ((.completed_phases == ["classify-bootnext","restore-bootnext"] and
          .current_phase == "prove-bootnext") or
       (.completed_phases ==
          ["classify-bootnext","restore-bootnext","prove-bootnext"] and
          .current_phase == null))
     end) and
    (if .status == "completed" then
      .domain_records.windows != null and .domain_records.final_proof != null and
      .completed_phases ==
        ["classify-bootnext","restore-bootnext","prove-bootnext"]
     else true end)
  ' <<< "$document" >/dev/null
}

# A software recovery attempt either restores files and proves the restore or
# proves an already completed root; its target may be any stable state.
validate_software_recovery_manifest_rules() {
  local document="$1"
  jq -e --argjson proof_schema "$SOFTWARE_RECOVERY_PROOF_SCHEMA_VERSION" \
    "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    .prior_state == "recovery-required" and
    (.target_state == "active" or .target_state == "disabled" or
      .target_state == "unmanaged") and
    .file_rollback_policy == "preserve" and no_firmware_evidence and
    .domain_records.bootnext == null and .domain_records.firmware == null and
    .domain_records.managed_settings == null and .domain_records.producer == null and
    .domain_records.tracking_ownership == null and .domain_records.unconfigure == null and
    .domain_records.windows == null and
    (.completed_phases == ["restore-files","prove-restored"] or
      .completed_phases == ["prove-completed"] or
      .completed_phases == [] or
      .completed_phases == ["restore-files"]) and
    (if .current_phase == null then true
     elif .completed_phases == [] then
       (.current_phase == "restore-files" or .current_phase == "prove-completed")
     elif .completed_phases == ["restore-files"] then
       .current_phase == "prove-restored"
     else false end) and
    (if .status == "completed" then
      .domain_records.final_proof != null and
      .domain_records.final_proof.schema_version == $proof_schema and
      ((.completed_phases == ["restore-files","prove-restored"]) or
       (.completed_phases == ["prove-completed"])) and .current_phase == null
     else true end)
  ' <<< "$document" >/dev/null
}

# An unconfigure recovery attempt replays the fixed phase sequence and
# completes only with the proof.
validate_unconfigure_recovery_manifest_rules() {
  local document="$1"
  jq -e --argjson proof_schema "$UNCONFIGURE_PROOF_SCHEMA_VERSION" \
    --argjson phases "$OMASECBOOT_OPERATION_PHASES" "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'
    .target_state == "disabled" and .prior_state == "recovery-required" and
    .file_rollback_policy == "preserve" and no_firmware_evidence and
    .domain_records.bootnext == null and .domain_records.firmware == null and
    .domain_records.managed_settings == null and .domain_records.producer == null and
    .domain_records.tracking_ownership == null and .domain_records.unconfigure == null and
    .domain_records.windows == null and
    ($phases["unconfigure-recovery"] as $phases |
      phase_sequence_valid($phases) and
      (if .domain_records.final_proof == null then true
       else .current_phase == "prove-unconfigured" or
         (.completed_phases == $phases and .current_phase == null) end) and
      (if .status == "completed" then
        .domain_records.final_proof != null and
        .domain_records.final_proof.schema_version == $proof_schema and
        .completed_phases == $phases and .current_phase == null
       else true end))
  ' <<< "$document" >/dev/null
}

# The evidence shape of a recovery attempt, by operation.
validate_recovery_attempt_manifest_rules() {
  local document="$1" operation="$2" firmware="$3"
  case "$operation" in
    producer-recovery)
      [[ "$firmware" == null ]] || return 1
      json_is "${OMASECBOOT_JQ_DEFS}${MANIFEST_JQ_DEFS}"'no_firmware_evidence and
        .file_rollback_policy == "preserve"' "$document"
      ;;
    firmware-recovery) validate_enrollment_manifest_rules "$document" recovery-required ;;
    windows-recovery) validate_windows_recovery_manifest_rules "$document" ;;
    software-recovery) validate_software_recovery_manifest_rules "$document" ;;
    unconfigure-recovery) validate_unconfigure_recovery_manifest_rules "$document" ;;
    *) return 1 ;;
  esac
}

# The domain records of one manifest: each present record proves its
# reference, and the record set matches the manifest's kind and operation.
validate_transaction_domain_records() {
  local transaction_id="$1" document="$2" extracted
  local bootnext producer proof firmware managed_settings tracking_ownership
  local unconfigure windows kind status operation
  local -a fields
  extracted=$(jq -er '
    (.domain_records.bootnext | tojson),
    (.domain_records.producer | tojson),
    (.domain_records.final_proof | tojson),
    (.domain_records.firmware | tojson),
    (.domain_records.managed_settings | tojson),
    (.domain_records.tracking_ownership | tojson),
    (.domain_records.unconfigure | tojson),
    (.domain_records.windows | tojson),
    .kind, .status, .operation
  ' <<< "$document") || return 1
  mapfile -t fields <<< "$extracted"
  [[ ${#fields[@]} -eq 11 ]] || return 1
  bootnext=${fields[0]}
  producer=${fields[1]}
  proof=${fields[2]}
  firmware=${fields[3]}
  managed_settings=${fields[4]}
  tracking_ownership=${fields[5]}
  unconfigure=${fields[6]}
  windows=${fields[7]}
  kind=${fields[8]}
  status=${fields[9]}
  operation=${fields[10]}

  validate_ownership_record_rules "$transaction_id" "$status" "$managed_settings" \
    "$tracking_ownership" || return 1
  if [[ "$unconfigure" != null ]]; then
    [[ "$operation" == unconfigure ]] || return 1
    validate_unconfigure_intent_reference "$transaction_id" "$unconfigure" "$document" \
      || return 1
  fi
  if [[ "$bootnext" != null ]]; then
    [[ "$kind" == root && "$operation" == windows-bootnext \
      && "$producer" == null ]] || return 1
    validate_bootnext_record_reference "$transaction_id" "$bootnext" "$document" || return 1
  fi
  if [[ "$producer" != null ]]; then
    [[ "$kind" == root ]] || return 1
    validate_producer_record_rules "$transaction_id" "$document" "$producer" || return 1
  fi
  if [[ "$windows" != null ]]; then
    [[ "$kind" == recovery-attempt && "$operation" == windows-recovery \
      && "$bootnext" == null && "$producer" == null && "$firmware" == null ]] || return 1
    validate_windows_recovery_record_reference "$transaction_id" "$windows" "$document" \
      || return 1
  fi
  if [[ "$proof" != null ]]; then
    validate_proof_record_reference "$transaction_id" "$document" "$kind" "$operation" \
      "$proof" || return 1
  fi
  if [[ "$firmware" != null ]]; then
    [[ "$producer" == null && "$proof" != null \
      && ( ( "$kind" == root && "$operation" == enroll-secure-boot ) \
        || ( "$kind" == recovery-attempt && "$operation" == firmware-recovery ) ) ]] \
      || return 1
    validate_firmware_proof_reference "$transaction_id" "$firmware" "$document" || return 1
  elif [[ "$operation" == enroll-secure-boot && "$status" == completed ]]; then
    return 1
  fi

  case "$operation" in
    enroll-secure-boot)
      [[ "$kind" == root && "$producer" == null ]] || return 1
      validate_enrollment_manifest_rules "$document" active || return 1
      ;;
    windows-bootnext)
      [[ "$kind" == root && "$producer" == null && "$proof" == null \
        && "$firmware" == null ]] || return 1
      validate_bootnext_manifest_rules "$document" || return 1
      ;;
    unconfigure)
      [[ "$kind" == root && "$producer" == null \
        && "$firmware" == null && "$managed_settings" == null \
        && "$tracking_ownership" == null && "$windows" == null ]] || return 1
      validate_unconfigure_manifest_rules "$document" || return 1
      ;;
  esac
  [[ "$kind" == recovery-attempt ]] || return 0
  [[ "$producer" == null ]] || return 1
  validate_recovery_attempt_manifest_rules "$document" "$operation" "$firmware" || return 1
  [[ "$status" != completed || "$proof" != null ]]
}

recovery_operation_for_root_manifest() {
  local document="$1" operation producer policy
  jq -e '.kind == "root"' <<< "$document" >/dev/null || return 1
  operation=$(jq -r '.operation' <<< "$document") || return 1
  producer=$(jq -c '.domain_records.producer' <<< "$document") || return 1
  policy=$(jq -r '.file_rollback_policy' <<< "$document") || return 1
  if [[ "$producer" != null ]]; then
    jq -e '.target_state == "active" and .prior_state == "active"' \
      <<< "$document" >/dev/null || return 1
    printf 'producer-recovery\n'
  elif [[ "$operation" == enroll-secure-boot ]]; then
    jq -e '.target_state == "active" and .prior_state == "active"' \
      <<< "$document" >/dev/null || return 1
    printf 'firmware-recovery\n'
  elif [[ "$operation" == windows-bootnext ]]; then
    jq -e '.target_state == "active" and .prior_state == "active"' \
      <<< "$document" >/dev/null || return 1
    printf 'windows-recovery\n'
  elif [[ "$operation" == unconfigure && "$policy" == preserve ]]; then
    jq -e '.target_state == "disabled" and .prior_state == "active" and
      .domain_records.unconfigure != null' <<< "$document" >/dev/null || return 1
    printf 'unconfigure-recovery\n'
  elif [[ "$policy" == restore ]] && software_recovery_root_is_supported "$document"; then
    printf 'software-recovery\n'
  else
    return 1
  fi
}

validate_recovery_manifest_evolution() {
  local previous="$1" current="$2" operation="$3"
  jq -en --arg operation "$operation" --argjson previous "$previous" \
    --argjson current "$current" "$OMASECBOOT_JQ_DEFS"'
    def writes_forward($old; $new):
      ($new | length) >= ($old | length) and
      if ($old | length) == 0 then true
      elif $old[-1].readback_status == "pending" then
        $new[0:(($old | length) - 1)] == $old[0:-1] and
        ($new[($old | length) - 1] == $old[-1] or
          firmware_write_resolved($old[-1]; $new[($old | length) - 1]))
      else $new[0:($old | length)] == $old end;
    $current.kind == "recovery-attempt" and $current.operation == $operation and
    $current.prior_state == "recovery-required" and
    if $operation == "producer-recovery" then
      $current.target_state == "active" and
      $previous.firmware_backup == null and $previous.enrollment_plan == null and
      $previous.firmware_writes == [] and $current.firmware_backup == null and
      $current.enrollment_plan == null and $current.firmware_writes == [] and
      $previous.file_rollback_policy == "preserve" and
      $current.file_rollback_policy == "preserve"
    elif $operation == "firmware-recovery" then
      $current.target_state == "active" and
      (($current.firmware_backup == $previous.firmware_backup and
          $current.enrollment_plan == $previous.enrollment_plan) or
        ($previous.firmware_backup == null and $previous.enrollment_plan == null and
          $previous.firmware_writes == [] and $current.firmware_backup != null and
          $current.enrollment_plan != null)) and
      writes_forward($previous.firmware_writes; $current.firmware_writes) and
      ($previous.file_rollback_policy == $current.file_rollback_policy or
        ($previous.file_rollback_policy == "restore" and
          $current.file_rollback_policy == "preserve"))
    elif $operation == "windows-recovery" then
      $current.target_state == "active" and
      $previous.firmware_backup == null and $previous.enrollment_plan == null and
      $previous.firmware_writes == [] and $current.firmware_backup == null and
      $current.enrollment_plan == null and $current.firmware_writes == [] and
      $previous.file_rollback_policy == "restore" and
      $current.file_rollback_policy == "restore"
    elif $operation == "software-recovery" then
      $current.target_state ==
        (if $previous.kind == "root" then
           (if $previous.status == "completed" then $previous.target_state
            else $previous.prior_state end)
         else $previous.target_state end) and
      $previous.firmware_writes == [] and $current.firmware_backup == null and
      $current.enrollment_plan == null and $current.firmware_writes == [] and
      $current.file_rollback_policy == "preserve" and
      (if $previous.kind == "root" then $previous.file_rollback_policy == "restore"
       else $previous.file_rollback_policy == "preserve" end)
    elif $operation == "unconfigure-recovery" then
      $current.target_state == "disabled" and
      $previous.firmware_writes == [] and $current.firmware_backup == null and
      $current.enrollment_plan == null and $current.firmware_writes == [] and
      $current.file_rollback_policy == "preserve" and
      $previous.file_rollback_policy == "preserve"
    else false end
  ' >/dev/null
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
  schema=$(document_schema_version "$document") || return 1
  [[ "$schema" == "$LIFECYCLE_SCHEMA_VERSION" ]] || return 1
  validate_transaction_manifest_json "$transaction_id" "$document" || return 1
  _manifest_json="$document"
  _manifest_id="$transaction_id"
  _manifest_sha256="$manifest_hash"
}

validate_incident_seal_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" "$OMASECBOOT_JQ_DEFS"'
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
      (.root_incident | incident_reference($max_attempts)) and .root_incident.kind == "root" and
      (if .ordinal == 1 then .previous_attempt == null
       else (.previous_attempt | incident_reference($max_attempts)) and
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
  schema=$(document_schema_version "$document") || {
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
    { [[ "$manifest_kind" == root ]] && json_is '.recovery == null' "$_manifest_json"; } || {
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
  jq -e --argjson max_attempts "$MAX_RECOVERY_ATTEMPT_SEALS" "$OMASECBOOT_JQ_DEFS"'
    incident_reference($max_attempts)
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
  local resolved="${4:-false}" expected current seal root_document
  local current_id current_status root_manifest recovery_operation
  local current_manifest newer_manifest=""
  local -A seen=()
  [[ "$attempt_count" =~ ^[0-9]+$ ]] || return 1
  if (( attempt_count > MAX_RECOVERY_ATTEMPT_SEALS )); then
    _incident_read_status=attempt-limit
    return 2
  fi
  validate_incident_reference "$root_reference" || return 1
  root_document="$_incident_json"
  root_manifest="$_manifest_json"
  [[ $(jq -r '.kind' <<< "$root_document") == root ]] || return 1
  current="$latest_reference"
  if (( attempt_count == 0 )); then
    [[ "$current" == null && "$resolved" == false ]] || return 1
    _incident_json="$root_document"
    return 0
  fi
  [[ "$current" != null ]] || return 1
  recovery_operation=$(recovery_operation_for_root_manifest "$root_manifest") || return 1

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
    [[ $(jq -r '.operation' <<< "$seal") == "$recovery_operation" ]] || return 1
    current_status=$(jq -r '.incident_status' <<< "$seal") || return 1
    current_manifest="$_manifest_json"
    if [[ -n "$newer_manifest" ]]; then
      validate_recovery_manifest_evolution "$current_manifest" "$newer_manifest" \
        "$recovery_operation" || return 1
    fi
    newer_manifest="$current_manifest"
    if (( expected == attempt_count )) && [[ "$resolved" == true ]]; then
      [[ "$current_status" == completed ]] || return 1
    else
      [[ "$current_status" == failed || "$current_status" == stale ]] || return 1
    fi
    current=$(jq -c '.previous_attempt' <<< "$seal") || return 1
    expected=$((expected - 1))
  done
  [[ "$current" == null ]] || return 1
  validate_recovery_manifest_evolution "$root_manifest" "$newer_manifest" \
    "$recovery_operation" || return 1
  _incident_json="$root_document"
}

validate_lifecycle_document_references() {
  local document="$1" state transaction_id manifest operation kind root latest count
  local reference managed_settings tracking_ownership
  local saved_manifest saved_manifest_id saved_manifest_hash rc
  local attempt_number final_attempt_id final_attempt_manifest final_proof
  local recovery_operation
  state=$(jq -r '.state' <<< "$document") || return 1

  managed_settings=$(jq -c '.managed_settings' <<< "$document") || return 1
  tracking_ownership=$(jq -c '.tracking_ownership' <<< "$document") || return 1
  validate_lifecycle_ownership_pair "$managed_settings" "$tracking_ownership" || return 1

  if json_is '.last_transaction != null' "$document"; then
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
    if [[ $(jq -r '.prior_state' <<< "$_manifest_json") == active \
      && $(jq -r '.target_state' <<< "$_manifest_json") == disabled ]]; then
      [[ "$operation" == unconfigure ]] || return 1
    fi
    if [[ "$kind" == root ]]; then
      json_is '.recovery == null' "$_manifest_json" || return 1
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
      validate_incident_reference "$root" || return 1
      recovery_operation=$(recovery_operation_for_root_manifest "$_manifest_json") || return 1
      [[ $(jq -r '.operation' <<< "$saved_manifest") == "$recovery_operation" ]] \
        || return 1
      validate_recovery_manifest_evolution "$_manifest_json" "$saved_manifest" \
        "$recovery_operation" || return 1
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

  if json_is '.last_recovery != null' "$document"; then
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

load_lifecycle_ownership_records() {
  local managed_reference tracking_reference managed_path tracking_path
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == active || "$_lifecycle_state" == transition \
    || "$_lifecycle_state" == recovery-required ]] || return 1
  managed_reference=$(jq -c '.managed_settings' <<< "$_lifecycle_json") || return 1
  tracking_reference=$(jq -c '.tracking_ownership' <<< "$_lifecycle_json") || return 1
  [[ "$managed_reference" != null && "$tracking_reference" != null ]] || return 1
  validate_lifecycle_ownership_pair "$managed_reference" "$tracking_reference" || return 1
  managed_path=$(jq -r '.path' <<< "$managed_reference") || return 1
  tracking_path=$(jq -r '.path' <<< "$tracking_reference") || return 1
  _managed_settings_record_json=$(read_control_document "$managed_path") || return 1
  _tracking_ownership_record_json=$(read_control_document "$tracking_path") || return 1
}

validate_completed_transaction_reference() {
  local document="$1" transaction_id state
  json_is '.last_transaction != null' "$document" || return 0
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
  if [[ "$state" == disabled \
    && $(jq -r '.prior_state' <<< "$_manifest_json") == active ]]; then
    [[ $(jq -r '.operation' <<< "$_manifest_json") == unconfigure ]] || return 1
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
  schema=$(document_schema_version "$document") || {
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
  schema=$(document_schema_version "$document") || return 1
  if [[ "$schema" == "$LIFECYCLE_SCHEMA_VERSION" ]]; then
    if validate_lifecycle_json "$document" \
      && [[ $(jq -r '.state' <<< "$document") == disabled ]] \
      && validate_lifecycle_document_references "$document" \
      && [[ $(jq -r '.last_transaction.operation' <<< "$document") == unconfigure \
        || $(jq -r '.last_transaction.operation' <<< "$document") == \
          unconfigure-recovery ]] \
      && read_transaction_manifest "$(jq -r '.last_transaction.id' <<< "$document")" \
      && jq -e '
        .status == "completed" and .target_state == "disabled" and
        .file_rollback_policy == "preserve" and
        ((.kind == "root" and .operation == "unconfigure" and
          .domain_records.unconfigure != null and .domain_records.final_proof != null) or
         (.kind == "recovery-attempt" and .operation == "unconfigure-recovery" and
          .domain_records.final_proof != null))
      ' <<< "$_manifest_json" >/dev/null; then
      result=0
    fi
  fi
  _manifest_json="$saved_manifest"
  _manifest_id="$saved_id"
  _manifest_sha256="$saved_hash"
  return "$result"
}

reset_recovery_context() {
  _recovery_root_reference=""
  _recovery_root_manifest_json=""
  _recovery_previous_reference="null"
  _recovery_previous_manifest_json=""
  _recovery_attempt_count=0
  _recovery_target_state=""
  _recovery_terminal_state=""
  _recovery_producer_reference="null"
}

load_recovery_context() {
  local root_id previous_id
  boot_locks_are_held || return 1
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
  if (( _recovery_attempt_count == 0 )); then
    _recovery_previous_manifest_json="$_recovery_root_manifest_json"
  else
    previous_id=$(jq -r '.id' <<< "$_recovery_previous_reference") || return 1
    read_transaction_manifest "$previous_id" || return 1
    _recovery_previous_manifest_json="$_manifest_json"
  fi
}

load_producer_recovery_context() {
  local root_id producer_path producer_document recovery_operation
  load_recovery_context || return $?
  root_id=$(jq -r '.id' <<< "$_recovery_root_reference") || return 1
  recovery_operation=$(recovery_operation_for_root_manifest \
    "$_recovery_root_manifest_json") || return 1
  [[ "$_recovery_target_state" == active && "$_recovery_producer_reference" != null ]] \
    && [[ "$recovery_operation" == producer-recovery ]] || return 1
  jq -e '
    .kind == "root" and .prior_state == "active" and
    .file_rollback_policy == "preserve" and
    .firmware_backup == null and .enrollment_plan == null and .firmware_writes == [] and
    .domain_records.bootnext == null and .domain_records.firmware == null and
    .domain_records.unconfigure == null and
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

# --- Transaction manifests ---------------------------------------------------

create_transaction_dir() {
  local transaction_dir
  transaction_dir="$(transactions_dir_path)/$1"
  install -d -m 700 "$transaction_dir" || return 1
  validate_private_control_directory "$transaction_dir" || return 1
  durable_sync "$(transactions_dir_path)" || return 1
  printf '%s\n' "$transaction_dir"
}

# Prints the backups array that records the lifecycle file as it was before
# this transaction: an absent-lifecycle marker, or a private copy plus hash.
prior_lifecycle_backups() {
  local transaction_dir="$1" prior_backup prior_hash
  if [[ "$_lifecycle_state" == unmanaged ]]; then
    printf '[{"path":null,"sha256":null,"kind":"absent-lifecycle","target":null}]\n'
    return 0
  fi
  prior_backup="${transaction_dir}/prior-lifecycle.json"
  cp -p "$(lifecycle_file_path)" "$prior_backup" || return 1
  chmod 600 "$prior_backup" || return 1
  validate_private_control_file "$prior_backup" || return 1
  durable_sync "$prior_backup" || return 1
  prior_hash=$(sha256_file "$prior_backup") || return 1
  jq -cn --arg path "$prior_backup" --arg hash "$prior_hash" \
    '[{path: $path, sha256: $hash, kind: "prior-lifecycle", target: null}]'
}

# Prints the identity fields of process $1 for a manifest owner. Callers pass
# their own PID from a local, because BASHPID inside a command substitution
# names the substitution subshell.
manifest_owner_json() {
  local pid="$1" owner_start
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$(process_effective_uid "$pid")" == "$(control_owner_uid)" ]] || return 1
  owner_start=$(process_start_time "$pid") || return 1
  jq -cn --argjson pid "$pid" --arg start "$owner_start" \
    --argjson uid "$(control_owner_uid)" '{pid: $pid, start_time: $start, uid: $uid}'
}

# Builds a new transaction manifest from the schema defaults deep-merged with
# the caller's fields.
new_transaction_manifest() {
  jq -cn --argjson schema "$LIFECYCLE_SCHEMA_VERSION" --arg version "$OMASECBOOT_VERSION" \
    --argjson overrides "$1" '{
      schema_version: $schema,
      writer_version: $version,
      id: null,
      kind: "root",
      operation: null,
      target_state: null,
      status: "transition",
      created_at: null,
      completed_at: null,
      boot_id: null,
      token_sha256: null,
      owner: null,
      prior_state: null,
      recovery: null,
      current_phase: null,
      completed_phases: [],
      backups: [],
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
    } * $overrides'
}

# Validates and writes a new manifest, then loads it as the current manifest.
publish_new_transaction_manifest() {
  local transaction_id="$1" document="$2" failpoint="$3" manifest
  manifest=$(lifecycle_manifest_path "$transaction_id") || return 1
  validate_transaction_manifest_json "$transaction_id" "$document" || return 1
  printf '%s\n' "$document" | atomic_write_control_file "$manifest" 600 || return 1
  _manifest_json="$document"
  _manifest_id="$transaction_id"
  _manifest_sha256=$(sha256_file "$manifest") || return 1
  lifecycle_failpoint "$failpoint"
}

activate_transaction_context() {
  local transaction_id="$1" token="$2" operation="$3" target_state="$4"
  _transaction_active=true
  _transaction_id="$transaction_id"
  _transaction_operation="$operation"
  _transaction_target_state="$target_state"
  OMASECBOOT_TRANSACTION_ID="$transaction_id"
  OMASECBOOT_TRANSACTION_TOKEN="$token"
  export OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

begin_lifecycle_transaction() {
  local operation="$1" target_state="$2"
  local transaction_id token boot_id owner timestamp transaction_dir backups self document
  [[ "$operation" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  [[ "$target_state" == active || "$target_state" == disabled ]] || return 1
  boot_locks_are_held || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == unmanaged || "$_lifecycle_state" == active \
    || "$_lifecycle_state" == disabled ]] || return 1
  if [[ "$_lifecycle_state" == active && "$target_state" == disabled ]]; then
    [[ "$operation" == unconfigure ]] || return 1
  fi
  transaction_id=$(new_transaction_id) || return 1
  token=$(new_transaction_token) || return 1
  boot_id=$(boot_id_value) || return 1
  self=$BASHPID
  owner=$(manifest_owner_json "$self") || return 1
  timestamp=$(utc_timestamp) || return 1
  transaction_dir=$(create_transaction_dir "$transaction_id") || return 1
  backups=$(prior_lifecycle_backups "$transaction_dir") || return 1
  document=$(new_transaction_manifest "$(jq -cn \
    --arg id "$transaction_id" --arg operation "$operation" --arg target "$target_state" \
    --arg timestamp "$timestamp" --arg boot_id "$boot_id" \
    --arg token_hash "$(sha256_text "$token")" --argjson owner "$owner" \
    --arg prior_state "$_lifecycle_state" --argjson backups "$backups" '{
      id: $id, operation: $operation, target_state: $target, created_at: $timestamp,
      boot_id: $boot_id, token_sha256: $token_hash, owner: $owner,
      prior_state: $prior_state, backups: $backups
    }')") || return 1
  publish_new_transaction_manifest "$transaction_id" "$document" after-manifest-write \
    || return 1
  lifecycle_package_boundary_is_clear || return 1
  activate_transaction_context "$transaction_id" "$token" "$operation" "$target_state"
  write_transition_lifecycle "$transaction_id" "$operation" \
    "$(lifecycle_manifest_path "$transaction_id")" "$timestamp" || return 1
  lifecycle_failpoint "after-transition-write"
}

begin_producer_lifecycle_transaction() {
  local transaction_id="$1" producer_reference="$2" backups="$3"
  local transaction_dir manifest producer_document operation owner_pid token timestamp
  local document
  boot_locks_are_held || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == active ]] || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  manifest="${transaction_dir}/manifest.json"
  validate_private_control_directory "$transaction_dir" || return 1
  [[ ! -e "$manifest" && ! -L "$manifest" ]] || return 1
  validate_producer_record_reference "$transaction_id" "$producer_reference" || return 1
  producer_document=$(read_control_document "$(jq -r '.path' <<< "$producer_reference")") \
    || return 1
  operation=$(jq -r '.operation' <<< "$producer_document") || return 1
  owner_pid=$(jq -r '.owner.pid' <<< "$producer_document") || return 1
  [[ $(jq -r '.owner.boot_id' <<< "$producer_document") == "$(boot_id_value)" \
    && $(jq -r '.owner.uid' <<< "$producer_document") == "$(control_owner_uid)" \
    && "$(process_effective_uid "$owner_pid")" == "$(control_owner_uid)" \
    && "$(process_start_time "$owner_pid")" == \
      "$(jq -r '.owner.start_time' <<< "$producer_document")" ]] || return 1
  process_matches_identity "$owner_pid" \
    "$(jq -r '.owner.identity_kind' <<< "$producer_document")" \
    "$(jq -r '.owner.identity' <<< "$producer_document")" || return 1
  process_has_ancestor "$owner_pid" "$BASHPID" || return 1
  token=$(new_transaction_token) || return 1
  timestamp=$(utc_timestamp) || return 1
  document=$(new_transaction_manifest "$(jq -cn \
    --arg id "$transaction_id" --arg operation "$operation" --arg timestamp "$timestamp" \
    --arg token_hash "$(sha256_text "$token")" --argjson producer_document "$producer_document" \
    --argjson backups "$backups" --argjson producer "$producer_reference" '{
      id: $id, operation: $operation, target_state: "active", created_at: $timestamp,
      boot_id: $producer_document.owner.boot_id, token_sha256: $token_hash,
      owner: ($producer_document.owner | {pid, start_time, uid}),
      prior_state: "active", backups: $backups,
      file_rollback_policy: "preserve", domain_records: {producer: $producer}
    }')") || return 1
  publish_new_transaction_manifest "$transaction_id" "$document" \
    after-producer-manifest-write || return 1
  activate_transaction_context "$transaction_id" "$token" "$operation" active
  write_transition_lifecycle "$transaction_id" "$operation" "$manifest" "$timestamp" \
    || return 1
  lifecycle_failpoint "after-producer-transition-write"
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
    --arg operation "$_transaction_operation" \
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
        operation: $operation,
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
  local operation="$1" transaction_id transaction_dir token boot_id owner timestamp self
  local attempt_number document recovery_operation terminal_state backups
  local inherited
  boot_locks_are_held || return 1
  case "$operation" in
    producer-recovery) load_producer_recovery_context || return $? ;;
    firmware-recovery|windows-recovery) load_recovery_context || return $? ;;
    software-recovery) load_software_recovery_context || return $? ;;
    unconfigure-recovery) load_unconfigure_recovery_context || return $? ;;
    *) return 1 ;;
  esac
  recovery_operation=$(recovery_operation_for_root_manifest \
    "$_recovery_root_manifest_json") || return 1
  [[ "$operation" == "$recovery_operation" ]] || return 1
  terminal_state=$(recovery_terminal_state_for_root_manifest \
    "$_recovery_root_manifest_json" "$recovery_operation") || return 1
  attempt_number=$((_recovery_attempt_count + 1))
  (( attempt_number <= MAX_RECOVERY_ATTEMPT_SEALS )) || return 2
  transaction_id=$(new_transaction_id) || return 1
  token=$(new_transaction_token) || return 1
  boot_id=$(boot_id_value) || return 1
  self=$BASHPID
  owner=$(manifest_owner_json "$self") || return 1
  timestamp=$(utc_timestamp) || return 1
  # Firmware recovery inherits the predecessor's binding and write ledger;
  # every other recovery starts clean under its fixed rollback policy.
  case "$operation" in
    firmware-recovery)
      inherited=$(jq -c '{file_rollback_policy, firmware_backup, enrollment_plan,
        firmware_writes}' <<< "$_recovery_previous_manifest_json") || return 1
      ;;
    windows-recovery) inherited='{"file_rollback_policy":"restore"}' ;;
    *) inherited='{"file_rollback_policy":"preserve"}' ;;
  esac
  transaction_dir=$(create_transaction_dir "$transaction_id") || return 1
  backups=$(prior_lifecycle_backups "$transaction_dir") || return 1
  document=$(new_transaction_manifest "$(jq -cn \
    --arg id "$transaction_id" --arg operation "$operation" --arg target "$terminal_state" \
    --arg timestamp "$timestamp" --arg boot_id "$boot_id" \
    --arg token_hash "$(sha256_text "$token")" --argjson owner "$owner" \
    --argjson attempt "$attempt_number" --argjson root "$_recovery_root_reference" \
    --argjson previous "$_recovery_previous_reference" --argjson backups "$backups" \
    --argjson inherited "$inherited" '{
      id: $id, kind: "recovery-attempt", operation: $operation, target_state: $target,
      created_at: $timestamp, boot_id: $boot_id, token_sha256: $token_hash, owner: $owner,
      prior_state: "recovery-required",
      recovery: {attempt_number: $attempt, previous_attempt: $previous, root_incident: $root},
      backups: $backups
    } + $inherited')") || return 1
  publish_new_transaction_manifest "$transaction_id" "$document" \
    after-attempt-manifest-write || return 1
  lifecycle_package_boundary_is_clear || return 1
  activate_transaction_context "$transaction_id" "$token" "$operation" "$terminal_state"
  write_recovery_attempt_transition_lifecycle "$transaction_id" \
    "$(lifecycle_manifest_path "$transaction_id")" "$timestamp" || return $?
  lifecycle_failpoint "after-attempt-transition-write"
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

  if json_is '.firmware_backup != null' "$candidate"; then
    firmware_id=$(jq -r '.firmware_backup.id' <<< "$candidate") || return 1
    firmware_path=$(jq -r '.firmware_backup.path' <<< "$candidate") || return 1
    [[ "$firmware_path" == \
      "$(state_dir_path)/firmware-backup/${firmware_id}" ]] || return 1
  fi
  if json_is '.enrollment_plan != null' "$candidate"; then
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
  transaction_locks_are_held || return 1
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  incident=$(lifecycle_incident_path "$_transaction_id") || return 1
  [[ ! -e "$incident" && ! -L "$incident" ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  # read_lifecycle already validated and loaded the transition's manifest.
  [[ "$_manifest_id" == "$_transaction_id" ]] || read_transaction_manifest "$_transaction_id" \
    || return 1
  current="$_manifest_json"
  candidate=$(jq -c . <<< "$document") || return 1
  validate_transaction_manifest_json "$_transaction_id" "$candidate" || return 1
  current_status=$(jq -r '.status' <<< "$current") || return 1
  next_status=$(jq -r '.status' <<< "$candidate") || return 1
  [[ "$current_status" == transition && "$next_status" == transition ]] || return 1
  jq -en --argjson current "$current" --argjson candidate "$candidate" "$OMASECBOOT_JQ_DEFS"'
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
           firmware_write_resolved($old[-1]; $new[-1]))
        else false end;
      def envelope:
        del(.backups, .completed_phases, .current_phase, .domain_records,
          .enrollment_plan, .file_rollback_policy, .firmware_backup, .firmware_writes,
          .rollback);
      ($current | envelope) == ($candidate | envelope) and
      (($candidate.completed_phases == $current.completed_phases and
        ($candidate.current_phase == $current.current_phase or
          ($current.current_phase == null and $candidate.current_phase != null))) or
       ($current.current_phase != null and $candidate.current_phase == null and
        $candidate.completed_phases ==
          ($current.completed_phases + [$current.current_phase]))) and
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
  transaction_locks_are_held || return 1
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
  # read_lifecycle already validated and loaded the transition's manifest.
  [[ "$_manifest_id" == "$_transaction_id" ]] || read_transaction_manifest "$_transaction_id" \
    || return 1
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
  entries_json=$(jq -c '.backups | reverse[] |
    select(.kind == "file" or .kind == "absent-file")' <<< "$_manifest_json") || return 1
  [[ -z "$entries_json" ]] || mapfile -t entries <<< "$entries_json"
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

# Runs one recovery attempt for an operation under the held locks: begins the
# attempt, runs the callback, commits or rolls back, and always restores traps.
# A callback may set this to name the reason its transaction is rolled back.
_transaction_failure_reason=""

# After a failed begin: roll back a transition this process published, or drop
# a context that never reached the lifecycle file.
abandon_failed_begin() {
  local rc="$1" label="$2"
  [[ "$_transaction_active" == true ]] || return 0
  if read_lifecycle && [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]]; then
    rollback_and_mark_recovery "$rc" "${label} initialization failed" failed || true
  else
    detach_transaction_context
  fi
}

# After the callback: commit on success, roll back on failure or on a failed
# commit; prints nothing and returns the final status.
finish_armed_transaction() {
  local commit="$1" callback_rc="$2" label="$3" commit_rc=0 reason
  if (( callback_rc == 0 )); then
    "$commit" || commit_rc=$?
    if (( commit_rc != 0 )); then
      rollback_and_mark_recovery "$commit_rc" "stable ${label} publication failed" failed \
        || true
      callback_rc=$commit_rc
    fi
  else
    reason=${_transaction_failure_reason:-${label} failed}
    rollback_and_mark_recovery "$callback_rc" "$reason" failed || true
  fi
  return "$callback_rc"
}

# One recovery attempt under both locks: begin, the callback with its
# arguments, then commit or rollback.
run_recovery_attempt_locked() {
  local operation="$1" callback="$2" label="$3" begin_rc=0 callback_rc=0
  shift 3
  boot_locks_are_held || return 1
  _transaction_failure_reason=""
  arm_transaction_traps
  begin_lifecycle_recovery_attempt "$operation" || begin_rc=$?
  if (( begin_rc != 0 )); then
    abandon_failed_begin "$begin_rc" "${label} attempt"
    restore_transaction_traps
    return "$begin_rc"
  fi
  "$callback" "$@" || callback_rc=$?
  finish_armed_transaction commit_lifecycle_recovery_attempt "$callback_rc" "$label" \
    || callback_rc=$?
  restore_transaction_traps
  return "$callback_rc"
}

run_registered_recovery_locked() {
  local operation
  boot_locks_are_held || return 1
  reconcile_stale_lifecycle || return 1
  read_lifecycle || return 1
  case "$_lifecycle_state" in
    unmanaged|disabled|active) return 0 ;;
    recovery-required) ;;
    transition) return 1 ;;
    *) return 1 ;;
  esac
  prepare_registered_recovery_runtime_locked || return 1
  load_recovery_context || return $?
  operation=$(recovery_operation_for_root_manifest "$_recovery_root_manifest_json") \
    || return 1
  case "$operation" in
    producer-recovery) run_registered_producer_recovery_locked ;;
    firmware-recovery) run_firmware_recovery_locked ;;
    windows-recovery) run_windows_recovery_locked ;;
    software-recovery) run_software_recovery_locked ;;
    unconfigure-recovery) run_unconfigure_recovery_locked ;;
    *) return 1 ;;
  esac
}

# Producer recovery never runs while the full-restore marker exists; the other
# recovery operations do not touch producer outputs and proceed.
prepare_registered_recovery_runtime_locked() {
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == recovery-required ]] || return 0
  load_recovery_context || return $?
  [[ $(recovery_operation_for_root_manifest "$_recovery_root_manifest_json") == \
    producer-recovery ]] || return 0
  producer_runtime_is_clear
}

recover_lifecycle_if_required() {
  local rc=0
  _lifecycle_recovery_performed=false
  require_control_root || return 1
  with_boot_repair_lock || return 1
  lifecycle_package_boundary_is_clear || {
    release_boot_repair_lock
    return 1
  }
  read_lifecycle || {
    release_boot_repair_lock
    return 1
  }
  if [[ "$_lifecycle_state" == transition || "$_lifecycle_state" == recovery-required ]]; then
    _lifecycle_recovery_performed=true
  fi
  run_registered_recovery_locked || rc=$?
  release_boot_repair_lock
  return "$rc"
}

rollback_and_mark_recovery() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  local manifest_status manifest_kind rollback_rc=0
  boot_locks_are_held || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  manifest_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  manifest_kind=$(jq -r '.kind' <<< "$_manifest_json") || return 1
  case "$manifest_status" in
    transition)
      rollback_transaction_files || rollback_rc=$?
      if [[ $rollback_rc -ne 0 ]]; then
        reason="${reason}; file rollback failed"
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
  jq -e --arg name "$name" '.domain_records[$name] == null' <<< "$_manifest_json" \
    >/dev/null || return 1
  document=$(jq -c --arg name "$name" --argjson reference "$reference" \
    '.domain_records[$name] = $reference' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

commit_lifecycle_transaction() {
  local manifest_document state_document timestamp manifest manifest_hash
  local manifest_operation manifest_target lifecycle_operation
  local managed_settings tracking_ownership
  [[ "$_transaction_active" == true ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  json_is '.current_phase == null and .kind == "root" and .recovery == null' \
    "$_manifest_json" || return 1
  manifest_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  manifest_target=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
  lifecycle_operation=$(jq -r '.transaction.operation' <<< "$_lifecycle_json") || return 1
  [[ "$manifest_operation" == "$_transaction_operation" \
    && "$manifest_operation" == "$lifecycle_operation" \
    && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == root \
    && "$manifest_target" == "$_transaction_target_state" ]] || return 1
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
  managed_settings=$(jq -c '.domain_records.managed_settings' <<< "$_manifest_json") || return 1
  tracking_ownership=$(jq -c '.domain_records.tracking_ownership' <<< "$_manifest_json") \
    || return 1
  lifecycle_failpoint "after-completed-manifest-write" || return 1

  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg state "$manifest_target" \
    --arg id "$_transaction_id" \
    --arg operation "$manifest_operation" \
    --arg manifest "$manifest" \
    --arg manifest_hash "$manifest_hash" \
    --arg timestamp "$timestamp" \
    --argjson managed_settings "$managed_settings" \
    --argjson tracking_ownership "$tracking_ownership" '
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
      if $operation == "unconfigure" then
        .managed_settings = null |
        .tracking_ownership = null
      elif $managed_settings != null and $tracking_ownership != null then
        .managed_settings = $managed_settings |
        .tracking_ownership = $tracking_ownership
      else . end |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$state_document" || return 1
  validate_lifecycle_document_references "$state_document" || return 1
  lifecycle_failpoint "before-stable-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1

  end_transaction_context
}

# --- Incident seals ----------------------------------------------------------

# Builds an incident seal from the schema defaults deep-merged with the
# caller's fields.
new_incident_seal() {
  jq -cn --argjson schema "$LIFECYCLE_SCHEMA_VERSION" --arg version "$OMASECBOOT_VERSION" \
    --argjson overrides "$1" '{
      schema_version: $schema,
      writer_version: $version,
      kind: null,
      id: null,
      operation: null,
      ordinal: 0,
      manifest: null,
      manifest_sha256: null,
      manifest_status: null,
      incident_status: null,
      failure: null,
      rollback_disposition: "manifest-recorded",
      root_incident: null,
      previous_attempt: null,
      sealed_at: null
    } * $overrides'
}

sync_incident_seal() {
  local incident_path
  incident_path=$(lifecycle_incident_path "$1") || return 1
  durable_sync "$incident_path" || return 1
  durable_sync "$(dirname "$incident_path")"
}

# Publishes a seal create-once; an existing identical seal is accepted.
publish_incident_seal() {
  local transaction_id="$1" document="$2" failpoint="$3" incident_path
  incident_path=$(lifecycle_incident_path "$transaction_id") || return 1
  validate_incident_seal_json "$transaction_id" "$document" || return 1
  if ! printf '%s\n' "$document" | atomic_create_control_file "$incident_path" 600; then
    read_incident_seal "$transaction_id" || return 1
    [[ "$(jq -Sc . <<< "$_incident_json")" == "$(jq -Sc . <<< "$document")" ]] || return 1
    sync_incident_seal "$transaction_id" || return 1
  fi
  lifecycle_failpoint "$failpoint" || return 1
  read_incident_seal "$transaction_id"
}

# Records a terminal failure on the current transition manifest.
fail_transaction_manifest() {
  local status="$1" exit_code="$2" reason="$3" timestamp="$4" current_phase document
  current_phase=$(jq -r '.current_phase // ""' <<< "$_manifest_json") || return 1
  document=$(jq -c --arg status "$status" --arg timestamp "$timestamp" \
    --arg reason "$reason" --arg phase "$current_phase" --argjson exit_code "$exit_code" '
    .status = $status | .completed_at = $timestamp |
    .failure = {
      exit_code: $exit_code, reason: $reason,
      phase: (if $phase == "" then null else $phase end), recorded_at: $timestamp
    }' <<< "$_manifest_json") || return 1
  write_transaction_manifest_status_json transition "$status" "$document" || return 1
  read_transaction_manifest "$_transaction_id"
}

finalize_transaction_incident() {
  local exit_code="$1" reason="$2" status="$3"
  local current_status timestamp manifest incident_status failure rollback_disposition
  transaction_locks_are_held || return 1
  [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -le 255 \
    && ${#reason} -gt 0 && ${#reason} -le 1024 \
    && ( "$status" == failed || "$status" == stale ) ]] || return 1
  if [[ -e "$(lifecycle_incident_path "$_transaction_id")" ]]; then
    read_incident_seal "$_transaction_id" || return 1
    [[ $(jq -r '.kind' <<< "$_incident_json") == root ]] || return 1
    sync_incident_seal "$_transaction_id" || return 1
    lifecycle_failpoint "after-incident-write"
    return
  fi
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.kind' <<< "$_manifest_json") == root ]] || return 1
  current_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  timestamp=$(utc_timestamp) || return 1
  rollback_disposition="manifest-recorded"
  case "$current_status" in
    transition)
      fail_transaction_manifest "$status" "$exit_code" "$reason" "$timestamp" || return 1
      incident_status="$status"
      failure=$(jq -c '.failure' <<< "$_manifest_json") || return 1
      ;;
    failed|stale)
      incident_status="$current_status"
      failure=$(jq -c '.failure' <<< "$_manifest_json") || return 1
      ;;
    completed)
      incident_status=publication-uncertain
      failure=$(jq -cn --arg timestamp "$timestamp" --arg reason "$reason" \
        --argjson exit_code "$exit_code" \
        '{exit_code: $exit_code, reason: $reason, phase: null, recorded_at: $timestamp}') \
        || return 1
      rollback_disposition=not-attempted-stable-publication-ambiguous
      ;;
    *) return 1 ;;
  esac
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  publish_incident_seal "$_transaction_id" "$(new_incident_seal "$(jq -cn \
    --arg id "$_transaction_id" --arg manifest "$manifest" \
    --arg manifest_hash "$(sha256_file "$manifest")" \
    --argjson manifest_json "$_manifest_json" --arg incident_status "$incident_status" \
    --argjson failure "$failure" --arg rollback_disposition "$rollback_disposition" \
    --arg timestamp "$timestamp" '{
      kind: "root", id: $id, operation: $manifest_json.operation, manifest: $manifest,
      manifest_sha256: $manifest_hash, manifest_status: $manifest_json.status,
      incident_status: $incident_status, failure: $failure,
      rollback_disposition: $rollback_disposition, sealed_at: $timestamp
    }')")" after-incident-write
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
    end_transaction_context
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

  end_transaction_context
}

finalize_recovery_attempt_incident() {
  local exit_code="$1" reason="$2" status="$3" current_status timestamp manifest document
  transaction_locks_are_held || return 1
  [[ "$exit_code" =~ ^[0-9]+$ && "$exit_code" -le 255 ]] || return 1
  case "$status" in
    completed) [[ "$exit_code" -eq 0 && -z "$reason" ]] || return 1 ;;
    failed|stale) [[ ${#reason} -gt 0 && ${#reason} -le 1024 ]] || return 1 ;;
    *) return 1 ;;
  esac
  if [[ -e "$(lifecycle_incident_path "$_transaction_id")" ]]; then
    read_incident_seal "$_transaction_id" || return 1
    [[ $(jq -r '.kind' <<< "$_incident_json") == attempt \
      && $(jq -r '.incident_status' <<< "$_incident_json") == "$status" ]] || return 1
    sync_incident_seal "$_transaction_id"
    return
  fi
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.kind' <<< "$_manifest_json") == recovery-attempt ]] || return 1
  current_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  timestamp=$(utc_timestamp) || return 1
  if [[ "$current_status" == transition ]]; then
    if [[ "$status" == completed ]]; then
      jq -e '.current_phase == null and .domain_records.final_proof != null and
        (.operation != "firmware-recovery" or .domain_records.firmware != null)' \
        <<< "$_manifest_json" >/dev/null || return 1
      document=$(jq -c --arg timestamp "$timestamp" \
        '.status = "completed" | .completed_at = $timestamp | .failure = null' \
        <<< "$_manifest_json") || return 1
      write_transaction_manifest_status_json transition completed "$document" || return 1
      read_transaction_manifest "$_transaction_id" || return 1
      lifecycle_failpoint "after-attempt-completed-manifest-write" || return 1
    else
      fail_transaction_manifest "$status" "$exit_code" "$reason" "$timestamp" || return 1
    fi
  else
    [[ "$current_status" == "$status" ]] || return 1
  fi
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  publish_incident_seal "$_transaction_id" "$(new_incident_seal "$(jq -cn \
    --arg id "$_transaction_id" --arg manifest "$manifest" \
    --arg manifest_hash "$(sha256_file "$manifest")" \
    --argjson manifest_json "$_manifest_json" --arg status "$status" \
    --arg timestamp "$timestamp" '{
      kind: "attempt", id: $id, operation: $manifest_json.operation,
      ordinal: $manifest_json.recovery.attempt_number, manifest: $manifest,
      manifest_sha256: $manifest_hash, manifest_status: $status, incident_status: $status,
      failure: $manifest_json.failure, root_incident: $manifest_json.recovery.root_incident,
      previous_attempt: $manifest_json.recovery.previous_attempt, sealed_at: $timestamp
    }')")" after-attempt-incident-write
}

publish_failed_recovery_attempt() {
  local seal reference root root_manifest timestamp state_document ordinal
  transaction_locks_are_held || return 1
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
    durable_sync "$(lifecycle_file_path)" || return 1
    durable_sync "$(dirname "$(lifecycle_file_path)")" || return 1
    end_transaction_context
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
  end_transaction_context
}

publish_resolved_recovery_attempt() {
  local seal reference root proof manifest manifest_hash completed_at timestamp state_document
  local ordinal managed_settings tracking_ownership operation terminal_state root_manifest
  local root_managed root_tracking
  transaction_locks_are_held || return 1
  read_incident_seal "$_transaction_id" || return 1
  seal="$_incident_json"
  [[ $(jq -r '.kind' <<< "$seal") == attempt \
    && $(jq -r '.incident_status' <<< "$seal") == completed ]] || return 1
  reference=$(incident_reference_from_json "$seal" \
    "$(lifecycle_incident_path "$_transaction_id")") || return 1
  root=$(jq -c '.root_incident' <<< "$seal") || return 1
  ordinal=$(jq -r '.ordinal' <<< "$seal") || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  terminal_state=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
  proof=$(jq -c '.domain_records.final_proof' <<< "$_manifest_json") || return 1
  [[ "$proof" != null ]] || return 1
  managed_settings=$(jq -c '.domain_records.managed_settings' <<< "$_manifest_json") || return 1
  tracking_ownership=$(jq -c '.domain_records.tracking_ownership' <<< "$_manifest_json") \
    || return 1
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  manifest_hash=$(sha256_file "$manifest") || return 1
  completed_at=$(jq -r '.completed_at' <<< "$_manifest_json") || return 1
  root_manifest=$(recovery_root_manifest_from_reference "$root") || return 1
  [[ $(recovery_operation_for_root_manifest "$root_manifest") == "$operation" \
    && $(recovery_terminal_state_for_root_manifest "$root_manifest" "$operation") == \
      "$terminal_state" ]] || return 1

  read_lifecycle || return 1
  if [[ "$terminal_state" == unmanaged ]]; then
    if [[ "$_lifecycle_state" == unmanaged ]]; then
      durable_sync "$(state_dir_path)" || return 1
      end_transaction_context
      return 0
    fi
    [[ "$_lifecycle_state" == transition \
      && "$_lifecycle_transaction_id" == "$_transaction_id" \
      && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == recovery-attempt ]] \
      || return 1
    validate_control_file "$(lifecycle_file_path)" || return 1
    rm -f "$(lifecycle_file_path)" || return 1
    durable_sync "$(state_dir_path)" || return 1
    end_transaction_context
    return 0
  fi
  [[ "$terminal_state" == active || "$terminal_state" == disabled ]] || return 1
  if [[ "$_lifecycle_state" == "$terminal_state" \
    && $(jq -r '.last_recovery.final_attempt.id // ""' <<< "$_lifecycle_json") == \
       "$_transaction_id" ]]; then
    durable_sync "$(lifecycle_file_path)" || return 1
    durable_sync "$(dirname "$(lifecycle_file_path)")" || return 1
    end_transaction_context
    return 0
  fi
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" \
    && $(jq -r '.transaction.kind' <<< "$_lifecycle_json") == recovery-attempt ]] \
    || return 1
  timestamp=$(utc_timestamp) || return 1
  if [[ "$operation" == software-recovery \
    && $(jq -r '.status' <<< "$root_manifest") == completed ]]; then
    root_managed=$(jq -c '.domain_records.managed_settings' <<< "$root_manifest") || return 1
    root_tracking=$(jq -c '.domain_records.tracking_ownership' <<< "$root_manifest") || return 1
    if [[ "$root_managed" != null && "$root_tracking" != null ]]; then
      managed_settings="$root_managed"
      tracking_ownership="$root_tracking"
    fi
  fi
  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg timestamp "$timestamp" \
    --arg id "$_transaction_id" \
    --arg operation "$operation" \
    --arg terminal_state "$terminal_state" \
    --arg manifest "$manifest" \
    --arg manifest_hash "$manifest_hash" \
    --arg completed_at "$completed_at" \
    --argjson root "$root" \
    --argjson reference "$reference" \
    --argjson ordinal "$ordinal" \
    --argjson proof "$proof" \
    --argjson managed_settings "$managed_settings" \
    --argjson tracking_ownership "$tracking_ownership" '
      .writer_version = $version |
      .generation += 1 |
      .state = $terminal_state |
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
      if $operation == "unconfigure-recovery" then
        .managed_settings = null |
        .tracking_ownership = null
      elif $managed_settings != null and $tracking_ownership != null then
        .managed_settings = $managed_settings |
        .tracking_ownership = $tracking_ownership
      else . end |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  validate_lifecycle_json "$state_document" || return 1
  validate_lifecycle_document_references "$state_document" || return 1
  lifecycle_failpoint "before-recovery-resolved-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1
  end_transaction_context
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
  json_is '.kind == "recovery-attempt" and .current_phase == null' "$_manifest_json" \
    || return 1
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
  local rc=0
  reconcile_stale_transition || rc=$?
  (( rc == 0 )) || detach_transaction_context
  return "$rc"
}

reconcile_stale_transition() {
  local transaction_id manifest_status manifest_kind incident_status
  local reason="transaction owner is no longer valid"
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition ]] || return 0
  transaction_id="$_lifecycle_transaction_id"
  read_transaction_manifest "$transaction_id" || return 1
  manifest_owner_is_alive && return 0
  producer_runtime_is_clear || {
    fail "Stale transaction ${transaction_id} blocked while full snapshot restore is running"
    return 1
  }

  set_transaction_context "$transaction_id" || return 1
  manifest_status=$(jq -r '.status' <<< "$_manifest_json") || return 1
  manifest_kind=$(jq -r '.kind' <<< "$_manifest_json") || return 1
  if [[ "$manifest_kind" == recovery-attempt ]]; then
    case "$manifest_status" in
      transition)
        rollback_transaction_files || true
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
  [[ "$manifest_status" =~ ^(transition|completed|failed|stale)$ ]] || return 1
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
  if [[ "$declaration" == "trap -- "*" EXIT" ]]; then
    # `trap -p` prints the handler shell-quoted; let the shell unquote it.
    eval "set -- ${declaration#trap -- }"
    command=$1
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
  local callback_rc=0 begin_rc=0

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
  producer_runtime_is_clear || {
    fail "Operation ${operation} blocked while full snapshot restore is running"
    release_boot_repair_lock
    return 1
  }
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

  _transaction_failure_reason=""
  arm_transaction_traps
  begin_lifecycle_transaction "$operation" "$target_state" || begin_rc=$?
  if (( begin_rc != 0 )); then
    abandon_failed_begin "$begin_rc" "transaction"
    restore_transaction_traps
    release_boot_repair_lock
    return "$begin_rc"
  fi
  "$callback" "$@" || callback_rc=$?
  finish_armed_transaction commit_lifecycle_transaction "$callback_rc" \
    "operation ${operation}" || callback_rc=$?
  restore_transaction_traps
  release_boot_repair_lock
  return "$callback_rc"
}

record_adoption_transaction() {
  local settings
  transaction_phase_start "record-adoption" || return 1
  lifecycle_failpoint "before-adoption-state-write" || return 1
  settings=$(jq -cn \
    --arg managed_verification "$1" --arg original_verification "$2" \
    --arg managed_enrollment "$3" --arg original_enrollment "$4" \
    --arg managed_before_save "$5" --arg original_before_save "$6" \
    --arg managed_after_save "$7" --arg original_after_save "$8" \
    --arg before_token limine-reset-enroll \
    --arg after_token limine-enroll-config '[
      {
        path: "/etc/default/limine", key: "ENABLE_VERIFICATION",
        managed: $managed_verification, original: $original_verification
      },
      {
        path: "/etc/default/limine", key: "ENABLE_ENROLL_LIMINE_CONFIG",
        managed: $managed_enrollment, original: $original_enrollment
      },
      {
        path: "/etc/default/limine", key: "COMMANDS_BEFORE_SAVE",
        token: $before_token, managed: $managed_before_save,
        original: $original_before_save
      },
      {
        path: "/etc/default/limine", key: "COMMANDS_AFTER_SAVE",
        token: $after_token, managed: $managed_after_save,
        original: $original_after_save
      }
    ]') || return 1
  persist_managed_settings_record adoption "$settings" || return 1
  persist_tracking_ownership_record '[]' || return 1
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
  boot_locks_are_held || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$transaction_id" ]] || return 1
  read_transaction_manifest "$transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
  set_transaction_context "$transaction_id"
}

# Bind the loaded manifest as the current transaction context.
set_transaction_context() {
  _transaction_active=true
  _transaction_id="$1"
  _transaction_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  _transaction_target_state=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
}

# Clears the transaction identity after its active window has ended.
detach_transaction_context() {
  _transaction_active=false
  _transaction_id=""
  _transaction_operation=""
  _transaction_target_state=""
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}
