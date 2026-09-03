#!/bin/bash
# shellcheck disable=SC2154 # Transaction globals come from the sourced lifecycle module.
# OmaSecBoot: validated Windows firmware handoff identity

readonly WINDOWS_ENTRY_MARKER="# omasecboot:windows begin"
readonly WINDOWS_ENTRY_END_MARKER="# omasecboot:windows end"
readonly WINDOWS_LEGACY_ENTRY_MARKER="# omasecboot:windows"
readonly WINDOWS_STATE_SCHEMA_VERSION=1
readonly WINDOWS_LOADER_UEFI='\EFI\Microsoft\Boot\bootmgfw.efi'
readonly WINDOWS_LOADER_POSIX='/EFI/Microsoft/Boot/bootmgfw.efi'
readonly WINDOWS_ESP_PARTTYPE='c12a7328-f81f-11d2-ba4b-00a0c93ec93b'

_windows_error=""
_windows_boot_number=""
_windows_label=""
_windows_partuuid=""
_windows_partition_number=""
_windows_hd_start=""
_windows_hd_size=""
_windows_device_path=""
_windows_maj_min=""
_windows_state_boot_number=""
_windows_state_label=""
_windows_state_partuuid=""
_windows_state_loader_path=""
_windows_state_kind=""
_windows_block_state=""
_windows_block_start=-1
_windows_block_count=0
_windows_owned_mount_active=false
_windows_owned_mount_path=""
_windows_reusable_mount=""
_windows_reusable_mount_id=""
_windows_reusable_mount_access=""
_windows_target_mount_id=""
_windows_descriptor_mount_id=""
_windows_runtime_mount_override=""
_windows_inspection_file=""
_windows_preflight_result=""
_windows_preflight_firmware_state=absent
_windows_preflight_bitlocker_state=absent
_windows_preflight_loader_state=absent
_windows_preflight_firmware_seen=false
_windows_preflight_firmware_unknown=false
_windows_preflight_bitlocker_seen=false
_windows_preflight_bitlocker_unknown=false
_windows_preflight_loader_seen=false
_windows_preflight_loader_unknown=false
_windows_preflight_gum=""
_windows_bootnext_record_json=""
_windows_bootnext_record_path=""
_windows_efibootmgr_fd=""
_windows_efibootmgr_hash=""
_windows_unlink_fd=""
_windows_unlink_hash=""
_windows_recovery_plan_json=""
_windows_recovery_record_json=""
_windows_recovery_record_path=""
_windows_recovery_command_rc="null"

declare -ag _windows_order=()
declare -Ag _windows_inventory_label=()
declare -Ag _windows_inventory_active=()
declare -Ag _windows_inventory_exact=()
declare -Ag _windows_inventory_valid=()
declare -Ag _windows_inventory_partuuid=()
declare -Ag _windows_inventory_partition=()
declare -Ag _windows_inventory_start=()
declare -Ag _windows_inventory_size=()
declare -ag _windows_preflight_bitlocker_devices=()
declare -ag _windows_preflight_esp_candidates=()
declare -ag _windows_preflight_signer_records=()
declare -ag _windows_preflight_unknown_reasons=()

windows_bootnext_failpoint() {
  return 0
}

windows_recovery_failpoint() {
  return 0
}

windows_bootnext_mutation_is_available() {
  return 1
}

windows_recovery_is_available() {
  return 0
}

windows_efibootmgr_executable_path() {
  printf '%s\n' "$WINDOWS_EFIBOOTMGR_EXECUTABLE"
}

windows_unlink_executable_path() {
  printf '%s\n' "$WINDOWS_UNLINK_EXECUTABLE"
}

windows_efibootmgr_query_path() {
  if [[ "${_windows_efibootmgr_fd:-}" =~ ^[0-9]+$ ]]; then
    printf '/proc/self/fd/%s\n' "$_windows_efibootmgr_fd"
  else
    windows_efibootmgr_executable_path
  fi
}

close_windows_efibootmgr_boundary() {
  if [[ "${_windows_efibootmgr_fd:-}" =~ ^[0-9]+$ ]]; then
    exec {_windows_efibootmgr_fd}<&-
  fi
  _windows_efibootmgr_fd=""
  _windows_efibootmgr_hash=""
}

close_windows_unlink_boundary() {
  if [[ "${_windows_unlink_fd:-}" =~ ^[0-9]+$ ]]; then
    exec {_windows_unlink_fd}<&-
  fi
  _windows_unlink_fd=""
  _windows_unlink_hash=""
}

windows_reject() {
  _windows_error="$1"
  return 1
}

windows_report_error() {
  [[ -z "$_windows_error" ]] || fail "$_windows_error"
}

windows_target_state_path() {
  printf '%s/windows-enabled\n' "$(state_dir_path)"
}

windows_limine_config_path() {
  limine_config_path
}

windows_runtime_dir_path() {
  printf '/run/omasecboot\n'
}

windows_runtime_mount_path() {
  if [[ -n "$_windows_runtime_mount_override" ]]; then
    printf '%s\n' "$_windows_runtime_mount_override"
  else
    printf '%s/windows-esp\n' "$(windows_runtime_dir_path)"
  fi
}

