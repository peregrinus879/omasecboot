#!/bin/bash
# shellcheck disable=SC2154 # Transaction globals come from the sourced lifecycle module.
# OmaSecBoot: domain record schemas, references, validators, and persistence

readonly PRODUCER_RECORD_SCHEMA_VERSION=1
readonly FINAL_PROOF_SCHEMA_VERSION=2
readonly FIRMWARE_PROOF_SCHEMA_VERSION=1
readonly BOOTNEXT_RECORD_SCHEMA_VERSION=1
readonly WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION=1
readonly WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION=1
readonly MANAGED_SETTINGS_SCHEMA_VERSION=1
readonly TRACKING_OWNERSHIP_SCHEMA_VERSION=1
readonly UNCONFIGURE_INTENT_SCHEMA_VERSION=1
readonly UNCONFIGURE_PROOF_SCHEMA_VERSION=1
readonly MAX_EXPECTED_EFI_ARTIFACTS=4096

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

validate_artifact_reference_file() {
  local reference="$1" owner_dir="${2:-$(state_dir_path)}" path hash
  path=$(jq -r '.path' <<< "$reference") || return 1
  hash=$(jq -r '.sha256' <<< "$reference") || return 1
  [[ "$path" == "${owner_dir}/"* && "$path" != *'/../'* ]] || return 1
  path_has_no_symlink_components "$path" || return 1
  validate_private_control_file "$path" || return 1
  [[ "$(sha256_file "$path")" == "$hash" ]]
}

# Validates a transaction-local domain record reference: schema, canonical
# filename inside the transaction directory, file hash, then the document
# through the named validator, which receives any extra arguments.
validate_domain_reference() {
  local transaction_id="$1" reference="$2" schema="$3" filename="$4" validator="$5"
  shift 5
  local transaction_dir path document
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$transaction_id")") || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  [[ $(jq -r '.schema_version' <<< "$reference") == "$schema" \
    && "$path" == "${transaction_dir}/${filename}" ]] || return 1
  validate_artifact_reference_file "$reference" "$transaction_dir" || return 1
  document=$(read_control_document "$path") || return 1
  "$validator" "$transaction_id" "$document" "$@"
}

reference_transaction_id() {
  local reference="$1" filename="$2" path transaction_dir transaction_id
  path=$(jq -r '.path' <<< "$reference") || return 1
  transaction_dir=$(dirname "$path") || return 1
  [[ "$(dirname "$transaction_dir")" == "$(transactions_dir_path)" \
    && "$(basename "$path")" == "$filename" ]] || return 1
  transaction_id=$(basename "$transaction_dir") || return 1
  lifecycle_manifest_path "$transaction_id" >/dev/null || return 1
  printf '%s\n' "$transaction_id"
}

validate_lifecycle_ownership_pair() {
  local managed="$1" tracking="$2" managed_id tracking_id
  if [[ "$managed" == null || "$tracking" == null ]]; then
    [[ "$managed" == null && "$tracking" == null ]]
    return
  fi
  managed_id=$(reference_transaction_id "$managed" managed-settings.json) || return 1
  tracking_id=$(reference_transaction_id "$tracking" tracking-ownership.json) || return 1
  [[ "$managed_id" == "$tracking_id" ]] || return 1
  validate_managed_settings_record_reference "$managed_id" "$managed" || return 1
  validate_tracking_ownership_record_reference "$tracking_id" "$tracking"
}

