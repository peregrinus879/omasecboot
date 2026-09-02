#!/bin/bash
# shellcheck disable=SC2154 # Lifecycle globals come from the sourced lifecycle module.
# OmaSecBoot: boot-artifact producer leases and registry-selected recovery

readonly SUPPORTED_LIMINE_MKINITCPIO_VERSION=1.38.0-1
readonly SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION=1.31.0-1

_producer_class=""
_producer_subtype=""
_producer_owner_pid=""
_producer_owner_kind=""
_producer_owner_identity=""
_producer_caller=""
_producer_restore=false
_producer_no_mutex=false
_producer_lock_policy=""
_producer_service_policy=quiesce
_producer_service_owner_json=null
_producer_targets_json='[]'
_producer_restore_marker_json=null
_producer_record_json=""
_producer_backups_json='[]'
_producer_baseline_reference=""
_producer_transaction_id=""
_producer_reference=""
_producer_captured_service=""

reset_producer_context() {
  _producer_class=""
  _producer_subtype=""
  _producer_owner_pid=""
  _producer_owner_kind=""
  _producer_owner_identity=""
  _producer_caller=""
  _producer_restore=false
  _producer_no_mutex=false
  _producer_lock_policy=""
  _producer_service_policy=quiesce
  _producer_service_owner_json=null
  _producer_targets_json='[]'
  _producer_restore_marker_json=null
  _producer_record_json=""
  _producer_backups_json='[]'
  _producer_baseline_reference=""
  _producer_transaction_id=""
  _producer_reference=""
  _producer_captured_service=""
}

producer_automation_is_available() {
  producer_recovery_is_available && lifecycle_repair_is_available
}