windows_label_is_safe() {
  local label="$1" pattern
  local LC_ALL=C
  pattern='^[A-Za-z0-9][A-Za-z0-9 ._()+&-]{0,126}$'
  [[ ${#label} -ge 1 && ${#label} -le 127 && "$label" =~ $pattern \
    && "$label" != *' ' && "$label" != *\$\{* ]]
}

windows_decimal_fits_limit() {
  local value="$1" maximum="$2"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  (( ${#value} < ${#maximum} )) && return 0
  (( ${#value} == ${#maximum} )) || return 1
  local index digit maximum_digit
  for ((index=0; index < ${#maximum}; index++)); do
    digit=${value:$index:1}
    maximum_digit=${maximum:$index:1}
    (( digit < maximum_digit )) && return 0
    (( digit > maximum_digit )) && return 1
  done
  return 0
}

windows_decimal_fits_int64() {
  windows_decimal_fits_limit "$1" 9223372036854775807
}

windows_decimal_fits_json_integer() {
  windows_decimal_fits_limit "$1" 9007199254740991
}

windows_le_unsigned() {
  local -a bytes=("$@")
  local index hex=""
  [[ ${#bytes[@]} -gt 0 && ${#bytes[@]} -le 8 ]] || return 1
  for ((index=${#bytes[@]} - 1; index >= 0; index--)); do
    [[ "${bytes[$index]}" =~ ^[0-9A-Fa-f]{2}$ ]] || return 1
    hex+="${bytes[$index],,}"
  done
  if (( ${#bytes[@]} == 8 )); then
    case "${hex:0:1}" in
      [0-7]) ;;
      *) return 1 ;;
    esac
  fi
  printf '%d\n' "$((16#$hex))"
}

windows_guid_from_bytes() {
  [[ $# -eq 16 ]] || return 1
  printf '%s%s%s%s-%s%s-%s%s-%s%s-%s%s%s%s%s%s\n' \
    "${4,,}" "${3,,}" "${2,,}" "${1,,}" \
    "${6,,}" "${5,,}" "${8,,}" "${7,,}" \
    "${9,,}" "${10,,}" "${11,,}" "${12,,}" \
    "${13,,}" "${14,,}" "${15,,}" "${16,,}"
}

windows_prefix_node_is_allowed() {
  local type="${1,,}" subtype="${2,,}" node_length="$3" raw="${4,,}"
  local index null_count=0
  local -a bytes=()
  read -r -a bytes <<< "$raw"
  (( ${#bytes[@]} == node_length )) || return 1
  case "${type}:${subtype}" in
    01:01) (( node_length == 6 )) ;;
    01:02) (( node_length == 5 )) ;;
    01:03) (( node_length == 24 )) ;;
    01:04) (( node_length >= 20 )) ;;
    01:05) (( node_length == 8 )) ;;
    01:06) (( node_length == 13 )) ;;
    02:01) (( node_length == 12 )) ;;
    02:02)
      (( node_length >= 19 )) || return 1
      for ((index=16; index < node_length; index++)); do
        if [[ "${bytes[$index]}" == 00 ]]; then
          null_count=$((null_count + 1))
        elif (( 16#${bytes[$index]} > 127 )); then
          return 1
        fi
      done
      (( null_count == 3 )) && [[ "${bytes[-1]}" == 00 ]]
      ;;
    02:03) (( node_length >= 8 && (node_length - 4) % 4 == 0 )) ;;
    02:04) (( node_length == 8 )) ;;
    03:01|03:02) (( node_length == 8 )) ;;
    03:03|03:15|03:16) (( node_length == 24 )) ;;
    03:04|03:17) (( node_length == 16 )) ;;
    03:05|03:19) (( node_length == 6 )) ;;
    03:06) (( node_length == 8 )) ;;
    03:0a)
      (( node_length == 44 )) \
        && [[ "${bytes[*]:4:16}" == \
          'b4 dd 87 d4 8b 00 d9 11 af dc 00 10 83 ff ca 4d' ]]
      ;;
    03:0f) (( node_length == 11 )) ;;
    03:10) (( node_length >= 12 && node_length <= 138 \
      && (node_length - 10) % 2 == 0 )) ;;
    03:11|03:1a|03:1d) (( node_length == 5 )) ;;
    03:12) (( node_length == 10 )) ;;
    03:20) (( node_length == 20 )) ;;
    *) return 1 ;;
  esac
}

windows_parse_device_path() {
  local raw="$1" remaining node final_node=false end_seen=false
  local -a bytes=()
  local byte_pattern='^([0-9A-Fa-f]{2})( [0-9A-Fa-f]{2})+$'
  local type subtype node_length stage=prefix
  local hd_count=0 file_count=0 exact_file_count=0
  local hd_valid=false sequence_valid=true file_ascii file_path char
  local partition start size guid index low high
  local LC_ALL=C

  _windows_dp_exact=false
  _windows_dp_valid=false
  _windows_dp_partuuid=""
  _windows_dp_partition=""
  _windows_dp_start=""
  _windows_dp_size=""

  [[ -n "$raw" ]] || return 0
  remaining="$raw"
  while [[ "$final_node" == false ]]; do
    if [[ "$remaining" == *' / '* ]]; then
      node=${remaining%%' / '*}
      remaining=${remaining#*' / '}
    else
      node="$remaining"
      remaining=""
      final_node=true
    fi
    [[ "$node" =~ $byte_pattern ]] || return 1
    read -r -a bytes <<< "$node"
    (( ${#bytes[@]} >= 4 )) || return 1
    type=${bytes[0],,}
    subtype=${bytes[1],,}
    node_length=$((16#${bytes[3]} * 256 + 16#${bytes[2]}))
    (( node_length >= 4 && node_length == ${#bytes[@]} )) || return 1

    if [[ "$type" == 7f ]]; then
      case "$subtype" in
        01)
          [[ $node_length -eq 4 && "${bytes[*],,}" == '7f 01 04 00' \
            && "$final_node" == false ]] || return 1
          sequence_valid=false
          stage=prefix
          continue
          ;;
        ff)
          [[ $node_length -eq 4 && "${bytes[*],,}" == '7f ff 04 00' \
            && "$final_node" == true ]] || return 1
          [[ "$stage" == file ]] || sequence_valid=false
          end_seen=true
          break
          ;;
        *) return 1 ;;
      esac
    fi

    case "${type}:${subtype}" in
      04:01)
        hd_count=$((hd_count + 1))
        [[ "$stage" == prefix ]] || sequence_valid=false
        stage=hd
        hd_valid=false
        if (( node_length == 42 )) \
          && [[ "${bytes[40],,}" == 02 && "${bytes[41],,}" == 02 ]]; then
          partition=$(windows_le_unsigned "${bytes[@]:4:4}") || return 1
          start=$(windows_le_unsigned "${bytes[@]:8:8}") || return 1
          size=$(windows_le_unsigned "${bytes[@]:16:8}") || return 1
          guid=$(windows_guid_from_bytes "${bytes[@]:24:16}") || return 1
          hd_valid=true
          if (( hd_count == 1 )); then
            _windows_dp_partition="$partition"
            _windows_dp_start="$start"
            _windows_dp_size="$size"
            _windows_dp_partuuid="$guid"
          fi
        fi
        ;;
      04:04)
        file_count=$((file_count + 1))
        [[ "$stage" == hd && "$hd_valid" == true ]] || sequence_valid=false
        stage="file"
        (( node_length >= 6 && (node_length - 4) % 2 == 0 )) || return 1
        [[ "${bytes[node_length - 2],,}" == 00 \
          && "${bytes[node_length - 1],,}" == 00 ]] || return 1
        file_ascii=true
        file_path=""
        for ((index=4; index < node_length - 2; index+=2)); do
          low=${bytes[$index],,}
          high=${bytes[$((index + 1))],,}
          [[ "$low" != 00 || "$high" != 00 ]] || return 1
          if [[ "$high" != 00 ]] || (( 16#$low > 127 )); then
            file_ascii=false
            continue
          fi
          printf -v char '%b' "\\x${low}"
          file_path+="$char"
        done
        if [[ "$file_ascii" == true \
          && "${file_path,,}" == "${WINDOWS_LOADER_UEFI,,}" ]]; then
          exact_file_count=$((exact_file_count + 1))
        fi
        ;;
      *)
        if [[ "$stage" != prefix ]] \
          || ! windows_prefix_node_is_allowed \
            "$type" "$subtype" "$node_length" "${bytes[*]}"; then
          sequence_valid=false
        fi
        ;;
    esac
  done

  if (( exact_file_count > 0 )); then
    _windows_dp_exact=true
  fi
  if [[ "$sequence_valid" == true && "$end_seen" == true && "$hd_valid" == true \
    && $hd_count -eq 1 && $file_count -eq 1 && $exact_file_count -eq 1 ]]; then
    _windows_dp_valid=true
  fi
}

windows_reset_inventory() {
  _windows_order=()
  unset _windows_inventory_label _windows_inventory_active
  unset _windows_inventory_exact _windows_inventory_valid
  unset _windows_inventory_partuuid _windows_inventory_partition
  unset _windows_inventory_start _windows_inventory_size
  declare -gA _windows_inventory_label=()
  declare -gA _windows_inventory_active=()
  declare -gA _windows_inventory_exact=()
  declare -gA _windows_inventory_valid=()
  declare -gA _windows_inventory_partuuid=()
  declare -gA _windows_inventory_partition=()
  declare -gA _windows_inventory_start=()
  declare -gA _windows_inventory_size=()
}

windows_reset_target() {
  _windows_boot_number=""
  _windows_label=""
  _windows_partuuid=""
  _windows_partition_number=""
  _windows_hd_start=""
  _windows_hd_size=""
  _windows_device_path=""
  _windows_maj_min=""
  _windows_reusable_mount=""
  _windows_reusable_mount_id=""
  _windows_reusable_mount_access=""
  _windows_target_mount_id=""
}

windows_parse_firmware_inventory() {
  local inventory line current="" order_seen=false rest label formatted
  local raw_number boot_number active raw_dp value
  local boot_pattern='^Boot([0-9A-F]{4})([* ]) (.*)$'
  local order_pattern='^([0-9A-F]{4})(,[0-9A-F]{4})*$'
  local data_pattern='^([0-9A-Fa-f]{2})( [0-9A-Fa-f]{2})*$'
  local diagnostics_file executable old_umask command_rc=0 diagnostics=false
  local -a raw_order=()
  local -A order_numbers=() dp_seen=()
  local LC_ALL=C

  _windows_error=""
  windows_reset_target
  windows_reset_inventory
  executable=$(windows_efibootmgr_query_path) || return 1
  [[ -x "$executable" ]] || {
    windows_reject "efibootmgr is required for Windows target discovery"
    return 1
  }
  old_umask=$(umask) || return 1
  umask 077
  diagnostics_file=$(mktemp "${TMPDIR:-/tmp}/omasecboot-efibootmgr.XXXXXX" \
    2>/dev/null) || {
    umask "$old_umask"
    windows_reject "Could not prepare EFI boot-entry diagnostics"
    return 1
  }
  umask "$old_umask"
  inventory=$(LC_ALL=C "$executable" -v 2> "$diagnostics_file") || command_rc=$?
  [[ ! -s "$diagnostics_file" ]] || diagnostics=true
  rm -f "$diagnostics_file" 2>/dev/null || {
    windows_reject "Could not remove EFI boot-entry diagnostics"
    return 1
  }
  if [[ $command_rc -ne 0 ]]; then
    windows_reject "Could not read EFI boot entries"
    return 1
  fi
  if [[ "$diagnostics" == true ]]; then
    windows_reject "efibootmgr reported incomplete EFI boot-entry inventory"
    return 1
  fi
  [[ -n "$inventory" ]] || {
    windows_reject "EFI boot entry inventory is empty"
    return 1
  }

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$current" && -z "${dp_seen[$current]:-}" \
      && "$line" != '      dp: '* ]]; then
      windows_reject "Boot${current} has no immediately associated raw device path"
      return 1
    fi
    if [[ "$line" == BootOrder:\ * ]]; then
      [[ "$order_seen" == false ]] || {
        windows_reject "EFI inventory contains multiple BootOrder records"
        return 1
      }
      value=${line#BootOrder: }
      [[ "$value" =~ $order_pattern ]] || {
        windows_reject "EFI BootOrder is malformed"
        return 1
      }
      IFS=',' read -r -a raw_order <<< "$value"
      (( ${#raw_order[@]} <= 128 )) || {
        windows_reject "EFI BootOrder exceeds Limine's 128-entry limit"
        return 1
      }
      for raw_number in "${raw_order[@]}"; do
        boot_number=${raw_number^^}
        [[ -z "${order_numbers[$boot_number]:-}" ]] || {
          windows_reject "EFI BootOrder contains duplicate Boot${boot_number}"
          return 1
        }
        order_numbers["$boot_number"]=1
        _windows_order+=("$boot_number")
      done
      order_seen=true
      continue
    fi

    if [[ "$line" =~ $boot_pattern ]]; then
      if [[ -n "$current" && -z "${dp_seen[$current]:-}" ]]; then
        windows_reject "Boot${current} has no raw device path"
        return 1
      fi
      boot_number=${BASH_REMATCH[1]^^}
      active=${BASH_REMATCH[2]}
      rest=${BASH_REMATCH[3]}
      [[ -z "${_windows_inventory_active[$boot_number]:-}" ]] || {
        windows_reject "EFI inventory contains duplicate Boot${boot_number}"
        return 1
      }
      [[ "$rest" == *$'\t'* ]] || {
        windows_reject "Boot${boot_number} has an ambiguous description record"
        return 1
      }
      label=${rest%%$'\t'*}
      formatted=${rest#*$'\t'}
      [[ "$formatted" != *$'\t'* ]] || {
        windows_reject "Boot${boot_number} contains an ambiguous tab-delimited record"
        return 1
      }
      _windows_inventory_label["$boot_number"]="$label"
      if [[ "$active" == '*' ]]; then
        _windows_inventory_active["$boot_number"]=true
      else
        _windows_inventory_active["$boot_number"]=false
      fi
      current="$boot_number"
      continue
    fi

    if [[ "$line" == '      dp: '* ]]; then
      [[ -n "$current" && -z "${dp_seen[$current]:-}" ]] || {
        windows_reject "EFI inventory contains an orphan or duplicate raw device path"
        return 1
      }
      raw_dp=${line#'      dp: '}
      windows_parse_device_path "$raw_dp" || {
        windows_reject "Boot${current} has a malformed raw device path"
        return 1
      }
      dp_seen["$current"]=1
      _windows_inventory_exact["$current"]="$_windows_dp_exact"
      _windows_inventory_valid["$current"]="$_windows_dp_valid"
      _windows_inventory_partuuid["$current"]="$_windows_dp_partuuid"
      _windows_inventory_partition["$current"]="$_windows_dp_partition"
      _windows_inventory_start["$current"]="$_windows_dp_start"
      _windows_inventory_size["$current"]="$_windows_dp_size"
      continue
    fi

    if [[ "$line" == '    data: '* ]]; then
      [[ -n "$current" && -n "${dp_seen[$current]:-}" \
        && "${line#'    data: '}" =~ $data_pattern ]] || {
        windows_reject "Boot${current:-unknown} has malformed optional data"
        return 1
      }
      continue
    fi

    case "$line" in
      BootCurrent:\ [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]|\
      BootNext:\ [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]|\
      Timeout:\ *\ seconds|\
      MirroredPercentageAbove4G:\ *|\
      MirrorMemoryBelow4GB:\ true|\
      MirrorMemoryBelow4GB:\ false|\
      MirrorStatus:\ *|\
      DesiredMirroredPercentageAbove4G:\ *|\
      DesiredMirrorMemoryBelow4GB:\ true|\
      DesiredMirrorMemoryBelow4GB:\ false|\
      RequestMirroredPercentageAbove4G:\ *|\
      RequestMirrorMemoryBelow4GB:\ true|\
      RequestMirrorMemoryBelow4GB:\ false)
        ;;
      *)
        windows_reject "EFI inventory contains an unsupported record"
        return 1
        ;;
    esac
  done <<< "$inventory"

  [[ "$order_seen" == true && ${#_windows_order[@]} -gt 0 ]] || {
    windows_reject "EFI BootOrder is missing or empty"
    return 1
  }
  if [[ -n "$current" && -z "${dp_seen[$current]:-}" ]]; then
    windows_reject "Boot${current} has no raw device path"
    return 1
  fi
  for boot_number in "${_windows_order[@]}"; do
    [[ -n "${_windows_inventory_active[$boot_number]:-}" \
      && -n "${dp_seen[$boot_number]:-}" ]] || {
      windows_reject "BootOrder entry Boot${boot_number} is missing or unreadable"
      return 1
    }
  done
}

windows_select_firmware_target() {
  local boot_number candidate="" candidate_count=0 order_count=0
  local label label_fold match_count=0 first_match=""
  local LC_ALL=C

  for boot_number in "${!_windows_inventory_exact[@]}"; do
    if [[ "${_windows_inventory_exact[$boot_number]}" == true ]]; then
      candidate="$boot_number"
      candidate_count=$((candidate_count + 1))
    fi
  done
  (( candidate_count == 1 )) \
    || windows_reject "Expected exactly one Windows boot loader target; found ${candidate_count}" \
    || return 1
  [[ "${_windows_inventory_valid[$candidate]}" == true ]] || {
    windows_reject "Boot${candidate} does not have a supported local HD/File device path"
    return 1
  }
  [[ "${_windows_inventory_active[$candidate]}" == true ]] || {
    windows_reject "Windows target Boot${candidate} is inactive"
    return 1
  }

  for boot_number in "${_windows_order[@]}"; do
    [[ "$boot_number" != "$candidate" ]] || order_count=$((order_count + 1))
  done
  (( order_count == 1 )) || {
    windows_reject "Windows target Boot${candidate} is not uniquely present in BootOrder"
    return 1
  }

  label=${_windows_inventory_label[$candidate]}
  windows_label_is_safe "$label" || {
    windows_reject "Windows firmware label uses unsupported characters"
    return 1
  }
  label_fold=${label,,}
  for boot_number in "${_windows_order[@]}"; do
    if [[ "${_windows_inventory_label[$boot_number],,}" == "$label_fold" ]]; then
      [[ -n "$first_match" ]] || first_match="$boot_number"
      match_count=$((match_count + 1))
    fi
  done
  [[ $match_count -eq 1 && "$first_match" == "$candidate" ]] || {
    windows_reject "Windows firmware label does not resolve uniquely under Limine BootOrder rules"
    return 1
  }

  _windows_boot_number="$candidate"
  _windows_label="$label"
  _windows_partuuid=${_windows_inventory_partuuid[$candidate],,}
  _windows_partition_number=${_windows_inventory_partition[$candidate]}
  _windows_hd_start=${_windows_inventory_start[$candidate]}
  _windows_hd_size=${_windows_inventory_size[$candidate]}
}

# Structural, unprivileged probe used by the Quattro guard.
find_windows_boot_entry() {
  windows_parse_firmware_inventory || return 1
  windows_select_firmware_target || return 1
  printf '%s\t%s\n' "$_windows_boot_number" "$_windows_label"
}

windows_block_device_matches() {
  local path="$1" expected="$2" major_hex minor_hex actual
  [[ ! -L "$path" && -b "$path" ]] || return 1
  read -r major_hex minor_hex < <(stat -Lc '%t %T' "$path" 2>/dev/null) \
    || return 1
  [[ "$major_hex" =~ ^[0-9a-fA-F]+$ && "$minor_hex" =~ ^[0-9a-fA-F]+$ ]] \
    || return 1
  actual="$((16#$major_hex)):$((16#$minor_hex))"
  [[ "$actual" == "$expected" ]]
}

windows_map_target_esp() {
  local json rows row path maj_min partn partuuid parttype start size log_sec fstype
  local maximum=9223372036854775807
  local -a candidates=()

  json=$(LC_ALL=C lsblk --json --bytes --paths --list \
    --output PATH,MAJ:MIN,TYPE,PARTN,PARTUUID,PARTTYPE,START,SIZE,LOG-SEC,FSTYPE \
    2>/dev/null) || {
    windows_reject "Could not read block-device inventory"
    return 1
  }
  jq -e '
    (.blockdevices | type) == "array" and
    all(.blockdevices[];
      type == "object" and
      (keys == ["fstype", "log-sec", "maj:min", "partn", "parttype", "partuuid", "path", "size", "start", "type"]) and
      (.path | type) == "string" and
      (."maj:min" | type) == "string" and
      (.type | type) == "string" and
      (.partn == null or ((.partn | type) == "number" and .partn >= 0 and .partn <= 9007199254740991 and (.partn | floor) == .partn)) and
      (.partuuid == null or (.partuuid | type) == "string") and
      (.parttype == null or (.parttype | type) == "string") and
      (.start == null or ((.start | type) == "number" and .start >= 0 and .start <= 9007199254740991 and (.start | floor) == .start)) and
      (.size == null or ((.size | type) == "number" and .size >= 0 and .size <= 9007199254740991 and (.size | floor) == .size)) and
      (."log-sec" == null or ((."log-sec" | type) == "number" and ."log-sec" >= 0 and ."log-sec" <= 9007199254740991 and (."log-sec" | floor) == ."log-sec")) and
      (.fstype == null or (.fstype | type) == "string"))
  ' <<< "$json" >/dev/null 2>&1 || {
    windows_reject "Block-device inventory has an unsupported JSON shape"
    return 1
  }
  rows=$(jq -c --arg uuid "$_windows_partuuid" '
    .blockdevices[] |
    select(.type == "part" and ((.partuuid // "") | ascii_downcase) == $uuid)
  ' <<< "$json") || return 1
  [[ -z "$rows" ]] || mapfile -t candidates <<< "$rows"
  (( ${#candidates[@]} == 1 )) || {
    windows_reject "Windows PARTUUID maps to ${#candidates[@]} block devices"
    return 1
  }
  row=${candidates[0]}
  jq -e '
    (.partn | type) == "number" and
    (.partuuid | type) == "string" and
    (.parttype | type) == "string" and
    (.start | type) == "number" and
    (.size | type) == "number" and
    (."log-sec" | type) == "number" and
    (.fstype | type) == "string"
  ' <<< "$row" >/dev/null || {
    windows_reject "Windows ESP mapping is incomplete"
    return 1
  }

  path=$(jq -r '.path' <<< "$row") || return 1
  maj_min=$(jq -r '."maj:min"' <<< "$row") || return 1
  partn=$(jq -r '.partn' <<< "$row") || return 1
  partuuid=$(jq -r '.partuuid' <<< "$row") || return 1
  parttype=$(jq -r '.parttype' <<< "$row") || return 1
  start=$(jq -r '.start' <<< "$row") || return 1
  size=$(jq -r '.size' <<< "$row") || return 1
  log_sec=$(jq -r '."log-sec"' <<< "$row") || return 1
  fstype=$(jq -r '.fstype' <<< "$row") || return 1

  [[ "$path" =~ ^/dev/[A-Za-z0-9._/+:-]+$ \
    && "$maj_min" =~ ^[0-9]+:[0-9]+$ \
    && "$partn" == "$_windows_partition_number" \
    && "${partuuid,,}" == "$_windows_partuuid" \
    && "${parttype,,}" == "$WINDOWS_ESP_PARTTYPE" \
    && "$fstype" == vfat ]] || {
    windows_reject "Windows target does not map to the expected FAT ESP"
    return 1
  }
  if ! windows_decimal_fits_json_integer "$start" \
    || ! windows_decimal_fits_json_integer "$size" \
    || ! windows_decimal_fits_json_integer "$log_sec"; then
    windows_reject "Windows ESP geometry is out of range"
    return 1
  fi
  case "$log_sec" in
    512|1024|2048|4096) ;;
    *)
      windows_reject "Windows ESP has an unsupported logical sector size"
      return 1
      ;;
  esac
  (( _windows_hd_start <= maximum / log_sec \
    && start <= maximum / 512 \
    && _windows_hd_size <= maximum / log_sec \
    && _windows_hd_start * log_sec == start * 512 \
    && _windows_hd_size * log_sec == size )) || {
    windows_reject "Windows ESP geometry does not match the firmware HD node"
    return 1
  }
  windows_block_device_matches "$path" "$maj_min" || {
    windows_reject "Windows ESP device identity changed during mapping"
    return 1
  }

  _windows_device_path="$path"
  _windows_maj_min="$maj_min"
}

windows_mount_locks_are_owned() {
  [[ "${_OMASECBOOT_LIMINE_LOCK_OWNED:-false}" != false \
    && "${_OMASECBOOT_REPAIR_LOCK_OWNED:-false}" == true ]]
}

windows_reconcile_runtime_mount() {
  local runtime mount_path mount_json
  windows_mount_locks_are_owned || return 1
  runtime=$(windows_runtime_dir_path) || return 1
  mount_path=$(windows_runtime_mount_path) || return 1
  validate_control_directory "$(dirname "$runtime")" || return 1
  if [[ ! -e "$runtime" && ! -L "$runtime" ]]; then
    return 0
  fi
  validate_private_control_directory "$runtime" || return 1
  if [[ ! -e "$mount_path" && ! -L "$mount_path" ]]; then
    return 0
  fi
  path_has_no_symlink_components "$mount_path" \
    && [[ -d "$mount_path" && ! -L "$mount_path" ]] || return 1
  if mount_json=$(LC_ALL=C findmnt --json --list --mountpoint "$mount_path" \
    --output TARGET,MAJ:MIN,FSTYPE,FSROOT 2>/dev/null); then
    jq -e --arg target "$mount_path" --arg maj "$_windows_maj_min" '
      (.filesystems | type) == "array" and
      (.filesystems | length) == 1 and
      (.filesystems[0] | keys) == ["fsroot", "fstype", "maj:min", "target"] and
      .filesystems[0].target == $target and
      .filesystems[0]."maj:min" == $maj and
      .filesystems[0].fstype == "vfat" and
      .filesystems[0].fsroot == "/"
    ' <<< "$mount_json" >/dev/null || return 1
    umount -- "$mount_path" || return 1
  fi
  validate_private_control_directory "$mount_path" || return 1
  rmdir -- "$mount_path" || return 1
}

windows_find_reusable_mount() {
  local owned json rows row target mount_id fstype fsroot vfs_options mount_access
  local -a mounts=() candidates=()
  owned=$(windows_runtime_mount_path) || return 1
  json=$(LC_ALL=C findmnt --json --list \
    --output TARGET,ID,MAJ:MIN,FSTYPE,FSROOT,VFS-OPTIONS 2>/dev/null) || {
    windows_reject "Could not read mount inventory"
    return 1
  }
  jq -e '
    (.filesystems | type) == "array" and
    all(.filesystems[];
      type == "object" and
      (keys == ["fsroot", "fstype", "id", "maj:min", "target", "vfs-options"]) and
      (.target | type) == "string" and
      (.id | type) == "number" and .id >= 1 and (.id | floor) == .id and
      (."maj:min" | type) == "string" and
      (.fstype | type) == "string" and
      (.fsroot | type) == "string" and
      (."vfs-options" | type) == "string")
  ' <<< "$json" >/dev/null 2>&1 || {
    windows_reject "Mount inventory has an unsupported JSON shape"
    return 1
  }
  rows=$(jq -c --arg maj "$_windows_maj_min" --arg owned "$owned" '
    .filesystems[] |
    select(."maj:min" == $maj and .target != $owned)
  ' <<< "$json") || return 1
  [[ -z "$rows" ]] || mapfile -t mounts <<< "$rows"
  for row in "${mounts[@]}"; do
    target=$(jq -r '.target' <<< "$row") || return 1
    mount_id=$(jq -r '.id' <<< "$row") || return 1
    fstype=$(jq -r '.fstype' <<< "$row") || return 1
    fsroot=$(jq -r '.fsroot' <<< "$row") || return 1
    vfs_options=$(jq -r '."vfs-options"' <<< "$row") || return 1
    [[ "$fstype" == vfat && "$fsroot" == / ]] || {
      windows_reject "Windows ESP has an unsupported same-device mount alias"
      return 1
    }
    if [[ ! ( ",${vfs_options}," == *,ro,* && ",${vfs_options}," != *,rw,* ) \
      && ! ( ",${vfs_options}," == *,rw,* && ",${vfs_options}," != *,ro,* ) ]]; then
      windows_reject "Windows ESP mount has unsupported VFS access options"
      return 1
    fi
    candidates+=("$row")
  done
  (( ${#candidates[@]} <= 1 )) || {
    windows_reject "Windows ESP has multiple reusable mounts"
    return 1
  }
  if (( ${#candidates[@]} == 0 )); then
    _windows_reusable_mount=""
    _windows_reusable_mount_id=""
    _windows_reusable_mount_access=""
    return 0
  fi
  row=${candidates[0]}
  target=$(jq -r '.target' <<< "$row") || return 1
  mount_id=$(jq -r '.id' <<< "$row") || return 1
  vfs_options=$(jq -r '."vfs-options"' <<< "$row") || return 1
  if [[ ",${vfs_options}," == *,ro,* && ",${vfs_options}," != *,rw,* ]]; then
    mount_access=ro
  else
    mount_access=rw
  fi
  if [[ "$target" =~ ^/[^[:cntrl:]]+$ ]] \
    && windows_path_has_controlled_ancestors "$target"; then
    _windows_reusable_mount="$target"
    _windows_reusable_mount_id="$mount_id"
    _windows_reusable_mount_access="$mount_access"
  elif [[ "$mount_access" == rw ]]; then
    windows_reject "Windows ESP has an uncontrolled writable mount"
    return 1
  else
    _windows_reusable_mount=""
    _windows_reusable_mount_id=""
    _windows_reusable_mount_access=""
  fi
}

windows_path_has_controlled_ancestors() {
  local path="$1" owner uid mode parent
  path_has_no_symlink_components "$path" || return 1
  owner=$(control_owner_uid) || return 1
  while true; do
    [[ -d "$path" && ! -L "$path" ]] || return 1
    read -r uid mode < <(stat -Lc '%u %a' "$path" 2>/dev/null) || return 1
    if [[ "$uid" == "$owner" ]] && mode_is_control_safe "$mode"; then
      :
    elif [[ "$uid" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] \
      && { mode_is_control_safe "$mode" || (( (8#$mode & 01000) != 0 )); }; then
      :
    else
      return 1
    fi
    [[ "$path" == / ]] && return 0
    parent=$(dirname -- "$path") || return 1
    [[ "$parent" != "$path" ]] || return 1
    path="$parent"
  done
}

windows_prepare_runtime_directory() {
  local runtime
  runtime=$(windows_runtime_dir_path) || return 1
  if [[ ! -e "$runtime" && ! -L "$runtime" ]]; then
    install -d -m 700 "$runtime" || return 1
  fi
  validate_private_control_directory "$runtime" || return 1
}

windows_prepare_runtime_mountpoint() {
  local mount_path
  windows_prepare_runtime_directory || return 1
  mount_path=$(windows_runtime_mount_path) || return 1
  [[ ! -e "$mount_path" && ! -L "$mount_path" ]] || return 1
  install -d -m 700 "$mount_path" || return 1
  validate_private_control_directory "$mount_path"
}

windows_target_mount_is_valid() {
  local mount_path="$1" expected_id="$2" expected_access="$3" json mount_id
  [[ "$expected_access" == ro || "$expected_access" == rw ]] || return 1
  json=$(LC_ALL=C findmnt --json --list --mountpoint "$mount_path" \
    --output TARGET,ID,MAJ:MIN,FSTYPE,FSROOT,VFS-OPTIONS 2>/dev/null) || return 1
  jq -e --arg target "$mount_path" --arg maj "$_windows_maj_min" \
    --arg expected_id "$expected_id" --arg expected_access "$expected_access" '
    (.filesystems | type) == "array" and
    (.filesystems | length) == 1 and
    (.filesystems[0] | keys) == ["fsroot", "fstype", "id", "maj:min", "target", "vfs-options"] and
    .filesystems[0].target == $target and
    (.filesystems[0].id | type) == "number" and
    .filesystems[0].id >= 1 and
    (.filesystems[0].id | floor) == .filesystems[0].id and
    ($expected_id == "" or (.filesystems[0].id | tostring) == $expected_id) and
    .filesystems[0]."maj:min" == $maj and
    .filesystems[0].fstype == "vfat" and
    .filesystems[0].fsroot == "/" and
    (
      ($expected_access == "ro" and
        (("," + .filesystems[0]."vfs-options" + ",") | contains(",ro,")) and
        ((("," + .filesystems[0]."vfs-options" + ",") | contains(",rw,")) | not)) or
      ($expected_access == "rw" and
        (("," + .filesystems[0]."vfs-options" + ",") | contains(",rw,")) and
        ((("," + .filesystems[0]."vfs-options" + ",") | contains(",ro,")) | not))
    )
  ' <<< "$json" >/dev/null || return 1
  mount_id=$(jq -r '.filesystems[0].id' <<< "$json") || return 1
  _windows_target_mount_id="$mount_id"
}

windows_descriptor_mount_id() {
  local fd_path="$1" pattern fd_number line mount_id="" count=0
  _windows_descriptor_mount_id=""
  pattern="^/proc/${BASHPID}/fd/([0-9]+)$"
  [[ "$fd_path" =~ $pattern ]] || return 1
  fd_number=${BASH_REMATCH[1]}
  while IFS= read -r line; do
    if [[ "$line" =~ ^mnt_id:[[:space:]]+([1-9][0-9]*)$ ]]; then
      mount_id=${BASH_REMATCH[1]}
      count=$((count + 1))
    fi
  done < "/proc/${BASHPID}/fdinfo/${fd_number}" || return 1
  (( count == 1 )) || return 1
  _windows_descriptor_mount_id="$mount_id"
}

windows_loader_descriptor_mount_is_valid() {
  local fd_path="$1" expected_mount_id="$2"
  windows_descriptor_mount_id "$fd_path" || return 1
  [[ "$_windows_descriptor_mount_id" == "$expected_mount_id" ]]
}

windows_loader_mount_cleanup() {
  local rc="$1" cleanup_rc=0 runtime
  trap - EXIT INT TERM HUP
  if [[ -n "$_windows_inspection_file" ]]; then
    runtime=$(windows_runtime_dir_path) || cleanup_rc=1
    case "$_windows_inspection_file" in
      "${runtime}"/bootmgfw.*)
        rm -f -- "$_windows_inspection_file" || cleanup_rc=1
        ;;
      *) cleanup_rc=1 ;;
    esac
    _windows_inspection_file=""
  fi
  if [[ "$_windows_owned_mount_active" == true ]]; then
    if LC_ALL=C findmnt --mountpoint "$_windows_owned_mount_path" >/dev/null 2>&1; then
      umount -- "$_windows_owned_mount_path" || cleanup_rc=1
    fi
    rmdir -- "$_windows_owned_mount_path" || cleanup_rc=1
  fi
  [[ $cleanup_rc -eq 0 ]] || rc=1
  exit "$rc"
}

windows_verify_loader_file() {
  local mount_path="$1" mount_id="$2" loader loader_fd fd_path
  local identity_before identity_after path_identity_before path_identity_after
  local maj_min inode size magic
  loader="${mount_path}${WINDOWS_LOADER_POSIX}"
  [[ -f "$loader" && ! -L "$loader" ]] || return 1
  exec {loader_fd}< "$loader" || return 1
  fd_path="/proc/${BASHPID}/fd/${loader_fd}"
  if ! windows_loader_descriptor_mount_is_valid "$fd_path" "$mount_id" \
    || [[ ! -f "$fd_path" ]] \
    || ! read -r maj_min inode size \
      < <(stat -Lc '%Hd:%Ld %i %s' "$fd_path" 2>/dev/null) \
    || [[ "$maj_min" != "$_windows_maj_min" ]] \
    || ! windows_decimal_fits_int64 "$size" \
    || (( size < 64 )); then
    exec {loader_fd}<&-
    return 1
  fi
  identity_before="${maj_min}:${inode}:${size}"
  if ! path_identity_before=$(stat -Lc '%Hd:%Ld:%i:%s' "$loader" 2>/dev/null) \
    || [[ "$identity_before" != "$path_identity_before" ]]; then
    exec {loader_fd}<&-
    return 1
  fi
  magic=$(dd bs=2 count=1 iflag=fullblock,noatime status=none \
    <&"$loader_fd" 2>/dev/null \
    | od -An -tx1 | tr -d '[:space:]') || {
    exec {loader_fd}<&-
    return 1
  }
  if [[ "$magic" != 4d5a ]] \
    || ! windows_loader_descriptor_mount_is_valid "$fd_path" "$mount_id" \
    || ! identity_after=$(stat -Lc '%Hd:%Ld:%i:%s' "$fd_path" 2>/dev/null) \
    || [[ -L "$loader" ]] \
    || ! path_identity_after=$(stat -Lc '%Hd:%Ld:%i:%s' "$loader" 2>/dev/null); then
    exec {loader_fd}<&-
    return 1
  fi
  exec {loader_fd}<&-
  [[ "$identity_before" == "$identity_after" \
    && "$identity_before" == "$path_identity_after" ]]
}

windows_with_target_mount() {
  local callback="$1" mount_override="${2:-}"
  (
    local mount_path expected_mount_id="" expected_mount_access=ro callback_rc=0
    _windows_runtime_mount_override="$mount_override"
    _windows_owned_mount_active=false
    _windows_owned_mount_path=""
    _windows_inspection_file=""
    trap 'windows_loader_mount_cleanup $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    windows_mount_locks_are_owned || exit 1
    windows_reconcile_runtime_mount || exit 1
    windows_find_reusable_mount || exit 1
    if [[ -n "$_windows_reusable_mount" ]]; then
      mount_path="$_windows_reusable_mount"
      expected_mount_id="$_windows_reusable_mount_id"
      expected_mount_access="$_windows_reusable_mount_access"
    else
      windows_prepare_runtime_mountpoint || exit 1
      mount_path=$(windows_runtime_mount_path) || exit 1
      _windows_owned_mount_active=true
      _windows_owned_mount_path="$mount_path"
      mount -t vfat -o ro,nosuid,nodev,noexec,noatime,dmask=0077,fmask=0177 -- \
        "$_windows_device_path" "$mount_path" || exit 1
    fi
    windows_target_mount_is_valid \
      "$mount_path" "$expected_mount_id" "$expected_mount_access" || exit 1
    "$callback" "$mount_path" "$_windows_target_mount_id" || callback_rc=$?
    case "$callback_rc" in
      0|2) ;;
      *) exit "$callback_rc" ;;
    esac
    windows_target_mount_is_valid \
      "$mount_path" "$_windows_target_mount_id" "$expected_mount_access" || exit 1
    exit "$callback_rc"
  )
}

windows_verify_target_loader() {
  local rc=0
  windows_with_target_mount windows_verify_loader_file || rc=$?
  if [[ $rc -ne 0 ]]; then
    windows_reject "Windows boot manager failed the read-only target proof"
    return 1
  fi
}

resolve_windows_target() {
  local command
  for command in dd dirname efibootmgr findmnt install jq lsblk mktemp mount od \
    readlink rm rmdir stat tr umount; do
    command -v "$command" >/dev/null 2>&1 || {
      windows_reject "Required Windows target tool is unavailable: ${command}"
      return 1
    }
  done
  windows_parse_firmware_inventory || return 1
  windows_select_firmware_target || return 1
  windows_map_target_esp || return 1
  windows_verify_target_loader || return 1
}

windows_preflight_reset() {
  _windows_preflight_result=""
  _windows_preflight_firmware_state=absent
  _windows_preflight_bitlocker_state=absent
  _windows_preflight_loader_state=absent
  _windows_preflight_firmware_seen=false
  _windows_preflight_firmware_unknown=false
  _windows_preflight_bitlocker_seen=false
  _windows_preflight_bitlocker_unknown=false
  _windows_preflight_loader_seen=false
  _windows_preflight_loader_unknown=false
  _windows_preflight_gum=""
  _windows_preflight_bitlocker_devices=()
  _windows_preflight_esp_candidates=()
  _windows_preflight_signer_records=()
  _windows_preflight_unknown_reasons=()
}

windows_preflight_mark_unknown() {
  local detector="$1" reason="$2"
  case "$detector" in
    firmware) _windows_preflight_firmware_unknown=true ;;
    bitlocker) _windows_preflight_bitlocker_unknown=true ;;
    loader) _windows_preflight_loader_unknown=true ;;
    *) return 1 ;;
  esac
  _windows_preflight_unknown_reasons+=("$reason")
}

windows_preflight_finalize_states() {
  local detector seen unknown state
  for detector in firmware bitlocker loader; do
    case "$detector" in
      firmware)
        seen=$_windows_preflight_firmware_seen
        unknown=$_windows_preflight_firmware_unknown
        ;;
      bitlocker)
        seen=$_windows_preflight_bitlocker_seen
        unknown=$_windows_preflight_bitlocker_unknown
        ;;
      loader)
        seen=$_windows_preflight_loader_seen
        unknown=$_windows_preflight_loader_unknown
        ;;
    esac
    if [[ "$unknown" == true ]]; then
      state=unknown
    elif [[ "$seen" == true ]]; then
      state=present
    else
      state=absent
    fi
    case "$detector" in
      firmware) _windows_preflight_firmware_state=$state ;;
      bitlocker) _windows_preflight_bitlocker_state=$state ;;
      loader) _windows_preflight_loader_state=$state ;;
    esac
  done
}

windows_preflight_detect_firmware() {
  local boot_number label
  if ! windows_parse_firmware_inventory; then
    windows_preflight_mark_unknown firmware \
      "Firmware Windows detection is inconclusive: ${_windows_error:-EFI inventory failed validation}"
    return 0
  fi
  for boot_number in "${!_windows_inventory_label[@]}"; do
    label=${_windows_inventory_label[$boot_number]}
    if [[ "${_windows_inventory_exact[$boot_number]:-false}" == true \
      || "${label,,}" == "windows boot manager" ]]; then
      _windows_preflight_firmware_seen=true
    fi
  done
}

windows_preflight_probe_type() {
  local path="$1" expected="$2" output rc=0
  output=$(LC_ALL=C blkid --probe --match-types "$expected" \
    --output value --match-tag TYPE -- "$path" 2>/dev/null) || rc=$?
  if [[ $rc -eq 0 && "$output" == "$expected" ]]; then
    return 0
  fi
  if [[ $rc -eq 2 && -z "$output" ]]; then
    return 2
  fi
  return 1
}

windows_preflight_device_is_external() {
  local removable="$1" transport="${2,,}" subsystems="${3,,}"
  [[ "$removable" == true ]] && return 0
  case "$transport" in
    usb|ieee1394) return 0 ;;
  esac
  case ":${subsystems}:" in
    *:usb:*|*:thunderbolt:*|*:firewire:*) return 0 ;;
  esac
  return 1
}

windows_preflight_read_block_inventory() {
  local json rows row path maj_min parttype removable transport subsystems rc
  local -a partitions=()
  local -A seen_paths=() seen_devices=()

  if ! command -v lsblk >/dev/null 2>&1 \
    || ! command -v blkid >/dev/null 2>&1 \
    || ! command -v jq >/dev/null 2>&1; then
    windows_preflight_mark_unknown bitlocker \
      "BitLocker detection requires util-linux and jq"
    windows_preflight_mark_unknown loader \
      "ESP loader detection requires util-linux and jq"
    return 0
  fi
  if ! json=$(LC_ALL=C lsblk --json --paths --list \
    --output PATH,MAJ:MIN,TYPE,PARTTYPE,RM,TRAN,SUBSYSTEMS 2>/dev/null); then
    windows_preflight_mark_unknown bitlocker \
      "Could not read the block-device inventory"
    windows_preflight_mark_unknown loader \
      "Could not read the ESP inventory"
    return 0
  fi
  if ! jq -e '
    (.blockdevices | type) == "array" and
    all(.blockdevices[];
      type == "object" and
      (keys == ["maj:min", "parttype", "path", "rm", "subsystems", "tran", "type"]) and
      (.path | type) == "string" and
      (."maj:min" | type) == "string" and
      (.type | type) == "string" and
      (.parttype == null or (.parttype | type) == "string") and
      (.rm | type) == "boolean" and
      (.tran == null or (.tran | type) == "string") and
      (.subsystems == null or (.subsystems | type) == "string"))
  ' <<< "$json" >/dev/null 2>&1; then
    windows_preflight_mark_unknown bitlocker \
      "Block-device inventory has an unsupported JSON shape"
    windows_preflight_mark_unknown loader \
      "ESP inventory has an unsupported JSON shape"
    return 0
  fi
  rows=$(jq -c '.blockdevices[] | select(.type == "part")' <<< "$json") \
    || return 1
  [[ -z "$rows" ]] || mapfile -t partitions <<< "$rows"

  for row in "${partitions[@]}"; do
    path=$(jq -r '.path' <<< "$row") || return 1
    maj_min=$(jq -r '."maj:min"' <<< "$row") || return 1
    parttype=$(jq -r '.parttype // ""' <<< "$row") || return 1
    removable=$(jq -r '.rm' <<< "$row") || return 1
    transport=$(jq -r '.tran // ""' <<< "$row") || return 1
    subsystems=$(jq -r '.subsystems // ""' <<< "$row") || return 1
    if [[ ! "$path" =~ ^/dev/[A-Za-z0-9._/+:-]+$ \
      || ! "$maj_min" =~ ^[0-9]+:[0-9]+$ \
      || -n "${seen_paths[$path]:-}" \
      || -n "${seen_devices[$maj_min]:-}" ]] \
      || ! windows_block_device_matches "$path" "$maj_min"; then
      windows_preflight_mark_unknown bitlocker \
        "A partition identity changed during BitLocker detection"
      if [[ "${parttype,,}" == "$WINDOWS_ESP_PARTTYPE" ]]; then
        windows_preflight_mark_unknown loader \
          "An ESP identity changed during loader detection"
      fi
      continue
    fi
    seen_paths["$path"]=1
    seen_devices["$maj_min"]=1

    rc=0
    windows_preflight_probe_type "$path" BitLocker || rc=$?
    case "$rc" in
      0)
        _windows_preflight_bitlocker_seen=true
        _windows_preflight_bitlocker_devices+=("$path")
        ;;
      2) ;;
      *)
        windows_preflight_mark_unknown bitlocker \
          "BitLocker signature probing is inconclusive for ${path}"
        ;;
    esac

    [[ "${parttype,,}" == "$WINDOWS_ESP_PARTTYPE" ]] || continue
    if windows_preflight_device_is_external \
      "$removable" "$transport" "$subsystems"; then
      windows_preflight_mark_unknown loader \
        "External ESP ${path} was not mounted; disconnect external boot media and retry"
      continue
    fi
    rc=0
    windows_preflight_probe_type "$path" vfat || rc=$?
    case "$rc" in
      0) _windows_preflight_esp_candidates+=("${path}"$'\t'"${maj_min}") ;;
      2)
        windows_preflight_mark_unknown loader \
          "Internal ESP ${path} is not a directly identified FAT filesystem"
        ;;
      *)
        windows_preflight_mark_unknown loader \
          "FAT signature probing is inconclusive for ESP ${path}"
        ;;
    esac
  done
}

windows_preflight_mount_path() {
  local maj_min="$1"
  [[ "$maj_min" =~ ^([0-9]+):([0-9]+)$ ]] || return 1
  printf '%s/windows-preflight-%s-%s\n' \
    "$(windows_runtime_dir_path)" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

windows_copy_loader_for_inspection() {
  local mount_path="$1" mount_id="$2" loader loader_fd fd_path runtime
  local maj_min inode size identity_before identity_after path_before path_after
  local copy_size magic old_umask
  loader="${mount_path}${WINDOWS_LOADER_POSIX}"
  [[ -f "$loader" && ! -L "$loader" ]] || return 1
  exec {loader_fd}< "$loader" || return 1
  fd_path="/proc/${BASHPID}/fd/${loader_fd}"
  if ! windows_loader_descriptor_mount_is_valid "$fd_path" "$mount_id" \
    || [[ ! -f "$fd_path" ]] \
    || ! read -r maj_min inode size \
      < <(stat -Lc '%Hd:%Ld %i %s' "$fd_path" 2>/dev/null) \
    || [[ "$maj_min" != "$_windows_maj_min" ]] \
    || ! windows_decimal_fits_int64 "$size" \
    || (( size < 64 || size > 67108864 )); then
    exec {loader_fd}<&-
    return 1
  fi
  identity_before="${maj_min}:${inode}:${size}"
  if ! path_before=$(stat -Lc '%Hd:%Ld:%i:%s' "$loader" 2>/dev/null) \
    || [[ "$identity_before" != "$path_before" ]] \
    || ! windows_prepare_runtime_directory; then
    exec {loader_fd}<&-
    return 1
  fi
  runtime=$(windows_runtime_dir_path) || {
    exec {loader_fd}<&-
    return 1
  }
  old_umask=$(umask) || {
    exec {loader_fd}<&-
    return 1
  }
  umask 077
  _windows_inspection_file=$(mktemp "${runtime}/bootmgfw.XXXXXX" 2>/dev/null) || {
    umask "$old_umask"
    exec {loader_fd}<&-
    return 1
  }
  umask "$old_umask"
  if ! dd bs=1M iflag=fullblock,noatime status=none \
    <&"$loader_fd" > "$_windows_inspection_file" 2>/dev/null \
    || ! copy_size=$(stat -Lc '%s' "$_windows_inspection_file" 2>/dev/null) \
    || [[ "$copy_size" != "$size" ]] \
    || ! magic=$(od -An -N2 -tx1 "$_windows_inspection_file" 2>/dev/null \
      | tr -d '[:space:]') \
    || [[ "$magic" != 4d5a ]] \
    || ! windows_loader_descriptor_mount_is_valid "$fd_path" "$mount_id" \
    || ! identity_after=$(stat -Lc '%Hd:%Ld:%i:%s' "$fd_path" 2>/dev/null) \
    || [[ -L "$loader" ]] \
    || ! path_after=$(stat -Lc '%Hd:%Ld:%i:%s' "$loader" 2>/dev/null); then
    exec {loader_fd}<&-
    return 1
  fi
  exec {loader_fd}<&-
  [[ "$identity_before" == "$identity_after" \
    && "$identity_before" == "$path_after" ]]
}

windows_preflight_setpriv_path() {
  printf '/usr/bin/setpriv\n'
}

windows_preflight_sbverify_path() {
  printf '/usr/bin/sbverify\n'
}

windows_preflight_prepare_inspection_owner() {
  local file="$1" uid gid actual_uid actual_gid mode links
  uid=$(/usr/bin/id -u nobody 2>/dev/null) || return 1
  gid=$(/usr/bin/id -g nobody 2>/dev/null) || return 1
  [[ "$uid" =~ ^[1-9][0-9]*$ && "$gid" =~ ^[1-9][0-9]*$ ]] || return 1
  chown "${uid}:${gid}" -- "$file" || return 1
  chmod 400 -- "$file" || return 1
  read -r actual_uid actual_gid mode links \
    < <(stat -Lc '%u %g %a %h' "$file" 2>/dev/null) || return 1
  [[ "$actual_uid" == "$uid" && "$actual_gid" == "$gid" \
    && "$mode" == 400 && "$links" == 1 && -f "$file" && ! -L "$file" ]]
}

windows_preflight_run_sbverify() {
  local file="$1" setpriv_path sbverify_path
  setpriv_path=$(windows_preflight_setpriv_path) || return 1
  sbverify_path=$(windows_preflight_sbverify_path) || return 1
  [[ "$setpriv_path" == /* && -x "$setpriv_path" \
    && "$sbverify_path" == /* && -x "$sbverify_path" ]] || return 1
  windows_preflight_prepare_inspection_owner "$file" || return 1
  "$setpriv_path" --reuid=nobody --regid=nobody --clear-groups \
    --inh-caps=-all --ambient-caps=-all --bounding-set=-all \
    --no-new-privs --reset-env -- /usr/bin/env -i LC_ALL=C \
    PATH=/usr/bin:/bin "$sbverify_path" --list /proc/self/fd/3 \
    3< "$file" 2>/dev/null
}

windows_preflight_parse_signers() {
  local output="$1" line normalized issuer joined="" classification
  local in_issuers=false seen_issuer_header=false seen_certificate_header=false
  local seen_2011=false seen_2023=false seen_unknown=false
  local -a issuers=()
  local LC_ALL=C
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ ! "$line" =~ [[:cntrl:]] ]] || return 1
    normalized=${line#"${line%%[! ]*}"}
    case "$normalized" in
      'image signature issuers:')
        in_issuers=true
        seen_issuer_header=true
        ;;
      'image signature certificates:')
        in_issuers=false
        seen_certificate_header=true
        ;;
      '- '*)
        [[ "$in_issuers" == true ]] || continue
        issuer=${normalized#'- '}
        [[ -n "$issuer" && ${#issuer} -le 512 \
          && ${#issuers[@]} -lt 64 ]] || return 1
        issuers+=("$issuer")
        case "$issuer" in
          *'/CN=Microsoft Windows Production PCA 2011'*) seen_2011=true ;;
          *'/CN=Windows UEFI CA 2023'*) seen_2023=true ;;
          *) seen_unknown=true ;;
        esac
        ;;
    esac
  done <<< "$output"
  [[ "$seen_issuer_header" == true && "$seen_certificate_header" == true ]] \
    && (( ${#issuers[@]} > 0 )) || return 1
  for issuer in "${issuers[@]}"; do
    [[ -z "$joined" ]] || joined+=' | '
    joined+="$issuer"
  done
  if [[ "$seen_unknown" == true ]]; then
    classification="unknown-issuer"
  elif [[ "$seen_2011" == true && "$seen_2023" == true ]]; then
    classification=known-both
  elif [[ "$seen_2011" == true ]]; then
    classification=known-2011
  elif [[ "$seen_2023" == true ]]; then
    classification=known-2023
  else
    classification="unknown-issuer"
  fi
  printf '%s\t%s\n' "$classification" "$joined"
}

windows_preflight_inspect_loader() {
  local mount_path="$1" mount_id="$2" loader output setpriv_path sbverify_path
  loader="${mount_path}${WINDOWS_LOADER_POSIX}"
  if [[ ! -e "$loader" && ! -L "$loader" ]]; then
    return 2
  fi
  setpriv_path=$(windows_preflight_setpriv_path) || return 1
  sbverify_path=$(windows_preflight_sbverify_path) || return 1
  if [[ ! -x "$sbverify_path" ]]; then
    printf 'unknown-missing-sbverify\t\n'
    return 0
  fi
  if [[ ! -x "$setpriv_path" ]]; then
    printf 'unknown-missing-setpriv\t\n'
    return 0
  fi
  if ! /usr/bin/id -u nobody >/dev/null 2>&1 \
    || ! /usr/bin/id -g nobody >/dev/null 2>&1; then
    printf 'unknown-missing-nobody\t\n'
    return 0
  fi
  windows_copy_loader_for_inspection "$mount_path" "$mount_id" || return 1
  if ! output=$(windows_preflight_run_sbverify "$_windows_inspection_file"); then
    printf 'unknown-sbverify\t\n'
    return 0
  fi
  if ! windows_preflight_parse_signers "$output"; then
    printf 'unknown-sbverify-output\t\n'
  fi
}

windows_preflight_record_inspection() {
  local device="$1" inspection="$2" classification issuers
  [[ "$inspection" == *$'\t'* && "$inspection" != *$'\n'* ]] || return 1
  classification=${inspection%%$'\t'*}
  issuers=${inspection#*$'\t'}
  case "$classification" in
    known-2011|known-2023|known-both)
      _windows_preflight_loader_seen=true
      ;;
    unknown-missing-sbverify)
      _windows_preflight_loader_seen=true
      windows_preflight_mark_unknown loader \
        "Signer inspection requires sbsigntools (/usr/bin/sbverify)"
      ;;
    unknown-missing-setpriv)
      _windows_preflight_loader_seen=true
      windows_preflight_mark_unknown loader \
        "Signer inspection requires util-linux (/usr/bin/setpriv)"
      ;;
    unknown-missing-nobody)
      _windows_preflight_loader_seen=true
      windows_preflight_mark_unknown loader \
        "Signer inspection requires the system nobody identity"
      ;;
    unknown-sbverify|unknown-sbverify-output)
      _windows_preflight_loader_seen=true
      windows_preflight_mark_unknown loader \
        "Boot manager signer metadata could not be inspected on ${device}"
      ;;
    unknown-issuer)
      _windows_preflight_loader_seen=true
      windows_preflight_mark_unknown loader \
        "Boot manager ${device} has unrecognized signer issuer metadata; maintainer review is required"
      ;;
    *) return 1 ;;
  esac
  _windows_preflight_signer_records+=(
    "${device}"$'\t'"${classification}"$'\t'"${issuers}"
  )
}

windows_preflight_scan_esps() {
  local prior_limine="$_OMASECBOOT_LIMINE_LOCK_OWNED"
  local prior_repair="$_OMASECBOOT_REPAIR_LOCK_OWNED"
  local acquired_limine=false acquired_repair=false candidate device maj_min
  local mount_path inspection rc=0 scan_rc=0
  (( ${#_windows_preflight_esp_candidates[@]} > 0 )) || return 0

  if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == false ]]; then
    if ! with_limine_lock; then
      windows_preflight_mark_unknown loader \
        "Could not acquire the shared ESP lock; retry after boot maintenance completes"
      return 0
    fi
    acquired_limine=true
  fi
  if [[ "$_OMASECBOOT_REPAIR_LOCK_OWNED" != true ]]; then
    if ! with_repair_lock; then
      windows_preflight_mark_unknown loader \
        "Could not acquire the repair lock; retry after OmaSecBoot maintenance completes"
      if [[ "$acquired_limine" == true ]]; then
        release_limine_lock
      fi
      return 0
    fi
    acquired_repair=true
  fi

  for candidate in "${_windows_preflight_esp_candidates[@]}"; do
    IFS=$'\t' read -r device maj_min <<< "$candidate"
    mount_path=$(windows_preflight_mount_path "$maj_min") || {
      windows_preflight_mark_unknown loader \
        "Could not derive a private mount path for ESP ${device}"
      continue
    }
    _windows_device_path="$device"
    _windows_maj_min="$maj_min"
    if ! windows_block_device_matches "$device" "$maj_min"; then
      windows_preflight_mark_unknown loader \
        "ESP ${device} changed identity before loader inspection"
      continue
    fi
    rc=0
    inspection=$(windows_with_target_mount \
      windows_preflight_inspect_loader "$mount_path") || rc=$?
    if ! windows_block_device_matches "$device" "$maj_min"; then
      windows_preflight_mark_unknown loader \
        "ESP ${device} changed identity during loader inspection"
      continue
    fi
    case "$rc" in
      0)
        if ! windows_preflight_record_inspection "$device" "$inspection"; then
          windows_preflight_mark_unknown loader \
            "ESP ${device} returned malformed signer inspection data"
        fi
        ;;
      2) ;;
      129|130|143)
        scan_rc=$rc
        break
        ;;
      *)
        windows_preflight_mark_unknown loader \
          "Microsoft loader inspection failed safely on ESP ${device}"
        ;;
    esac
  done

  if [[ "$acquired_repair" == true ]]; then
    release_repair_lock
  fi
  if [[ "$acquired_limine" == true ]]; then
    release_limine_lock
  fi
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == "$prior_limine" \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == "$prior_repair" ]] || return 1
  [[ $scan_rc -eq 0 ]] || return "$scan_rc"
}

windows_collect_encryption_preflight() {
  local rc=0
  windows_preflight_reset
  windows_preflight_detect_firmware
  if ! windows_preflight_read_block_inventory; then
    windows_preflight_mark_unknown bitlocker \
      "Block-device inventory processing failed safely"
    windows_preflight_mark_unknown loader \
      "ESP inventory processing failed safely"
  fi
  windows_preflight_scan_esps || rc=$?
  [[ $rc -eq 0 ]] || return "$rc"
  windows_preflight_finalize_states
}

windows_preflight_print_summary() {
  local device record classification issuers
  printf '  Detection summary:\n'
  printf '    Firmware option: %s\n' "$_windows_preflight_firmware_state"
  printf '    BitLocker signature: %s\n' "$_windows_preflight_bitlocker_state"
  printf '    Microsoft loader on ESP: %s\n' "$_windows_preflight_loader_state"
  for device in "${_windows_preflight_bitlocker_devices[@]}"; do
    printf '    BitLocker-format volume: %s\n' "$device"
  done
  for record in "${_windows_preflight_signer_records[@]}"; do
    IFS=$'\t' read -r device classification issuers <<< "$record"
    printf '    Boot manager: %s (%s)\n' "$device" "$classification"
    [[ -z "$issuers" ]] || printf '      Embedded issuer metadata: %s\n' "$issuers"
  done
  echo
  warn "Boot-manager signer metadata is advisory and does not evaluate firmware db, dbx, revocation, or bootability"
}

windows_preflight_print_home_guidance() {
  echo -e "  ${BOLD}Windows Home${NC}"
  echo "    1. Back up and verify the recovery key if Device Encryption is active."
  echo "    2. Open Settings > Privacy & security > Device encryption."
  echo "    3. Turn Device Encryption off and wait for decryption to finish."
  echo "    4. After the final direct Windows boot, run Confirm-SecureBootUEFI and verify Device Encryption state."
  echo "    Microsoft documents Settings decryption for Home; use this workflow only."
  echo
}

windows_preflight_print_pro_guidance() {
  echo -e "  ${BOLD}Windows Pro, Enterprise, or Education${NC}"
  echo "    1. Back up and verify every recovery key."
  echo "    2. In administrator PowerShell, inspect: manage-bde -status \$env:SystemDrive"
  echo "    3. Suspend: Suspend-BitLocker -MountPoint \$env:SystemDrive -RebootCount 0"
  echo "    4. Confirm protection is suspended before any Secure Boot setting changes."
  echo "    5. On the first direct Windows boot, run Confirm-SecureBootUEFI."
  echo "    6. Resume: Resume-BitLocker -MountPoint \$env:SystemDrive"
  echo "    7. Verify with manage-bde -status and manage-bde -protectors -get \$env:SystemDrive."
  echo
}

windows_preflight_print_common_guidance() {
  warn "Secure Boot changes can trigger BitLocker recovery"
  warn "Direct firmware handoff does not guarantee Windows boot, PCR7 binding, stable measurements, or no recovery prompt"
}

windows_preflight_print_unknown_reasons() {
  local reason
  (( ${#_windows_preflight_unknown_reasons[@]} > 0 )) || return 0
  echo -e "  ${BOLD}Technical blockers${NC}"
  for reason in "${_windows_preflight_unknown_reasons[@]}"; do
    fail "$reason"
  done
  echo
}

windows_preflight_gum_path() {
  command -v gum
}

windows_preflight_confirm() {
  local prompt="$1"
  "$_windows_preflight_gum" confirm "$prompt"
}

windows_encryption_gate() {
  local collection_rc=0 edition management
  windows_collect_encryption_preflight || collection_rc=$?
  case "$collection_rc" in
    0) ;;
    129|130|143)
      _windows_preflight_result=declined
      return "$collection_rc"
      ;;
    *)
      windows_preflight_mark_unknown loader \
        "Windows preflight collection failed safely"
      windows_preflight_finalize_states
      windows_preflight_print_summary
      windows_preflight_print_common_guidance
      windows_preflight_print_home_guidance
      windows_preflight_print_pro_guidance
      windows_preflight_print_unknown_reasons
      fail "Windows preflight remains technically inconclusive; no firmware instruction is authorized"
      _windows_preflight_result=technical-unknown
      return 2
      ;;
  esac

  windows_preflight_print_summary
  if [[ "$_windows_preflight_firmware_state" == absent \
    && "$_windows_preflight_bitlocker_state" == absent \
    && "$_windows_preflight_loader_state" == absent ]]; then
    pass "No Windows signal was observed in the current firmware and visible block inventory"
    warn "This bounded observation does not prove Windows is absent and is not firmware clearance"
    warn "If Windows exists outside this inventory, Secure Boot changes can still trigger BitLocker recovery"
    _windows_preflight_result=negative
    return 0
  fi

  if ! _windows_preflight_gum=$(windows_preflight_gum_path); then
    windows_preflight_print_common_guidance
    windows_preflight_print_home_guidance
    windows_preflight_print_pro_guidance
    windows_preflight_print_unknown_reasons
    fail "gum is required to collect edition, management, and preparation acknowledgments"
    _windows_preflight_result=technical-unknown
    return 2
  fi
  edition=$("$_windows_preflight_gum" choose --header "Windows edition" \
    Home Pro Enterprise Education) || {
    warn "Windows preflight declined"
    _windows_preflight_result=declined
    return 1
  }
  case "$edition" in
    Home|Pro|Enterprise|Education) ;;
    *)
      fail "Windows edition selection was not recognized"
      _windows_preflight_result=technical-unknown
      return 2
      ;;
  esac
  management=$("$_windows_preflight_gum" choose --header "Windows management" \
    "Personal device" "Managed by an organization") || {
    warn "Windows preflight declined"
    _windows_preflight_result=declined
    return 1
  }
  case "$management" in
    "Personal device"|"Managed by an organization") ;;
    *)
      fail "Windows management selection was not recognized"
      _windows_preflight_result=technical-unknown
      return 2
      ;;
  esac

  windows_preflight_print_common_guidance
  if [[ "$edition" == Home ]]; then
    windows_preflight_print_home_guidance
  else
    windows_preflight_print_pro_guidance
  fi
  windows_preflight_print_unknown_reasons
  if [[ "$management" == "Managed by an organization" ]]; then
    warn "Organization-managed devices require administrator approval before firmware keys are replaced"
    if ! windows_preflight_confirm \
      "Has the organization's administrator approved replacing the firmware Secure Boot keys?"; then
      fail "Administrator approval is required for a managed Windows device"
      _windows_preflight_result=declined
      return 1
    fi
  fi
  if ! windows_preflight_confirm \
    "Have you checked Windows encryption state and backed up every available recovery key?"; then
    fail "Windows encryption-state review and recovery-key preparation are required"
    _windows_preflight_result=declined
    return 1
  fi
  if [[ "$_windows_preflight_bitlocker_state" != absent ]]; then
    if [[ "$edition" == Home ]]; then
      if ! windows_preflight_confirm \
        "Is Device Encryption off with decryption fully complete?"; then
        fail "Windows Home must finish Device Encryption decryption"
        _windows_preflight_result=declined
        return 1
      fi
    elif ! windows_preflight_confirm \
      "Is BitLocker protection suspended on every protected Windows volume?"; then
      fail "BitLocker protection must be suspended before Secure Boot changes"
      _windows_preflight_result=declined
      return 1
    fi
  fi

  if [[ "$_windows_preflight_firmware_state" == unknown \
    || "$_windows_preflight_bitlocker_state" == unknown \
    || "$_windows_preflight_loader_state" == unknown ]]; then
    fail "Windows preflight remains technically inconclusive; no firmware instruction is authorized"
    _windows_preflight_result=technical-unknown
    return 2
  fi
  pass "Windows encryption preparation acknowledged"
  _windows_preflight_result=prepared
}

windows_classify_target_state() {
  local state_file
  state_file=$(windows_target_state_path) || return 1
  _windows_state_kind=absent
  if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
    return 0
  fi
  validate_control_file "$state_file" || {
    _windows_state_kind=invalid
    return 1
  }
  if [[ ! -s "$state_file" ]]; then
    _windows_state_kind=legacy-empty
    return 0
  fi
  if read_windows_target_state; then
    _windows_state_kind=current
    return 0
  fi
  _windows_state_kind=invalid
  return 1
}

read_windows_target_state() {
  local state_file document label
  state_file=$(windows_target_state_path) || return 1
  validate_control_directory "$(dirname "$state_file")" || return 1
  validate_control_file "$state_file" || return 1
  document=$(<"$state_file") || return 1
  jq -e '.schema_version | select(type == "number" and floor == .)' \
    <<< "$document" >/dev/null 2>&1 || return 1
  if jq -e --argjson schema "$WINDOWS_STATE_SCHEMA_VERSION" \
    '.schema_version > $schema' <<< "$document" >/dev/null 2>&1; then
    windows_reject "Windows target state uses a newer schema"
    return 1
  fi
  jq -e --argjson schema "$WINDOWS_STATE_SCHEMA_VERSION" \
    --arg loader "$WINDOWS_LOADER_UEFI" '
      type == "object" and
      (keys == ["boot_number", "enabled", "label", "loader_path", "partuuid", "schema_version", "writer_version"]) and
      .schema_version == $schema and
      (.writer_version | type) == "string" and (.writer_version | length) > 0 and
      .enabled == true and
      (.boot_number | type) == "string" and (.boot_number | test("^[0-9A-F]{4}$")) and
      (.label | type) == "string" and
      (.partuuid | type) == "string" and (.partuuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")) and
      .loader_path == $loader
    ' <<< "$document" >/dev/null || return 1
  label=$(jq -r '.label' <<< "$document") || return 1
  windows_label_is_safe "$label" || return 1
  _windows_state_boot_number=$(jq -r '.boot_number' <<< "$document") || return 1
  _windows_state_label="$label"
  _windows_state_partuuid=$(jq -r '.partuuid' <<< "$document") || return 1
  _windows_state_loader_path=$(jq -r '.loader_path' <<< "$document") || return 1
}

windows_state_matches_resolved_target() {
  [[ "$_windows_state_boot_number" == "$_windows_boot_number" \
    && "$_windows_state_label" == "$_windows_label" \
    && "$_windows_state_partuuid" == "$_windows_partuuid" \
    && "$_windows_state_loader_path" == "$WINDOWS_LOADER_UEFI" ]]
}

write_windows_target_state() {
  local state_file document
  [[ "${_transaction_active:-false}" == true ]] || return 1
  state_file=$(windows_target_state_path) || return 1
  document=$(jq -cn \
    --arg version "$OMASECBOOT_VERSION" \
    --arg boot_number "$_windows_boot_number" \
    --arg label "$_windows_label" \
    --arg partuuid "$_windows_partuuid" \
    --arg loader "$WINDOWS_LOADER_UEFI" '{
      schema_version: 1,
      writer_version: $version,
      enabled: true,
      boot_number: $boot_number,
      label: $label,
      partuuid: $partuuid,
      loader_path: $loader
    }') || return 1
  printf '%s\n' "$document" | atomic_write_control_file "$state_file" 644
}

revalidate_windows_target_state() {
  local boot_number label partuuid loader
  read_windows_target_state || return 1
  boot_number="$_windows_state_boot_number"
  label="$_windows_state_label"
  partuuid="$_windows_state_partuuid"
  loader="$_windows_state_loader_path"
  resolve_windows_target || return 1
  [[ "$boot_number" == "$_windows_boot_number" \
    && "$label" == "$_windows_label" \
    && "$partuuid" == "$_windows_partuuid" \
    && "$loader" == "$WINDOWS_LOADER_UEFI" ]] || {
    windows_reject "Persisted Windows target identity is stale"
    return 2
  }
}

windows_validate_efivarfs_mount() {
  local directory mount_info target fstype extra
  directory=$(windows_bootnext_efivars_dir) || return 1
  [[ -d "$directory" && ! -L "$directory" ]] || {
    windows_reject "EFI variable filesystem is unavailable"
    return 1
  }
  mount_info=$(findmnt --noheadings --raw --target "$directory" \
    --output TARGET,FSTYPE 2>/dev/null) || {
    windows_reject "Cannot resolve the EFI variable filesystem"
    return 1
  }
  read -r target fstype extra <<< "$mount_info"
  [[ -z "$extra" && "$target" == "$directory" && "$fstype" == efivarfs ]] || {
    windows_reject "EFI variables are not backed by the expected efivarfs mount"
    return 1
  }
}

read_windows_bootnext_state() {
  local directory path basename directory_identity matches owner uid mode size device inode
  local extra mode_value fd bytes_text
  local post_uid post_mode post_size post_device post_inode post_extra number
  local -a bytes=()
  windows_validate_efivarfs_mount || return 1
  directory=$(windows_bootnext_efivars_dir) || return 1
  path=$(windows_bootnext_variable_path) || return 1
  basename=${path##*/}
  [[ "$path" == "${directory}/BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c" ]] \
    || return 1
  validate_control_directory "$directory" || {
    windows_reject "EFI variable filesystem permissions are unsafe"
    return 1
  }
  directory_identity=$(stat -Lc '%d:%i' "$directory" 2>/dev/null) || return 1
  matches=$(find -P "$directory" -mindepth 1 -maxdepth 1 -name "$basename" \
    -printf '%p\n' 2>/dev/null) || {
      windows_reject "Cannot scan the EFI variable filesystem"
      return 1
    }
  windows_validate_efivarfs_mount || return 1
  [[ $(stat -Lc '%d:%i' "$directory" 2>/dev/null) == "$directory_identity" ]] || {
    windows_reject "EFI variable filesystem changed while it was scanned"
    return 1
  }
  if [[ -z "$matches" ]]; then
    jq -cn '{boot_number:null,present:false}'
    return
  fi
  [[ "$matches" == "$path" ]] || {
    windows_reject "BootNext EFI variable lookup is ambiguous"
    return 1
  }
  [[ -f "$path" && ! -L "$path" ]] || {
    windows_reject "BootNext EFI variable is not a safe regular file"
    return 1
  }
  owner=$(control_owner_uid) || return 1
  read -r uid mode size device inode extra \
    < <(stat -Lc '%u %a %s %d %i' "$path" 2>/dev/null) || {
      windows_reject "Cannot inspect the BootNext EFI variable"
      return 1
    }
  [[ -z "$extra" && "$uid" == "$owner" && "$mode" =~ ^[0-7]{3,4}$ \
    && "$size" == 6 && "$device" =~ ^[0-9]+$ && "$inode" =~ ^[0-9]+$ ]] || {
    windows_reject "BootNext EFI variable metadata is invalid"
    return 1
  }
  mode_value=$((8#$mode))
  (( (mode_value & 0022) == 0 )) || {
    windows_reject "BootNext EFI variable permissions are unsafe"
    return 1
  }
  exec {fd}< "$path" || {
    windows_reject "Cannot open the BootNext EFI variable"
    return 1
  }
  if ! bytes_text=$(od -An -v -tu1 -N 6 "/proc/self/fd/${fd}" 2>/dev/null); then
    exec {fd}<&-
    windows_reject "Cannot read the BootNext EFI variable"
    return 1
  fi
  read -r -a bytes <<< "$bytes_text"
  read -r post_uid post_mode post_size post_device post_inode post_extra \
    < <(stat -Lc '%u %a %s %d %i' "/proc/self/fd/${fd}" 2>/dev/null) || {
      exec {fd}<&-
      windows_reject "Cannot revalidate the BootNext EFI variable"
      return 1
    }
  exec {fd}<&-
  [[ -z "$post_extra" && "$post_uid" == "$uid" && "$post_mode" == "$mode" \
    && "$post_size" == "$size" && "$post_device" == "$device" \
    && "$post_inode" == "$inode" \
    && $(stat -Lc '%d:%i' "$path" 2>/dev/null) == "${device}:${inode}" \
    && ${#bytes[@]} -eq 6 ]] || {
    windows_reject "BootNext EFI variable changed while it was read"
    return 1
  }
  (( bytes[0] == 7 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0 )) || {
    windows_reject "BootNext EFI variable attributes are unsupported"
    return 1
  }
  number=$((bytes[4] + (bytes[5] << 8)))
  printf -v number '%04X' "$number"
  jq -cn --arg number "$number" '{boot_number:$number,present:true}'
}

validate_windows_efibootmgr_boundary() {
  local package owner path path_uid path_mode path_device path_inode
  local fd_path fd_uid fd_mode fd_device fd_inode executable_hash
  close_windows_efibootmgr_boundary
  path=$(windows_efibootmgr_executable_path) || return 1
  [[ "$path" == "$WINDOWS_EFIBOOTMGR_EXECUTABLE" ]] || return 1
  package=$(/usr/bin/pacman -Q efibootmgr 2>/dev/null) || {
    windows_reject "Cannot verify the installed efibootmgr package"
    return 1
  }
  [[ "$package" == "$WINDOWS_EFIBOOTMGR_PACKAGE_IDENTITY" ]] || {
    windows_reject "Unsupported efibootmgr package: ${package}"
    return 1
  }
  owner=$(/usr/bin/pacman -Qqo "$path" 2>/dev/null) || {
    windows_reject "Cannot verify ownership of the efibootmgr executable"
    return 1
  }
  [[ "$owner" == efibootmgr && -x "$path" ]] || {
    windows_reject "The supported package does not own the efibootmgr executable"
    return 1
  }
  validate_control_file "$path" || {
    windows_reject "The efibootmgr executable is unsafe"
    return 1
  }
  read -r path_uid path_mode path_device path_inode \
    < <(stat -Lc '%u %a %d %i' "$path" 2>/dev/null) || return 1
  exec {_windows_efibootmgr_fd}< "$path" || {
    windows_reject "Cannot bind the efibootmgr executable"
    return 1
  }
  fd_path="/proc/self/fd/${_windows_efibootmgr_fd}"
  read -r fd_uid fd_mode fd_device fd_inode \
    < <(stat -Lc '%u %a %d %i' "$fd_path" 2>/dev/null) || {
      close_windows_efibootmgr_boundary
      return 1
    }
  [[ "$fd_uid" == "$path_uid" && "$fd_mode" == "$path_mode" \
    && "$fd_device" == "$path_device" && "$fd_inode" == "$path_inode" ]] || {
      close_windows_efibootmgr_boundary
      windows_reject "The efibootmgr executable changed while it was opened"
      return 1
    }
  executable_hash=$(sha256_file "$fd_path") || {
    close_windows_efibootmgr_boundary
    return 1
  }
  [[ "$executable_hash" =~ ^[0-9a-f]{64}$ \
    && $(stat -Lc '%d:%i' "$path" 2>/dev/null) == "${fd_device}:${fd_inode}" ]] || {
      close_windows_efibootmgr_boundary
      windows_reject "The efibootmgr executable changed while it was validated"
      return 1
    }
  _windows_efibootmgr_hash="$executable_hash"
}

run_windows_efibootmgr() {
  [[ "${_windows_efibootmgr_fd:-}" =~ ^[0-9]+$ ]] || return 1
  "/proc/self/fd/${_windows_efibootmgr_fd}" "$@"
}

hash_bound_windows_efibootmgr() {
  [[ "${_windows_efibootmgr_fd:-}" =~ ^[0-9]+$ ]] || return 1
  sha256_file "/proc/self/fd/${_windows_efibootmgr_fd}"
}

validate_windows_unlink_boundary() {
  local package owner path path_uid path_mode path_device path_inode
  local fd_path fd_uid fd_mode fd_device fd_inode executable_hash
  close_windows_unlink_boundary
  path=$(windows_unlink_executable_path) || return 1
  [[ "$path" == "$WINDOWS_UNLINK_EXECUTABLE" ]] || return 1
  package=$(/usr/bin/pacman -Q coreutils 2>/dev/null) || {
    windows_reject "Cannot verify the installed coreutils package"
    return 1
  }
  [[ "$package" == "$WINDOWS_UNLINK_PACKAGE_IDENTITY" ]] || {
    windows_reject "Unsupported coreutils package: ${package}"
    return 1
  }
  owner=$(/usr/bin/pacman -Qqo "$path" 2>/dev/null) || {
    windows_reject "Cannot verify ownership of the unlink executable"
    return 1
  }
  [[ "$owner" == coreutils && -x "$path" ]] || {
    windows_reject "The supported package does not own the unlink executable"
    return 1
  }
  validate_control_file "$path" || {
    windows_reject "The unlink executable is unsafe"
    return 1
  }
  read -r path_uid path_mode path_device path_inode \
    < <(stat -Lc '%u %a %d %i' "$path" 2>/dev/null) || return 1
  exec {_windows_unlink_fd}< "$path" || {
    windows_reject "Cannot bind the unlink executable"
    return 1
  }
  fd_path="/proc/self/fd/${_windows_unlink_fd}"
  read -r fd_uid fd_mode fd_device fd_inode \
    < <(stat -Lc '%u %a %d %i' "$fd_path" 2>/dev/null) || {
      close_windows_unlink_boundary
      return 1
    }
  [[ "$fd_uid" == "$path_uid" && "$fd_mode" == "$path_mode" \
    && "$fd_device" == "$path_device" && "$fd_inode" == "$path_inode" ]] || {
      close_windows_unlink_boundary
      windows_reject "The unlink executable changed while it was opened"
      return 1
    }
  executable_hash=$(sha256_file "$fd_path") || {
    close_windows_unlink_boundary
    return 1
  }
  [[ "$executable_hash" =~ ^[0-9a-f]{64}$ \
    && $(stat -Lc '%d:%i' "$path" 2>/dev/null) == "${fd_device}:${fd_inode}" ]] || {
      close_windows_unlink_boundary
      windows_reject "The unlink executable changed while it was validated"
      return 1
    }
  _windows_unlink_hash="$executable_hash"
}

run_windows_unlink() {
  local path="$1"
  [[ "${_windows_unlink_fd:-}" =~ ^[0-9]+$ \
    && "$path" == "$(windows_bootnext_variable_path)" ]] || return 1
  "/proc/self/fd/${_windows_unlink_fd}" "$path"
}

hash_bound_windows_unlink() {
  [[ "${_windows_unlink_fd:-}" =~ ^[0-9]+$ ]] || return 1
  sha256_file "/proc/self/fd/${_windows_unlink_fd}"
}

capture_windows_bootnext_variable_evidence() {
  local path state before_identity after_identity before_hash after_hash
  path=$(windows_bootnext_variable_path) || return 1
  state=$(read_windows_bootnext_state) || return 1
  [[ $(jq -r '.present' <<< "$state") == true ]] || return 1
  before_identity=$(stat -Lc '%d:%i' "$path" 2>/dev/null) || return 1
  before_hash=$(sha256_file "$path") || return 1
  after_identity=$(stat -Lc '%d:%i' "$path" 2>/dev/null) || return 1
  after_hash=$(sha256_file "$path") || return 1
  [[ "$before_identity" == "$after_identity" && "$before_hash" == "$after_hash" ]] \
    || return 1
  jq -cn --arg path "$path" --arg identity "$before_identity" --arg hash "$before_hash" '{
    path: $path,
    identity: $identity,
    sha256: $hash
  }'
}

load_windows_recovery_context() {
  local root_id reference path record root_boot_id recovery_boot_id relation prior observed
  local target action outcome write_frontier tool=null variable=null current_hash
  local first_state second_state
  windows_recovery_is_available || return 1
  load_recovery_context || return $?
  [[ $(recovery_operation_for_root_manifest "$_recovery_root_manifest_json") == \
    windows-recovery ]] || return 1
  jq -e '
    .kind == "root" and .operation == "windows-bootnext" and
    .target_state == "active" and .prior_state == "active" and
    .file_rollback_policy == "restore" and .domain_records.producer == null and
    .domain_records.final_proof == null and .domain_records.firmware == null and
    .domain_records.managed_settings == null and
    .domain_records.tracking_ownership == null and
    .domain_records.unconfigure == null and .domain_records.windows == null and
    .firmware_backup == null and .enrollment_plan == null and .firmware_writes == []
  ' <<< "$_recovery_root_manifest_json" >/dev/null || return 1
  root_id=$(jq -r '.id' <<< "$_recovery_root_reference") || return 1
  reference=$(jq -c '.domain_records.bootnext' <<< "$_recovery_root_manifest_json") \
    || return 1
  recovery_boot_id=$(boot_id_value) || return 1
  if [[ "$reference" == null ]]; then
    _windows_recovery_plan_json=$(jq -cn \
      --arg recovery_boot_id "$recovery_boot_id" \
      --argjson root_incident "$_recovery_root_reference" '{
        action: "none",
        bootnext_record: null,
        observed: null,
        planned_outcome: "not-published",
        prior: null,
        recovery_boot_id: $recovery_boot_id,
        relation: null,
        root_boot_id: null,
        root_incident: $root_incident,
        target: null,
        tool: null,
        variable: null,
        write_frontier: "not-published"
      }') || return 1
    return 0
  fi

  validate_bootnext_record_reference "$root_id" "$reference" \
    "$_recovery_root_manifest_json" || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  record=$(read_control_document "$path") || return 1
  root_boot_id=$(jq -r '.boot_id' <<< "$record") || return 1
  if [[ "$root_boot_id" == "$recovery_boot_id" ]]; then
    relation=same-boot
  else
    relation=later-boot
  fi
  prior=$(jq -c '.prior' <<< "$record") || return 1
  target=$(jq -r '.target.boot_number' <<< "$record") || return 1
  if jq -e '.completed_phases | index("record-bootnext") != null' \
    <<< "$_recovery_root_manifest_json" >/dev/null; then
    write_frontier=write-possible
  else
    write_frontier=not-reached
  fi
  observed=$(read_windows_bootnext_state) || {
    windows_reject "BootNext is unreadable during Windows recovery classification"
    windows_report_error
    return 1
  }
  if [[ "$write_frontier" == not-reached ]]; then
    jq -e --argjson prior "$prior" '. == $prior' <<< "$observed" >/dev/null || {
      windows_reject "BootNext changed after a root transaction that never reached its write phase"
      windows_report_error
      return 1
    }
    action=none
    outcome="prior-unchanged"
  elif [[ "$relation" == later-boot \
    && $(jq -r '.present' <<< "$observed") == false ]]; then
    action=none
    outcome=consumed-unknown
  elif jq -e --argjson prior "$prior" '. == $prior' <<< "$observed" >/dev/null; then
    action=none
    outcome="prior-unchanged"
  elif jq -e --arg target "$target" \
    '.present == true and .boot_number == $target' <<< "$observed" >/dev/null; then
    outcome="prior-restored"
    if [[ $(jq -r '.present' <<< "$prior") == true ]]; then
      action=set-prior
      validate_windows_efibootmgr_boundary || {
        windows_report_error
        return 1
      }
      current_hash=$(hash_bound_windows_efibootmgr) || {
        close_windows_efibootmgr_boundary
        return 1
      }
      jq -e --arg hash "$current_hash" '.efibootmgr.executable_sha256 == $hash' \
        <<< "$record" >/dev/null || {
          close_windows_efibootmgr_boundary
          windows_reject "The recorded efibootmgr executable is no longer available"
          windows_report_error
          return 1
        }
      tool=$(jq -c '.efibootmgr' <<< "$record") || {
        close_windows_efibootmgr_boundary
        return 1
      }
      close_windows_efibootmgr_boundary
    else
      action=delete
      first_state="$observed"
      variable=$(capture_windows_bootnext_variable_evidence) || return 1
      second_state=$(read_windows_bootnext_state) || return 1
      jq -e --argjson expected "$first_state" '. == $expected' \
        <<< "$second_state" >/dev/null || return 1
      validate_windows_unlink_boundary || {
        windows_report_error
        return 1
      }
      current_hash=$(hash_bound_windows_unlink) || {
        close_windows_unlink_boundary
        return 1
      }
      tool=$(jq -cn \
        --arg package "$WINDOWS_UNLINK_PACKAGE_IDENTITY" \
        --arg executable "$WINDOWS_UNLINK_EXECUTABLE" \
        --arg hash "$current_hash" '{
          package: $package,
          executable: $executable,
          executable_sha256: $hash
        }') || {
          close_windows_unlink_boundary
          return 1
        }
      close_windows_unlink_boundary
    fi
  else
    windows_reject "BootNext no longer matches the recorded prior state or Windows target"
    windows_report_error
    return 1
  fi
  _windows_recovery_plan_json=$(jq -cn \
    --arg action "$action" \
    --arg outcome "$outcome" \
    --arg recovery_boot_id "$recovery_boot_id" \
    --arg relation "$relation" \
    --arg root_boot_id "$root_boot_id" \
    --arg target "$target" \
    --arg write_frontier "$write_frontier" \
    --argjson bootnext_record "$reference" \
    --argjson observed "$observed" \
    --argjson prior "$prior" \
    --argjson root_incident "$_recovery_root_reference" \
    --argjson tool "$tool" \
    --argjson variable "$variable" '{
      action: $action,
      bootnext_record: $bootnext_record,
      observed: $observed,
      planned_outcome: $outcome,
      prior: $prior,
      recovery_boot_id: $recovery_boot_id,
      relation: $relation,
      root_boot_id: $root_boot_id,
      root_incident: $root_incident,
      target: $target,
      tool: $tool,
      variable: $variable,
      write_frontier: $write_frontier
    }')
}

persist_windows_recovery_record() {
  local transaction_dir path timestamp document reference
  [[ -n "$_windows_recovery_plan_json" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  path="${transaction_dir}/windows-recovery.json"
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION" \
    --arg transaction_id "$_transaction_id" \
    --arg writer_version "$OMASECBOOT_VERSION" \
    --arg recorded_at "$timestamp" \
    --argjson plan "$_windows_recovery_plan_json" '
      $plan + {
        schema_version: $schema,
        transaction_id: $transaction_id,
        writer_version: $writer_version,
        operation: "windows-recovery",
        recorded_at: $recorded_at
      }
    ') || return 1
  validate_windows_recovery_record_json "$_transaction_id" "$document" "$_manifest_json" \
    || return 1
  printf '%s\n' "$document" | atomic_create_control_file "$path" 600 || return 1
  reference=$(transaction_artifact_reference "$path" \
    "$WINDOWS_RECOVERY_RECORD_SCHEMA_VERSION") || return 1
  transaction_set_domain_record windows "$reference" || return 1
  _windows_recovery_record_json="$document"
  _windows_recovery_record_path="$path"
}

load_windows_recovery_record() {
  local reference path
  read_transaction_manifest "$_transaction_id" || return 1
  reference=$(jq -c '.domain_records.windows' <<< "$_manifest_json") || return 1
  [[ "$reference" != null ]] || return 1
  validate_windows_recovery_record_reference "$_transaction_id" "$reference" \
    "$_manifest_json" || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  _windows_recovery_record_json=$(read_control_document "$path") || return 1
  _windows_recovery_record_path="$path"
}

execute_windows_recovery_action() {
  local action recovery_boot_id observed expected_hash prior_number variable current_variable
  local current_state
  local command_rc=0
  load_windows_recovery_record || return 1
  action=$(jq -r '.action' <<< "$_windows_recovery_record_json") || return 1
  recovery_boot_id=$(jq -r '.recovery_boot_id' <<< "$_windows_recovery_record_json") \
    || return 1
  [[ "$recovery_boot_id" == "$(boot_id_value)" ]] || {
    windows_reject "The system boot changed during Windows recovery"
    return 1
  }
  windows_recovery_is_available || return 1
  if [[ "$action" == none ]]; then
    _windows_recovery_command_rc=null
    return 0
  fi
  observed=$(jq -c '.observed' <<< "$_windows_recovery_record_json") || return 1
  case "$action" in
    set-prior)
      validate_windows_efibootmgr_boundary || return 1
      expected_hash=$(jq -r '.tool.executable_sha256' \
        <<< "$_windows_recovery_record_json") || {
          close_windows_efibootmgr_boundary
          return 1
        }
      [[ "$(hash_bound_windows_efibootmgr)" == "$expected_hash" \
        && "$recovery_boot_id" == "$(boot_id_value)" ]] || {
          close_windows_efibootmgr_boundary
          return 1
        }
      windows_recovery_is_available || {
        close_windows_efibootmgr_boundary
        return 1
      }
      current_state=$(read_windows_bootnext_state) || {
        close_windows_efibootmgr_boundary
        windows_reject "BootNext became unreadable before Windows recovery mutation"
        windows_report_error
        return 1
      }
      jq -e --argjson expected "$observed" '. == $expected' \
        <<< "$current_state" >/dev/null || {
        close_windows_efibootmgr_boundary
        windows_reject "BootNext changed after Windows recovery evidence was recorded"
        windows_report_error
        return 1
      }
      prior_number=$(jq -r '.prior.boot_number' <<< "$_windows_recovery_record_json") \
        || {
          close_windows_efibootmgr_boundary
          return 1
        }
      run_windows_efibootmgr -n "$prior_number" || command_rc=$?
      windows_recovery_failpoint "after-recovery-command" || {
        close_windows_efibootmgr_boundary
        return 1
      }
      close_windows_efibootmgr_boundary
      ;;
    delete)
      validate_windows_unlink_boundary || return 1
      expected_hash=$(jq -r '.tool.executable_sha256' \
        <<< "$_windows_recovery_record_json") || {
          close_windows_unlink_boundary
          return 1
        }
      [[ "$(hash_bound_windows_unlink)" == "$expected_hash" \
        && "$recovery_boot_id" == "$(boot_id_value)" ]] || {
          close_windows_unlink_boundary
          return 1
        }
      windows_recovery_is_available || {
        close_windows_unlink_boundary
        return 1
      }
      current_state=$(read_windows_bootnext_state) || {
        close_windows_unlink_boundary
        windows_reject "BootNext became unreadable before Windows recovery mutation"
        windows_report_error
        return 1
      }
      jq -e --argjson expected "$observed" '. == $expected' \
        <<< "$current_state" >/dev/null || {
        close_windows_unlink_boundary
        windows_reject "BootNext changed after Windows recovery evidence was recorded"
        windows_report_error
        return 1
      }
      variable=$(jq -c '.variable' <<< "$_windows_recovery_record_json") || {
        close_windows_unlink_boundary
        return 1
      }
      current_variable=$(capture_windows_bootnext_variable_evidence) || {
        close_windows_unlink_boundary
        return 1
      }
      [[ "$(jq -Sc . <<< "$current_variable")" == "$(jq -Sc . <<< "$variable")" ]] \
        || {
          close_windows_unlink_boundary
          return 1
        }
      run_windows_unlink "$(windows_bootnext_variable_path)" || command_rc=$?
      windows_recovery_failpoint "after-recovery-command" || {
        close_windows_unlink_boundary
        return 1
      }
      close_windows_unlink_boundary
      ;;
    *) return 1 ;;
  esac
  _windows_recovery_command_rc="$command_rc"
  current_state=$(read_windows_bootnext_state) || {
    windows_reject "BootNext recovery readback is unreadable"
    windows_report_error
    return 1
  }
  jq -e --argjson expected "$(jq -c '.prior' <<< "$_windows_recovery_record_json")" \
    '. == $expected' <<< "$current_state" >/dev/null || {
      windows_reject "BootNext recovery readback does not match the recorded prior state"
      windows_report_error
      return 1
    }
}

persist_windows_recovery_proof() {
  local transaction_dir path timestamp outcome final_state document reference record_reference
  load_windows_recovery_record || return 1
  [[ $(jq -r '.recovery_boot_id' <<< "$_windows_recovery_record_json") == \
    "$(boot_id_value)" ]] || return 1
  outcome=$(jq -r '.planned_outcome' <<< "$_windows_recovery_record_json") || return 1
  if [[ "$outcome" == not-published ]]; then
    final_state=null
  else
    final_state=$(read_windows_bootnext_state) || {
      windows_reject "BootNext proof readback is unreadable"
      windows_report_error
      return 1
    }
  fi
  case "$outcome" in
    not-published) [[ "$final_state" == null ]] || return 1 ;;
    consumed-unknown)
      jq -e '.present == false and .boot_number == null' \
        <<< "$final_state" >/dev/null || return 1
      ;;
    prior-unchanged|prior-restored)
      jq -e --argjson expected "$(jq -c '.prior' \
        <<< "$_windows_recovery_record_json")" '. == $expected' \
        <<< "$final_state" >/dev/null || return 1
      ;;
    *) return 1 ;;
  esac
  read_transaction_manifest "$_transaction_id" || return 1
  record_reference=$(jq -c '.domain_records.windows' <<< "$_manifest_json") || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  path="${transaction_dir}/windows-recovery-proof.json"
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION" \
    --arg transaction_id "$_transaction_id" \
    --arg writer_version "$OMASECBOOT_VERSION" \
    --arg proved_at "$timestamp" \
    --arg outcome "$outcome" \
    --argjson command_exit_code "$_windows_recovery_command_rc" \
    --argjson final_state "$final_state" \
    --argjson record "$record_reference" '{
      schema_version: $schema,
      transaction_id: $transaction_id,
      writer_version: $writer_version,
      operation: "windows-recovery",
      proved_at: $proved_at,
      record: $record,
      outcome: $outcome,
      command_exit_code: $command_exit_code,
      final_state: $final_state
    }') || return 1
  validate_windows_recovery_proof_json "$_transaction_id" "$document" "$_manifest_json" \
    || return 1
  printf '%s\n' "$document" | atomic_create_control_file "$path" 600 || return 1
  reference=$(transaction_artifact_reference "$path" \
    "$WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION") || return 1
  transaction_set_domain_record final_proof "$reference"
}

windows_recovery_transaction() {
  windows_recovery_is_available || return 1
  transaction_phase_start "classify-bootnext" || return 1
  persist_windows_recovery_record || return 1
  windows_recovery_failpoint "after-recovery-record" || return 1
  transaction_phase_complete "classify-bootnext" || return 1

  transaction_phase_start "restore-bootnext" || return 1
  execute_windows_recovery_action || return 1
  transaction_phase_complete "restore-bootnext" || return 1

  transaction_phase_start "prove-bootnext" || return 1
  persist_windows_recovery_proof || return 1
  transaction_phase_complete "prove-bootnext"
}

run_windows_recovery_locked() {
  local callback_rc=0 commit_rc=0 begin_rc=0 stale_attempt_id="" failure_reason
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1
  windows_recovery_is_available || return 1
  _windows_error=""
  read_lifecycle || return 1
  if [[ "$_lifecycle_state" == transition ]]; then
    read_transaction_manifest "$_lifecycle_transaction_id" || return 1
    jq -e '.kind == "recovery-attempt" and .operation == "windows-recovery"' \
      <<< "$_manifest_json" >/dev/null || return 1
    stale_attempt_id="$_lifecycle_transaction_id"
    if ! reconcile_stale_lifecycle; then
      detach_transaction_context
      return 1
    fi
    read_lifecycle || return 1
    if [[ "$_lifecycle_state" == active \
      && $(jq -r '.last_recovery.final_attempt.id // ""' <<< "$_lifecycle_json") == \
        "$stale_attempt_id" ]]; then
      return 0
    fi
  fi
  load_windows_recovery_context || return $?
  arm_transaction_traps
  begin_lifecycle_recovery_attempt windows-recovery || begin_rc=$?
  if [[ $begin_rc -ne 0 ]]; then
    if [[ "$_transaction_active" == true ]]; then
      if read_lifecycle && [[ "$_lifecycle_state" == transition \
        && "$_lifecycle_transaction_id" == "$_transaction_id" ]]; then
        rollback_and_mark_recovery "$begin_rc" \
          "Windows recovery attempt initialization failed" failed || true
      else
        detach_transaction_context
      fi
    fi
    restore_transaction_traps
    return "$begin_rc"
  fi
  windows_recovery_transaction || callback_rc=$?
  close_windows_efibootmgr_boundary
  close_windows_unlink_boundary
  if [[ $callback_rc -eq 0 ]]; then
    commit_lifecycle_recovery_attempt || commit_rc=$?
    if [[ $commit_rc -ne 0 ]]; then
      rollback_and_mark_recovery "$commit_rc" \
        "stable Windows recovery publication failed" failed || true
      callback_rc=$commit_rc
    fi
  else
    failure_reason=${_windows_error:-Windows BootNext recovery failed}
    rollback_and_mark_recovery "$callback_rc" "$failure_reason" failed \
      || true
  fi
  restore_transaction_traps
  return "$callback_rc"
}

windows_bootnext_exact_target_is_current() {
  local record="$1"
  read_windows_target_state || return 1
  resolve_windows_target || {
    windows_report_error
    return 1
  }
  windows_state_matches_resolved_target || {
    windows_reject "Persisted Windows target identity is stale"
    return 1
  }
  jq -e \
    --arg boot_number "$_windows_state_boot_number" \
    --arg label "$_windows_state_label" \
    --arg partuuid "$_windows_state_partuuid" \
    --arg loader_path "$_windows_state_loader_path" '
      .target == {
        boot_number: $boot_number,
        label: $label,
        loader_path: $loader_path,
        partuuid: $partuuid
      }
    ' <<< "$record" >/dev/null || {
      windows_reject "The persisted Windows target does not match the BootNext record"
      return 1
    }
}

