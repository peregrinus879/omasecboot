#!/bin/bash
# shellcheck disable=SC2154 # Transaction and artifact globals come from sourced modules.
# OmaSecBoot: state-aware firmware backup and guarded key enrollment

readonly EFI_GLOBAL_VARIABLE_GUID="8be4df61-93ca-11d2-aa0d-00e098032b8c"
readonly EFI_IMAGE_SECURITY_DATABASE_GUID="d719b2cb-3d3a-4596-a3bc-dad00e67656f"
readonly EFI_SIGNATURE_X509_BYTES="a159c0a5e494a74a87b5ab155c2bf072"
readonly EFI_SIGNATURE_SHA256_BYTES="2616c4c14c509240aca941f936934328"
readonly EFI_ACTIVE_AUTH_ATTRIBUTES=39
readonly EFI_STATE_ATTRIBUTES=6
readonly FIRMWARE_BACKUP_SCHEMA_VERSION=1
readonly ENROLLMENT_PLAN_SCHEMA_VERSION=1

_firmware_backup_id=""
_firmware_backup_dir=""
_firmware_backup_json=""
_firmware_product_uuid=""
_firmware_machine_json=""
_firmware_raw_attributes=""
_firmware_raw_hash=""
_firmware_payload_hash=""
_firmware_payload_size=""
_firmware_state_value=""
_firmware_current_file=""
_sbctl_package_identity=""
_sbctl_executable=""
_sbctl_executable_hash=""
_sbctl_config_state=""
_sbctl_config_hash=""
_local_key_state=""
_setup_mode=""
_audit_mode=""
_deployed_mode=""
_secure_boot_mode=""
_setup_state=""
_enrollment_backup_id=""
_firmware_recovery_backup_id=""
_validated_current_pk_hash=""
_enrollment_current_pk_hash=""
_enrollment_planned_pk_hash=""

enrollment_failpoint() {
  return 0
}

firmware_runtime_dir_path() {
  printf '/run/omasecboot/firmware\n'
}

firmware_backup_root_path() {
  printf '%s/firmware-backup\n' "$(state_dir_path)"
}

firmware_dmi_root_path() {
  printf '/sys/devices/virtual/dmi/id\n'
}

firmware_variable_filename() {
  case "$1" in
    PK|KEK) printf '%s-%s\n' "$1" "$EFI_GLOBAL_VARIABLE_GUID" ;;
    db|dbx) printf '%s-%s\n' "$1" "$EFI_IMAGE_SECURITY_DATABASE_GUID" ;;
    SetupMode|AuditMode|DeployedMode|SecureBoot)
      printf '%s-%s\n' "$1" "$EFI_GLOBAL_VARIABLE_GUID"
      ;;
    *) return 1 ;;
  esac
}

firmware_variable_path() {
  local filename
  filename=$(firmware_variable_filename "$1") || return 1
  printf '%s/%s\n' "$(efivars_path)" "$filename"
}