read_package_producer_targets() {
  local line count=0 bytes=0 raw="" document invalid=false
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" || ${#line} -gt 4096 ]]; then
      invalid=true
      continue
    fi
    count=$((count + 1))
    bytes=$((bytes + ${#line} + 1))
    if (( count > MAX_PRODUCER_TARGETS || bytes > MAX_PRODUCER_TARGET_BYTES )); then
      invalid=true
      continue
    fi
    raw+="${line}"$'\n'
  done
  [[ "$invalid" == false ]] && (( count > 0 )) || return 1
  document=$(printf '%s' "$raw" | jq -Rsc '
    split("\n") | map(select(length > 0)) |
    if all(.[];
      length <= 4096 and (startswith("/") | not) and
      (explode | all(. >= 32 and . <= 126)))
    then sort | unique else error("unsafe package target") end
  ') || return 1
  [[ $(jq -r 'length' <<< "$document") -gt 0 ]] || return 1
  _producer_targets_json="$document"
}

drain_package_producer_targets() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do :; done
}

package_targets_change_pinned_producer() {
  local state
  state=$(jq -er '
    if index("limine-mkinitcpio-hook") != null or
      index("limine-snapper-sync") != null
    then "blocked" else "clear" end
  ' <<< "$_producer_targets_json") || return 2
  [[ "$state" == blocked ]]
}

find_root_process_ancestor() {
  local start_pid="$1" kind="$2" identity="$3" current parent loops=0
  current="$start_pid"
  while [[ "$current" =~ ^[0-9]+$ && "$current" -gt 0 && $loops -lt 256 ]]; do
    if [[ "$(process_effective_uid "$current" 2>/dev/null || true)" == \
      "$(control_owner_uid)" ]] \
      && process_matches_identity "$current" "$kind" "$identity"; then
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

set_producer_owner() {
  local pid="$1" kind="$2" identity="$3"
  [[ "$(process_effective_uid "$pid")" == "$(control_owner_uid)" ]] || return 1
  process_matches_identity "$pid" "$kind" "$identity" || return 1
  _producer_owner_pid="$pid"
  _producer_owner_kind="$kind"
  _producer_owner_identity="$identity"
}

resolve_package_producer_context() {
  local owner
  reset_producer_context
  owner=$(find_root_process_ancestor "$PPID" executable /usr/bin/pacman) || return 1
  set_producer_owner "$owner" executable /usr/bin/pacman || return 1
  _producer_class=package
  _producer_subtype="package-transaction"
  _producer_caller=pacman
  _producer_lock_policy=coordinator-lease
}

resolve_limine_producer_context() {
  resolve_limine_producer_process "$PPID"
}

resolve_limine_producer_process() {
  local owner="$1" wrapper
  [[ "$owner" =~ ^[1-9][0-9]*$ ]] || return 1
  reset_producer_context
  if process_runs_script "$owner" /usr/bin/limine-entry-tool; then
    set_producer_owner "$owner" script /usr/bin/limine-entry-tool || return 1
    process_cmdline_has_argument "$owner" --no-mutex && return 1
    _producer_class=limine
    _producer_subtype="entry-tool"
    _producer_caller=limine-entry-tool
    _producer_lock_policy=inherited
  elif process_runs_script "$owner" \
    /usr/share/libalpm/scripts/limine-mkinitcpio-install; then
    set_producer_owner "$owner" script \
      /usr/share/libalpm/scripts/limine-mkinitcpio-install || return 1
    _producer_class=limine
    _producer_subtype=uki-build
    _producer_caller=limine-mkinitcpio-install
    _producer_lock_policy=inherited
  elif process_runs_script "$owner" /usr/bin/limine-snapper-sync; then
    set_producer_owner "$owner" script /usr/bin/limine-snapper-sync || return 1
    if process_cmdline_has_argument "$owner" --restore \
      && process_cmdline_has_argument "$owner" --no-mutex; then
      _producer_class=restore
      _producer_subtype=full-restore
      _producer_restore=true
      _producer_no_mutex=true
      _producer_lock_policy=restore-window
      wrapper=$(process_parent_pid "$owner") || return 1
      if [[ "$(process_effective_uid "$wrapper" 2>/dev/null || true)" == \
        "$(control_owner_uid)" ]] \
        && process_runs_script "$wrapper" /usr/bin/limine-snapper-restore; then
        _producer_caller=limine-snapper-restore
      else
        _producer_caller=limine-snapper-sync
      fi
    else
      process_cmdline_has_argument "$owner" --restore && return 1
      process_cmdline_has_argument "$owner" --restore-kernels && return 1
      process_cmdline_has_argument "$owner" --no-mutex && return 1
      _producer_class=snapshot
      _producer_subtype=snapshot-sync
      _producer_caller=limine-snapper-sync
      _producer_lock_policy=inherited
    fi
  else
    return 1
  fi
  return 0
}

limine_vendor_config_dir() {
  printf '%s\n' /usr/share/limine-entry-tool.d
}

limine_system_config_path() {
  printf '%s\n' /etc/limine-entry-tool.conf
}

limine_system_config_dir() {
  printf '%s\n' /etc/limine-entry-tool.d
}

limine_snapper_config_path() {
  printf '%s\n' /etc/limine-snapper-sync.conf
}

machine_id_path() {
  printf '%s\n' /etc/machine-id
}

kernel_modules_dir() {
  printf '%s\n' /usr/lib/modules
}

producer_uefi_is_available() {
  [[ -d /sys/firmware/efi ]]
}

parse_pacman_query_version() {
  local package="$1" output="$2" version
  [[ "$package" =~ ^[A-Za-z0-9@+_.-]+$ \
    && "$output" == "$package "* && "$output" != *$'\n'* ]] || return 1
  version=${output#"$package "}
  [[ -n "$version" && ${#version} -le 255 && "$version" != *[[:space:]]* \
    && "$version" != *[$'\001'-$'\037'$'\177']* ]] || return 1
  printf '%s\n' "$version"
}

producer_package_version() {
  local package="$1" output
  validate_control_file /usr/bin/pacman || return 1
  output=$(/usr/bin/pacman -Q "$package" 2>/dev/null) || return 1
  parse_pacman_query_version "$package" "$output"
}

producer_compatibility_is_supported() {
  local version
  case "$_producer_class" in
    package|limine)
      version=$(producer_package_version limine-mkinitcpio-hook) || return 1
      [[ "$version" == "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" ]]
      ;;
    snapshot|restore)
      version=$(producer_package_version limine-snapper-sync) || return 1
      [[ "$version" == "$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION" ]]
      ;;
    *) return 1 ;;
  esac
}

producer_file_owner_package() {
  local path="$1"
  validate_control_file /usr/bin/pacman || return 1
  /usr/bin/pacman -Qqo "$path" 2>/dev/null
}

apply_limine_config_file() {
  local file="$1" key="$2" line value
  validate_control_file "$file" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      value=${BASH_REMATCH[1]}
      value=${value%\"}
      value=${value#\"}
      _limine_effective_value="$value"
      _limine_effective_value_found=true
    fi
  done < "$file"
}

apply_limine_config_directory() {
  local directory="$1" key="$2" file
  if [[ ! -e "$directory" && ! -L "$directory" ]]; then
    return 0
  fi
  validate_control_directory "$directory" || return 1
  for file in "$directory"/*.conf; do
    [[ -e "$file" || -L "$file" ]] || continue
    apply_limine_config_file "$file" "$key" || return 1
  done
}

load_effective_limine_entry_value() {
  local key="$1" file
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  _limine_effective_value=""
  _limine_effective_value_found=false
  apply_limine_config_directory "$(limine_vendor_config_dir)" "$key" || return 1
  file=$(limine_system_config_path) || return 1
  if [[ -e "$file" || -L "$file" ]]; then
    apply_limine_config_file "$file" "$key" || return 1
  fi
  apply_limine_config_directory "$(limine_system_config_dir)" "$key" || return 1
  file=$(limine_default_config_path) || return 1
  if [[ -e "$file" || -L "$file" ]]; then
    apply_limine_config_file "$file" "$key" || return 1
  fi
}

load_effective_limine_snapper_value() {
  local key="$1" file
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
  _limine_effective_value=""
  _limine_effective_value_found=false
  for file in "$(limine_snapper_config_path)" "$(limine_default_config_path)"; do
    if [[ -e "$file" || -L "$file" ]]; then
      apply_limine_config_file "$file" "$key" || return 1
    fi
  done
}

resolve_producer_esp_path() {
  local config_family="$1" configured candidate fstype
  case "$config_family" in
    entry) load_effective_limine_entry_value ESP_PATH || return 1 ;;
    snapshot) load_effective_limine_snapper_value ESP_PATH || return 1 ;;
    *) return 1 ;;
  esac
  configured="$_limine_effective_value"
  if [[ "$_limine_effective_value_found" != true || -z "${configured// /}" ]]; then
    configured=""
    for candidate in /efi /boot /boot/efi /limine; do
      [[ -d "$candidate" && ! -L "$candidate" ]] || continue
      fstype=$(findmnt -n -T "$candidate" -o FSTYPE 2>/dev/null || true)
      if [[ "$fstype" == vfat ]]; then
        configured="$candidate"
        break
      fi
    done
  fi
  [[ -n "$configured" && "$configured" == "$(esp_path)" ]] || return 1
  _producer_esp_path="$configured"
}

read_producer_machine_id() {
  local path machine_id
  path=$(machine_id_path) || return 1
  validate_control_file "$path" || return 1
  machine_id=$(<"$path") || return 1
  [[ "$machine_id" =~ ^[0-9a-f]{32}$ ]] || return 1
  _producer_machine_id="$machine_id"
}

derive_uki_inventory_obligations() {
  local version enabled prefix fallback modules modules_builtin kernel_name path raw="" paths
  local obligations
  version=$(producer_package_version limine-mkinitcpio-hook) || return 1
  [[ "$version" == "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" ]] || return 1
  resolve_producer_esp_path entry || return 1
  load_effective_limine_entry_value ENABLE_UKI || return 1
  enabled="${_limine_effective_value:-no}"
  [[ "$enabled" == yes || "$enabled" == no ]] || return 1
  if [[ "$enabled" == no ]] || ! producer_uefi_is_available; then
    printf '%s\n' '{"kind":"not-applicable","paths":[]}'
    return 0
  fi

  load_effective_limine_entry_value CUSTOM_UKI_NAME || return 1
  prefix="$_limine_effective_value"
  if [[ ! "$prefix" =~ ^[a-z0-9]+$ ]]; then
    read_producer_machine_id || return 1
    prefix="$_producer_machine_id"
  fi
  load_effective_limine_entry_value MKINITCPIO_FALLBACK || return 1
  fallback="$_limine_effective_value"
  [[ ${#fallback} -le 255 && "$fallback" != *[$'\001'-$'\037'$'\177']* ]] || return 1
  modules=$(kernel_modules_dir) || return 1
  validate_control_directory "$modules" || return 1

  for modules_builtin in "$modules"/*/modules.builtin; do
    [[ -e "$modules_builtin" || -L "$modules_builtin" ]] || continue
    validate_control_file "$modules_builtin" || return 1
    kernel_name=$(producer_file_owner_package "$modules_builtin") || return 1
    kernel_name=${kernel_name// /}
    [[ "$kernel_name" =~ ^[A-Za-z0-9@+_.-]+$ && ${#kernel_name} -le 255 ]] || return 1
    path="${_producer_esp_path}/EFI/Linux/${prefix}_${kernel_name}.efi"
    raw+="${path}"$'\n'
    if [[ "$fallback" == yes || "$fallback" == "$kernel_name" ]]; then
      raw+="${_producer_esp_path}/EFI/Linux/${prefix}_${kernel_name}-fallback.efi"$'\n'
    fi
  done
  paths=$(printf '%s' "$raw" | jq -Rsc \
    'split("\n") | map(select(length > 0)) | sort | unique') || return 1
  obligations=$(jq -cn --argjson paths "$paths" \
    '{kind: "uki-inventory", paths: $paths}') || return 1
  validate_efi_obligations_json "$obligations" || return 1
  printf '%s\n' "$obligations"
}

derive_snapshot_manifest_obligations() {
  local version history manifest document paths obligations
  version=$(producer_package_version limine-snapper-sync) || return 1
  [[ "$version" == "$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION" ]] || return 1
  resolve_producer_esp_path snapshot || return 1
  read_producer_machine_id || return 1
  history="${_producer_esp_path}/${_producer_machine_id}/limine_history"
  validate_control_directory "$history" || return 1
  manifest="${history}/snapshots.json"
  validate_control_file "$manifest" || return 1
  document=$(read_control_document "$manifest") || return 1
  (( ${#document} <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  jq -e '
    def image:
      type == "object" and (.fileName | type == "string") and
      (.fileHashName | type == "string");
    def kernel:
      type == "object" and (.imageDetails | type == "array" and all(.[]; image)) and
      (.subKernels | type == "array" and all(.[]; kernel));
    type == "object" and .jsonFormatVersion == "1.3.0" and
    (.snapshotEntries | type == "array" and all(.[];
      type == "object" and
      (.kernelEntries | type == "array" and all(.[]; kernel))))
  ' <<< "$document" >/dev/null || return 1
  paths=$(jq -c --arg history "$history" '
    [ .snapshotEntries[].kernelEntries[]
      | recurse(.subKernels[]?)
      | .imageDetails[]
      | select(.fileName | test("\\.efi$"; "i"))
      | . as $image
       | if ($image.fileHashName |
          startswith($image.fileName + "_") and
          (contains("/") | not) and
          test("\\.efi_(sha1_[0-9a-f]{40}|sha256_[0-9a-f]{64}|b3_[0-9a-f]{64}|xxh_[0-9a-f]{16})$"; "i"))
        then "\($history)/\($image.fileHashName)"
        else error("unsupported snapshot EFI output") end
    ] | sort | unique
  ' <<< "$document") || return 1
  obligations=$(jq -cn --argjson paths "$paths" \
    '{kind: "snapshot-manifest", paths: $paths}') || return 1
  validate_efi_obligations_json "$obligations" || return 1
  printf '%s\n' "$obligations"
}

derive_registered_producer_obligations() {
  local producer="$1" class subtype
  class=$(jq -r '.producer_class' <<< "$producer") || return 1
  subtype=$(jq -r '.subtype' <<< "$producer") || return 1
  case "${class}:${subtype}" in
    package:package-transaction|limine:uki-build)
      derive_uki_inventory_obligations
      ;;
    snapshot:snapshot-sync|restore:full-restore)
      derive_snapshot_manifest_obligations
      ;;
    limine:entry-tool)
      printf '%s\n' '{"kind":"not-applicable","paths":[]}'
      ;;
    *) return 1 ;;
  esac
}

verify_obligated_efi_artifacts_exist() {
  local obligations="$1" discovered file
  local -A discovered_map=()
  validate_efi_obligations_json "$obligations" || return 1
  discovered=$(discover_efi_files) || return 1
  if [[ -n "$discovered" ]]; then
    while IFS= read -r file; do
      [[ -n "$file" ]] && discovered_map["$file"]=1
    done <<< "$discovered"
  fi
  while IFS= read -r file; do
    [[ -n "${discovered_map[$file]:-}" ]] || {
      fail "Expected producer EFI output is missing: ${file}"
      return 1
    }
  done < <(jq -r '.paths[]' <<< "$obligations")
}

select_producer_service_policy() {
  local captured="$1" active main_pid
  _producer_service_policy=quiesce
  _producer_service_owner_json=null
  [[ "$_producer_class" == snapshot ]] || return 0
  active=$(jq -r --arg unit "$TRANSACTION_SERVICE_UNIT" \
    '.[$unit].active_state' <<< "$captured") || return 1
  [[ "$active" == active ]] || return 0
  main_pid=$(transaction_service_main_pid) || return 1
  [[ "$(process_effective_uid "$main_pid")" == "$(control_owner_uid)" ]] || return 1
  process_runs_script "$main_pid" /usr/bin/limine-snapper-watcher || return 1
  if process_has_ancestor "$main_pid" "$_producer_owner_pid"; then
    _producer_service_policy=preserve-owner
    _producer_service_owner_json=$(jq -cn \
      --arg boot_id "$(boot_id_value)" \
      --arg identity /usr/bin/limine-snapper-watcher \
      --argjson pid "$main_pid" \
      --arg start_time "$(process_start_time "$main_pid")" \
      --argjson uid "$(control_owner_uid)" '{
        boot_id: $boot_id,
        identity: $identity,
        identity_kind: "script",
        pid: $pid,
        start_time: $start_time,
        uid: $uid
      }') || return 1
  fi
}

producer_baseline_entry() {
  local kind="$1" path="$2" allow_absent="${3:-false}"
  [[ "$allow_absent" == true || "$allow_absent" == false ]] || return 1
  [[ "$path" =~ ^/[^[:cntrl:]]+$ ]] || return 1
  validate_control_directory "$(dirname "$path")" || return 1
  if [[ -e "$path" || -L "$path" ]]; then
    validate_control_file "$path" || return 1
    jq -cn \
      --arg kind "$kind" \
      --arg path "$path" \
      --arg hash "$(sha256_file "$path")" \
      --arg identity "$(control_file_identity "$path")" '{
        identity: $identity,
        kind: $kind,
        path: $path,
        presence: "present",
        sha256: $hash
      }'
  else
    [[ "$allow_absent" == true ]] || return 1
    jq -cn --arg kind "$kind" --arg path "$path" '{
      identity: null,
      kind: $kind,
      path: $path,
      presence: "absent",
      sha256: null
    }'
  fi
}

capture_producer_baseline() {
  local transaction_id="$1" artifacts='[]' entry path discovered candidates timestamp document
  producer_reconstruction_preflight || return 1
  entry=$(producer_baseline_entry config "$(limine_config_path)") || return 1
  artifacts=$(jq -c --argjson entry "$entry" '. + [$entry]' <<< "$artifacts") || return 1
  entry=$(producer_baseline_entry defaults "$(limine_default_config_path)") || return 1
  artifacts=$(jq -c --argjson entry "$entry" '. + [$entry]' <<< "$artifacts") || return 1

  discovered=$(discover_efi_files) || return 1
  if [[ -n "$discovered" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      entry=$(producer_baseline_entry efi "$path") || return 1
      artifacts=$(jq -c --argjson entry "$entry" '. + [$entry]' <<< "$artifacts") \
        || return 1
    done <<< "$discovered"
  fi
  candidates=$(sbctl_database_candidate_paths) || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    entry=$(producer_baseline_entry tracking "$path" true) || return 1
    artifacts=$(jq -c --argjson entry "$entry" '. + [$entry]' <<< "$artifacts") \
      || return 1
  done <<< "$candidates"
  artifacts=$(jq -c 'sort_by(.path)' <<< "$artifacts") || return 1
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$PRODUCER_BASELINE_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg timestamp "$timestamp" \
    --argjson artifacts "$artifacts" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      captured_at: $timestamp,
      artifacts: $artifacts
    }') || return 1
  validate_producer_baseline_json "$transaction_id" "$document" || return 1
  printf '%s\n' "$document"
}

producer_baseline_matches_current() {
  local document="$1" transaction_id current recorded_artifacts current_artifacts
  transaction_id=$(jq -r '.transaction_id' <<< "$document") || return 1
  validate_producer_baseline_json "$transaction_id" "$document" || return 1
  current=$(capture_producer_baseline "$transaction_id") || return 1
  recorded_artifacts=$(jq -Sc '.artifacts' <<< "$document") || return 1
  current_artifacts=$(jq -Sc '.artifacts' <<< "$current") || return 1
  [[ "$recorded_artifacts" == "$current_artifacts" ]]
}

capture_restore_marker_reference() {
  local path identity
  path=$(snapshot_restore_lock_path) || return 1
  validate_control_file "$path" || return 1
  identity=$(control_file_identity "$path") || return 1
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  jq -cn --arg path "$path" --arg identity "$identity" '{
    path: $path,
    identity: $identity
  }'
}

producer_restore_marker_matches_current() {
  local producer="$1" path expected_identity
  [[ $(jq -r '.producer_class' <<< "$producer") == restore ]] || return 1
  path=$(jq -r '.restore_marker.path' <<< "$producer") || return 1
  expected_identity=$(jq -r '.restore_marker.identity' <<< "$producer") || return 1
  [[ "$path" == "$(snapshot_restore_lock_path)" ]] || return 1
  validate_control_file "$path" || return 1
  [[ $(control_file_identity "$path") == "$expected_identity" ]]
}

producer_operation() {
  case "$_producer_class" in
    package) printf 'producer-package\n' ;;
    limine) printf 'producer-limine\n' ;;
    snapshot) printf 'producer-snapshot\n' ;;
    restore) printf 'producer-restore\n' ;;
    *) return 1 ;;
  esac
}

prepare_producer_transaction_documents() {
  local captured_service="$1" transaction_id transaction_dir prior_backup prior_hash
  local baseline_path producer_path baseline producer operation timestamp producer_reference
  transaction_id=$(new_transaction_id) || return 1
  baseline=$(capture_producer_baseline "$transaction_id") || return 1
  transaction_dir="$(transactions_dir_path)/${transaction_id}"
  install -d -m 700 "$transaction_dir" || return 1
  validate_private_control_directory "$transaction_dir" || return 1
  durable_sync "$(transactions_dir_path)" || return 1
  prior_backup="${transaction_dir}/prior-lifecycle.json"
  cp -p "$(lifecycle_file_path)" "$prior_backup" || return 1
  chmod 600 "$prior_backup" || return 1
  validate_private_control_file "$prior_backup" || return 1
  durable_sync "$prior_backup" || return 1
  prior_hash=$(sha256_file "$prior_backup") || return 1
  _producer_backups_json=$(jq -cn --arg path "$prior_backup" --arg hash "$prior_hash" \
    '[{path: $path, sha256: $hash, kind: "prior-lifecycle", target: null}]') \
    || return 1

  baseline_path="${transaction_dir}/producer-baseline.json"
  printf '%s\n' "$baseline" | atomic_create_control_file "$baseline_path" 600 || return 1
  _producer_baseline_reference=$(transaction_artifact_reference "$baseline_path" \
    "$PRODUCER_BASELINE_SCHEMA_VERSION") || return 1
  operation=$(producer_operation) || return 1
  timestamp=$(utc_timestamp) || return 1
  producer=$(jq -cn \
    --argjson schema "$PRODUCER_RECORD_SCHEMA_VERSION" \
    --arg version "$OMASECBOOT_VERSION" \
    --arg id "$transaction_id" \
    --arg operation "$operation" \
    --arg timestamp "$timestamp" \
    --arg class "$_producer_class" \
    --arg subtype "$_producer_subtype" \
    --arg boot_id "$(boot_id_value)" \
    --arg owner_kind "$_producer_owner_kind" \
    --arg owner_identity "$_producer_owner_identity" \
    --argjson owner_pid "$_producer_owner_pid" \
    --arg owner_start "$(process_start_time "$_producer_owner_pid")" \
    --argjson owner_uid "$(control_owner_uid)" \
    --arg caller "$_producer_caller" \
    --argjson restore "$_producer_restore" \
    --argjson no_mutex "$_producer_no_mutex" \
    --argjson targets "$_producer_targets_json" \
    --arg lock_policy "$_producer_lock_policy" \
    --arg service_policy "$_producer_service_policy" \
    --argjson service_owner "$_producer_service_owner_json" \
    --argjson restore_marker "$_producer_restore_marker_json" \
    --argjson baseline "$_producer_baseline_reference" '{
      schema_version: $schema,
      writer_version: $version,
      transaction_id: $id,
      operation: $operation,
      created_at: $timestamp,
      producer_class: $class,
      subtype: $subtype,
      restore_marker: $restore_marker,
      owner: {
        boot_id: $boot_id,
        identity: $owner_identity,
        identity_kind: $owner_kind,
        pid: $owner_pid,
        start_time: $owner_start,
        uid: $owner_uid
      },
      invocation: {
        caller: $caller,
        no_mutex: $no_mutex,
        restore: $restore,
        targets: $targets
      },
      baseline: $baseline,
      lock_policy: $lock_policy,
      service_policy: $service_policy,
      service_owner: $service_owner
    }') || return 1
  (( ${#producer} <= MAX_CONTROL_DOCUMENT_BYTES )) || return 1
  validate_producer_record_json "$transaction_id" "$producer" || return 1
  producer_path="${transaction_dir}/producer.json"
  printf '%s\n' "$producer" | atomic_create_control_file "$producer_path" 600 || return 1
  producer_reference=$(transaction_artifact_reference "$producer_path" \
    "$PRODUCER_RECORD_SCHEMA_VERSION") || return 1
  producer_baseline_matches_current "$baseline" || return 1
  _producer_transaction_id="$transaction_id"
  _producer_reference="$producer_reference"
  _producer_record_json="$producer"
  _producer_captured_service="$captured_service"
}

begin_registered_producer_lease() {
  local captured rc=0
  [[ "$_lifecycle_state" == active ]] || return 1
  producer_compatibility_is_supported || return 1
  if [[ "$_producer_class" == restore ]]; then
    _producer_restore_marker_json=$(capture_restore_marker_reference) || return 1
  else
    _producer_restore_marker_json=null
  fi
  captured=$(capture_service_state) || return 1
  select_producer_service_policy "$captured" || return 1
  prepare_producer_transaction_documents "$captured" || return 1
  begin_producer_lifecycle_transaction "$_producer_transaction_id" "$_producer_reference" \
    "$captured" "$_producer_backups_json" || rc=$?
  if [[ $rc -eq 0 && "$_producer_class" == restore ]] \
    && ! producer_restore_marker_matches_current "$_producer_record_json"; then
    rc=1
  fi
  if [[ $rc -ne 0 && "$_transaction_active" == true ]]; then
    if read_lifecycle && [[ "$_lifecycle_state" == transition \
      && "$_lifecycle_transaction_id" == "$_transaction_id" ]]; then
      rollback_and_mark_recovery "$rc" "producer lease initialization failed" failed || true
    else
      detach_transaction_context
    fi
  fi
  [[ $rc -eq 0 ]] || return "$rc"
  detach_transaction_context
}

read_transition_producer_record() {
  local reference path
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition ]] || return 1
  read_transaction_manifest "$_lifecycle_transaction_id" || return 1
  [[ $(jq -r '.kind' <<< "$_manifest_json") == root \
    && $(jq -r '.status' <<< "$_manifest_json") == transition ]] || return 1
  reference=$(jq -c '.domain_records.producer' <<< "$_manifest_json") || return 1
  [[ "$reference" != null ]] || return 1
  validate_producer_record_reference "$_lifecycle_transaction_id" "$reference" || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  _producer_record_json=$(read_control_document "$path") || return 1
}

producer_transition_is_owned() {
  local owner_pid
  read_transition_producer_record || return 1
  manifest_owner_is_alive || return 1
  owner_pid=$(jq -r '.owner.pid' <<< "$_producer_record_json") || return 1
  process_matches_identity "$owner_pid" \
    "$(jq -r '.owner.identity_kind' <<< "$_producer_record_json")" \
    "$(jq -r '.owner.identity' <<< "$_producer_record_json")" || return 1
  process_has_ancestor "$owner_pid" "$BASHPID"
}

with_registry_limine_handoff() {
  local child_rc=0 lock_rc=0
  [[ "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == local ]]; then
    with_delegated_limine_lock "$@" || child_rc=$?
    if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false ]]; then
      with_limine_lock || return 1
    fi
    return "$child_rc"
  fi
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == inherited ]] || return 1
  inherited_limine_fd_is_valid || return 1
  flock -u 200 || return 1
  _OMASECBOOT_LIMINE_LOCK_OWNED=false
  "$@" || child_rc=$?
  flock -w 30 200 || lock_rc=$?
  if [[ $lock_rc -eq 0 ]] && inherited_limine_fd_is_valid; then
    _OMASECBOOT_LIMINE_LOCK_OWNED=inherited
  else
    _OMASECBOOT_LIMINE_LOCK_OWNED=false
    with_limine_lock || return 1
    return 1
  fi
  return "$child_rc"
}

run_package_producer_reconstruction() {
  validate_control_file /usr/bin/env || return 1
  validate_control_file /usr/bin/limine-mkinitcpio || return 1
  with_registry_limine_handoff /usr/bin/env -u HOOK_CALLER -u HOOK_CMDLINE \
    /usr/bin/limine-mkinitcpio
}

run_snapshot_producer_reconstruction() {
  validate_control_file /usr/bin/env || return 1
  validate_control_file /usr/bin/limine-snapper-sync || return 1
  [[ ! -e "$(snapshot_restore_lock_path)" && ! -L "$(snapshot_restore_lock_path)" ]] \
    || return 1
  with_registry_limine_handoff /usr/bin/env -u HOOK_CALLER -u HOOK_CMDLINE \
    /usr/bin/limine-snapper-sync --no-force-save
}

run_registered_producer_preparation() {
  local producer="$1" recovery="${2:-false}" class subtype
  [[ "$recovery" == true || "$recovery" == false ]] || return 1
  class=$(jq -r '.producer_class' <<< "$producer") || return 1
  subtype=$(jq -r '.subtype' <<< "$producer") || return 1
  case "${class}:${subtype}" in
    package:package-transaction|limine:uki-build)
      run_package_producer_reconstruction
      ;;
    limine:entry-tool)
      return 0
      ;;
    snapshot:snapshot-sync|restore:full-restore)
      if [[ "$recovery" == true ]]; then
        run_snapshot_producer_reconstruction
      fi
      ;;
    *) return 1 ;;
  esac
}