validate_managed_settings_record_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson schema "$MANAGED_SETTINGS_SCHEMA_VERSION" "$OMASECBOOT_JQ_DEFS"'
    type == "object" and
    keys == ["recorded_at","schema_version","settings","source","transaction_id",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.recorded_at | timestamp) and
    (.source == "adoption" or .source == "repair" or .source == "setup") and
    (.settings | type == "array" and length == 4) and
    (.settings[0] |
      keys == ["key","managed","original","path"] and
      .path == "/etc/default/limine" and .key == "ENABLE_VERIFICATION" and
      (.managed == "yes" or .managed == "no" or .managed == "unset") and
      (.original == "yes" or .original == "no" or .original == "unset" or
        .original == "unknown")) and
    (.settings[1] |
      keys == ["key","managed","original","path"] and
      .path == "/etc/default/limine" and .key == "ENABLE_ENROLL_LIMINE_CONFIG" and
      (.managed == "yes" or .managed == "no" or .managed == "unset") and
      (.original == "yes" or .original == "no" or .original == "unset" or
        .original == "unknown")) and
    (.settings[2] |
      keys == ["key","managed","original","path","token"] and
      .path == "/etc/default/limine" and .key == "COMMANDS_BEFORE_SAVE" and
      .token == "limine-reset-enroll" and
      (.managed == "present" or .managed == "absent") and
      (.original == "present" or .original == "absent" or .original == "unknown")) and
    (.settings[3] |
      keys == ["key","managed","original","path","token"] and
      .path == "/etc/default/limine" and .key == "COMMANDS_AFTER_SAVE" and
      .token == "limine-enroll-config" and
      (.managed == "present" or .managed == "absent") and
      (.original == "present" or .original == "absent" or .original == "unknown"))
  ' <<< "$document" >/dev/null
}

validate_managed_settings_record_reference() {
  validate_domain_reference "$1" "$2" "$MANAGED_SETTINGS_SCHEMA_VERSION" managed-settings.json validate_managed_settings_record_json
}

validate_tracking_ownership_record_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson schema "$TRACKING_OWNERSHIP_SCHEMA_VERSION" \
    --argjson maximum "$MAX_EXPECTED_EFI_ARTIFACTS" "$OMASECBOOT_JQ_DEFS"'
    type == "object" and
    keys == ["paths","recorded_at","schema_version","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.recorded_at | timestamp) and
    (.paths | type == "array" and length <= $maximum and all(.[]; absolute_path) and
      . == sort and length == (unique | length) and
      (map(ascii_downcase) | length == (unique | length)))
  ' <<< "$document" >/dev/null
}

validate_tracking_ownership_record_reference() {
  validate_domain_reference "$1" "$2" "$TRACKING_OWNERSHIP_SCHEMA_VERSION" tracking-ownership.json validate_tracking_ownership_record_json
}

