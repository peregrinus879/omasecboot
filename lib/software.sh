#!/bin/bash
# shellcheck disable=SC2154 # Transaction globals come from the sourced lifecycle module.
# OmaSecBoot: software recovery for restore-policy roots

readonly SOFTWARE_RECOVERY_PROOF_SCHEMA_VERSION=1

software_recovery_root_is_supported() {
  local document="$1"
  jq -e --argjson final_schema "$FINAL_PROOF_SCHEMA_VERSION" \
    --argjson phases "$OMASECBOOT_OPERATION_PHASES" "$OMASECBOOT_JQ_DEFS"'
    .kind == "root" and .file_rollback_policy == "restore" and
    .firmware_writes == [] and .domain_records.producer == null and
    .domain_records.bootnext == null and .domain_records.firmware == null and
    (.operation == "unconfigure" or .domain_records.unconfigure == null) and
    .domain_records.windows == null and
    if .operation == "adopt" then
      .prior_state == "unmanaged" and .target_state == "active" and
      .firmware_backup == null and .enrollment_plan == null and
      phase_sequence_valid($phases["adopt"]) and
      (if .status == "completed" then
        .domain_records.managed_settings != null and
        .domain_records.tracking_ownership != null
       else true end)
    elif .operation == "prepare-secure-boot" then
      (.prior_state == "unmanaged" or .prior_state == "disabled") and
      .target_state == "disabled" and .enrollment_plan == null and
      .domain_records.final_proof == null and
      .domain_records.managed_settings == null and
      .domain_records.tracking_ownership == null and
      phase_sequence_valid($phases["prepare-secure-boot"]) and
      (if .status == "completed" then
        .firmware_backup != null and .firmware_backup.status == "complete"
       else true end)
    elif .operation == "activate-secure-boot-plan" then
      (.prior_state == "disabled" or .prior_state == "active") and
      .target_state == "active" and
      phase_sequence_valid($phases["activate-secure-boot-plan"]) and
      (if .status == "completed" then
        .firmware_backup != null and .firmware_backup.status == "complete" and
        .enrollment_plan != null and .domain_records.final_proof != null and
        .domain_records.final_proof.schema_version == $final_schema and
        .domain_records.managed_settings != null and
        .domain_records.tracking_ownership != null
       else true end)
    elif .operation == "sign" then
      .prior_state == "active" and .target_state == "active" and
      .firmware_backup == null and .enrollment_plan == null and
      phase_sequence_valid($phases["sign"]) and
      (if .status == "completed" then
        .domain_records.final_proof != null and
        .domain_records.final_proof.schema_version == $final_schema and
        .domain_records.managed_settings != null and
        .domain_records.tracking_ownership != null
       else true end)
    elif .operation == "cleanup" then
      .prior_state == "active" and .target_state == "active" and
      .firmware_backup == null and .enrollment_plan == null and
      .domain_records.final_proof == null and
      .domain_records.managed_settings == null and
      .domain_records.tracking_ownership == null and
      phase_sequence_valid($phases["cleanup"])
    elif .operation == "windows-setup" then
      .prior_state == "active" and .target_state == "active" and
      .firmware_backup == null and .enrollment_plan == null and
      phase_sequence_valid($phases["windows-setup"]) and
      (if .status == "completed" then
        .domain_records.final_proof != null and
        .domain_records.final_proof.schema_version == $final_schema and
        .domain_records.managed_settings != null and
        .domain_records.tracking_ownership != null
       else true end)
    elif .operation == "windows-suppress" then
      .prior_state == "active" and .target_state == "active" and
      .firmware_backup == null and .enrollment_plan == null and
      phase_sequence_valid($phases["windows-suppress"]) and
      (if .status == "completed" then
        .domain_records.final_proof != null and
        .domain_records.final_proof.schema_version == $final_schema and
        .domain_records.managed_settings != null and
        .domain_records.tracking_ownership != null
       else true end)
    elif .operation == "unconfigure" then
      .prior_state == "active" and .target_state == "disabled" and
      .firmware_backup == null and .enrollment_plan == null
    else false end
  ' <<< "$document" >/dev/null
}