registered_producer_repair() {
  registered_producer_repair_impl
}

registered_producer_repair_impl() {
  local reference path producer root_id class subtype obligations before_obligations
  local final_obligations
  before_obligations=""
  local recovery=false
  read_transaction_manifest "$_transaction_id" || return 1
  if [[ $(jq -r '.kind' <<< "$_manifest_json") == recovery-attempt ]]; then
    reference="$_recovery_producer_reference"
    root_id=$(jq -r '.id' <<< "$_recovery_root_reference") || return 1
    recovery=true
  else
    reference=$(jq -c '.domain_records.producer' <<< "$_manifest_json") || return 1
    root_id="$_transaction_id"
  fi
  [[ "$reference" != null ]] || return 1
  validate_producer_record_reference "$root_id" "$reference" || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  producer=$(read_control_document "$path") || return 1
  class=$(jq -r '.producer_class' <<< "$producer") || return 1
  subtype=$(jq -r '.subtype' <<< "$producer") || return 1

  transaction_phase_start "reconstruct-producer" || return 1
  producer_reconstruction_preflight || return 1
  case "${class}:${subtype}" in
    package:package-transaction|limine:uki-build)
      before_obligations=$(derive_registered_producer_obligations "$producer") || return 1
      ;;
  esac
  run_registered_producer_preparation "$producer" "$recovery" || return 1
  obligations=$(derive_registered_producer_obligations "$producer") || return 1
  if [[ -n "$before_obligations" ]]; then
    [[ $(jq -Sc . <<< "$before_obligations") == $(jq -Sc . <<< "$obligations") ]] \
      || return 1
  fi
  verify_obligated_efi_artifacts_exist "$obligations" || return 1
  transaction_phase_complete "reconstruct-producer" || return 1
  artifact_repair_preflight || return 1
  repair_boot_artifacts "$obligations" || return 1

  transaction_phase_start "confirm-producer-output" || return 1
  final_obligations=$(derive_registered_producer_obligations "$producer") || return 1
  [[ $(jq -Sc . <<< "$obligations") == $(jq -Sc . <<< "$final_obligations") ]] \
    || return 1
  verify_obligated_efi_artifacts_exist "$final_obligations" || return 1
  transaction_phase_complete "confirm-producer-output"
}