# The recorded tool version is historical evidence and is checked for shape
# only; whether the tools may run again is proved against the installed
# package when they are executed.
validate_unconfigure_intent_json() {
  local transaction_id="$1" document="$2" manifest="$3" prior_path prior_lifecycle
  local managed tracking
  jq -e --arg id "$transaction_id" --argjson schema "$UNCONFIGURE_INTENT_SCHEMA_VERSION" \
    --arg source "$(limine_unsigned_binary_path)" \
    --arg install "$(limine_install_path)" \
    --arg mkinitcpio "$(limine_mkinitcpio_path)" \
    --arg reset "$(limine_reset_enroll_path)" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS"'
    type == "object" and
    keys == ["limine_source","limine_tools","managed_settings","operation","recorded_at",
      "schema_version","tracking_ownership","transaction_id","windows_state_identity",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "unconfigure" and (.recorded_at | timestamp) and
    (.managed_settings | artifact_reference) and
    (.tracking_ownership | artifact_reference) and
    (.limine_source | type == "object" and keys == ["identity","path","sha256"] and
      .path == $source and (.identity | identity) and (.sha256 | digest)) and
    (.limine_tools | type == "object" and
      keys == ["install","mkinitcpio","package","reset","version"] and
      .package == "limine-mkinitcpio-hook" and
      (.version | type == "string" and length > 0 and length <= 64 and
        test("^[0-9A-Za-z][0-9A-Za-z.+:~-]*$")) and
      (.install | type == "object" and keys == ["identity","path","sha256"] and
        .path == $install and (.identity | identity) and (.sha256 | digest)) and
      (.mkinitcpio | type == "object" and keys == ["identity","path","sha256"] and
        .path == $mkinitcpio and (.identity | identity) and (.sha256 | digest)) and
      (.reset | type == "object" and keys == ["identity","path","sha256"] and
        .path == $reset and (.identity | identity) and (.sha256 | digest))) and
    (.windows_state_identity == "absent" or
      (.windows_state_identity | test("^present:[0-9]+:[0-9]+:[0-9a-f]{64}$"))) and
    $manifest.kind == "root" and $manifest.operation == "unconfigure" and
    $manifest.prior_state == "active" and $manifest.target_state == "disabled"
  ' <<< "$document" >/dev/null || return 1
  prior_path=$(jq -r '.backups[0].path' <<< "$manifest") || return 1
  prior_lifecycle=$(read_control_document "$prior_path") || return 1
  validate_lifecycle_json "$prior_lifecycle" || return 1
  managed=$(jq -c '.managed_settings' <<< "$prior_lifecycle") || return 1
  tracking=$(jq -c '.tracking_ownership' <<< "$prior_lifecycle") || return 1
  [[ "$managed" != null && "$tracking" != null ]] || return 1
  validate_lifecycle_ownership_pair "$managed" "$tracking" || return 1
  jq -en --argjson intent "$document" --argjson managed "$managed" \
    --argjson tracking "$tracking" '
      $intent.managed_settings == $managed and $intent.tracking_ownership == $tracking
    ' >/dev/null
}

validate_unconfigure_intent_reference() {
  validate_domain_reference "$1" "$2" "$UNCONFIGURE_INTENT_SCHEMA_VERSION" unconfigure-intent.json validate_unconfigure_intent_json "$3"
}

validate_unconfigure_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" zero_checksum root intent
  local intent_document
  zero_checksum=$(printf '0%.0s' {1..128})
  if [[ $(jq -r '.kind' <<< "$manifest") == root ]]; then
    root="$manifest"
  else
    root=$(recovery_root_manifest_from_reference \
      "$(jq -c '.recovery.root_incident' <<< "$manifest")") || return 1
  fi
  intent=$(jq -c '.domain_records.unconfigure' <<< "$root") || return 1
  [[ "$intent" != null ]] || return 1
  intent_document=$(read_control_document "$(jq -r '.path' <<< "$intent")") || return 1
  validate_unconfigure_intent_json "$(jq -r '.id' <<< "$root")" "$intent_document" "$root" \
    || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$UNCONFIGURE_PROOF_SCHEMA_VERSION" \
    --arg zero "$zero_checksum" --arg primary "$(limine_primary_binary_path)" \
    --arg fallback "$(limine_fallback_binary_path)" \
    --arg source "$(limine_unsigned_binary_path)" --argjson manifest "$manifest" \
    --argjson intent "$intent" --argjson intent_document "$intent_document" "$OMASECBOOT_JQ_DEFS"'
    def target($path):
      type == "object" and keys == ["config_checksum","path","sha256"] and
      .path == $path and .config_checksum == $zero and (.sha256 | digest);
    def source:
      type == "object" and keys == ["path","sha256"] and
      .path == $source and (.sha256 | digest);
    type == "object" and
    keys == ["intent","limine","managed_settings","operation","proved_at","root_incident",
      "schema_version","secure_boot","settings","tracking_ownership","transaction_id",
      "windows","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.operation == "unconfigure" or .operation == "unconfigure-recovery") and
    (.proved_at | timestamp) and .secure_boot == 0 and
    .settings == "original" and .windows == "managed-block-absent" and
    .intent == $intent and
    .managed_settings == $intent_document.managed_settings and
    .tracking_ownership == $intent_document.tracking_ownership and
    (.managed_settings | artifact_reference) and (.tracking_ownership | artifact_reference) and
    (.limine | type == "object" and keys == ["fallback","primary","source"] and
      (.source | source) and (.primary | target($primary)) and
      (.fallback | target($fallback)) and
      .source.sha256 == $intent_document.limine_source.sha256 and
      .primary.sha256 == .source.sha256 and .fallback.sha256 == .source.sha256) and
    (if $manifest.kind == "root" then
      .operation == "unconfigure" and .root_incident == null and
      $manifest.operation == "unconfigure" and $manifest.prior_state == "active" and
      $manifest.target_state == "disabled" and $manifest.file_rollback_policy == "preserve"
     else
      .operation == "unconfigure-recovery" and
      .root_incident == $manifest.recovery.root_incident and
      $manifest.kind == "recovery-attempt" and
      $manifest.operation == "unconfigure-recovery" and
      $manifest.target_state == "disabled" and
      $manifest.file_rollback_policy == "preserve"
     end)
  ' <<< "$document" >/dev/null
}

validate_unconfigure_proof_reference() {
  validate_domain_reference "$1" "$2" "$UNCONFIGURE_PROOF_SCHEMA_VERSION" final-proof.json validate_unconfigure_proof_json "$3"
}

validate_producer_record_json() {
  local transaction_id="$1" document="$2"
  jq -e --arg id "$transaction_id" --argjson owner_uid "$(control_owner_uid)" \
    --argjson schema "$PRODUCER_RECORD_SCHEMA_VERSION" "$OMASECBOOT_JQ_DEFS"'
    def process_identity:
      type == "object" and
      keys == ["boot_id","identity","identity_kind","pid","start_time","uid"] and
      (.boot_id | uuid) and (.identity | absolute_path) and
      (.identity_kind == "executable" or .identity_kind == "script") and
      (.pid | type == "number" and . > 0 and floor == .) and
      (.start_time | type == "string" and test("^[0-9]+$") and length <= 32) and
      .uid == $owner_uid;
    type == "object" and
    keys == ["caller","created_at","operation","owner","producer_class","schema_version",
      "subtype","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    (.created_at | timestamp) and (.operation | operation) and
    (.owner | process_identity) and
    (.caller | type == "string" and length > 0 and length <= 64 and
      test("^[a-z0-9][a-z0-9-]*$")) and
    if .producer_class == "package" then
      .operation == "producer-package" and .subtype == "package-transaction" and
      .owner.identity_kind == "executable" and .owner.identity == "/usr/bin/pacman" and
      .caller == "pacman"
    elif .producer_class == "limine" then
      ((.subtype == "entry-tool" and .owner.identity == "/usr/bin/limine-entry-tool" and
          .caller == "limine-entry-tool") or
       (.subtype == "uki-build" and
          .owner.identity == "/usr/share/libalpm/scripts/limine-mkinitcpio-install" and
          .caller == "limine-mkinitcpio-install")) and
      .operation == "producer-limine" and .owner.identity_kind == "script"
    elif .producer_class == "snapshot" then
      .operation == "producer-snapshot" and .subtype == "snapshot-sync" and
      .owner.identity_kind == "script" and
      .owner.identity == "/usr/bin/limine-snapper-sync" and .caller == "limine-snapper-sync"
    elif .producer_class == "restore" then
      .operation == "producer-restore" and .subtype == "full-restore" and
      .owner.identity_kind == "script" and
      .owner.identity == "/usr/bin/limine-snapper-sync" and
      (.caller == "limine-snapper-sync" or .caller == "limine-snapper-restore")
    else false end
  ' <<< "$document" >/dev/null
}

validate_producer_record_reference() {
  validate_domain_reference "$1" "$2" "$PRODUCER_RECORD_SCHEMA_VERSION" producer.json validate_producer_record_json
}

validate_final_proof_json() {
  local transaction_id="$1" document="$2"
  [[ $(document_schema_version "$document") == "$FINAL_PROOF_SCHEMA_VERSION" ]] || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$FINAL_PROOF_SCHEMA_VERSION" "$OMASECBOOT_JQ_DEFS"'
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
}

validate_final_proof_reference() {
  validate_domain_reference "$1" "$2" "$FINAL_PROOF_SCHEMA_VERSION" final-proof.json validate_final_proof_json
}

validate_firmware_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" writes writes_hash
  writes=$(jq -cS '.firmware_writes' <<< "$manifest") || return 1
  writes_hash=$(sha256_text "$writes") || return 1
  jq -e --arg id "$transaction_id" --argjson schema "$FIRMWARE_PROOF_SCHEMA_VERSION" \
    --argjson final_schema "$FINAL_PROOF_SCHEMA_VERSION" \
    --arg writes_hash "$writes_hash" --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS"'
    def proof_reference:
      type == "object" and keys == ["path","schema_version","sha256"] and
      (.path | absolute_path) and .schema_version == $final_schema and (.sha256 | digest);
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
      (.AuditMode == 0 or .AuditMode == null) and
      (.DeployedMode == 0 or .DeployedMode == null) and
      .SecureBoot == 0 and .SetupMode == 0) and
    .firmware_writes_sha256 == $writes_hash and
    (.artifact_proof | proof_reference) and
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
  validate_domain_reference "$1" "$2" "$FIRMWARE_PROOF_SCHEMA_VERSION" firmware-proof.json validate_firmware_proof_json "$3"
}

