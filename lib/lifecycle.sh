#!/bin/bash
# OmaSecBoot: durable lifecycle, transaction, and hook ownership protocol

readonly LIFECYCLE_SCHEMA_VERSION=1

_lifecycle_state=unmanaged
_lifecycle_generation=0
_lifecycle_transaction_id=""
_lifecycle_json=""
_manifest_json=""
_transaction_active=false
_transaction_id=""
_transaction_token=""
_transaction_operation=""
_transaction_target_state=""
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

lifecycle_file_path() {
  printf '%s/lifecycle.json\n' "$(state_dir_path)"
}

transactions_dir_path() {
  printf '%s/transactions\n' "$(state_dir_path)"
}

snapshot_restore_lock_path() {
  printf '/run/lock/limine-snapper-restore.lock\n'
}

lifecycle_manifest_path() {
  local transaction_id="$1"
  [[ "$transaction_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || return 1
  printf '%s/%s/manifest.json\n' "$(transactions_dir_path)" "$transaction_id"
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
  printf '%s' "$1" | sha256sum | awk '{ print $1 }'
}

sha256_file() {
  sha256sum "$1" | awk '{ print $1 }'
}

capture_service_state() {
  local unit="limine-snapper-sync.service"
  local load_state="unavailable" active_state="unavailable" unit_file_state="unavailable"
  if command -v systemctl >/dev/null 2>&1; then
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) \
      || load_state="unknown"
    active_state=$(systemctl is-active "$unit" 2>/dev/null) || true
    unit_file_state=$(systemctl is-enabled "$unit" 2>/dev/null) || true
    [[ -n "$load_state" ]] || load_state="unknown"
    [[ -n "$active_state" ]] || active_state="unknown"
    [[ -n "$unit_file_state" ]] || unit_file_state="unknown"
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

read_lifecycle() {
  local state_dir state_file
  state_dir=$(state_dir_path)
  state_file=$(lifecycle_file_path)
  _lifecycle_state=unmanaged
  _lifecycle_generation=0
  _lifecycle_transaction_id=""
  _lifecycle_json=""

  if [[ ! -e "$state_dir" && ! -L "$state_dir" ]]; then
    return 0
  fi
  validate_control_directory "$state_dir" || return 1
  if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
    return 0
  fi
  validate_control_file "$state_file" || return 1

  jq -e --argjson schema "$LIFECYCLE_SCHEMA_VERSION" '
    type == "object" and
    .schema_version == $schema and
    (.writer_version | type == "string") and
    (.generation | type == "number" and . >= 1 and floor == .) and
    (.state == "disabled" or .state == "active" or
      .state == "transition" or .state == "recovery-required") and
    (.updated_at | type == "string") and
    (if .state == "transition" or .state == "recovery-required" then
      (.transaction | type == "object") and
      (.transaction.id | type == "string") and
      (.transaction.operation | type == "string") and
      (.transaction.manifest | type == "string")
    else
      .transaction == null
    end)
  ' "$state_file" >/dev/null || return 1

  _lifecycle_json=$(jq -c . "$state_file") || return 1
  _lifecycle_state=$(jq -r '.state' <<< "$_lifecycle_json") || return 1
  _lifecycle_generation=$(jq -r '.generation' <<< "$_lifecycle_json") || return 1
  if [[ "$_lifecycle_state" == transition || "$_lifecycle_state" == recovery-required ]]; then
    _lifecycle_transaction_id=$(jq -r '.transaction.id' <<< "$_lifecycle_json") || return 1
    [[ "$(jq -r '.transaction.manifest' <<< "$_lifecycle_json")" == \
      "$(lifecycle_manifest_path "$_lifecycle_transaction_id")" ]] || return 1
  fi
}

read_transaction_manifest() {
  local transaction_id="$1" manifest transaction_dir prior_state
  local backup_kind backup_path backup_hash
  manifest=$(lifecycle_manifest_path "$transaction_id") || return 1
  transaction_dir=$(dirname "$manifest")
  validate_private_control_directory "$transaction_dir" || return 1
  validate_private_control_file "$manifest" || return 1

  jq -e --arg id "$transaction_id" --argjson schema "$LIFECYCLE_SCHEMA_VERSION" \
    --argjson owner_uid "$(control_owner_uid)" '
    type == "object" and
    .schema_version == $schema and
    (.writer_version | type == "string") and
    .id == $id and
    (.operation | type == "string" and length > 0) and
    (.target_state == "disabled" or .target_state == "active") and
    (.status == "transition" or .status == "completed" or
      .status == "failed" or .status == "stale") and
    (.created_at | type == "string") and
    (.boot_id | type == "string") and
    (.token_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.owner | type == "object") and
    (.owner.pid | type == "number" and . > 0 and floor == .) and
    (.owner.start_time | type == "string" and test("^[0-9]+$")) and
    .owner.uid == $owner_uid and
    (.prior_state == "unmanaged" or .prior_state == "disabled" or .prior_state == "active") and
    (.completed_phases | type == "array" and all(.[]; type == "string")) and
    (.backups | type == "array" and length == 1) and
    (all(.backups[];
      type == "object" and
      (.kind == "absent-lifecycle" or .kind == "prior-lifecycle") and
      ((.path == null and .sha256 == null) or
        ((.path | type == "string") and
          (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
    )) and
    (.service_state | type == "object") and
    (.current_phase == null or (.current_phase | type == "string")) and
    (.failure == null or (.failure | type == "object"))
  ' "$manifest" >/dev/null || return 1
  _manifest_json=$(jq -c . "$manifest") || return 1
  prior_state=$(jq -r '.prior_state' <<< "$_manifest_json") || return 1
  backup_kind=$(jq -r '.backups[0].kind' <<< "$_manifest_json") || return 1
  if [[ "$prior_state" == unmanaged ]]; then
    [[ "$backup_kind" == absent-lifecycle \
      && $(jq -r '.backups[0].path' <<< "$_manifest_json") == null \
      && $(jq -r '.backups[0].sha256' <<< "$_manifest_json") == null ]] || return 1
  else
    backup_path=$(jq -r '.backups[0].path' <<< "$_manifest_json") || return 1
    backup_hash=$(jq -r '.backups[0].sha256' <<< "$_manifest_json") || return 1
    [[ "$backup_kind" == prior-lifecycle \
      && "$backup_path" == "${transaction_dir}/prior-lifecycle.json" ]] || return 1
    validate_private_control_file "$backup_path" || return 1
    [[ "$(sha256_file "$backup_path")" == "$backup_hash" ]] || return 1
  fi
}

manifest_owner_is_alive() {
  local boot_id owner_pid owner_start current_start owner_uid
  boot_id=$(jq -r '.boot_id' <<< "$_manifest_json") || return 1
  [[ "$boot_id" == "$(boot_id_value)" ]] || return 1
  owner_pid=$(jq -r '.owner.pid' <<< "$_manifest_json") || return 1
  owner_start=$(jq -r '.owner.start_time' <<< "$_manifest_json") || return 1
  owner_uid=$(process_effective_uid "$owner_pid") || return 1
  [[ "$owner_uid" == "$(control_owner_uid)" ]] || return 1
  current_start=$(process_start_time "$owner_pid") || return 1
  [[ "$current_start" == "$owner_start" ]]
}

write_transition_lifecycle() {
  local transaction_id="$1" operation="$2" manifest="$3" timestamp="$4"
  local base generation document

  if [[ "$_lifecycle_state" == unmanaged ]]; then
    base=$(jq -cn --arg version "$OMASECBOOT_VERSION" '{
      schema_version: 1,
      writer_version: $version,
      generation: 0,
      state: "unmanaged",
      transaction: null,
      last_transaction: null,
      adoption: null,
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
    --arg timestamp "$timestamp" '
      $base |
      .schema_version = 1 |
      .writer_version = $version |
      .generation = $generation |
      .state = "transition" |
      .transaction = {
        id: $id,
        operation: $operation,
        manifest: $manifest
      } |
      .updated_at = $timestamp
    ') || return 1
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
  owner_start=$(process_start_time "$owner_pid") || return 1
  timestamp=$(utc_timestamp) || return 1
  service_state=$(capture_service_state) || return 1
  transaction_dir="$(transactions_dir_path)/${transaction_id}"
  manifest="${transaction_dir}/manifest.json"

  install -d -m 700 "$transaction_dir" || return 1
  validate_control_directory "$transaction_dir" || return 1

  if [[ "$_lifecycle_state" == unmanaged ]]; then
    backups='[{"path":null,"sha256":null,"kind":"absent-lifecycle"}]'
  else
    prior_backup="${transaction_dir}/prior-lifecycle.json"
    cp -p "$(lifecycle_file_path)" "$prior_backup" || return 1
    chmod 600 "$prior_backup" || return 1
    validate_private_control_file "$prior_backup" || return 1
    durable_sync "$prior_backup" || return 1
    prior_hash=$(sha256_file "$prior_backup") || return 1
    backups=$(jq -cn --arg path "$prior_backup" --arg hash "$prior_hash" \
      '[{path: $path, sha256: $hash, kind: "prior-lifecycle"}]') || return 1
  fi

  manifest_document=$(jq -cn \
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
      schema_version: 1,
      writer_version: $version,
      id: $id,
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
      current_phase: null,
      completed_phases: [],
      backups: $backups,
      service_state: $service_state,
      failure: null
    }') || return 1
  printf '%s\n' "$manifest_document" | atomic_write_control_file "$manifest" 600 \
    || return 1
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
  lifecycle_failpoint "after-transition-write"
}

write_transaction_manifest_json() {
  local document="$1" manifest
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1
  printf '%s\n' "$document" | atomic_write_control_file "$manifest" 600
}

transaction_phase_start() {
  local phase="$1" document
  [[ "$_transaction_active" == true && "$phase" =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
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
    if (.completed_phases | index($phase)) == null then
      .completed_phases += [$phase]
    else . end |
    .current_phase = null
  ' <<< "$_manifest_json") || return 1
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
  lifecycle_failpoint "before-adoption-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644
}

commit_lifecycle_transaction() {
  local manifest_document state_document timestamp manifest
  [[ "$_transaction_active" == true ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.current_phase // ""' <<< "$_manifest_json") == "" ]] || return 1
  timestamp=$(utc_timestamp) || return 1
  manifest=$(lifecycle_manifest_path "$_transaction_id") || return 1

  manifest_document=$(jq -c --arg timestamp "$timestamp" '
    .status = "completed" |
    .completed_at = $timestamp |
    .failure = null
  ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$manifest_document" || return 1
  lifecycle_failpoint "after-completed-manifest-write" || return 1

  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg state "$_transaction_target_state" \
    --arg id "$_transaction_id" \
    --arg operation "$_transaction_operation" \
    --arg manifest "$manifest" \
    --arg timestamp "$timestamp" '
      .writer_version = $version |
      .generation += 1 |
      .state = $state |
      .transaction = null |
      .last_transaction = {
        id: $id,
        operation: $operation,
        manifest: $manifest,
        completed_at: $timestamp
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  lifecycle_failpoint "before-stable-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1

  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

mark_lifecycle_recovery() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  local manifest_document state_document timestamp current_phase
  [[ "$_transaction_active" == true ]] || return 1
  [[ "$status" == failed || "$status" == stale ]] || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition \
    && "$_lifecycle_transaction_id" == "$_transaction_id" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  timestamp=$(utc_timestamp) || return 1
  current_phase=$(jq -r '.current_phase // empty' <<< "$_manifest_json") || return 1

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
  write_transaction_manifest_json "$manifest_document" || return 1

  state_document=$(jq -c \
    --arg version "$OMASECBOOT_VERSION" \
    --arg timestamp "$timestamp" \
    --arg reason "$reason" \
    --argjson exit_code "$exit_code" '
      .writer_version = $version |
      .generation += 1 |
      .state = "recovery-required" |
      .transaction.failure = {
        exit_code: $exit_code,
        reason: $reason,
        recorded_at: $timestamp
      } |
      .updated_at = $timestamp
    ' <<< "$_lifecycle_json") || return 1
  lifecycle_failpoint "before-recovery-state-write" || return 1
  printf '%s\n' "$state_document" | atomic_write_control_file "$(lifecycle_file_path)" 644 \
    || return 1

  _transaction_active=false
  unset OMASECBOOT_TRANSACTION_ID OMASECBOOT_TRANSACTION_TOKEN
}

ensure_lifecycle_recovery() {
  local exit_code="$1" reason="$2" status="${3:-failed}"
  mark_lifecycle_recovery "$exit_code" "$reason" "$status" \
    || mark_lifecycle_recovery "$exit_code" "$reason" "$status"
}

reconcile_stale_lifecycle() {
  local transaction_id
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition ]] || return 0
  transaction_id="$_lifecycle_transaction_id"
  read_transaction_manifest "$transaction_id" || return 1
  manifest_owner_is_alive && return 0

  _transaction_active=true
  _transaction_id="$transaction_id"
  _transaction_operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
  _transaction_target_state=$(jq -r '.target_state' <<< "$_manifest_json") || return 1
  ensure_lifecycle_recovery 1 "transaction owner is no longer valid" stale
}

transaction_exit_handler() {
  local exit_code=$?
  trap - EXIT INT TERM HUP
  if [[ "$_transaction_active" == true ]]; then
    [[ $exit_code -ne 0 ]] || exit_code=1
    ensure_lifecycle_recovery "$exit_code" "command exited before transaction commit" failed \
      || true
  fi
  release_boot_repair_lock
  run_previous_exit_trap
  return "$exit_code"
}

transaction_signal_handler() {
  local signal="$1" exit_code="$2"
  trap - EXIT INT TERM HUP
  if [[ "$_transaction_active" == true ]]; then
    ensure_lifecycle_recovery "$exit_code" "transaction interrupted by ${signal}" failed \
      || true
  fi
  release_boot_repair_lock
  run_previous_exit_trap
  exit "$exit_code"
}

run_previous_exit_trap() {
  local declaration="$_transaction_previous_exit" command
  [[ -n "$declaration" ]] || return 0
  if [[ "$declaration" =~ ^trap\ --\ \'(.*)\'\ EXIT$ ]]; then
    command=${BASH_REMATCH[1]}
    eval "$command"
  fi
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

run_lifecycle_transaction_with_preflight() {
  local operation="$1" target_state="$2" allowed_states="$3"
  local preflight="$4" callback="$5"
  shift 5
  local callback_rc=0 commit_rc=0 begin_rc=0

  require_control_root || return 1
  with_boot_repair_lock || return 1
  reconcile_stale_lifecycle || {
    release_boot_repair_lock
    return 1
  }
  read_lifecycle || {
    release_boot_repair_lock
    fail "Lifecycle state is invalid or unsafe"
    return 1
  }
  if [[ -e "$(snapshot_restore_lock_path)" \
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

  _transaction_previous_exit=$(trap -p EXIT || true)
  _transaction_previous_int=$(trap -p INT || true)
  _transaction_previous_term=$(trap -p TERM || true)
  _transaction_previous_hup=$(trap -p HUP || true)
  trap transaction_exit_handler EXIT
  trap 'transaction_signal_handler INT 130' INT
  trap 'transaction_signal_handler TERM 143' TERM
  trap 'transaction_signal_handler HUP 129' HUP

  begin_lifecycle_transaction "$operation" "$target_state" || begin_rc=$?
  if [[ $begin_rc -ne 0 ]]; then
    if [[ "$_transaction_active" == true ]]; then
      if read_lifecycle && [[ "$_lifecycle_state" == transition \
        && "$_lifecycle_transaction_id" == "$_transaction_id" ]]; then
        ensure_lifecycle_recovery "$begin_rc" "transaction publication failed" failed \
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
      ensure_lifecycle_recovery "$commit_rc" "stable lifecycle commit failed" failed || true
      callback_rc=$commit_rc
    fi
  else
    ensure_lifecycle_recovery "$callback_rc" "operation ${operation} failed" failed || true
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

lifecycle_hook_pre() {
  require_control_root || return 100
  read_lifecycle || {
    fail "Lifecycle state is invalid or unsafe"
    return 100
  }

  if is_full_snapshot_restore_hook; then
    if [[ "$_lifecycle_state" == active ]] && ! lifecycle_repair_is_available; then
      fail "Full snapshot restore is blocked until complete boot repair is available"
      return 100
    fi
    if [[ "$_lifecycle_state" == transition \
      || "$_lifecycle_state" == recovery-required ]]; then
      [[ "$_lifecycle_state" != transition ]] \
        || reconcile_stale_transition_from_hook || true
      fail "Full snapshot restore is allowed only in stable lifecycle state"
      return 100
    fi
    with_repair_lock || return 100
    if ! read_lifecycle; then
      release_repair_lock
      fail "Lifecycle state became invalid during full snapshot restore admission"
      return 100
    fi
    if [[ "$_lifecycle_state" == transition \
      || "$_lifecycle_state" == recovery-required ]]; then
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
  esac
}

guard_boot_transaction() {
  require_control_root || return 1
  read_lifecycle || {
    fail "Boot-mutating package transaction blocked: lifecycle state is invalid or unsafe"
    return 1
  }
  if [[ -e "$(snapshot_restore_lock_path)" ]]; then
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
        warn "Lifecycle: active (boot producers blocked until complete repair is available)"
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
  esac
}