run_registered_producer_recovery_locked() {
  local callback_rc=0 commit_rc=0 begin_rc=0
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  load_producer_recovery_context || return $?
  arm_transaction_traps
  begin_lifecycle_recovery_attempt producer-recovery || begin_rc=$?
  if [[ $begin_rc -ne 0 ]]; then
    if [[ "$_transaction_active" == true ]]; then
      if read_lifecycle && [[ "$_lifecycle_state" == transition \
        && "$_lifecycle_transaction_id" == "$_transaction_id" ]]; then
        rollback_and_mark_recovery "$begin_rc" \
          "producer recovery attempt initialization failed" failed || true
      else
        detach_transaction_context
      fi
    fi
    restore_transaction_traps
    return "$begin_rc"
  fi
  registered_producer_repair || callback_rc=$?
  if [[ $callback_rc -eq 0 ]]; then
    commit_lifecycle_recovery_attempt || commit_rc=$?
    if [[ $commit_rc -ne 0 ]]; then
      rollback_and_mark_recovery "$commit_rc" \
        "stable producer recovery publication failed" failed || true
      callback_rc=$commit_rc
    fi
  else
    rollback_and_mark_recovery "$callback_rc" "registered producer recovery failed" failed \
      || true
  fi
  restore_transaction_traps
  return "$callback_rc"
}