windows_bootnext_preflight() {
  windows_bootnext_mutation_is_available || {
    fail "Windows BootNext mutation is not available in this build"
    return 1
  }
  read_windows_target_state || return 1
  resolve_windows_target || {
    windows_report_error
    return 1
  }
  windows_state_matches_resolved_target || {
    windows_reject "Persisted Windows target identity is stale"
    return 1
  }
  read_windows_bootnext_state >/dev/null || {
    windows_report_error
    return 1
  }
  validate_windows_efibootmgr_boundary || {
    windows_report_error
    return 1
  }
  close_windows_efibootmgr_boundary
}

persist_windows_bootnext_record() {
  local prior="$1" executable_hash="$2" transaction_dir path boot_id timestamp
  local document reference
  [[ "$WINDOWS_BOOTNEXT_LOADER_PATH" == "$WINDOWS_LOADER_UEFI" ]] || return 1
  read_transaction_manifest "$_transaction_id" || return 1
  transaction_dir=$(dirname "$(lifecycle_manifest_path "$_transaction_id")") || return 1
  path="${transaction_dir}/bootnext.json"
  boot_id=$(boot_id_value) || return 1
  timestamp=$(utc_timestamp) || return 1
  document=$(jq -cn \
    --argjson schema "$BOOTNEXT_RECORD_SCHEMA_VERSION" \
    --arg transaction_id "$_transaction_id" \
    --arg writer_version "$OMASECBOOT_VERSION" \
    --arg boot_id "$boot_id" \
    --arg recorded_at "$timestamp" \
    --arg executable "$WINDOWS_EFIBOOTMGR_EXECUTABLE" \
    --arg executable_sha256 "$executable_hash" \
    --arg package "$WINDOWS_EFIBOOTMGR_PACKAGE_IDENTITY" \
    --arg boot_number "$_windows_state_boot_number" \
    --arg label "$_windows_state_label" \
    --arg loader_path "$_windows_state_loader_path" \
    --arg partuuid "$_windows_state_partuuid" \
    --argjson prior "$prior" '{
      schema_version: $schema,
      transaction_id: $transaction_id,
      writer_version: $writer_version,
      operation: "windows-bootnext",
      boot_id: $boot_id,
      recorded_at: $recorded_at,
      efibootmgr: {
        package: $package,
        executable: $executable,
        executable_sha256: $executable_sha256
      },
      target: {
        boot_number: $boot_number,
        label: $label,
        partuuid: $partuuid,
        loader_path: $loader_path
      },
      prior: $prior
    }') || return 1
  validate_bootnext_record_json "$_transaction_id" "$document" "$_manifest_json" || return 1
  printf '%s\n' "$document" | atomic_create_control_file "$path" 600 || return 1
  reference=$(transaction_artifact_reference "$path" "$BOOTNEXT_RECORD_SCHEMA_VERSION") \
    || return 1
  transaction_set_domain_record bootnext "$reference" || return 1
  _windows_bootnext_record_json="$document"
  _windows_bootnext_record_path="$path"
}