firmware_backup_path() {
  local backup_id="$1"
  [[ "$backup_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || return 1
  printf '%s/%s\n' "$(firmware_backup_root_path)" "$backup_id"
}

firmware_plan_path() {
  printf '%s/plan\n' "$(firmware_backup_path "$1")"
}

validate_efivarfs_mount() {
  efivarfs_mount_is_valid
}

validate_firmware_variable_file() {
  local path="$1" root uid mode links
  root=$(efivars_path) || return 1
  [[ "$(dirname "$path")" == "$root" ]] || return 1
  path_has_no_symlink_components "$path" || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  read -r uid mode links < <(stat -Lc '%u %a %h' "$path" 2>/dev/null) || return 1
  [[ "$uid" == "$(control_owner_uid)" && "$links" == 1 ]] || return 1
  mode_is_control_safe "$mode"
}

ensure_firmware_runtime_dir() {
  local runtime parent
  runtime=$(firmware_runtime_dir_path) || return 1
  parent=$(dirname "$runtime")
  if [[ ! -e "$parent" && ! -L "$parent" ]]; then
    install -d -m 700 "$parent" || return 1
  fi
  validate_control_directory "$parent" || return 1
  if [[ -e "$runtime" || -L "$runtime" ]]; then
    validate_private_control_directory "$runtime" || return 1
  else
    install -d -m 700 "$runtime" || return 1
  fi
  validate_private_control_directory "$runtime"
}

ensure_firmware_backup_root() {
  local root
  ensure_state_layout || return 1
  root=$(firmware_backup_root_path) || return 1
  if [[ -e "$root" || -L "$root" ]]; then
    validate_private_control_directory "$root" || return 1
  else
    install -d -m 700 "$root" || return 1
    durable_sync "$(dirname "$root")" || return 1
  fi
  validate_private_control_directory "$root"
}

firmware_variable_presence() {
  local name="$1" root filename matches
  root=$(efivars_path) || return 2
  filename=$(firmware_variable_filename "$name") || return 2
  validate_efivarfs_mount || return 2
  matches=$(find "$root" -xdev -mindepth 1 -maxdepth 1 -name "$filename" \
    -printf '%f\n' 2>/dev/null) || return 2
  if [[ -z "$matches" ]]; then
    printf 'absent\n'
  elif [[ "$matches" == "$filename" ]]; then
    printf 'present\n'
  else
    return 2
  fi
}

inspect_raw_efivar_file() {
  local path="$1" size bytes remainder payload_hash
  local -a values=()
  validate_private_control_file "$path" || return 1
  size=$(stat -Lc '%s' "$path" 2>/dev/null) || return 1
  [[ "$size" =~ ^[0-9]+$ && $size -ge 4 ]] || return 1
  bytes=$(od -An -N4 -v -t u1 "$path" 2>/dev/null) || return 1
  read -r -a values <<< "$bytes"
  [[ ${#values[@]} -eq 4 ]] || return 1
  for remainder in "${values[@]}"; do
    [[ "$remainder" =~ ^[0-9]+$ && $remainder -le 255 ]] || return 1
  done
  _firmware_raw_attributes=$((values[0] | values[1] << 8 | values[2] << 16 | values[3] << 24))
  _firmware_raw_hash=$(sha256_file "$path") || return 1
  payload_hash=$(dd if="$path" bs=1 skip=4 status=none 2>/dev/null | sha256sum) \
    || return 1
  read -r _firmware_payload_hash remainder <<< "$payload_hash"
  [[ "$_firmware_payload_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  _firmware_payload_size=$((size - 4))
  _firmware_state_value=""
  if [[ $_firmware_payload_size -eq 1 ]]; then
    _firmware_state_value=$(od -An -j4 -N1 -v -t u1 "$path" 2>/dev/null) || return 1
    _firmware_state_value=${_firmware_state_value//[[:space:]]/}
    [[ "$_firmware_state_value" =~ ^[0-9]+$ && $_firmware_state_value -le 255 ]] \
      || return 1
  fi
}

copy_firmware_variable_snapshot() {
  local name="$1" destination="$2" source parent first second rc=0
  source=$(firmware_variable_path "$name") || return 1
  validate_firmware_variable_file "$source" || return 1
  parent=$(dirname "$destination")
  validate_private_control_directory "$parent" || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  first=$(mktemp "${parent}/.${name}.first.XXXXXX") || return 1
  second=$(mktemp "${parent}/.${name}.second.XXXXXX") || {
    rm -f "$first"
    return 1
  }
  copy_firmware_variable_twice "$source" "$first" "$second" || rc=1
  rm -f "$second"
  if (( rc == 0 )); then
    { mv "$first" "$destination" && durable_sync "$parent"; } || rc=1
  fi
  (( rc == 0 )) || rm -f "$first"
  return "$rc"
}

# Two reads must agree and the source inode must not change while it is read.
copy_firmware_variable_twice() {
  local source="$1" first="$2" second="$3" identity
  identity=$(stat -Lc '%d:%i' "$source" 2>/dev/null) || return 1
  dd if="$source" of="$first" iflag=fullblock status=none 2>/dev/null || return 1
  dd if="$source" of="$second" iflag=fullblock status=none 2>/dev/null || return 1
  chmod 600 "$first" "$second" || return 1
  cmp -s "$first" "$second" || return 1
  [[ $(stat -Lc '%d:%i' "$source" 2>/dev/null) == "$identity" ]] || return 1
  validate_private_control_file "$first" || return 1
  inspect_raw_efivar_file "$first" || return 1
  durable_sync "$first"
}

read_firmware_machine_identity() {
  local root product_uuid field path value machine
  root=$(firmware_dmi_root_path) || return 1
  path_has_no_symlink_components "$root" || return 1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  path="${root}/product_uuid"
  path_has_no_symlink_components "$path" || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  IFS= read -r product_uuid < "$path" || return 1
  product_uuid=${product_uuid,,}
  [[ "$product_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ \
    && "$product_uuid" != 00000000-0000-0000-0000-000000000000 \
    && "$product_uuid" != ffffffff-ffff-ffff-ffff-ffffffffffff ]] || return 1
  machine=$(jq -cn --arg uuid "$product_uuid" '{product_uuid: $uuid, dmi: {}}') \
    || return 1
  for field in sys_vendor product_name product_version board_vendor board_name \
    board_version board_serial bios_vendor bios_version; do
    path="${root}/${field}"
    value=""
    if [[ -e "$path" || -L "$path" ]]; then
      path_has_no_symlink_components "$path" || return 1
      [[ -f "$path" && ! -L "$path" ]] || return 1
      IFS= read -r value < "$path" || return 1
      [[ "$value" != *[[:cntrl:]]* ]] || return 1
      machine=$(jq -c --arg field "$field" --arg value "$value" \
        '.dmi[$field] = $value' <<< "$machine") || return 1
    else
      machine=$(jq -c --arg field "$field" '.dmi[$field] = null' <<< "$machine") \
        || return 1
    fi
  done
  _firmware_product_uuid="$product_uuid"
  _firmware_machine_json="$machine"
}

firmware_variable_expected_attributes() {
  case "$1" in
    PK|KEK|db|dbx) printf '%s\n' "$EFI_ACTIVE_AUTH_ATTRIBUTES" ;;
    SetupMode|AuditMode|DeployedMode|SecureBoot) printf '%s\n' "$EFI_STATE_ATTRIBUTES" ;;
    *) return 1 ;;
  esac
}

firmware_variable_is_state() {
  case "$1" in
    SetupMode|AuditMode|DeployedMode|SecureBoot) return 0 ;;
    *) return 1 ;;
  esac
}

# The last inspected raw efivar carries the attributes variable $1 must have;
# a state variable must also hold a one-byte 0 or 1.
firmware_inspection_is_expected() {
  local name="$1" expected
  expected=$(firmware_variable_expected_attributes "$name") || return 1
  [[ "$_firmware_raw_attributes" == "$expected" ]] || return 1
  ! firmware_variable_is_state "$name" || [[ $_firmware_payload_size -eq 1 \
    && ( "$_firmware_state_value" == 0 || "$_firmware_state_value" == 1 ) ]]
}

inspect_firmware_variable_file() {
  inspect_raw_efivar_file "$2" || return 1
  firmware_inspection_is_expected "$1"
}

# Copies the current value of firmware variable $1 into the runtime directory
# and inspects it; the caller removes _firmware_current_file.
inspect_current_firmware_variable() {
  local name="$1" runtime
  _firmware_current_file=""
  ensure_firmware_runtime_dir || return 1
  runtime=$(firmware_runtime_dir_path) || return 1
  _firmware_current_file=$(mktemp -u "${runtime}/.${name}.XXXXXX") || return 1
  if ! read_current_firmware_variable "$name" "$_firmware_current_file" \
    || ! inspect_raw_efivar_file "$_firmware_current_file"; then
    rm -f "$_firmware_current_file"
    _firmware_current_file=""
    return 1
  fi
}

record_transaction_firmware_backup_attachment() {
  local backup_id="$1" status="$2" directory manifest_hash="" document current
  [[ "$_transaction_active" == true \
    && "$backup_id" == "$_transaction_id" \
    && ( "$status" == pending || "$status" == complete ) ]] || return 1
  directory=$(firmware_backup_path "$backup_id") || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  current=$(jq -r '.firmware_backup.status // ""' <<< "$_manifest_json") || return 1
  if [[ "$status" == pending ]]; then
    [[ -z "$current" ]] || return 1
  else
    [[ "$current" == pending ]] || return 1
    validate_private_control_directory "$directory" || return 1
    validate_private_control_file "${directory}/manifest.json" || return 1
    manifest_hash=$(sha256_file "${directory}/manifest.json") || return 1
  fi
  document=$(jq -c --arg id "$backup_id" --arg path "$directory" \
    --arg status "$status" --arg manifest_hash "$manifest_hash" '
      .firmware_backup = {
        id: $id,
        path: $path,
        status: $status,
        manifest_sha256: (if $status == "complete" then $manifest_hash else null end)
      }
    ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

capture_prechange_firmware_set() {
  local backup_id="${1:-$_transaction_id}" root staging destination
  [[ "$_transaction_active" == true && "$backup_id" == "$_transaction_id" ]] || return 1
  validate_efivarfs_mount || return 1
  read_firmware_machine_identity || return 1
  ensure_firmware_backup_root || return 1
  root=$(firmware_backup_root_path) || return 1
  destination=$(firmware_backup_path "$backup_id") || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  staging="${root}/.${backup_id}.tmp"
  [[ ! -e "$staging" && ! -L "$staging" ]] || return 1
  record_transaction_firmware_backup_attachment "$backup_id" pending || return 1
  install -d -m 700 "$staging" || return 1
  if ! validate_private_control_directory "$staging" \
    || ! stage_firmware_backup "$backup_id" "$staging" \
    || ! durable_sync "$staging" \
    || ! mv "$staging" "$destination"; then
    rm -rf "$staging"
    return 1
  fi
  durable_sync "$root" || return 1
  record_transaction_firmware_backup_attachment "$backup_id" complete || return 1
  _firmware_backup_id="$backup_id"
  _firmware_backup_dir="$destination"
}

# Copies every firmware variable into the staging directory, reads each one
# again to prove the set did not change meanwhile, and writes the manifest.
stage_firmware_backup() {
  local backup_id="$1" staging="$2" name presence raw_file entry variables='{}'
  local manifest timestamp boot_id
  local -a names=(PK KEK db dbx SetupMode AuditMode DeployedMode SecureBoot)
  local -A observed_presence=() observed_hash=()

  for name in "${names[@]}"; do
    presence=$(firmware_variable_presence "$name") || return 1
    observed_presence["$name"]=$presence
    if [[ "$presence" == present ]]; then
      raw_file="${staging}/${name}.efivar"
      copy_firmware_variable_snapshot "$name" "$raw_file" || return 1
      inspect_firmware_variable_file "$name" "$raw_file" || return 1
      observed_hash["$name"]=$_firmware_raw_hash
      entry=$(jq -cn --arg file "${name}.efivar" \
        --arg raw_hash "$_firmware_raw_hash" \
        --arg payload_hash "$_firmware_payload_hash" \
        --argjson attributes "$_firmware_raw_attributes" \
        --argjson payload_size "$_firmware_payload_size" \
        --arg state_value "$_firmware_state_value" '{
          present: true,
          raw_file: $file,
          attributes: $attributes,
          raw_sha256: $raw_hash,
          payload_sha256: $payload_hash,
          payload_size: $payload_size,
          value: (if $state_value == "" then null else ($state_value | tonumber) end)
        }') || return 1
    else
      ! firmware_variable_is_state "$name" || return 1
      entry='{"present":false,"raw_file":null,"attributes":null,"raw_sha256":null,"payload_sha256":null,"payload_size":null,"value":null}'
    fi
    variables=$(jq -c --arg name "$name" --argjson entry "$entry" \
      '.[$name] = $entry' <<< "$variables") || return 1
  done

  enrollment_failpoint "after-firmware-snapshot" || return 1

  for name in "${names[@]}"; do
    presence=$(firmware_variable_presence "$name") || return 1
    [[ "$presence" == "${observed_presence[$name]}" ]] || return 1
    [[ "$presence" == present ]] || continue
    raw_file="${staging}/.${name}.verify"
    copy_firmware_variable_snapshot "$name" "$raw_file" || return 1
    inspect_raw_efivar_file "$raw_file" || return 1
    rm -f "$raw_file"
    [[ "$_firmware_raw_hash" == "${observed_hash[$name]}" ]] || return 1
  done

  timestamp=$(utc_timestamp) || return 1
  boot_id=$(boot_id_value) || return 1
  manifest=$(jq -cn --argjson schema "$FIRMWARE_BACKUP_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg id "$backup_id" \
    --arg timestamp "$timestamp" --arg boot_id "$boot_id" \
    --argjson machine "$_firmware_machine_json" --argjson variables "$variables" '{
      schema_version: $schema,
      writer_version: $version,
      backup_id: $id,
      created_at: $timestamp,
      boot_id: $boot_id,
      machine: $machine,
      variables: $variables
    }') || return 1
  printf '%s\n' "$manifest" | atomic_write_control_file "${staging}/manifest.json" 600
}

validate_firmware_backup() {
  local backup_id="$1" directory manifest name present raw_file attributes
  local raw_sha256 payload_sha256 payload_size value
  local -a names=(PK KEK db dbx SetupMode AuditMode DeployedMode SecureBoot)
  directory=$(firmware_backup_path "$backup_id") || return 1
  validate_private_control_directory "$directory" || return 1
  manifest="${directory}/manifest.json"
  validate_private_control_file "$manifest" || return 1
  jq -e --arg id "$backup_id" --argjson schema "$FIRMWARE_BACKUP_SCHEMA_VERSION" '
    type == "object" and
    keys == ["backup_id","boot_id","created_at","machine","schema_version","variables","writer_version"] and
    .schema_version == $schema and
    (.writer_version | type == "string" and length > 0) and .backup_id == $id and
    (.created_at | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    (.boot_id | type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
    (.machine | type == "object" and keys == ["dmi","product_uuid"]) and
    (.machine.product_uuid | type == "string" and
      test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
    (.machine.dmi | type == "object" and
      keys == ["bios_vendor","bios_version","board_name","board_serial","board_vendor","board_version","product_name","product_version","sys_vendor"] and
      all(.[]; . == null or (type == "string" and
        (explode | all(. >= 32 and . != 127))))) and
    (.variables | type == "object" and
      keys == ["AuditMode","DeployedMode","KEK","PK","SecureBoot","SetupMode","db","dbx"] and
      all(.[];
        type == "object" and
        keys == ["attributes","payload_sha256","payload_size","present","raw_file","raw_sha256","value"] and
        (.present | type == "boolean") and
        (if .present then
          (.raw_file | type == "string") and
          (.attributes | type == "number" and . >= 0 and floor == .) and
          (.raw_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.payload_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
          (.payload_size | type == "number" and . >= 0 and floor == .) and
          (.value == null or (.value | type == "number" and . >= 0 and . <= 255 and floor == .))
        else
          .raw_file == null and .attributes == null and .raw_sha256 == null and
          .payload_sha256 == null and .payload_size == null and .value == null
        end)))
  ' "$manifest" >/dev/null || return 1
  _firmware_backup_json=$(jq -c . "$manifest") || return 1
  read_firmware_machine_identity || return 1
  [[ "$(jq -r '.machine.product_uuid' <<< "$_firmware_backup_json")" == \
    "$_firmware_product_uuid" ]] || return 1

  for name in "${names[@]}"; do
    read_lines present raw_file attributes raw_sha256 payload_sha256 payload_size \
      value < <(jq -r --arg name "$name" '
        .variables[$name] | .present, (.raw_file // ""), (.attributes // ""),
          (.raw_sha256 // ""), (.payload_sha256 // ""), (.payload_size // ""),
          (.value // "")
      ' <<< "$_firmware_backup_json") || return 1
    if [[ "$present" == true ]]; then
      [[ "$raw_file" == "${name}.efivar" ]] || return 1
      raw_file="${directory}/${raw_file}"
      validate_private_control_file "$raw_file" || return 1
      inspect_firmware_variable_file "$name" "$raw_file" || return 1
      [[ "$_firmware_raw_attributes" == "$attributes" \
        && "$_firmware_raw_hash" == "$raw_sha256" \
        && "$_firmware_payload_hash" == "$payload_sha256" \
        && "$_firmware_payload_size" == "$payload_size" ]] || return 1
      ! firmware_variable_is_state "$name" \
        || [[ "$_firmware_state_value" == "$value" ]] || return 1
    else
      ! firmware_variable_is_state "$name" || return 1
      [[ ! -e "${directory}/${name}.efivar" \
        && ! -L "${directory}/${name}.efivar" ]] || return 1
    fi
  done
  _firmware_backup_id="$backup_id"
  _firmware_backup_dir="$directory"
}

read_current_firmware_variable() {
  local name="$1" destination="$2" presence
  presence=$(firmware_variable_presence "$name") || return 2
  [[ "$presence" == present ]] || return 1
  copy_firmware_variable_snapshot "$name" "$destination"
}

current_firmware_backup_status() {
  local backup_id="$1" name="$2" expected_present expected_hash current_present
  validate_firmware_backup "$backup_id" || return 1
  read_lines expected_present expected_hash < <(jq -r --arg name "$name" \
    '.variables[$name] | .present, (.raw_sha256 // "")' \
    <<< "$_firmware_backup_json") || return 1
  current_present=$(firmware_variable_presence "$name") || return 1
  if [[ "$expected_present" == false || "$current_present" == absent ]]; then
    if [[ "$expected_present" == false && "$current_present" == absent ]]; then
      printf 'exact\n'
    else
      printf 'different\n'
    fi
    return 0
  fi
  inspect_current_firmware_variable "$name" || return 1
  rm -f "$_firmware_current_file"
  if [[ "$_firmware_raw_hash" == "$expected_hash" ]]; then
    printf 'exact\n'
  else
    printf 'different\n'
  fi
}

current_firmware_variable_matches_backup() {
  [[ "$(current_firmware_backup_status "$1" "$2")" == exact ]]
}

le32_hex_to_decimal() {
  local value="$1"
  [[ "$value" =~ ^[0-9a-f]{8}$ ]] || return 1
  printf '%u\n' "$((16#${value:6:2}${value:4:2}${value:2:2}${value:0:2}))"
}

validate_esl_x509_entry() {
  local file="$1" offset="$2" length="$3" temporary normalized parent
  command -v openssl >/dev/null 2>&1 || return 1
  parent=$(dirname "$file")
  temporary=$(mktemp "${parent}/.x509.XXXXXX") || return 1
  normalized=$(mktemp "${parent}/.x509-normalized.XXXXXX") || {
    rm -f "$temporary"
    return 1
  }
  if ! dd if="$file" of="$temporary" bs=1 skip="$offset" count="$length" \
    status=none 2>/dev/null \
    || ! openssl x509 -inform DER -in "$temporary" -outform DER \
      -out "$normalized" >/dev/null 2>&1 \
    || ! cmp -s "$temporary" "$normalized"; then
    rm -f "$temporary" "$normalized"
    return 1
  fi
  rm -f "$temporary" "$normalized"
}

canonicalize_esl() {
  local input="$1" output="$2" parent temporary
  validate_private_control_file "$input" || return 1
  parent=$(dirname "$output")
  validate_private_control_directory "$parent" || return 1
  temporary=$(mktemp "${parent}/.$(basename "$output").XXXXXX") || return 1
  if ! canonical_esl_rows "$input" > "$temporary" \
    || ! LC_ALL=C sort -o "$temporary" "$temporary" \
    || ! chmod 600 "$temporary" \
    || ! durable_sync "$temporary" \
    || ! mv "$temporary" "$output"; then
    rm -f "$temporary"
    return 1
  fi
  durable_sync "$parent"
}

# Prints one "type size owner data_size data_sha256" row per signature entry
# of an EFI_SIGNATURE_LIST sequence; only X.509 and SHA-256 lists are accepted.
canonical_esl_rows() {
  local input="$1" hex total offset=0 type list_size header_size signature_size
  local entries_size entry_count index entry_offset data_offset data_size data_hash
  hex=$(od -An -v -t x1 "$input" 2>/dev/null | tr -d '[:space:]') || return 1
  [[ "$hex" =~ ^([0-9a-f]{2})+$ ]] || return 1
  total=$(stat -Lc '%s' "$input" 2>/dev/null) || return 1
  [[ "$total" =~ ^[0-9]+$ && ${#hex} -eq $((total * 2)) ]] || return 1
  while (( offset < total )); do
    (( total - offset >= 28 )) || return 1
    type=${hex:$((offset * 2)):32}
    list_size=$(le32_hex_to_decimal "${hex:$(((offset + 16) * 2)):8}") || return 1
    header_size=$(le32_hex_to_decimal "${hex:$(((offset + 20) * 2)):8}") || return 1
    signature_size=$(le32_hex_to_decimal "${hex:$(((offset + 24) * 2)):8}") || return 1
    (( list_size >= 28 && list_size <= total - offset )) || return 1
    (( header_size == 0 && signature_size > 16 )) || return 1
    entries_size=$((list_size - 28 - header_size))
    (( entries_size > 0 && entries_size % signature_size == 0 )) || return 1
    case "$type" in
      "$EFI_SIGNATURE_X509_BYTES") data_size=$((signature_size - 16)) ;;
      "$EFI_SIGNATURE_SHA256_BYTES")
        (( signature_size == 48 )) || return 1
        data_size=32
        ;;
      *) return 1 ;;
    esac
    entry_count=$((entries_size / signature_size))
    for ((index = 0; index < entry_count; index++)); do
      entry_offset=$((offset + 28 + header_size + index * signature_size))
      data_offset=$((entry_offset + 16))
      if [[ "$type" == "$EFI_SIGNATURE_X509_BYTES" ]]; then
        validate_esl_x509_entry "$input" "$data_offset" "$data_size" || return 1
      fi
      data_hash=$(dd if="$input" bs=1 skip="$data_offset" count="$data_size" \
        status=none 2>/dev/null | sha256sum) || return 1
      data_hash=${data_hash%% *}
      [[ "$data_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
      printf '%s\t%s\t%s\t%s\t%s\n' "$type" "$signature_size" \
        "${hex:$((entry_offset * 2)):32}" "$data_size" "$data_hash"
    done
    offset=$((offset + list_size))
  done
  (( offset == total ))
}

canonical_entries_have_duplicates() {
  local file="$1" duplicates
  [[ -s "$file" ]] || return 1
  duplicates=$(LC_ALL=C uniq -d "$file") || return 1
  [[ -n "$duplicates" ]]
}

canonical_entries_are_subset() {
  local current="$1" planned="$2" missing
  [[ -f "$current" && -f "$planned" ]] || return 1
  missing=$(LC_ALL=C comm -23 "$current" "$planned") || return 1
  [[ -z "$missing" ]]
}

canonical_entries_are_equal() {
  cmp -s "$1" "$2"
}

validate_sbctl_enrollment_boundary() {
  local package version executable config owner path
  version=$(producer_package_version sbctl) || return 1
  [[ "$version" == "$SUPPORTED_SBCTL_VERSION" ]] || return 1
  package="sbctl ${version}"
  executable=$(command -v sbctl) || return 1
  executable=$(readlink -f "$executable" 2>/dev/null) || return 1
  [[ "$executable" == /usr/bin/sbctl ]] || return 1
  validate_control_file "$executable" || return 1
  owner=$(producer_file_owner_package "$executable") || return 1
  [[ "$owner" == sbctl ]] || return 1
  config=$(sbctl_config_path) || return 1
  if [[ -e "$config" || -L "$config" ]]; then
    parse_sbctl_config "$config" true || return 1
    _sbctl_config_state=present
    _sbctl_config_hash=$(sha256_file "$config") || return 1
  else
    [[ ! -d /usr/share/secureboot ]] || return 1
    _sbctl_keydir=/var/lib/sbctl/keys
    _sbctl_guid_path=/var/lib/sbctl/GUID
    _sbctl_config_state=absent
    _sbctl_config_hash=""
  fi
  path_has_no_symlink_components "$_sbctl_keydir" || return 1
  path_has_no_symlink_components "$_sbctl_guid_path" || return 1
  [[ "$_sbctl_keydir" == /var/lib/sbctl/keys \
    && "$_sbctl_guid_path" == /var/lib/sbctl/GUID ]] || return 1
  for path in /var/lib /var/lib/sbctl "$_sbctl_keydir"; do
    if [[ -e "$path" || -L "$path" ]]; then
      validate_control_directory "$path" || return 1
    fi
  done
  if [[ -e "$_sbctl_guid_path" || -L "$_sbctl_guid_path" ]]; then
    validate_control_file "$_sbctl_guid_path" || return 1
  fi
  _sbctl_package_identity="$package"
  _sbctl_executable="$executable"
  _sbctl_executable_hash=$(sha256_file "$executable") || return 1
}

run_sbctl_enrollment() {
  [[ -n "$_sbctl_executable" ]] || return 1
  "$_sbctl_executable" "$@"
}

validate_local_key_pair() {
  local private_key="$1" certificate="$2" private_public certificate_public remainder
  validate_private_control_file "$private_key" || return 1
  validate_private_control_file "$certificate" || return 1
  private_public=$(openssl pkey -in "$private_key" -pubout -outform DER 2>/dev/null \
    | sha256sum) || return 1
  read -r private_public remainder <<< "$private_public"
  certificate_public=$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum) || return 1
  read -r certificate_public remainder <<< "$certificate_public"
  [[ "$private_public" =~ ^[0-9a-f]{64}$ \
    && "$private_public" == "$certificate_public" ]]
}

validate_local_key_hierarchy() {
  local -a guid=()
  validate_control_file "$_sbctl_guid_path" || return 1
  mapfile -t guid < "$_sbctl_guid_path" || return 1
  [[ ${#guid[@]} -eq 1 \
    && ${guid[0],,} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || return 1
  validate_local_key_pair "$_sbctl_keydir/PK/PK.key" \
    "$_sbctl_keydir/PK/PK.pem" || return 1
  validate_local_key_pair "$_sbctl_keydir/KEK/KEK.key" \
    "$_sbctl_keydir/KEK/KEK.pem" || return 1
  validate_local_key_pair "$_sbctl_keydir/db/db.key" \
    "$_sbctl_keydir/db/db.pem"
}

classify_local_sbctl_keys() {
  local path present=0 absent=0
  local -a paths
  validate_sbctl_enrollment_boundary || return 1
  paths=("$_sbctl_guid_path"
    "$_sbctl_keydir/PK/PK.key" "$_sbctl_keydir/PK/PK.pem"
    "$_sbctl_keydir/KEK/KEK.key" "$_sbctl_keydir/KEK/KEK.pem"
    "$_sbctl_keydir/db/db.key" "$_sbctl_keydir/db/db.pem")
  for path in "${paths[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
      if [[ "$path" == "$_sbctl_guid_path" ]]; then
        validate_control_file "$path" || return 1
      else
        validate_private_control_file "$path" || return 1
      fi
      present=$((present + 1))
    else
      absent=$((absent + 1))
    fi
  done
  if [[ $present -eq 0 ]]; then
    _local_key_state=none
  elif [[ $absent -eq 0 ]]; then
    _local_key_state=complete
    validate_local_key_hierarchy || return 1
  else
    _local_key_state=partial
  fi
}

create_local_sbctl_keys() {
  local directory path parent
  local -a paths
  classify_local_sbctl_keys || return 1
  [[ "$_local_key_state" == none ]] || return 1
  parent=$(dirname "$_sbctl_keydir")
  if [[ ! -e "$parent" && ! -L "$parent" ]]; then
    validate_control_directory "$(dirname "$parent")" || return 1
    install -d -m 700 "$parent" || return 1
    durable_sync "$(dirname "$parent")" || return 1
  fi
  validate_private_control_directory "$parent" || return 1
  for directory in "$_sbctl_keydir" "$_sbctl_keydir/PK" \
    "$_sbctl_keydir/KEK" "$_sbctl_keydir/db"; do
    if [[ -e "$directory" || -L "$directory" ]]; then
      validate_control_directory "$directory" || return 1
    else
      install -d -m 700 "$directory" || return 1
      durable_sync "$(dirname "$directory")" || return 1
    fi
  done
  paths=("$_sbctl_guid_path"
    "$_sbctl_keydir/PK/PK.key" "$_sbctl_keydir/PK/PK.pem"
    "$_sbctl_keydir/KEK/KEK.key" "$_sbctl_keydir/KEK/KEK.pem"
    "$_sbctl_keydir/db/db.key" "$_sbctl_keydir/db/db.pem")
  for path in "${paths[@]}"; do
    transaction_backup_file "$path" true || return 1
  done
  run_sbctl_enrollment create-keys || return 1
  classify_local_sbctl_keys || return 1
  [[ "$_local_key_state" == complete ]]
}

write_backup_payload() {
  local raw="$1" output="$2" parent temporary
  validate_private_control_file "$raw" || return 1
  parent=$(dirname "$output")
  validate_private_control_directory "$parent" || return 1
  temporary=$(mktemp "${parent}/.payload.XXXXXX") || return 1
  if ! dd if="$raw" of="$temporary" bs=1 skip=4 status=none 2>/dev/null \
    || ! chmod 600 "$temporary" \
    || ! durable_sync "$temporary" \
    || ! mv "$temporary" "$output" \
    || ! durable_sync "$parent"; then
    rm -f "$temporary"
    return 1
  fi
}

canonicalize_backup_database() {
  local backup_id="$1" name="$2" output="$3" directory present raw payload
  validate_firmware_backup "$backup_id" || return 1
  directory="$_firmware_backup_dir"
  present=$(jq -r --arg name "$name" '.variables[$name].present' \
    <<< "$_firmware_backup_json") || return 1
  if [[ "$present" == false ]]; then
    : | atomic_write_control_file "$output" 600
    return
  fi
  raw="${directory}/${name}.efivar"
  payload="$(dirname "$output")/.${name}.payload"
  write_backup_payload "$raw" "$payload" || return 1
  canonicalize_esl "$payload" "$output" || {
    rm -f "$payload"
    return 1
  }
  rm -f "$payload"
}

# The hash of the single X.509 entry in a canonical PK entries file.
single_x509_pk_hash() {
  local file="$1" type size owner data_size hash
  [[ $(wc -l < "$file") -eq 1 ]] || return 1
  IFS=$'\t' read -r type size owner data_size hash < "$file" || return 1
  [[ "$type" == "$EFI_SIGNATURE_X509_BYTES" && "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$hash"
}

validate_planned_trust_preserves_backup() {
  local backup_id="$1" plan_dir="$2" runtime current_dir rc=0
  _validated_current_pk_hash=""
  ensure_firmware_runtime_dir || return 1
  runtime=$(firmware_runtime_dir_path) || return 1
  current_dir=$(mktemp -d "${runtime}/current-plan.XXXXXX") || return 1
  planned_trust_preserves_backup "$backup_id" "$plan_dir" "$current_dir" \
    && planned_trust_backup_match_is_whole "$plan_dir" "$current_dir" || rc=1
  rm -rf "$current_dir" || return 1
  return "$rc"
}

# Every backed-up KEK and db entry must survive in the plan, and both the
# current and the planned PK must be one X.509 certificate.
planned_trust_preserves_backup() {
  local backup_id="$1" plan_dir="$2" current_dir="$3" name current planned
  chmod 700 "$current_dir" || return 1
  validate_private_control_directory "$current_dir" || return 1
  for name in PK KEK db; do
    current="${current_dir}/${name}.entries"
    planned="${plan_dir}/${name}.entries"
    canonicalize_backup_database "$backup_id" "$name" "$current" || return 1
    validate_private_control_file "$current" || return 1
    validate_private_control_file "$planned" || return 1
    ! canonical_entries_have_duplicates "$planned" || return 1
  done
  single_x509_pk_hash "${plan_dir}/PK.entries" >/dev/null || return 1
  canonical_entries_are_subset "${current_dir}/KEK.entries" \
    "${plan_dir}/KEK.entries" || return 1
  canonical_entries_are_subset "${current_dir}/db.entries" \
    "${plan_dir}/db.entries" || return 1
  _validated_current_pk_hash=$(single_x509_pk_hash "${current_dir}/PK.entries") \
    || return 1
}

readonly PARTIAL_TRUST_PLAN_MESSAGE='The firmware already holds part of the planned trust set; restore the factory Secure Boot keys in firmware settings, then run setup again'

# The F0-F3 frontiers need every planned database to differ from its backup.
# A backup that already holds the whole plan is an enrolled firmware, which
# setup observes as enrolled and never writes; a backup that holds part of it
# has no representable enrollment sequence and is refused before the plan is
# recorded.
planned_trust_backup_match_is_whole() {
  local plan_dir="$1" current_dir="$2" name matches=0
  for name in PK KEK db; do
    if canonical_entries_are_equal "${current_dir}/${name}.entries" \
      "${plan_dir}/${name}.entries"; then
      matches=$((matches + 1))
    fi
  done
  [[ $matches -eq 0 || $matches -eq 3 ]] && return 0
  fail "$PARTIAL_TRUST_PLAN_MESSAGE"
  return 1
}

# Enrollment starts at F0 only when every planned database differs from the
# firmware's; a partial match is refused before any firmware instruction, and
# a database that cannot be read is reported as unreadable, never as a match.
planned_trust_is_representable() {
  local backup_id="$1" name status
  for name in PK KEK db; do
    status=$(current_database_plan_status "$backup_id" "$name") || {
      fail "Could not read the firmware's ${name} database to compare it with the plan"
      return 1
    }
    [[ "$status" == different ]] || {
      fail "$PARTIAL_TRUST_PLAN_MESSAGE"
      return 1
    }
  done
}

build_enrollment_plan() {
  local backup_id="$1" backup_dir plan_dir name manifest timestamp config_hash key_records='{}'
  local file hash canonical_hash count path
  validate_firmware_backup "$backup_id" || return 1
  validate_sbctl_enrollment_boundary || return 1
  classify_local_sbctl_keys || return 1
  [[ "$_local_key_state" == complete ]] || return 1
  backup_dir="$_firmware_backup_dir"
  plan_dir="${backup_dir}/plan"
  [[ ! -e "$plan_dir" && ! -L "$plan_dir" ]] || return 1
  install -d -m 700 "$plan_dir" || return 1
  validate_private_control_directory "$plan_dir" || return 1
  if ! (umask 077; cd "$plan_dir" \
    && run_sbctl_enrollment enroll-keys -m -f --export esl); then
    return 1
  fi
  for name in PK KEK db; do
    file="${plan_dir}/${name}.esl"
    validate_control_file "$file" || return 1
    chmod 600 "$file" || return 1
    validate_private_control_file "$file" || return 1
    canonicalize_esl "$file" "${plan_dir}/${name}.entries" || return 1
  done
  validate_planned_trust_preserves_backup "$backup_id" "$plan_dir" || return 1

  for path in "$_sbctl_guid_path" \
    "$_sbctl_keydir/PK/PK.key" "$_sbctl_keydir/PK/PK.pem" \
    "$_sbctl_keydir/KEK/KEK.key" "$_sbctl_keydir/KEK/KEK.pem" \
    "$_sbctl_keydir/db/db.key" "$_sbctl_keydir/db/db.pem"; do
    if [[ "$path" == "$_sbctl_guid_path" ]]; then
      validate_control_file "$path" || return 1
    else
      validate_private_control_file "$path" || return 1
    fi
    hash=$(sha256_file "$path") || return 1
    key_records=$(jq -c --arg path "$path" --arg hash "$hash" \
      '.[$path] = $hash' <<< "$key_records") || return 1
  done
  manifest='{}'
  for name in PK KEK db; do
    hash=$(sha256_file "${plan_dir}/${name}.esl") || return 1
    canonical_hash=$(sha256_file "${plan_dir}/${name}.entries") || return 1
    count=$(wc -l < "${plan_dir}/${name}.entries") || return 1
    manifest=$(jq -c --arg name "$name" --arg hash "$hash" \
      --arg canonical_hash "$canonical_hash" --argjson count "$count" '
        .[$name] = {
          esl_file: ($name + ".esl"),
          esl_sha256: $hash,
          entries_file: ($name + ".entries"),
          entries_sha256: $canonical_hash,
          entry_count: $count
        }
      ' <<< "$manifest") || return 1
  done
  timestamp=$(utc_timestamp) || return 1
  config_hash=${_sbctl_config_hash:-}
  file=$(jq -cn --argjson schema "$ENROLLMENT_PLAN_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" --arg backup_id "$backup_id" \
    --arg timestamp "$timestamp" --arg package "$_sbctl_package_identity" \
    --arg executable "$_sbctl_executable" --arg executable_hash "$_sbctl_executable_hash" \
    --arg config_state "$_sbctl_config_state" --arg config_hash "$config_hash" \
    --arg keydir "$_sbctl_keydir" --arg guid "$_sbctl_guid_path" \
    --arg working_directory "$plan_dir" \
    --argjson keys "$key_records" --argjson variables "$manifest" '{
      schema_version: $schema,
      writer_version: $version,
      backup_id: $backup_id,
      created_at: $timestamp,
      command: [$executable, "enroll-keys", "-m", "-f", "--export", "esl"],
      working_directory: $working_directory,
      sbctl: {
        package: $package,
        executable: $executable,
        executable_sha256: $executable_hash,
        config_state: $config_state,
        config_sha256: (if $config_hash == "" then null else $config_hash end),
        keydir: $keydir,
        guid: $guid,
        key_sha256: $keys
      },
      variables: $variables,
      confirmation: null
    }') || return 1
  printf '%s\n' "$file" | atomic_write_control_file "${plan_dir}/manifest.json" 600 \
    || return 1
  durable_sync "$plan_dir"
}

# The plan manifest hash that a confirmation binds: everything but itself.
enrollment_plan_hash() {
  local hash
  hash=$(jq -c 'del(.confirmation)' "$1" | sha256sum) || return 1
  printf '%s\n' "${hash%% *}"
}

validate_enrollment_plan() {
  local backup_id="$1" require_confirmed="${2:-false}" plan_dir manifest name
  local config config_state expected_config_hash package executable executable_hash
  local keydir guid esl_file esl_hash entries_file entries_hash entry_count
  local hash key_path key_hash key_rows current_pk planned_pk key_count=0
  local -A expected_keys=()
  [[ "$require_confirmed" == true || "$require_confirmed" == false ]] || return 1
  validate_firmware_backup "$backup_id" || return 1
  validate_sbctl_enrollment_boundary || return 1
  plan_dir=$(firmware_plan_path "$backup_id") || return 1
  validate_private_control_directory "$plan_dir" || return 1
  manifest="${plan_dir}/manifest.json"
  validate_private_control_file "$manifest" || return 1
  jq -e --arg id "$backup_id" --arg executable "$_sbctl_executable" \
    --arg working_directory "$plan_dir" \
    --argjson schema "$ENROLLMENT_PLAN_SCHEMA_VERSION" '
    type == "object" and
    keys == ["backup_id","command","confirmation","created_at","sbctl","schema_version","variables","working_directory","writer_version"] and
    .schema_version == $schema and .backup_id == $id and
    (.writer_version | type == "string" and length > 0) and
    (.created_at | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    .working_directory == $working_directory and
    .command == [$executable, "enroll-keys", "-m", "-f", "--export", "esl"] and
    (.sbctl | type == "object" and
      keys == ["config_sha256","config_state","executable","executable_sha256","guid","key_sha256","keydir","package"]) and
    (.sbctl.package | type == "string" and length > 0) and
    (.sbctl.executable | type == "string" and startswith("/")) and
    (.sbctl.executable_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.sbctl.config_state == "present" or .sbctl.config_state == "absent") and
    (if .sbctl.config_state == "present" then
      (.sbctl.config_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    else .sbctl.config_sha256 == null end) and
    (.sbctl.keydir | type == "string" and startswith("/")) and
    (.sbctl.guid | type == "string" and startswith("/")) and
    (.sbctl.key_sha256 | type == "object" and
      all(to_entries[];
        (.key | type == "string" and startswith("/")) and
        (.value | type == "string" and test("^[0-9a-f]{64}$")))) and
    (.variables | type == "object" and keys == ["KEK","PK","db"] and
      all(.[];
        type == "object" and
        keys == ["entries_file","entries_sha256","entry_count","esl_file","esl_sha256"] and
        (.entries_file | type == "string") and
        (.entries_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.entry_count | type == "number" and . > 0 and floor == .) and
        (.esl_file | type == "string") and
        (.esl_sha256 | type == "string" and test("^[0-9a-f]{64}$")))) and
    (.confirmation == null or (
      (.confirmation | type == "object" and
        keys == ["accepted","confirmed_at","current_pk_sha256","pk_only_capability_confirmed","pk_replacement_confirmed","plan_sha256","planned_pk_sha256","retained_artifacts_acknowledged"]) and
      .confirmation.accepted == true and
      .confirmation.pk_replacement_confirmed == true and
      .confirmation.pk_only_capability_confirmed == true and
      .confirmation.retained_artifacts_acknowledged == true and
      (.confirmation.confirmed_at | type == "string" and
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      (.confirmation.current_pk_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.confirmation.planned_pk_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.confirmation.plan_sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
  ' "$manifest" >/dev/null || return 1
  read_lines config_state expected_config_hash package executable executable_hash \
    keydir guid < <(jq -r '
      .sbctl | .config_state, (.config_sha256 // ""), .package, .executable,
        .executable_sha256, .keydir, .guid
    ' "$manifest") || return 1
  config=$(sbctl_config_path) || return 1
  if [[ "$config_state" == present ]]; then
    [[ -e "$config" && "$(sha256_file "$config")" == "$expected_config_hash" ]] || return 1
  else
    [[ ! -e "$config" && ! -L "$config" && -z "$expected_config_hash" ]] || return 1
  fi
  [[ "$package" == "$_sbctl_package_identity" && "$executable" == "$_sbctl_executable" \
    && "$executable_hash" == "$_sbctl_executable_hash" \
    && "$keydir" == "$_sbctl_keydir" && "$guid" == "$_sbctl_guid_path" ]] || return 1
  for key_path in "$_sbctl_guid_path" \
    "$_sbctl_keydir/PK/PK.key" "$_sbctl_keydir/PK/PK.pem" \
    "$_sbctl_keydir/KEK/KEK.key" "$_sbctl_keydir/KEK/KEK.pem" \
    "$_sbctl_keydir/db/db.key" "$_sbctl_keydir/db/db.pem"; do
    expected_keys["$key_path"]=1
  done
  key_rows=$(jq -r '.sbctl.key_sha256 | to_entries[] | [.key,.value] | @tsv' \
    "$manifest") || return 1
  while IFS=$'\t' read -r key_path key_hash; do
    [[ -n "$key_path" && -n "${expected_keys[$key_path]:-}" ]] || return 1
    if [[ "$key_path" == "$_sbctl_guid_path" ]]; then
      validate_control_file "$key_path" || return 1
    else
      validate_private_control_file "$key_path" || return 1
    fi
    [[ "$(sha256_file "$key_path")" == "$key_hash" ]] || return 1
    key_count=$((key_count + 1))
  done <<< "$key_rows"
  [[ $key_count -eq 7 ]] || return 1
  validate_local_key_hierarchy || return 1
  for name in PK KEK db; do
    read_lines esl_file esl_hash entries_file entries_hash entry_count \
      < <(jq -r --arg name "$name" '
        .variables[$name] | .esl_file, .esl_sha256, .entries_file, .entries_sha256,
          .entry_count
      ' "$manifest") || return 1
    [[ "$esl_file" == "${name}.esl" && "$entries_file" == "${name}.entries" ]] \
      || return 1
    validate_private_control_file "${plan_dir}/${name}.esl" || return 1
    validate_private_control_file "${plan_dir}/${name}.entries" || return 1
    [[ $(sha256_file "${plan_dir}/${name}.esl") == "$esl_hash" \
      && $(sha256_file "${plan_dir}/${name}.entries") == "$entries_hash" \
      && $(wc -l < "${plan_dir}/${name}.entries") == "$entry_count" ]] || return 1
  done
  validate_planned_trust_preserves_backup "$backup_id" "$plan_dir" || return 1
  if jq -e '.confirmation != null' "$manifest" >/dev/null; then
    read_lines hash current_pk planned_pk < <(jq -r '
      .confirmation | .plan_sha256, .current_pk_sha256, .planned_pk_sha256
    ' "$manifest") || return 1
    [[ $(enrollment_plan_hash "$manifest") == "$hash" \
      && "$_validated_current_pk_hash" == "$current_pk" \
      && $(cut -f5 "${plan_dir}/PK.entries") == "$planned_pk" ]] || return 1
  elif [[ "$require_confirmed" == true ]]; then
    return 1
  fi
}

load_enrollment_pk_fingerprints() {
  local backup_id="$1" plan_dir
  validate_enrollment_plan "$backup_id" false || return 1
  plan_dir=$(firmware_plan_path "$backup_id") || return 1
  _enrollment_current_pk_hash="$_validated_current_pk_hash"
  _enrollment_planned_pk_hash=$(cut -f5 "${plan_dir}/PK.entries") || return 1
  [[ "$_enrollment_current_pk_hash" =~ ^[0-9a-f]{64}$ \
    && "$_enrollment_planned_pk_hash" =~ ^[0-9a-f]{64}$ ]]
}

record_enrollment_plan_confirmation() {
  local backup_id="$1" pk_replacement="${2:-}" pk_only="${3:-}" retained="${4:-}"
  local plan_dir manifest document timestamp hash current_pk planned_pk
  [[ "$_transaction_active" == true \
    && "$pk_replacement" == true && "$pk_only" == true && "$retained" == true ]] \
    || return 1
  validate_enrollment_plan "$backup_id" false || return 1
  plan_dir=$(firmware_plan_path "$backup_id") || return 1
  manifest="${plan_dir}/manifest.json"
  transaction_backup_file "$manifest" || return 1
  timestamp=$(utc_timestamp) || return 1
  hash=$(enrollment_plan_hash "$manifest") || return 1
  current_pk="$_validated_current_pk_hash"
  planned_pk=$(cut -f5 "${plan_dir}/PK.entries") || return 1
  [[ "$current_pk" =~ ^[0-9a-f]{64}$ && "$planned_pk" =~ ^[0-9a-f]{64}$ ]] \
    || return 1
  document=$(jq -c --arg timestamp "$timestamp" --arg hash "$hash" \
    --arg current_pk "$current_pk" --arg planned_pk "$planned_pk" '
    .confirmation = {
      accepted: true,
      confirmed_at: $timestamp,
      plan_sha256: $hash,
      current_pk_sha256: $current_pk,
      planned_pk_sha256: $planned_pk,
      pk_replacement_confirmed: true,
      pk_only_capability_confirmed: true,
      retained_artifacts_acknowledged: true
    }
  ' "$manifest") || return 1
  printf '%s\n' "$document" | atomic_write_control_file "$manifest" 600
}

revalidate_enrollment_plan_export() {
  local backup_id="$1" require_confirmed="${2:-true}" plan_dir runtime fresh name
  [[ "$require_confirmed" == true || "$require_confirmed" == false ]] || return 1
  validate_enrollment_plan "$backup_id" "$require_confirmed" || return 1
  plan_dir=$(firmware_plan_path "$backup_id") || return 1
  ensure_firmware_runtime_dir || return 1
  runtime=$(firmware_runtime_dir_path) || return 1
  fresh=$(mktemp -d "${runtime}/plan.XXXXXX") || return 1
  chmod 700 "$fresh" || return 1
  if ! (umask 077; cd "$fresh" \
    && run_sbctl_enrollment enroll-keys -m -f --export esl); then
    rm -rf "$fresh"
    return 1
  fi
  for name in PK KEK db; do
    chmod 600 "${fresh}/${name}.esl" 2>/dev/null || {
      rm -rf "$fresh"
      return 1
    }
    canonicalize_esl "${fresh}/${name}.esl" "${fresh}/${name}.entries" || {
      rm -rf "$fresh"
      return 1
    }
    canonical_entries_are_equal "${fresh}/${name}.entries" \
      "${plan_dir}/${name}.entries" || {
      rm -rf "$fresh"
      return 1
    }
  done
  rm -rf "$fresh"
}

read_current_firmware_modes() {
  local name
  for name in SetupMode AuditMode DeployedMode SecureBoot; do
    inspect_current_firmware_variable "$name" || return 1
    rm -f "$_firmware_current_file"
    firmware_inspection_is_expected "$name" || return 1
    case "$name" in
      SetupMode) _setup_mode=$_firmware_state_value ;;
      AuditMode) _audit_mode=$_firmware_state_value ;;
      DeployedMode) _deployed_mode=$_firmware_state_value ;;
      SecureBoot) _secure_boot_mode=$_firmware_state_value ;;
    esac
  done
  [[ "$_setup_mode" != 1 || "$_secure_boot_mode" != 1 ]]
}

classify_setup_state() {
  local keys="$1" enrollment="$2" setup="$3" secure="$4"
  [[ "$keys" == none || "$keys" == complete || "$keys" == partial ]] || return 1
  [[ "$enrollment" == absent || "$enrollment" == partial || "$enrollment" == exact ]] \
    || return 1
  [[ "$setup" == 0 || "$setup" == 1 ]] || return 1
  [[ "$secure" == 0 || "$secure" == 1 ]] || return 1
  [[ "$keys" != partial && ! ( "$setup" == 1 && "$secure" == 1 ) ]] || return 1
  if [[ "$keys" == none ]]; then
    [[ "$enrollment" == absent && "$setup" == 0 ]] || return 1
    _setup_state=1
  elif [[ "$enrollment" == exact ]]; then
    [[ "$setup" == 0 ]] || return 1
    if [[ "$secure" == 1 ]]; then _setup_state=5; else _setup_state=4; fi
  else
    if [[ "$setup" == 1 ]]; then _setup_state=2; else _setup_state=3; fi
  fi
  printf '%s\n' "$_setup_state"
}

# Test seam: suites replace this to stub the Windows encryption gate.
secure_boot_windows_gate() {
  windows_encryption_gate
}

prepare_secure_boot_preflight() {
  local preparation_consent="${1:-}"
  [[ "$preparation_consent" == true ]] || return 1
  validate_efivarfs_mount || return 1
  classify_local_sbctl_keys || return 1
  [[ "$_local_key_state" == none || "$_local_key_state" == complete ]] || return 1
  read_current_firmware_modes || return 1
  [[ "$_setup_mode" == 0 && "$_audit_mode" == 0 \
    && "$_deployed_mode" == 0 ]] || return 1
  secure_boot_windows_gate
}

prepare_secure_boot_transaction() {
  transaction_phase_start "backup-firmware" || return 1
  capture_prechange_firmware_set || return 1
  transaction_phase_complete "backup-firmware" || return 1

  transaction_phase_start "create-keys" || return 1
  classify_local_sbctl_keys || return 1
  if [[ "$_local_key_state" == none ]]; then
    create_local_sbctl_keys || return 1
  else
    [[ "$_local_key_state" == complete ]] || return 1
    validate_local_key_hierarchy || return 1
  fi
  transaction_phase_complete "create-keys" || return 1

  transaction_phase_start "build-enrollment-plan" || return 1
  build_enrollment_plan "$_firmware_backup_id" || return 1
  transaction_phase_complete "build-enrollment-plan"
}

prepare_state_aware_setup() {
  local preparation_consent="${1:-}"
  [[ "$preparation_consent" == true ]] || return 1
  run_lifecycle_transaction_with_preflight "prepare-secure-boot" "disabled" \
    "unmanaged,disabled" prepare_secure_boot_preflight prepare_secure_boot_transaction \
    "$preparation_consent"
}

activate_enrollment_plan_preflight() {
  local backup_id="$1" pk_replacement="${2:-}" pk_only="${3:-}" retained="${4:-}"
  [[ "$pk_replacement" == true && "$pk_only" == true && "$retained" == true ]] \
    || return 1
  lifecycle_activation_environment_is_ready || return 1
  validate_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" false || return 1
  revalidate_enrollment_plan_export "$backup_id" false || return 1
  read_current_firmware_modes || return 1
  [[ "$_setup_mode" == 0 && "$_audit_mode" == 0 \
    && "$_deployed_mode" == 0 && "$_secure_boot_mode" == 0 ]] || return 1
  current_firmware_variable_matches_backup "$backup_id" PK || return 1
  current_firmware_variable_matches_backup "$backup_id" KEK || return 1
  current_firmware_variable_matches_backup "$backup_id" db || return 1
  current_firmware_variable_matches_backup "$backup_id" dbx || return 1
  secure_boot_windows_gate || return 1
  artifact_repair_preflight
}

activate_enrollment_plan_transaction() {
  local backup_id="$1" pk_replacement="$2" pk_only="$3" retained="$4"
  transaction_phase_start "confirm-enrollment-plan" || return 1
  record_enrollment_plan_confirmation "$backup_id" "$pk_replacement" "$pk_only" \
    "$retained" || return 1
  transaction_phase_complete "confirm-enrollment-plan" || return 1
  transaction_phase_start "bind-enrollment-plan" || return 1
  bind_enrollment_transaction "$backup_id" || return 1
  transaction_phase_complete "bind-enrollment-plan" || return 1
  enrollment_failpoint "before-activation-artifact-repair" || return 1
  repair_boot_artifacts || return 1
  revalidate_enrollment_plan_export "$backup_id"
}

activate_confirmed_enrollment_plan() {
  local backup_id="$1" pk_replacement="${2:-}" pk_only="${3:-}" retained="${4:-}"
  [[ "$pk_replacement" == true && "$pk_only" == true && "$retained" == true ]] \
    || return 1
  run_lifecycle_transaction_with_preflight "activate-secure-boot-plan" "active" \
    "disabled,active" activate_enrollment_plan_preflight \
    activate_enrollment_plan_transaction "$backup_id" "$pk_replacement" "$pk_only" \
    "$retained"
}

current_database_plan_status() {
  local backup_id="$1" name="$2" plan_dir presence raw payload entries status=""
  plan_dir=$(firmware_plan_path "$backup_id") || return 1
  presence=$(firmware_variable_presence "$name") || return 1
  if [[ "$presence" == absent ]]; then
    printf 'different\n'
    return 0
  fi
  inspect_current_firmware_variable "$name" || return 1
  raw="$_firmware_current_file"
  payload="${raw}.payload"
  entries="${raw}.entries"
  if firmware_inspection_is_expected "$name" \
    && write_backup_payload "$raw" "$payload" \
    && canonicalize_esl "$payload" "$entries"; then
    status=different
    if canonical_entries_are_equal "$entries" "${plan_dir}/${name}.entries"; then
      status=exact
    fi
  fi
  rm -f "$raw" "$payload" "$entries"
  [[ -n "$status" ]] || return 1
  printf '%s\n' "$status"
}

compare_current_database_to_plan() {
  [[ "$(current_database_plan_status "$1" "$2")" == exact ]]
}

classify_firmware_enrollment_frontier() {
  local backup_id="$1" pk_presence pk_backup pk_plan kek_backup kek_plan
  local db_backup db_plan dbx_backup
  validate_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" true || return 1
  read_current_firmware_modes || return 1
  pk_presence=$(firmware_variable_presence PK) || return 1
  pk_backup=$(current_firmware_backup_status "$backup_id" PK) || return 1
  pk_plan=$(current_database_plan_status "$backup_id" PK) || return 1
  kek_backup=$(current_firmware_backup_status "$backup_id" KEK) || return 1
  kek_plan=$(current_database_plan_status "$backup_id" KEK) || return 1
  db_backup=$(current_firmware_backup_status "$backup_id" db) || return 1
  db_plan=$(current_database_plan_status "$backup_id" db) || return 1
  dbx_backup=$(current_firmware_backup_status "$backup_id" dbx) || return 1

  if [[ "$_audit_mode" != 0 || "$_deployed_mode" != 0 \
    || "$_secure_boot_mode" != 0 || "$dbx_backup" != exact ]]; then
    printf 'invalid\n'
    return 0
  fi
  if [[ "$_setup_mode" == 1 && "$pk_presence" == absent \
    && "$pk_backup" == different && "$pk_plan" == different ]]; then
    if [[ "$kek_backup" == exact && "$kek_plan" == different \
      && "$db_backup" == exact && "$db_plan" == different ]]; then
      printf 'F0\n'
    elif [[ "$kek_backup" == exact && "$kek_plan" == different \
      && "$db_backup" == different && "$db_plan" == exact ]]; then
      printf 'F1\n'
    elif [[ "$kek_backup" == different && "$kek_plan" == exact \
      && "$db_backup" == different && "$db_plan" == exact ]]; then
      printf 'F2\n'
    else
      printf 'invalid\n'
    fi
    return 0
  fi
  if [[ "$_setup_mode" == 0 && "$pk_presence" == present \
    && "$pk_backup" == different && "$pk_plan" == exact \
    && "$kek_backup" == different && "$kek_plan" == exact \
    && "$db_backup" == different && "$db_plan" == exact ]]; then
    printf 'F3\n'
  else
    printf 'invalid\n'
  fi
}

setup_backup_id_from_lifecycle_json() {
  local document="$1" required_operation="${2:-any}" state reference transaction_id
  local operation backup_id prior_path prior_hash prior_document depth=0
  local -A visited=()
  [[ "$required_operation" == any || "$required_operation" == activation ]] || return 1
  while (( depth < MAX_SETUP_LINEAGE_MANIFESTS )); do
    validate_lifecycle_json "$document" || return 1
    validate_lifecycle_document_references "$document" || return 1
    state=$(jq -r '.state' <<< "$document") || return 1
    case "$state" in
      active|disabled)
        reference=$(jq -c '.last_transaction' <<< "$document") || return 1
        [[ "$reference" != null ]] || return 1
        transaction_id=$(jq -r '.id' <<< "$reference") || return 1
        ;;
      recovery-required)
        reference=$(jq -c '.transaction.root_incident' <<< "$document") || return 1
        validate_incident_reference "$reference" || return 1
        transaction_id=$(jq -r '.id' <<< "$reference") || return 1
        ;;
      *) return 1 ;;
    esac
    [[ -z "${visited[$transaction_id]:-}" ]] || return 1
    visited["$transaction_id"]=1
    read_transaction_manifest "$transaction_id" || return 1
    operation=$(jq -r '.operation' <<< "$_manifest_json") || return 1
    if [[ $(jq -r '.status' <<< "$_manifest_json") == completed \
      && ( "$operation" == unconfigure || "$operation" == unconfigure-recovery ) ]]; then
      return 1
    fi
    if [[ $(jq -r '.status' <<< "$_manifest_json") == completed \
      && $(jq -r '.firmware_backup.status // ""' <<< "$_manifest_json") == complete ]]; then
      if [[ ( "$required_operation" == activation \
          && "$operation" == activate-secure-boot-plan ) \
        || ( "$required_operation" == any \
          && ( "$operation" == prepare-secure-boot \
            || "$operation" == activate-secure-boot-plan \
            || "$operation" == enroll-secure-boot \
            || "$operation" == firmware-recovery ) ) ]]; then
        backup_id=$(jq -r '.firmware_backup.id' <<< "$_manifest_json") || return 1
        validate_firmware_backup "$backup_id" || return 2
        validate_enrollment_plan "$backup_id" false || return 2
        if [[ "$required_operation" == activation ]]; then
          printf '%s\n' "$transaction_id"
        else
          printf '%s\n' "$backup_id"
        fi
        return 0
      fi
    fi
    [[ $(jq -r '.backups[0].kind' <<< "$_manifest_json") == prior-lifecycle ]] \
      || return 1
    prior_path=$(jq -r '.backups[0].path' <<< "$_manifest_json") || return 1
    prior_hash=$(jq -r '.backups[0].sha256' <<< "$_manifest_json") || return 1
    validate_private_control_file "$prior_path" || return 1
    [[ $(sha256_file "$prior_path") == "$prior_hash" ]] || return 1
    prior_document=$(read_control_document "$prior_path") || return 1
    document="$prior_document"
    depth=$((depth + 1))
  done
  return 1
}

current_setup_backup_id() {
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == disabled || "$_lifecycle_state" == active ]] || return 1
  setup_backup_id_from_lifecycle_json "$_lifecycle_json"
}

lifecycle_references_firmware_backup() {
  local backup_id="$1" current
  current=$(current_setup_backup_id) || return 1
  [[ "$current" == "$backup_id" ]]
}

observe_setup_state() {
  local backup_id="${1:-}" name status enrollment pk_presence matches=0
  classify_local_sbctl_keys || return 1
  read_current_firmware_modes || return 1
  pk_presence=$(firmware_variable_presence PK) || return 1
  if [[ "$_setup_mode" == 1 ]]; then
    [[ "$pk_presence" == absent ]] || return 1
  else
    [[ "$pk_presence" == present ]] || return 1
  fi
  if [[ "$_local_key_state" == none ]]; then
    read_lifecycle || return 1
    [[ "$_lifecycle_state" == unmanaged || "$_lifecycle_state" == disabled ]] || return 1
    classify_setup_state none absent "$_setup_mode" "$_secure_boot_mode"
    return
  fi
  [[ "$_local_key_state" == complete && -n "$backup_id" ]] || return 1
  lifecycle_references_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" false || return 1
  [[ "$_audit_mode" == 0 && "$_deployed_mode" == 0 \
    && $(current_firmware_backup_status "$backup_id" dbx) == exact ]] || return 1
  for name in PK KEK db; do
    status=$(current_database_plan_status "$backup_id" "$name") || return 1
    [[ "$status" == exact || "$status" == different ]] || return 1
    [[ "$status" != exact ]] || matches=$((matches + 1))
  done
  if [[ $matches -eq 3 ]]; then
    enrollment=exact
  elif [[ $matches -eq 0 ]]; then
    enrollment=absent
  else
    enrollment=partial
  fi
  classify_setup_state complete "$enrollment" "$_setup_mode" "$_secure_boot_mode"
}

validate_setup_instruction_boundary() {
  local backup_id="$1" state="$2" name
  [[ "$state" == 3 || "$state" == 4 ]] || return 1
  validate_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" true || return 1
  revalidate_enrollment_plan_export "$backup_id" || return 1
  read_current_firmware_modes || return 1
  [[ "$_setup_mode" == 0 && "$_audit_mode" == 0 \
    && "$_deployed_mode" == 0 && "$_secure_boot_mode" == 0 ]] || return 1
  current_firmware_variable_matches_backup "$backup_id" dbx || return 1
  if [[ "$state" == 3 ]]; then
    for name in PK KEK db; do
      current_firmware_variable_matches_backup "$backup_id" "$name" || return 1
    done
    planned_trust_is_representable "$backup_id" || return 1
  else
    for name in PK KEK db; do
      compare_current_database_to_plan "$backup_id" "$name" || return 1
    done
  fi
  artifact_repair_preflight || return 1
  verify_all_efi_artifacts "$_repair_config_checksum" || return 1
  secure_boot_windows_gate
}

current_pk_is_absent() {
  [[ "$(firmware_variable_presence PK)" == absent ]]
}

bind_enrollment_transaction() {
  local backup_id="$1" backup_dir plan_dir backup_manifest plan_manifest
  local backup_hash plan_hash variables dbx_present dbx_hash document
  [[ "$_transaction_active" == true ]] || return 1
  validate_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" true || return 1
  backup_dir="$_firmware_backup_dir"
  plan_dir=$(firmware_plan_path "$backup_id") || return 1
  backup_manifest="${backup_dir}/manifest.json"
  plan_manifest="${plan_dir}/manifest.json"
  backup_hash=$(sha256_file "$backup_manifest") || return 1
  plan_hash=$(sha256_file "$plan_manifest") || return 1
  variables=$(jq -c '.variables | with_entries(.value = {
      esl_sha256: .value.esl_sha256,
      entries_sha256: .value.entries_sha256
    })' "$plan_manifest") || return 1
  dbx_present=$(jq -r '.variables.dbx.present' <<< "$_firmware_backup_json") || return 1
  dbx_hash=$(jq -r '.variables.dbx.raw_sha256 // ""' <<< "$_firmware_backup_json") \
    || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.status' <<< "$_manifest_json") == transition \
    && $(jq -r '.firmware_backup == null and .enrollment_plan == null' \
      <<< "$_manifest_json") == true ]] || return 1
  document=$(jq -c --arg backup_id "$backup_id" --arg backup_path "$backup_dir" \
    --arg backup_hash "$backup_hash" --arg plan_path "$plan_dir" \
    --arg plan_hash "$plan_hash" --argjson variables "$variables" \
    --argjson dbx_present "$dbx_present" --arg dbx_hash "$dbx_hash" '
      .firmware_backup = {
        id: $backup_id,
        path: $backup_path,
        status: "complete",
        manifest_sha256: $backup_hash
      } |
      .enrollment_plan = {
        backup_id: $backup_id,
        path: $plan_path,
        manifest_sha256: $plan_hash,
        variables: $variables,
        dbx: {
          present: $dbx_present,
          raw_sha256: (if $dbx_present then $dbx_hash else null end)
        }
      }
    ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

validate_enrollment_transaction_binding() {
  local backup_id="$1" backup_dir plan_dir backup_manifest plan_manifest name
  [[ "$_transaction_active" == true ]] || return 1
  validate_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" true || return 1
  backup_dir="$_firmware_backup_dir"
  plan_dir=$(firmware_plan_path "$backup_id") || return 1
  backup_manifest="${backup_dir}/manifest.json"
  plan_manifest="${plan_dir}/manifest.json"
  read_transaction_manifest "$_transaction_id" || return 1
  [[ "$(jq -r '.firmware_backup.id' <<< "$_manifest_json")" == "$backup_id" \
    && "$(jq -r '.firmware_backup.path' <<< "$_manifest_json")" == "$backup_dir" \
    && "$(jq -r '.firmware_backup.status' <<< "$_manifest_json")" == complete \
    && "$(jq -r '.firmware_backup.manifest_sha256' <<< "$_manifest_json")" == \
      "$(sha256_file "$backup_manifest")" \
    && "$(jq -r '.enrollment_plan.backup_id' <<< "$_manifest_json")" == "$backup_id" \
    && "$(jq -r '.enrollment_plan.path' <<< "$_manifest_json")" == "$plan_dir" \
    && "$(jq -r '.enrollment_plan.manifest_sha256' <<< "$_manifest_json")" == \
      "$(sha256_file "$plan_manifest")" ]] || return 1
  for name in PK KEK db; do
    [[ "$(jq -r --arg name "$name" \
      '.enrollment_plan.variables[$name].esl_sha256' <<< "$_manifest_json")" == \
        "$(jq -r --arg name "$name" '.variables[$name].esl_sha256' "$plan_manifest")" \
      && "$(jq -r --arg name "$name" \
        '.enrollment_plan.variables[$name].entries_sha256' <<< "$_manifest_json")" == \
        "$(jq -r --arg name "$name" '.variables[$name].entries_sha256' \
          "$plan_manifest")" ]] || return 1
  done
  [[ "$(jq -r '.enrollment_plan.dbx.present' <<< "$_manifest_json")" == \
      "$(jq -r '.variables.dbx.present' "$backup_manifest")" \
    && "$(jq -r '.enrollment_plan.dbx.raw_sha256 // ""' <<< "$_manifest_json")" == \
      "$(jq -r '.variables.dbx.raw_sha256 // ""' "$backup_manifest")" ]]
}

firmware_ledger_expected_frontier() {
  local document="$1"
  jq -r '
    reduce .firmware_writes[] as $write (
      "F0";
      if $write.readback_status == "verified" then
        if . == "F0" then "F1" elif . == "F1" then "F2"
        elif . == "F2" then "F3" else "invalid" end
      elif $write.readback_status == "unchanged" then .
      elif $write.readback_status == "pending" then
        if ($write.hierarchy == "db" and . == "F0") then "pending-F0-F1"
        elif ($write.hierarchy == "KEK" and . == "F1") then "pending-F1-F2"
        elif ($write.hierarchy == "PK" and . == "F2") then "pending-F2-F3"
        else "invalid" end
      else "invalid" end
    )
  ' <<< "$document"
}

firmware_ledger_matches_frontier() {
  local document="$1" frontier="$2" expected
  expected=$(firmware_ledger_expected_frontier "$document") || return 1
  case "$expected" in
    F0|F1|F2|F3) [[ "$frontier" == "$expected" ]] ;;
    pending-F0-F1) [[ "$frontier" == F0 || "$frontier" == F1 ]] ;;
    pending-F1-F2) [[ "$frontier" == F1 || "$frontier" == F2 ]] ;;
    pending-F2-F3) [[ "$frontier" == F2 || "$frontier" == F3 ]] ;;
    *) return 1 ;;
  esac
}

validate_firmware_recovery_authority() {
  local prior_path prior_lifecycle activation_id activation_manifest backup_id
  local root_binding previous_binding frontier rollback_policy
  [[ "$_recovery_target_state" == active \
    && "$_recovery_producer_reference" == null ]] || return 1
  jq -e '
    .kind == "root" and .operation == "enroll-secure-boot" and
    .target_state == "active" and .prior_state == "active" and
    .domain_records.producer == null
  ' <<< "$_recovery_root_manifest_json" >/dev/null || return 1

  prior_path=$(jq -r '.backups[0].path' <<< "$_recovery_root_manifest_json") || return 1
  prior_lifecycle=$(read_control_document "$prior_path") || return 1
  validate_lifecycle_json "$prior_lifecycle" || return 1
  validate_lifecycle_document_references "$prior_lifecycle" || return 1
  jq -e '.state == "active" and .transaction == null' \
    <<< "$prior_lifecycle" >/dev/null || return 1
  activation_id=$(setup_backup_id_from_lifecycle_json "$prior_lifecycle" activation) \
    || return 1
  read_transaction_manifest "$activation_id" || return 1
  activation_manifest="$_manifest_json"
  jq -e '
    .kind == "root" and .operation == "activate-secure-boot-plan" and
    .target_state == "active" and .status == "completed" and
    .firmware_backup.status == "complete" and .enrollment_plan != null and
    .firmware_writes == []
  ' <<< "$activation_manifest" >/dev/null || return 1
  backup_id=$(jq -r '.firmware_backup.id' <<< "$activation_manifest") || return 1
  validate_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" true || return 1

  root_binding=$(jq -c '{firmware_backup, enrollment_plan}' \
    <<< "$_recovery_root_manifest_json") || return 1
  previous_binding=$(jq -c '{firmware_backup, enrollment_plan}' \
    <<< "$_recovery_previous_manifest_json") || return 1
  jq -en --argjson authority "$activation_manifest" --argjson root "$root_binding" \
    --argjson previous "$previous_binding" '
      def binding_is_authorized($binding):
        ($binding.firmware_backup == null and $binding.enrollment_plan == null) or
        ($binding.firmware_backup == $authority.firmware_backup and
          $binding.enrollment_plan == $authority.enrollment_plan);
      binding_is_authorized($root) and binding_is_authorized($previous)
    ' >/dev/null || return 1
  if [[ $(jq -r '.firmware_backup == null' \
    <<< "$_recovery_previous_manifest_json") == true ]]; then
    [[ $(jq -r '.firmware_writes == []' \
      <<< "$_recovery_previous_manifest_json") == true ]] || return 1
  fi

  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  if [[ "$frontier" != F0 && "$frontier" != F1 && "$frontier" != F2 \
    && "$frontier" != F3 ]]; then
    fail "observed firmware trust state is outside the recoverable frontier"
    return 1
  fi
  if [[ $(jq -r '.firmware_writes[-1].readback_status // ""' \
    <<< "$_recovery_previous_manifest_json") != pending ]]; then
    if ! firmware_ledger_matches_frontier "$_recovery_previous_manifest_json" \
      "$frontier"; then
      fail "firmware write evidence contradicts the observed trust frontier"
      return 1
    fi
  fi
  rollback_policy=$(jq -r '.file_rollback_policy' \
    <<< "$_recovery_previous_manifest_json") || return 1
  if [[ "$rollback_policy" == restore ]]; then
    [[ "$frontier" == F0 \
      && $(jq -r '.firmware_writes == []' \
        <<< "$_recovery_previous_manifest_json") == true ]] || return 1
  else
    [[ "$rollback_policy" == preserve ]] || return 1
  fi
  _firmware_recovery_backup_id="$backup_id"
}

load_firmware_recovery_context() {
  load_recovery_context || return $?
  [[ $(recovery_operation_for_root_manifest "$_recovery_root_manifest_json") == \
    firmware-recovery ]] || return 1
  validate_firmware_recovery_authority
}

record_firmware_write_start() {
  local hierarchy="$1" document timestamp next attempt_count
  [[ "$hierarchy" == db || "$hierarchy" == KEK || "$hierarchy" == PK ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  next=$(jq -r '
    reduce .firmware_writes[] as $write (
      "db";
      if $write.readback_status == "verified" then
        if . == "db" then "KEK" elif . == "KEK" then "PK" else "complete" end
      elif $write.readback_status == "unchanged" then .
      else "blocked"
      end
    )
  ' <<< "$_manifest_json") || return 1
  [[ "$next" == "$hierarchy" ]] || return 1
  attempt_count=$(jq -r --arg hierarchy "$hierarchy" \
    '[.firmware_writes[] | select(.hierarchy == $hierarchy)] | length' \
    <<< "$_manifest_json") || return 1
  if (( attempt_count >= MAX_FIRMWARE_HIERARCHY_ATTEMPTS )); then
    fail "firmware write retry limit reached for ${hierarchy}"
    return 1
  fi
  [[ $(jq -r '.file_rollback_policy' <<< "$_manifest_json") == preserve \
    ]] || return 1
  json_is '.enrollment_plan != null' "$_manifest_json" || return 1
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -c --arg hierarchy "$hierarchy" --arg timestamp "$timestamp" '
    .firmware_writes += [{
      hierarchy: $hierarchy,
      started_at: $timestamp,
      command_exit_code: null,
      readback_status: "pending",
      completed_at: null
    }]
  ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

record_firmware_write_command_result() {
  local hierarchy="$1" command_rc="$2" document
  [[ "$hierarchy" == db || "$hierarchy" == KEK || "$hierarchy" == PK ]] || return 1
  [[ "$command_rc" =~ ^[0-9]+$ && "$command_rc" -le 255 ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ "$(jq -r '.firmware_writes[-1].hierarchy' <<< "$_manifest_json")" == \
      "$hierarchy" \
    && "$(jq -r '.firmware_writes[-1].readback_status' <<< "$_manifest_json")" == \
      pending \
    && "$(jq -r '.firmware_writes[-1].command_exit_code == null' \
      <<< "$_manifest_json")" == true ]] || return 1
  document=$(jq -c --argjson command_rc "$command_rc" \
    '.firmware_writes[-1].command_exit_code = $command_rc' \
    <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

record_firmware_write_result() {
  local hierarchy="$1" readback_status="$2" timestamp document
  [[ "$hierarchy" == db || "$hierarchy" == KEK || "$hierarchy" == PK ]] || return 1
  [[ "$readback_status" == unchanged || "$readback_status" == verified \
    || "$readback_status" == failed ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  [[ "$(jq -r '.firmware_writes[-1].hierarchy' <<< "$_manifest_json")" == \
      "$hierarchy" \
    && "$(jq -r '.firmware_writes[-1].readback_status' <<< "$_manifest_json")" == \
      pending ]] || return 1
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -c --arg readback_status "$readback_status" --arg timestamp "$timestamp" '
      .firmware_writes[-1].readback_status = $readback_status |
      .firmware_writes[-1].completed_at = $timestamp
    ' <<< "$_manifest_json") || return 1
  write_transaction_manifest_json "$document"
}

revalidate_firmware_write_boundary() {
  local backup_id="$1" hierarchy="$2" frontier expected
  validate_enrollment_transaction_binding "$backup_id" || return 1
  revalidate_enrollment_plan_export "$backup_id" || return 1
  case "$hierarchy" in
    db) expected=F0 ;;
    KEK) expected=F1 ;;
    PK) expected=F2 ;;
    *) return 1 ;;
  esac
  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  [[ "$frontier" == "$expected" ]]
}

enrollment_preflight() {
  local backup_id="$1"
  validate_firmware_backup "$backup_id" || return 1
  validate_enrollment_plan "$backup_id" true || return 1
  revalidate_enrollment_plan_export "$backup_id" || return 1
  read_current_firmware_modes || return 1
  [[ "$_setup_mode" == 1 && "$_audit_mode" == 0 \
    && "$_deployed_mode" == 0 && "$_secure_boot_mode" == 0 ]] || return 1
  current_pk_is_absent || return 1
  current_firmware_variable_matches_backup "$backup_id" KEK || return 1
  current_firmware_variable_matches_backup "$backup_id" db || return 1
  current_firmware_variable_matches_backup "$backup_id" dbx || return 1
  planned_trust_is_representable "$backup_id" || return 1
  secure_boot_windows_gate || return 1
  artifact_repair_preflight || return 1
  _enrollment_backup_id="$backup_id"
}

apply_enrollment_hierarchy() {
  local hierarchy="$1"
  [[ "$hierarchy" == db || "$hierarchy" == KEK || "$hierarchy" == PK ]] || return 1
  run_sbctl_enrollment enroll-keys -m -f --partial "$hierarchy"
}

# A first enrollment requires sbctl to succeed; a recovery retry accepts a
# verified readback even when the command itself failed.
run_enrollment_write_phase() {
  local backup_id="$1" hierarchy="$2" recovery="${3:-false}"
  local command_rc=0 frontier readback_status
  [[ "$recovery" == true || "$recovery" == false ]] || return 1
  transaction_phase_start "enroll-${hierarchy,,}" || return 1
  revalidate_firmware_write_boundary "$backup_id" "$hierarchy" || return 1
  if [[ "$hierarchy" == db ]]; then
    preserve_transaction_files_on_failure || return 1
  fi
  record_firmware_write_start "$hierarchy" || return 1
  enrollment_failpoint "before-${hierarchy,,}-write" || return 1
  apply_enrollment_hierarchy "$hierarchy" || command_rc=$?
  enrollment_failpoint "after-${hierarchy,,}-command" || return 1
  record_firmware_write_command_result "$hierarchy" "$command_rc" || return 1
  enrollment_failpoint "after-${hierarchy,,}-command-result" || return 1
  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  case "${hierarchy}:${frontier}" in
    db:F0|KEK:F1|PK:F2) readback_status=unchanged ;;
    db:F1|KEK:F2|PK:F3) readback_status=verified ;;
    *) readback_status=failed ;;
  esac
  record_firmware_write_result "$hierarchy" "$readback_status" || return 1
  [[ "$readback_status" == verified ]] || return 1
  [[ "$recovery" == true || $command_rc -eq 0 ]] || return 1
  transaction_phase_complete "enroll-${hierarchy,,}"
}

persist_firmware_enrollment_proof() {
  local backup_id="$1" frontier timestamp writes writes_hash document
  [[ "$_transaction_active" == true ]] || return 1
  validate_enrollment_transaction_binding "$backup_id" || return 1
  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  [[ "$frontier" == F3 ]] || return 1
  read_current_firmware_modes || return 1
  [[ "$_setup_mode" == 0 && "$_audit_mode" == 0 \
    && "$_deployed_mode" == 0 && "$_secure_boot_mode" == 0 ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  jq -e '
    .domain_records.final_proof != null and
    (all(.firmware_writes[];
      .readback_status == "verified" or .readback_status == "unchanged")) and
    [.firmware_writes[] | select(.readback_status == "verified") | .hierarchy] ==
      ["db","KEK","PK"]
  ' <<< "$_manifest_json" >/dev/null || return 1
  timestamp=$(utc_timestamp) || return 1
  writes=$(jq -cS '.firmware_writes' <<< "$_manifest_json") || return 1
  writes_hash=$(sha256_text "$writes") || return 1
  document=$(jq -cn \
      --argjson schema "$FIRMWARE_PROOF_SCHEMA_VERSION" \
      --arg version "$OMASECBOOT_VERSION" \
      --arg id "$_transaction_id" \
      --arg timestamp "$timestamp" \
      --arg writes_hash "$writes_hash" \
      --argjson setup_mode "$_setup_mode" \
      --argjson audit_mode "$_audit_mode" \
      --argjson deployed_mode "$_deployed_mode" \
      --argjson secure_boot_mode "$_secure_boot_mode" \
      --argjson manifest "$_manifest_json" '{
        schema_version: $schema,
        writer_version: $version,
        transaction_id: $id,
        proved_at: $timestamp,
        firmware_backup: {
          id: $manifest.firmware_backup.id,
          manifest_sha256: $manifest.firmware_backup.manifest_sha256,
          path: $manifest.firmware_backup.path
        },
        enrollment_plan: {
          backup_id: $manifest.enrollment_plan.backup_id,
          manifest_sha256: $manifest.enrollment_plan.manifest_sha256,
          path: $manifest.enrollment_plan.path
        },
        variables: {
          PK: {entries_sha256: $manifest.enrollment_plan.variables.PK.entries_sha256},
          KEK: {entries_sha256: $manifest.enrollment_plan.variables.KEK.entries_sha256},
          db: {entries_sha256: $manifest.enrollment_plan.variables.db.entries_sha256},
          dbx: $manifest.enrollment_plan.dbx
        },
        modes: {
          SetupMode: $setup_mode,
          AuditMode: $audit_mode,
          DeployedMode: $deployed_mode,
          SecureBoot: $secure_boot_mode
        },
        firmware_writes_sha256: $writes_hash,
        artifact_proof: $manifest.domain_records.final_proof
      }') || return 1
  persist_transaction_domain_record firmware firmware-proof.json \
    "$FIRMWARE_PROOF_SCHEMA_VERSION" validate_firmware_proof_json '["proved_at"]' \
    "$document"
}

enroll_planned_trust_set() {
  local backup_id="$1" frontier
  [[ "$backup_id" == "$_enrollment_backup_id" ]] || return 1

  transaction_phase_start "bind-enrollment-plan" || return 1
  bind_enrollment_transaction "$backup_id" || return 1
  transaction_phase_complete "bind-enrollment-plan" || return 1

  repair_boot_artifacts || return 1
  enrollment_failpoint "after-enrollment-artifact-repair" || return 1

  run_enrollment_write_phase "$backup_id" db || return 1
  run_enrollment_write_phase "$backup_id" KEK || return 1
  run_enrollment_write_phase "$backup_id" PK || return 1

  transaction_phase_start "prove-enrolled-trust" || return 1
  validate_enrollment_transaction_binding "$backup_id" || return 1
  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  [[ "$frontier" == F3 ]] || return 1
  verify_all_efi_artifacts "$_repair_config_checksum" || return 1
  persist_firmware_enrollment_proof "$backup_id" || return 1
  transaction_phase_complete "prove-enrolled-trust"
}

reconcile_pending_firmware_write() {
  local backup_id="$1" hierarchy frontier readback_status
  read_transaction_manifest "$_transaction_id" || return 1
  [[ $(jq -r '.firmware_writes[-1].readback_status // ""' \
    <<< "$_manifest_json") == pending ]] || return 0
  hierarchy=$(jq -r '.firmware_writes[-1].hierarchy' <<< "$_manifest_json") || return 1
  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  case "${hierarchy}:${frontier}" in
    db:F0|KEK:F1|PK:F2) readback_status=unchanged ;;
    db:F1|KEK:F2|PK:F3) readback_status=verified ;;
    db:F2|db:F3|KEK:F0|KEK:F3|PK:F0|PK:F1) readback_status=failed ;;
    *) return 1 ;;
  esac
  record_firmware_write_result "$hierarchy" "$readback_status" || return 1
  [[ "$readback_status" != failed ]]
}

firmware_recovery_transaction() {
  local backup_id="$1" frontier
  read_transaction_manifest "$_transaction_id" || return 1
  if json_is '.firmware_backup == null' "$_manifest_json"; then
    transaction_phase_start "bind-enrollment-plan" || return 1
    bind_enrollment_transaction "$backup_id" || return 1
    transaction_phase_complete "bind-enrollment-plan" || return 1
  else
    validate_enrollment_transaction_binding "$backup_id" || return 1
  fi

  transaction_phase_start "reconcile-firmware-write" || return 1
  reconcile_pending_firmware_write "$backup_id" || return 1
  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  firmware_ledger_matches_frontier "$_manifest_json" "$frontier" || return 1
  transaction_phase_complete "reconcile-firmware-write" || return 1

  artifact_repair_preflight || return 1
  repair_boot_artifacts || return 1
  enrollment_failpoint "after-recovery-artifact-repair" || return 1
  validate_enrollment_transaction_binding "$backup_id" || return 1
  revalidate_enrollment_plan_export "$backup_id" || return 1

  while true; do
    frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
    read_transaction_manifest "$_transaction_id" || return 1
    firmware_ledger_matches_frontier "$_manifest_json" "$frontier" || return 1
    case "$frontier" in
      F0) run_enrollment_write_phase "$backup_id" db true || return 1 ;;
      F1) run_enrollment_write_phase "$backup_id" KEK true || return 1 ;;
      F2) run_enrollment_write_phase "$backup_id" PK true || return 1 ;;
      F3) break ;;
      *) return 1 ;;
    esac
  done

  transaction_phase_start "prove-enrolled-trust" || return 1
  validate_enrollment_transaction_binding "$backup_id" || return 1
  [[ $(classify_firmware_enrollment_frontier "$backup_id") == F3 ]] || return 1
  verify_all_efi_artifacts "$_repair_config_checksum" || return 1
  persist_firmware_enrollment_proof "$backup_id" || return 1
  transaction_phase_complete "prove-enrolled-trust"
}

# Firmware recovery may still write trust entries, so it needs the Windows
# preparation gate as a fresh observation before an attempt is consumed; an
# incident already at F3 only reconciles and proves, and needs no gate.
firmware_recovery_windows_gate() {
  local backup_id="$1" frontier
  frontier=$(classify_firmware_enrollment_frontier "$backup_id") || return 1
  [[ "$frontier" != F3 ]] || return 0
  secure_boot_windows_gate
}

run_firmware_recovery_locked() {
  boot_locks_are_held || return 1
  load_firmware_recovery_context || return $?
  firmware_recovery_windows_gate "$_firmware_recovery_backup_id" || return 1
  run_recovery_attempt_locked firmware-recovery firmware_recovery_transaction \
    "firmware recovery" "$_firmware_recovery_backup_id"
}

run_enrollment() {
  local backup_id="$1"
  run_lifecycle_transaction_with_preflight "enroll-secure-boot" "active" "active" \
    enrollment_preflight enroll_planned_trust_set "$backup_id"
}