process_observation_is_uncertain() {
  local pid="$1" expected_start="$2" current_start
  current_start=$(process_start_time "$pid" 2>/dev/null) || return 1
  [[ "$current_start" == "$expected_start" ]]
}

full_restore_process_root() {
  printf '/proc\n'
}

full_restore_process_executable() {
  readlink -f "$1/exe" 2>/dev/null
}

full_restore_process_script() {
  local process_path="$1" argument="$2"
  if [[ "$argument" == /* ]]; then
    readlink -f "$argument" 2>/dev/null
  else
    readlink -f "${process_path}/cwd/${argument}" 2>/dev/null
  fi
}

full_restore_runtime_state() {
  local path process_root proc pid start uid state executable current_start script argument
  local has_restore has_no_mutex
  local -a arguments
  for path in /usr/bin/limine-snapper-restore /usr/bin/limine-snapper-sync \
    /usr/lib/limine/limine-snapper-sync; do
    validate_control_file "$path" || {
      printf 'unknown\n'
      return
    }
  done

  process_root=$(full_restore_process_root) || {
    printf 'unknown\n'
    return
  }
  [[ "$process_root" == /* && -d "$process_root" && ! -L "$process_root" ]] || {
    printf 'unknown\n'
    return
  }
  for proc in "${process_root}"/[0-9]*; do
    [[ -d "$proc" ]] || continue
    pid=${proc##*/}
    start=$(process_start_time "$pid" 2>/dev/null) || {
      [[ -d "$proc" ]] && {
        printf 'unknown\n'
        return
      }
      continue
    }
    uid=$(process_effective_uid "$pid" 2>/dev/null) || {
      if process_observation_is_uncertain "$pid" "$start"; then
        printf 'unknown\n'
        return
      fi
      continue
    }
    [[ "$uid" == "$(control_owner_uid)" ]] || continue
    state=$(process_state "$pid" 2>/dev/null) || {
      if process_observation_is_uncertain "$pid" "$start"; then
        printf 'unknown\n'
        return
      fi
      continue
    }
    [[ "$state" != Z && "$state" != X && "$state" != x ]] || continue
    arguments=()
    mapfile -d '' -t arguments 2>/dev/null < "${proc}/cmdline" || {
      if process_observation_is_uncertain "$pid" "$start"; then
        printf 'unknown\n'
        return
      fi
      continue
    }
    (( ${#arguments[@]} > 0 )) || continue
    executable=$(full_restore_process_executable "$proc") || {
      if process_observation_is_uncertain "$pid" "$start"; then
        printf 'unknown\n'
        return
      fi
      continue
    }
    current_start=$(process_start_time "$pid" 2>/dev/null) || continue
    [[ "$current_start" == "$start" ]] || continue

    script=""
    if [[ "$executable" == /usr/bin/bash && ${#arguments[@]} -ge 2 ]]; then
      script=$(full_restore_process_script "$proc" "${arguments[1]}") || {
        if process_observation_is_uncertain "$pid" "$start"; then
          printf 'unknown\n'
          return
        fi
        continue
      }
    fi
    if [[ "$script" == /usr/bin/limine-snapper-restore ]]; then
      printf 'running\n'
      return
    fi

    has_restore=false
    has_no_mutex=false
    for argument in "${arguments[@]}"; do
      [[ "$argument" == --restore ]] && has_restore=true
      [[ "$argument" == --no-mutex ]] && has_no_mutex=true
    done
    if [[ "$script" == /usr/bin/limine-snapper-sync \
      && "$has_restore" == true && "$has_no_mutex" == true ]] \
      || [[ "$executable" == /usr/lib/limine/limine-snapper-sync \
        && "$has_restore" == true ]]; then
      printf 'running\n'
      return
    fi
  done
  printf 'clear\n'
}

restore_runtime_is_quiescent() {
  local state
  state=$(full_restore_runtime_state) || return 1
  [[ "$state" == clear ]]
}

prepare_stale_transition_reconciliation_locked() {
  local manifest_kind root_reference root_id reference path class marker_path owner_boot_id
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  marker_path=$(snapshot_restore_lock_path) || return 1
  read_lifecycle || return 1
  [[ "$_lifecycle_state" == transition ]] || return 1
  read_transaction_manifest "$_lifecycle_transaction_id" || return 1
  manifest_kind=$(jq -r '.kind' <<< "$_manifest_json") || return 1
  if [[ "$manifest_kind" == recovery-attempt ]]; then
    root_reference=$(jq -c '.recovery.root_incident' <<< "$_manifest_json") || return 1
    validate_incident_reference "$root_reference" || return 1
    root_id=$(jq -r '.id' <<< "$root_reference") || return 1
    read_transaction_manifest "$root_id" || return 1
    [[ $(jq -r '.kind' <<< "$_manifest_json") == root ]] || return 1
    reference=$(jq -c '.domain_records.producer' <<< "$_manifest_json") || return 1
    [[ "$reference" != null ]] || return 1
    validate_producer_record_reference "$root_id" "$reference" || return 1
    path=$(jq -r '.path' <<< "$reference") || return 1
    _producer_record_json=$(read_control_document "$path") || return 1
    class=$(jq -r '.producer_class' <<< "$_producer_record_json") || return 1
    if [[ "$class" == restore ]]; then
      restore_runtime_is_quiescent || return 1
    fi
    [[ ! -e "$marker_path" && ! -L "$marker_path" ]]
    return
  fi
  [[ "$manifest_kind" == root ]] || return 1
  read_transition_producer_record || return 1
  class=$(jq -r '.producer_class' <<< "$_producer_record_json") || return 1
  if [[ "$class" != restore ]]; then
    [[ ! -e "$marker_path" && ! -L "$marker_path" ]]
    return
  fi
  restore_runtime_is_quiescent || return 1
  if [[ -e "$marker_path" || -L "$marker_path" ]]; then
    producer_restore_marker_matches_current "$_producer_record_json"
    return
  fi
  owner_boot_id=$(jq -r '.owner.boot_id' <<< "$_producer_record_json") || return 1
  [[ "$owner_boot_id" != "$(boot_id_value)" ]]
}

prepare_recovery_runtime_locked() {
  local reference path producer class marker_path
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  load_producer_recovery_context || return $?
  reference="$_recovery_producer_reference"
  path=$(jq -r '.path' <<< "$reference") || return 1
  producer=$(read_control_document "$path") || return 1
  class=$(jq -r '.producer_class' <<< "$producer") || return 1
  marker_path=$(snapshot_restore_lock_path) || return 1
  if [[ "$class" != restore ]]; then
    [[ ! -e "$marker_path" && ! -L "$marker_path" ]]
    return
  fi
  restore_runtime_is_quiescent || return 1
  if [[ -e "$marker_path" || -L "$marker_path" ]]; then
    producer_restore_marker_matches_current "$producer" || return 1
    rm -f -- "$marker_path" || return 1
    [[ ! -e "$marker_path" && ! -L "$marker_path" ]] || return 1
    durable_sync "$(dirname "$marker_path")" || return 1
  fi
}

reconcile_and_recover_producer_locked() {
  local marker_path
  marker_path=$(snapshot_restore_lock_path) || return 1
  read_lifecycle || return 1
  if [[ "$_lifecycle_state" == transition ]]; then
    read_transaction_manifest "$_lifecycle_transaction_id" || return 1
    manifest_owner_is_alive && return 1
    prepare_stale_transition_reconciliation_locked || return 1
    reconcile_stale_lifecycle || return 1
    read_lifecycle || return 1
  fi
  if [[ "$_lifecycle_state" == recovery-required ]]; then
    prepare_recovery_runtime_locked || return 1
    run_registered_producer_recovery_locked || return 1
    read_lifecycle || return 1
  fi
  [[ "$_lifecycle_state" == active \
    && ! -e "$marker_path" && ! -L "$marker_path" ]]
}

producer_transition_matches_current_context() {
  [[ -n "$_producer_record_json" ]] || read_transition_producer_record || return 1
  [[ $(jq -r '.producer_class' <<< "$_producer_record_json") == "$_producer_class" \
    && $(jq -r '.subtype' <<< "$_producer_record_json") == "$_producer_subtype" \
    && $(jq -r '.owner.pid' <<< "$_producer_record_json") == "$_producer_owner_pid" ]]
}

complete_registered_producer_locked() {
  local expected_class="$1" require_checkpoint="${2:-false}" callback_rc=0 commit_rc=0
  producer_transition_is_owned || return 1
  [[ $(jq -r '.producer_class' <<< "$_producer_record_json") == "$expected_class" ]] \
    || return 2
  adopt_transaction_context "$_lifecycle_transaction_id" || return 1
  if [[ "$require_checkpoint" == true ]]; then
    read_transaction_manifest "$_transaction_id" || return 1
    jq -e '.completed_phases | index("package-pre-sbctl") != null' \
      <<< "$_manifest_json" >/dev/null || callback_rc=1
  fi
  arm_transaction_traps
  if [[ $callback_rc -eq 0 ]]; then
    registered_producer_repair || callback_rc=$?
  fi
  if [[ $callback_rc -eq 0 ]]; then
    commit_lifecycle_transaction || commit_rc=$?
    if [[ $commit_rc -ne 0 ]]; then
      rollback_and_mark_recovery "$commit_rc" "stable producer commit failed" failed || true
      callback_rc=$commit_rc
    fi
  else
    rollback_and_mark_recovery "$callback_rc" "producer post-repair failed" failed || true
  fi
  restore_transaction_traps
  return "$callback_rc"
}

producer_package_pre_locked() {
  read_lifecycle || return 1
  if [[ "$_lifecycle_state" == transition ]]; then
    if current_transition_is_owned || producer_transition_is_owned; then
      return 0
    fi
  fi
  reconcile_and_recover_producer_locked || return 1
  begin_registered_producer_lease
}

producer_package_pre() {
  local rc=0 target_policy_rc=0 targets
  require_control_root || {
    drain_package_producer_targets
    return 1
  }
  read_lifecycle || {
    drain_package_producer_targets
    fail "Boot-mutating package transaction blocked: lifecycle state is invalid or unsafe"
    return 1
  }
  case "$_lifecycle_state" in
    unmanaged|disabled)
      if [[ -e "$(snapshot_restore_lock_path)" || -L "$(snapshot_restore_lock_path)" ]]; then
        drain_package_producer_targets
        fail "Boot-mutating package transaction blocked: full snapshot restore is running"
        return 1
      fi
      drain_package_producer_targets
      return 0
      ;;
  esac
  producer_automation_is_available || {
    drain_package_producer_targets
    fail "Boot-mutating package transaction blocked: complete boot repair is unavailable"
    return 1
  }
  read_package_producer_targets || {
    fail "Boot-mutating package transaction blocked: package targets are invalid"
    return 1
  }
  package_targets_change_pinned_producer || target_policy_rc=$?
  if [[ $target_policy_rc -eq 0 ]]; then
    fail "Boot-mutating package transaction blocked: disable lifecycle before changing pinned producers"
    return 1
  elif [[ $target_policy_rc -ne 1 ]]; then
    fail "Boot-mutating package transaction blocked: package target policy failed"
    return 1
  fi
  targets="$_producer_targets_json"
  resolve_package_producer_context || return 1
  _producer_targets_json="$targets"
  with_boot_repair_lock || return 1
  producer_package_pre_locked || rc=$?
  release_boot_repair_lock
  return "$rc"
}

producer_package_checkpoint() {
  local rc=0
  require_control_root || return 1
  read_lifecycle || return 1
  case "$_lifecycle_state" in
    unmanaged|disabled) return 0 ;;
  esac
  producer_automation_is_available || return 1
  resolve_package_producer_context || return 1
  with_boot_repair_lock || return 1
  if ! producer_transition_is_owned \
    || [[ $(jq -r '.producer_class' <<< "$_producer_record_json") != package ]] \
    || ! adopt_transaction_context "$_lifecycle_transaction_id"; then
    rc=1
  else
    read_transaction_manifest "$_transaction_id" || rc=$?
    if [[ $rc -eq 0 ]] && ! jq -e \
      '.completed_phases | index("package-pre-sbctl") != null' \
      <<< "$_manifest_json" >/dev/null; then
      transaction_phase_start "package-pre-sbctl" || rc=$?
      [[ $rc -ne 0 ]] || transaction_phase_complete "package-pre-sbctl" || rc=$?
    fi
  fi
  detach_transaction_context
  release_boot_repair_lock
  return "$rc"
}

producer_package_post() {
  local rc=0
  require_control_root || return 1
  read_lifecycle || return 1
  case "$_lifecycle_state" in
    unmanaged|disabled) return 0 ;;
  esac
  producer_automation_is_available || return 1
  resolve_package_producer_context || return 1
  with_boot_repair_lock || return 1
  complete_registered_producer_locked package true || rc=$?
  detach_transaction_context
  release_boot_repair_lock
  return "$rc"
}

producer_limine_lock() {
  local phase="$1"
  if [[ "$_producer_class" == restore ]]; then
    with_boot_repair_lock
  elif [[ "$phase" == pre ]]; then
    lock_inherited_limine_fd || return 1
    with_repair_lock
  else
    with_limine_lock || return 1
    with_repair_lock
  fi
}

producer_limine_pre_locked() {
  read_lifecycle || return 1
  if [[ "$_producer_class" == restore ]]; then
    [[ "$_lifecycle_state" == active ]] || return 1
    [[ -e "$(snapshot_restore_lock_path)" || -L "$(snapshot_restore_lock_path)" ]] \
      || return 1
    validate_control_file "$(snapshot_restore_lock_path)" || return 1
    begin_registered_producer_lease
    return
  fi
  if [[ "$_lifecycle_state" == transition ]]; then
    if current_transition_is_owned || producer_transition_is_owned; then
      return 0
    fi
  fi
  reconcile_and_recover_producer_locked || return 1
  if [[ -e "$(snapshot_restore_lock_path)" || -L "$(snapshot_restore_lock_path)" ]]; then
    return 1
  fi
  begin_registered_producer_lease
}

producer_limine_hook_pre() {
  local rc=0
  require_control_root || return 100
  read_lifecycle || {
    fail "Lifecycle state is invalid or unsafe"
    return 100
  }
  case "$_lifecycle_state" in
    unmanaged|disabled) return 0 ;;
  esac
  producer_automation_is_available || {
    fail "Boot mutation is blocked until complete boot repair is available"
    return 100
  }
  resolve_limine_producer_context || return 100
  if [[ "$_producer_class" == restore && "$_lifecycle_state" != active ]]; then
    fail "Full snapshot restore is allowed only in active lifecycle state"
    return 100
  fi
  producer_limine_lock pre || return 100
  producer_limine_pre_locked || rc=$?
  release_boot_repair_lock
  [[ $rc -eq 0 ]] || return 100
}

producer_limine_hook_post() {
  local rc=0 record_class record_owner
  require_control_root || return 100
  read_lifecycle || return 100
  case "$_lifecycle_state" in
    unmanaged|disabled) return 0 ;;
  esac
  producer_automation_is_available || return 100
  resolve_limine_producer_context || return 100
  producer_limine_lock post || return 100
  if current_transition_is_owned; then
    release_boot_repair_lock
    return 0
  fi
  if ! producer_transition_is_owned; then
    rc=1
  else
    record_class=$(jq -r '.producer_class' <<< "$_producer_record_json") || rc=$?
    if [[ $rc -eq 0 && "$record_class" != "$_producer_class" ]]; then
      release_boot_repair_lock
      return 0
    fi
    if [[ $rc -eq 0 ]]; then
      record_owner=$(jq -r '.owner.pid' <<< "$_producer_record_json") || rc=$?
    fi
    if [[ $rc -eq 0 && "$record_owner" != "$_producer_owner_pid" ]] \
      && process_has_ancestor "$record_owner" "$_producer_owner_pid"; then
      release_boot_repair_lock
      return 0
    fi
    if [[ $rc -eq 0 ]] && ! producer_transition_matches_current_context; then
      rc=1
    fi
    if [[ $rc -eq 0 ]]; then
      complete_registered_producer_locked "$record_class" false || rc=$?
    fi
  fi
  detach_transaction_context
  release_boot_repair_lock
  if [[ $rc -ne 0 ]]; then
    fail "Post-hook producer repair failed"
    return 100
  fi
}