load_windows_bootnext_record() {
  local reference path
  read_transaction_manifest "$_transaction_id" || return 1
  reference=$(jq -c '.domain_records.bootnext' <<< "$_manifest_json") || return 1
  [[ "$reference" != null ]] || return 1
  validate_bootnext_record_reference "$_transaction_id" "$reference" "$_manifest_json" \
    || return 1
  path=$(jq -r '.path' <<< "$reference") || return 1
  _windows_bootnext_record_json=$(read_control_document "$path") || return 1
  _windows_bootnext_record_path="$path"
}

record_and_set_windows_bootnext() {
  local prior executable_hash boot_id current_hash target_number command_rc observed
  transaction_phase_start "record-bootnext" || return 1
  read_windows_target_state || return 1
  resolve_windows_target || {
    windows_report_error
    return 1
  }
  windows_state_matches_resolved_target || {
    windows_reject "Persisted Windows target identity is stale"
    return 1
  }
  prior=$(read_windows_bootnext_state) || {
    windows_report_error
    return 1
  }
  validate_windows_efibootmgr_boundary || {
    windows_report_error
    return 1
  }
  executable_hash="$_windows_efibootmgr_hash"
  close_windows_efibootmgr_boundary
  persist_windows_bootnext_record "$prior" "$executable_hash" || return 1
  windows_bootnext_failpoint "after-bootnext-record" || return 1
  transaction_phase_complete "record-bootnext" || return 1

  transaction_phase_start "set-bootnext" || return 1
  load_windows_bootnext_record || return 1
  boot_id=$(boot_id_value) || return 1
  [[ $(jq -r '.boot_id' <<< "$_windows_bootnext_record_json") == "$boot_id" ]] || {
    windows_reject "The system boot changed before the BootNext write"
    return 1
  }
  validate_windows_efibootmgr_boundary || {
    windows_report_error
    return 1
  }
  windows_bootnext_failpoint "before-target-revalidation" || {
    close_windows_efibootmgr_boundary
    return 1
  }
  windows_bootnext_exact_target_is_current "$_windows_bootnext_record_json" || {
    close_windows_efibootmgr_boundary
    windows_report_error
    return 1
  }
  current_hash=$(hash_bound_windows_efibootmgr) || {
    close_windows_efibootmgr_boundary
    return 1
  }
  jq -e --arg hash "$current_hash" '.efibootmgr.executable_sha256 == $hash' \
    <<< "$_windows_bootnext_record_json" >/dev/null || {
      close_windows_efibootmgr_boundary
      windows_reject "The efibootmgr executable changed before the BootNext write"
      return 1
    }
  boot_id=$(boot_id_value) || {
    close_windows_efibootmgr_boundary
    return 1
  }
  [[ $(jq -r '.boot_id' <<< "$_windows_bootnext_record_json") == "$boot_id" ]] || {
    close_windows_efibootmgr_boundary
    windows_reject "The system boot changed before the BootNext write"
    return 1
  }
  prior=$(read_windows_bootnext_state) || {
    close_windows_efibootmgr_boundary
    windows_report_error
    return 1
  }
  jq -e --argjson prior "$prior" '.prior == $prior' \
    <<< "$_windows_bootnext_record_json" >/dev/null || {
      close_windows_efibootmgr_boundary
      windows_reject "BootNext changed after its prior value was recorded"
      return 1
    }
  windows_bootnext_mutation_is_available || {
    close_windows_efibootmgr_boundary
    fail "Windows BootNext mutation is not available in this build"
    return 1
  }
  target_number=$(jq -r '.target.boot_number' <<< "$_windows_bootnext_record_json") \
    || {
      close_windows_efibootmgr_boundary
      return 1
    }
  command_rc=0
  run_windows_efibootmgr -n "$target_number" || command_rc=$?
  windows_bootnext_failpoint "after-bootnext-command" || {
    close_windows_efibootmgr_boundary
    return 1
  }
  observed=$(read_windows_bootnext_state) || {
    close_windows_efibootmgr_boundary
    windows_report_error
    return 1
  }
  [[ $command_rc -eq 0 ]] || {
    close_windows_efibootmgr_boundary
    fail "efibootmgr failed while setting BootNext"
    return "$command_rc"
  }
  jq -e --arg target "$target_number" \
    '.present == true and .boot_number == $target' <<< "$observed" >/dev/null || {
      close_windows_efibootmgr_boundary
      windows_reject "BootNext readback does not match the requested Windows target"
      windows_report_error
      return 1
    }
  windows_bootnext_exact_target_is_current "$_windows_bootnext_record_json" || {
    close_windows_efibootmgr_boundary
    windows_report_error
    return 1
  }
  current_hash=$(hash_bound_windows_efibootmgr) || {
    close_windows_efibootmgr_boundary
    return 1
  }
  jq -e --arg hash "$current_hash" '.efibootmgr.executable_sha256 == $hash' \
    <<< "$_windows_bootnext_record_json" >/dev/null || {
      close_windows_efibootmgr_boundary
      windows_reject "The efibootmgr executable changed after the BootNext write"
      return 1
    }
  boot_id=$(boot_id_value) || {
    close_windows_efibootmgr_boundary
    return 1
  }
  [[ $(jq -r '.boot_id' <<< "$_windows_bootnext_record_json") == "$boot_id" ]] || {
    close_windows_efibootmgr_boundary
    windows_reject "The system boot changed after the BootNext write"
    return 1
  }
  observed=$(read_windows_bootnext_state) || {
    close_windows_efibootmgr_boundary
    windows_report_error
    return 1
  }
  jq -e --arg target "$target_number" \
    '.present == true and .boot_number == $target' <<< "$observed" >/dev/null || {
      close_windows_efibootmgr_boundary
      windows_reject "BootNext changed during final target verification"
      windows_report_error
      return 1
    }
  close_windows_efibootmgr_boundary
  transaction_phase_complete "set-bootnext"
}