validate_software_recovery_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" root terminal resolution
  local expected_backups
  root=$(recovery_root_manifest_from_reference \
    "$(jq -c '.recovery.root_incident' <<< "$manifest")") || return 1
  [[ $(recovery_operation_for_root_manifest "$root") == software-recovery ]] || return 1
  terminal=$(recovery_terminal_state_for_root_manifest "$root" software-recovery) || return 1
  if [[ $(jq -r '.status' <<< "$root") == completed ]]; then
    resolution=completed
    expected_backups='[]'
  else
    resolution=rolled-back
    expected_backups=$(jq -c '[.backups[] |
      select(.kind == "file" or .kind == "absent-file") |
      {kind, target, sha256}]' <<< "$root") || return 1
  fi
  jq -e --arg id "$transaction_id" \
    --argjson schema "$SOFTWARE_RECOVERY_PROOF_SCHEMA_VERSION" \
    --arg terminal "$terminal" --arg resolution "$resolution" \
    --arg root_operation "$(jq -r '.operation' <<< "$root")" \
    --argjson expected_backups "$expected_backups" --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS"'
    def restored_backup:
      type == "object" and keys == ["kind","sha256","target"] and
      (.kind == "file" or .kind == "absent-file") and (.target | absolute_path) and
      (if .kind == "file" then (.sha256 | digest) else .sha256 == null end);
    type == "object" and
    keys == ["operation","proved_at","resolution","restored_backups","root_incident",
      "root_operation","schema_version","terminal_state","transaction_id",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "software-recovery" and (.proved_at | timestamp) and
    .resolution == $resolution and .terminal_state == $terminal and
    .root_operation == $root_operation and
    .root_incident == $manifest.recovery.root_incident and
    (.restored_backups | type == "array" and length <= 4096 and
      all(.[]; restored_backup)) and .restored_backups == $expected_backups and
    $manifest.kind == "recovery-attempt" and
    $manifest.operation == "software-recovery" and
    $manifest.target_state == $terminal
  ' <<< "$document" >/dev/null
}

validate_software_recovery_proof_reference() {
  validate_domain_reference "$1" "$2" "$SOFTWARE_RECOVERY_PROOF_SCHEMA_VERSION" final-proof.json validate_software_recovery_proof_json "$3"
}

load_software_recovery_context() {
  local recovery_operation
  load_recovery_context || return $?
  recovery_operation=$(recovery_operation_for_root_manifest \
    "$_recovery_root_manifest_json") || return 1
  [[ "$recovery_operation" == software-recovery ]] || return 1
  _recovery_terminal_state=$(recovery_terminal_state_for_root_manifest \
    "$_recovery_root_manifest_json" "$recovery_operation") || return 1
  [[ "$_recovery_terminal_state" == active || "$_recovery_terminal_state" == disabled \
    || "$_recovery_terminal_state" == unmanaged ]] || return 1
  software_recovery_esp_is_safe
}