validate_bootnext_record_json() {
  local transaction_id="$1" document="$2" manifest="$3"
  jq -e --arg id "$transaction_id" \
    --argjson schema "$BOOTNEXT_RECORD_SCHEMA_VERSION" \
    --arg executable "$WINDOWS_EFIBOOTMGR_EXECUTABLE" \
    --arg loader "$WINDOWS_BOOTNEXT_LOADER_PATH" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS"'
    def safe_label:
      type == "string" and length >= 1 and length <= 127 and
      test("^[A-Za-z0-9][A-Za-z0-9 ._()+&-]{0,126}$") and
      (endswith(" ") | not) and (contains("${") | not);
    type == "object" and
    keys == ["boot_id","efibootmgr","operation","prior","recorded_at","schema_version",
      "target","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "windows-bootnext" and (.boot_id | uuid) and
    .boot_id == $manifest.boot_id and (.recorded_at | timestamp) and
    (.efibootmgr | type == "object" and
      keys == ["executable","executable_sha256","package"] and
      (.package | type == "string" and length > 0 and length <= 128) and
      .executable == $executable and (.executable_sha256 | digest)) and
    (.target | type == "object" and
      keys == ["boot_number","label","loader_path","partuuid"] and
      (.boot_number | boot_number) and (.label | safe_label) and
      (.partuuid | type == "string" and
        test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      .loader_path == $loader) and
    (.prior | type == "object" and keys == ["boot_number","present"] and
      (.present | type == "boolean") and
      (if .present then (.boot_number | boot_number) else .boot_number == null end))
  ' <<< "$document" >/dev/null
}

validate_bootnext_record_reference() {
  validate_domain_reference "$1" "$2" "$BOOTNEXT_RECORD_SCHEMA_VERSION" bootnext.json validate_bootnext_record_json "$3"
}

# Windows BootNext records: an observed variable state and a bound record.
readonly WINDOWS_STATE_JQ_DEFS='
  def state:
    type == "object" and keys == ["boot_number","present"] and
    (.present | type == "boolean") and
    (if .present then (.boot_number | boot_number) else .boot_number == null end);
  def reference:
    type == "object" and keys == ["path","schema_version","sha256"] and
    (.path | absolute_path) and .schema_version == 1 and (.sha256 | digest);
'

validate_windows_recovery_record_json() {
  local transaction_id="$1" document="$2" manifest="$3"
  local root_id root_manifest_path root_manifest bootnext_reference bootnext_path
  local bootnext_document
  jq -e --arg id "$transaction_id" \
    --argjson schema "$WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION" \
    --arg efibootmgr_executable "$WINDOWS_EFIBOOTMGR_EXECUTABLE" \
    --arg variable_path "$(windows_bootnext_variable_path)" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS$WINDOWS_STATE_JQ_DEFS"'
    def incident:
      type == "object" and
      keys == ["id","kind","operation","ordinal","path","sha256","status"] and
      (.id | uuid) and .kind == "root" and .operation == "windows-bootnext" and
      .ordinal == 0 and (.path | type == "string" and startswith("/")) and
      (.sha256 | digest) and
      (.status == "failed" or .status == "stale" or .status == "publication-uncertain");
    def tool:
      type == "object" and keys == ["executable","executable_sha256","package"] and
      (.executable_sha256 | digest);
    type == "object" and
    keys == ["action","bootnext_record","observed","operation","planned_outcome","prior",
      "recorded_at","recovery_boot_id","relation","root_boot_id","root_incident",
      "schema_version","target","tool","transaction_id","variable","write_frontier",
      "writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "windows-recovery" and (.recorded_at | timestamp) and
    (.recovery_boot_id | uuid) and .recovery_boot_id == $manifest.boot_id and
    (.root_incident | incident) and .root_incident == $manifest.recovery.root_incident and
    if .bootnext_record == null then
      .root_boot_id == null and .relation == null and .prior == null and .target == null and
      .observed == null and .action == "none" and
      .planned_outcome == "not-published" and .tool == null and .variable == null and
      .write_frontier == "not-published"
    else
      (.bootnext_record | reference) and (.root_boot_id | uuid) and
      (.relation == "same-boot" or .relation == "later-boot") and
      .relation == (if .root_boot_id == .recovery_boot_id then "same-boot" else "later-boot" end) and
      (.prior | state) and (.target | boot_number) and (.observed | state) and
      (.write_frontier == "not-reached" or .write_frontier == "write-possible") and
      (if .write_frontier == "not-reached" then
        .observed == .prior and .action == "none" and
        .planned_outcome == "prior-unchanged" and .tool == null and .variable == null
       elif .relation == "later-boot" and .observed.present == false then
        .action == "none" and .planned_outcome == "consumed-unknown" and
        .tool == null and .variable == null
       elif .observed == .prior then
        .action == "none" and .planned_outcome == "prior-unchanged" and
        .tool == null and .variable == null
       elif .observed.present and .observed.boot_number == .target and
           (.observed != .prior) then
        .planned_outcome == "prior-restored" and
        if .prior.present then
          .action == "set-prior" and .variable == null and (.tool | tool) and
          .tool.executable == $efibootmgr_executable
        else
          .action == "delete" and .tool == null and
          (.variable | type == "object" and keys == ["identity","path","sha256"] and
            .path == $variable_path and (.identity | identity) and (.sha256 | digest))
        end
       else false end)
    end
  ' <<< "$document" >/dev/null || return 1

  root_id=$(jq -r '.root_incident.id' <<< "$document") || return 1
  root_manifest_path=$(lifecycle_manifest_path "$root_id") || return 1
  root_manifest=$(read_control_document "$root_manifest_path") || return 1
  validate_transaction_manifest_json "$root_id" "$root_manifest" false || return 1
  jq -e '
    .kind == "root" and .operation == "windows-bootnext" and
    .target_state == "active" and .prior_state == "active" and
    .domain_records.producer == null
  ' <<< "$root_manifest" >/dev/null || return 1
  bootnext_reference=$(jq -c '.domain_records.bootnext' <<< "$root_manifest") || return 1
  jq -e --argjson reference "$bootnext_reference" --argjson root "$root_manifest" '
    .bootnext_record == $reference and
    .write_frontier ==
      (if $reference == null then "not-published"
       elif ($root.completed_phases | index("record-bootnext")) == null then "not-reached"
       else "write-possible" end)
  ' \
    <<< "$document" >/dev/null || return 1
  if [[ "$bootnext_reference" == null ]]; then
    return 0
  fi
  validate_bootnext_record_reference "$root_id" "$bootnext_reference" "$root_manifest" \
    || return 1
  bootnext_path=$(jq -r '.path' <<< "$bootnext_reference") || return 1
  bootnext_document=$(read_control_document "$bootnext_path") || return 1
  jq -e --argjson recovery "$document" '
    .boot_id == $recovery.root_boot_id and .prior == $recovery.prior and
    .target.boot_number == $recovery.target and
    (if $recovery.action == "set-prior" then
      .efibootmgr == $recovery.tool
     else true end)
  ' <<< "$bootnext_document" >/dev/null
}

validate_windows_recovery_record_reference() {
  validate_domain_reference "$1" "$2" "$WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION" windows-recovery.json validate_windows_recovery_record_json "$3"
}

validate_windows_recovery_proof_json() {
  local transaction_id="$1" document="$2" manifest="$3" reference path record
  jq -e --arg id "$transaction_id" \
    --argjson schema "$WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION" \
    --argjson manifest "$manifest" "$OMASECBOOT_JQ_DEFS$WINDOWS_STATE_JQ_DEFS"'
    type == "object" and
    keys == ["command_exit_code","final_state","operation","outcome","proved_at","record",
      "schema_version","transaction_id","writer_version"] and
    .schema_version == $schema and .transaction_id == $id and (.transaction_id | uuid) and
    (.writer_version | type == "string" and length > 0 and length <= 128) and
    .operation == "windows-recovery" and (.proved_at | timestamp) and
    (.record | reference) and .record == $manifest.domain_records.windows and
    (.outcome == "not-published" or .outcome == "prior-unchanged" or
      .outcome == "prior-restored" or .outcome == "consumed-unknown") and
    (.final_state == null or (.final_state | state)) and
    (.command_exit_code == null or
      (.command_exit_code | type == "number" and . >= 0 and . <= 255 and floor == .))
  ' <<< "$document" >/dev/null || return 1
  reference=$(jq -c '.record' <<< "$document") || return 1
  validate_windows_recovery_record_reference "$transaction_id" "$reference" "$manifest" \
    || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  record=$(read_control_document "$path") || return 1
  jq -e --argjson record "$record" '
    .outcome == $record.planned_outcome and
    (if $record.action == "none" then .command_exit_code == null
     else .command_exit_code != null end) and
    (if .outcome == "not-published" then .final_state == null
     elif .outcome == "consumed-unknown" then
       .final_state == {boot_number:null,present:false}
     else .final_state == $record.prior end)
  ' <<< "$document" >/dev/null
}

validate_windows_recovery_proof_reference() {
  validate_domain_reference "$1" "$2" "$WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION" windows-recovery-proof.json validate_windows_recovery_proof_json "$3"
}

# Publishes one domain record of the current transaction exactly once: the
# document is validated, created if absent, compared with an existing copy
# ignoring the listed volatile keys, and bound into the manifest. Idempotent,
# so recovery phases may call it again.
persist_transaction_domain_record() {
  local name="$1" filename="$2" schema="$3" validator="$4" ignore="$5" document="$6"
  local path existing reference current_reference
  [[ "$_transaction_active" == true ]] || return 1
  path="$(dirname "$(lifecycle_manifest_path "$_transaction_id")")/${filename}"
  read_transaction_manifest "$_transaction_id" || return 1
  "$validator" "$_transaction_id" "$document" "$_manifest_json" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    existing=$(read_control_document "$path") || return 1
    "$validator" "$_transaction_id" "$existing" "$_manifest_json" || return 1
    jq -en --argjson existing "$existing" --argjson candidate "$document" \
      --argjson ignore "$ignore" '
      ($existing | delpaths($ignore | map([.]))) ==
        ($candidate | delpaths($ignore | map([.])))
    ' >/dev/null || return 1
  else
    printf '%s\n' "$document" | atomic_create_control_file "$path" 600 || return 1
  fi
  reference=$(transaction_artifact_reference "$path" "$schema") || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  current_reference=$(jq -c --arg name "$name" '.domain_records[$name]' \
    <<< "$_manifest_json") || return 1
  if [[ "$current_reference" == null ]]; then
    transaction_set_domain_record "$name" "$reference" || return 1
  else
    [[ "$(jq -Sc . <<< "$current_reference")" == "$(jq -Sc . <<< "$reference")" ]] \
      || return 1
  fi
  _persisted_record_reference="$reference"
}

persist_managed_settings_record() {
  local source="$1" settings="$2" timestamp document
  [[ "$source" == adoption || "$source" == repair || "$source" == setup ]] || return 1
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$MANAGED_SETTINGS_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg timestamp "$timestamp" \
    --arg source "$source" \
    --argjson settings "$settings" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      recorded_at: $timestamp,
      source: $source,
      settings: $settings
    }') || return 1
  persist_transaction_domain_record managed_settings managed-settings.json \
    "$MANAGED_SETTINGS_SCHEMA_VERSION" validate_managed_settings_record_json \
    '["writer_version","recorded_at"]' "$document"
}

persist_tracking_ownership_record() {
  local paths="$1" timestamp document
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$TRACKING_OWNERSHIP_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$_transaction_id" \
    --arg timestamp "$timestamp" \
    --argjson paths "$paths" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      recorded_at: $timestamp,
      paths: $paths
    }') || return 1
  persist_transaction_domain_record tracking_ownership tracking-ownership.json \
    "$TRACKING_OWNERSHIP_SCHEMA_VERSION" validate_tracking_ownership_record_json \
    '["writer_version","recorded_at"]' "$document"
}