run_dormant_windows_bootnext() {
  run_lifecycle_transaction_with_preflight "windows-bootnext" "active" "active" \
    windows_bootnext_preflight record_and_set_windows_bootnext
}

windows_managed_block_state() {
  local label="$1" config index begin_count=0 end_count=0 legacy_count=0
  local suspicious_count=0
  local begin_index=-1 end_index=-1 legacy_index=-1 next_index
  local -a lines=()
  config=$(windows_limine_config_path) || return 1
  [[ -f "$config" && ! -L "$config" ]] || return 1
  mapfile -t lines < "$config" || return 1
  for ((index=0; index < ${#lines[@]}; index++)); do
    case "${lines[$index]}" in
      "$WINDOWS_ENTRY_MARKER")
        begin_count=$((begin_count + 1))
        begin_index=$index
        ;;
      "$WINDOWS_ENTRY_END_MARKER")
        end_count=$((end_count + 1))
        end_index=$index
        ;;
      "$WINDOWS_LEGACY_ENTRY_MARKER")
        legacy_count=$((legacy_count + 1))
        legacy_index=$index
        ;;
      "$WINDOWS_ENTRY_MARKER"*|"$WINDOWS_ENTRY_END_MARKER"*|\
      "$WINDOWS_LEGACY_ENTRY_MARKER"*)
        suspicious_count=$((suspicious_count + 1))
        ;;
    esac
  done
  _windows_block_state=invalid
  _windows_block_start=-1
  _windows_block_count=0
  if (( begin_count == 0 && end_count == 0 && legacy_count == 0 \
    && suspicious_count == 0 )); then
    _windows_block_state=absent
    return 0
  fi
  if (( begin_count == 1 && end_count == 1 && legacy_count == 0 \
    && suspicious_count == 0 \
    && end_index == begin_index + 5 )) \
    && [[ "${lines[begin_index + 1]}" == /Windows \
      && "${lines[begin_index + 2]}" == "    comment: ${label}" \
      && "${lines[begin_index + 3]}" == '    protocol: efi_boot_entry' \
      && "${lines[begin_index + 4]}" == "    entry: ${label}" ]]; then
    _windows_block_state=canonical
    _windows_block_start=$begin_index
    _windows_block_count=6
    return 0
  fi
  if (( begin_count == 0 && end_count == 0 && legacy_count == 1 \
    && suspicious_count == 0 \
    && legacy_index + 4 < ${#lines[@]} )) \
    && [[ "${lines[legacy_index + 1]}" == /Windows \
      && "${lines[legacy_index + 2]}" == "    comment: ${label}" \
      && "${lines[legacy_index + 3]}" == '    protocol: efi_boot_entry' \
      && "${lines[legacy_index + 4]}" == "    entry: ${label}" ]]; then
    next_index=$((legacy_index + 5))
    if (( next_index == ${#lines[@]} )) \
      || [[ -z "${lines[$next_index]}" \
        || "${lines[$next_index]}" != [[:space:]]* ]]; then
      _windows_block_state=legacy
      _windows_block_start=$legacy_index
      _windows_block_count=5
      return 0
    fi
  fi
  return 1
}

windows_emit_managed_block() {
  local label="$1"
  printf '%s\n' \
    "$WINDOWS_ENTRY_MARKER" \
    '/Windows' \
    "    comment: ${label}" \
    '    protocol: efi_boot_entry' \
    "    entry: ${label}" \
    "$WINDOWS_ENTRY_END_MARKER"
}

windows_preserve_config_metadata() {
  local temporary="$1" uid="$2" gid="$3" mode="$4" current
  if ! chown "${uid}:${gid}" "$temporary" 2>/dev/null; then
    current=$(stat -Lc '%u:%g' "$temporary" 2>/dev/null) || return 1
    [[ "$current" == "${uid}:${gid}" ]] || return 1
  fi
  if ! chmod "$mode" "$temporary" 2>/dev/null; then
    current=$(stat -Lc '%a' "$temporary" 2>/dev/null) || return 1
    [[ "$current" == "$mode" ]] || return 1
  fi
}

windows_rewrite_managed_block() {
  local action="$1" label="$2" config config_dir temporary old_umask
  local uid gid mode index inserted=false
  local -a lines=()
  [[ "$action" == install || "$action" == remove ]] || return 1
  [[ "${_transaction_active:-false}" == true ]] || return 1
  windows_managed_block_state "$label" || return 1
  case "$action:$_windows_block_state" in
    install:canonical|remove:absent)
      return 0
      ;;
    install:absent|install:legacy|remove:canonical|remove:legacy)
      ;;
    *)
      return 1
      ;;
  esac
  config=$(windows_limine_config_path) || return 1
  transaction_backup_file "$config" || return 1
  read -r uid gid mode < <(stat -Lc '%u %g %a' "$config" 2>/dev/null) \
    || return 1
  mapfile -t lines < "$config" || return 1
  config_dir=$(dirname "$config")
  [[ -d "$config_dir" && ! -L "$config_dir" ]] || return 1
  old_umask=$(umask)
  umask 077
  temporary=$(mktemp "${config_dir}/.omasecboot-windows.XXXXXX") || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"

  if ! {
    for ((index=0; index < ${#lines[@]}; index++)); do
      if (( index == _windows_block_start )); then
        if [[ "$action" == install ]]; then
          windows_emit_managed_block "$label"
        fi
        index=$((index + _windows_block_count - 1))
        inserted=true
        continue
      fi
      printf '%s\n' "${lines[$index]}"
    done
    if [[ "$action" == install && "$inserted" == false ]]; then
      if (( ${#lines[@]} > 0 )) && [[ -n "${lines[-1]}" ]]; then
        printf '\n'
      fi
      windows_emit_managed_block "$label"
    fi
  } > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if ! windows_preserve_config_metadata "$temporary" "$uid" "$gid" "$mode" \
    || ! durable_sync "$temporary" \
    || ! mv -f "$temporary" "$config" \
    || ! durable_sync "$config_dir"; then
    rm -f "$temporary"
    return 1
  fi
}

update_windows_boot_entry() {
  local label="$1"
  revalidate_windows_target_state || return 1
  [[ "$_windows_label" == "$label" ]] || return 1
  windows_rewrite_managed_block install "$label"
}

windows_setup_preflight() {
  resolve_windows_target || return 1
  windows_managed_block_state "$_windows_label" || return 1
  windows_classify_target_state || return 1
  if [[ "$_windows_state_kind" == current ]]; then
    windows_state_matches_resolved_target || return 1
  fi
  windows_setup_inputs_are_consistent || return 1
  artifact_repair_preflight
}

windows_setup_inputs_are_consistent() {
  case "${_windows_state_kind}:${_windows_block_state}" in
    absent:absent|legacy-empty:absent|legacy-empty:legacy|\
    current:absent|current:legacy|current:canonical)
      return 0
      ;;
  esac
  windows_reject "Windows state and managed-block ownership do not agree"
}

configure_windows_handoff() {
  local state_file config
  state_file=$(windows_target_state_path) || return 1
  config=$(windows_limine_config_path) || return 1
  transaction_phase_start "backup-windows" || return 1
  transaction_backup_file "$state_file" true || return 1
  transaction_backup_file "$config" || return 1
  transaction_phase_complete "backup-windows" || return 1

  transaction_phase_start "resolve-windows" || return 1
  resolve_windows_target || return 1
  windows_managed_block_state "$_windows_label" || return 1
  windows_classify_target_state || return 1
  if [[ "$_windows_state_kind" == current ]]; then
    windows_state_matches_resolved_target || return 1
  fi
  windows_setup_inputs_are_consistent || return 1
  transaction_phase_complete "resolve-windows" || return 1

  transaction_phase_start "persist-windows-target" || return 1
  write_windows_target_state || return 1
  transaction_phase_complete "persist-windows-target" || return 1

  transaction_phase_start "configure-windows-entry" || return 1
  update_windows_boot_entry "$_windows_label" || return 1
  _repair_config_checksum=$(current_limine_config_checksum) || return 1
  transaction_phase_complete "configure-windows-entry" || return 1

  repair_boot_artifacts || return 1

  transaction_phase_start "prove-windows" || return 1
  revalidate_windows_target_state || return 1
  windows_managed_block_state "$_windows_state_label" || return 1
  [[ "$_windows_block_state" == canonical ]] || return 1
  transaction_phase_complete "prove-windows"
}

run_windows_handoff_setup() {
  run_lifecycle_transaction_with_preflight "windows-setup" "active" "active" \
    windows_setup_preflight configure_windows_handoff
}

add_windows_boot_entry() {
  local boot_number label
  header "Windows Dual-Boot"
  find_windows_boot_entry >/dev/null || {
    windows_report_error
    return 1
  }
  boot_number="$_windows_boot_number"
  label="$_windows_label"
  pass "Found ${label} (Boot${boot_number})"
  require_gum || return 1
  if ! gum confirm "Validate and add Windows to the Limine boot menu?"; then
    warn "Aborted"
    return 1
  fi
  run_windows_handoff_setup || {
    windows_report_error
    return 1
  }
  pass "Windows target identity and managed Limine entry proved"
}

windows_require_unsafe_target() {
  local revalidation_rc=0
  _windows_error=""
  revalidate_windows_target_state || revalidation_rc=$?
  if [[ $revalidation_rc -eq 0 ]]; then
    windows_reject "Windows target remains valid; suppression is not allowed"
    return 1
  fi
  [[ -n "$_windows_error" ]] \
    || _windows_error="Persisted Windows target could not be proved safe"
}

windows_suppression_preflight() {
  local label
  read_windows_target_state || return 1
  label="$_windows_state_label"
  windows_require_unsafe_target || return 1
  read_windows_target_state || return 1
  [[ "$_windows_state_label" == "$label" ]] || return 1
  windows_managed_block_state "$label" || return 1
  [[ "$_windows_block_state" == canonical || "$_windows_block_state" == legacy ]] \
    || return 1
  artifact_repair_preflight
}

suppress_stale_windows_entry_body() {
  local state_file config state_hash label
  state_file=$(windows_target_state_path) || return 1
  config=$(windows_limine_config_path) || return 1
  read_windows_target_state || return 1
  label="$_windows_state_label"
  state_hash=$(sha256_file "$state_file") || return 1

  transaction_phase_start "backup-windows" || return 1
  transaction_backup_file "$state_file" || return 1
  transaction_backup_file "$config" || return 1
  transaction_phase_complete "backup-windows" || return 1

  transaction_phase_start "suppress-windows-entry" || return 1
  [[ "$(sha256_file "$state_file")" == "$state_hash" ]] || return 1
  windows_require_unsafe_target || return 1
  windows_rewrite_managed_block remove "$label" || return 1
  _repair_config_checksum=$(current_limine_config_checksum) || return 1
  transaction_phase_complete "suppress-windows-entry" || return 1

  repair_boot_artifacts || return 1

  transaction_phase_start "prove-windows-suppression" || return 1
  [[ "$(sha256_file "$state_file")" == "$state_hash" ]] || return 1
  windows_managed_block_state "$label" || return 1
  [[ "$_windows_block_state" == absent ]] || return 1
  transaction_phase_complete "prove-windows-suppression"
}

suppress_stale_windows_entry() {
  run_lifecycle_transaction_with_preflight "windows-suppress" "active" "active" \
    windows_suppression_preflight suppress_stale_windows_entry_body
}