software_recovery_esp_is_safe() {
  local esp target
  [[ $(jq -r '.status' <<< "$_recovery_root_manifest_json") != completed ]] || return 0
  esp=$(esp_path) || return 1
  esp=${esp%/}
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    case "$target" in
      "${esp}"/*)
        esp_is_mounted_vfat || return 1
        return 0
        ;;
    esac
  done < <(jq -r '.backups[] |
    select(.kind == "file" or .kind == "absent-file") | .target' \
    <<< "$_recovery_root_manifest_json")
}

software_recovery_backups_are_restored() {
  local root_manifest="$1" entry kind target expected mode uid gid current_mode current_uid current_gid
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    kind=$(jq -r '.kind' <<< "$entry") || return 1
    target=$(jq -r '.target' <<< "$entry") || return 1
    if [[ "$kind" == absent-file ]]; then
      [[ ! -e "$target" && ! -L "$target" ]] || return 1
      continue
    fi
    [[ "$kind" == file ]] || return 1
    expected=$(jq -r '.sha256' <<< "$entry") || return 1
    mode=$(jq -r '.mode' <<< "$entry") || return 1
    uid=$(jq -r '.uid' <<< "$entry") || return 1
    gid=$(jq -r '.gid' <<< "$entry") || return 1
    validate_control_file "$target" || return 1
    read -r current_uid current_gid current_mode \
      < <(stat -Lc '%u %g %a' "$target" 2>/dev/null) || return 1
    [[ "$current_uid" == "$uid" && "$current_gid" == "$gid" \
      && "$current_mode" == "$mode" && "$(sha256_file "$target")" == "$expected" ]] \
      || return 1
  done < <(jq -c '.backups[] |
    select(.kind == "file" or .kind == "absent-file")' <<< "$root_manifest")
}

restore_software_recovery_backups() {
  local entry
  local -a entries=()
  entries_json=$(jq -c '.backups | reverse[] |
    select(.kind == "file" or .kind == "absent-file")' \
    <<< "$_recovery_root_manifest_json") || return 1
  [[ -z "$entries_json" ]] || mapfile -t entries <<< "$entries_json"
  for entry in "${entries[@]}"; do
    restore_transaction_backup_entry "$entry" || return 1
  done
  software_recovery_backups_are_restored "$_recovery_root_manifest_json"
}

persist_software_recovery_proof() {
  local timestamp resolution backups document
  timestamp=$(utc_timestamp) || return 1
  if [[ $(jq -r '.status' <<< "$_recovery_root_manifest_json") == completed ]]; then
    resolution=completed
    backups='[]'
  else
    software_recovery_backups_are_restored "$_recovery_root_manifest_json" || return 1
    resolution=rolled-back
    backups=$(jq -c '[.backups[] |
      select(.kind == "file" or .kind == "absent-file") |
      {kind, target, sha256}]' <<< "$_recovery_root_manifest_json") || return 1
  fi
  document=$(jq -cn \
    --argjson schema "$SOFTWARE_RECOVERY_PROOF_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg id "$_transaction_id" \
    --arg timestamp "$timestamp" --arg resolution "$resolution" \
    --arg terminal "$_transaction_target_state" \
    --arg root_operation "$(jq -r '.operation' <<< "$_recovery_root_manifest_json")" \
    --argjson root "$_recovery_root_reference" --argjson backups "$backups" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      operation: "software-recovery",
      proved_at: $timestamp,
      root_incident: $root,
      root_operation: $root_operation,
      resolution: $resolution,
      terminal_state: $terminal,
      restored_backups: $backups
    }') || return 1
  persist_transaction_domain_record final_proof final-proof.json \
    "$SOFTWARE_RECOVERY_PROOF_SCHEMA_VERSION" validate_software_recovery_proof_json \
    '["proved_at"]' "$document"
}

software_recovery_transaction() {
  if [[ $(jq -r '.status' <<< "$_recovery_root_manifest_json") == completed ]]; then
    transaction_phase_start prove-completed || return 1
    persist_software_recovery_proof || return 1
    transaction_phase_complete prove-completed
    return
  fi
  transaction_phase_start restore-files || return 1
  restore_software_recovery_backups || return 1
  transaction_phase_complete restore-files || return 1
  transaction_phase_start prove-restored || return 1
  software_recovery_backups_are_restored "$_recovery_root_manifest_json" || return 1
  persist_software_recovery_proof || return 1
  transaction_phase_complete prove-restored
}

run_software_recovery_locked() {
  boot_locks_are_held || return 1
  load_software_recovery_context || return $?
  run_recovery_attempt_locked software-recovery software_recovery_transaction \
    "software recovery"
}
