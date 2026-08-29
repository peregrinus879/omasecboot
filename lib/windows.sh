#!/bin/bash
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

declare -ag _windows_order=()
declare -Ag _windows_inventory_label=()
declare -Ag _windows_inventory_active=()
declare -Ag _windows_inventory_exact=()
declare -Ag _windows_inventory_valid=()
declare -Ag _windows_inventory_partuuid=()
declare -Ag _windows_inventory_partition=()
declare -Ag _windows_inventory_start=()
declare -Ag _windows_inventory_size=()

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
  printf '%s/windows-esp\n' "$(windows_runtime_dir_path)"
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
  local diagnostics_file old_umask command_rc=0 diagnostics=false
  local -a raw_order=()
  local -A order_numbers=() dp_seen=()
  local LC_ALL=C

  _windows_error=""
  windows_reset_target
  windows_reset_inventory
  command -v efibootmgr >/dev/null 2>&1 || {
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
  inventory=$(LC_ALL=C efibootmgr -v 2> "$diagnostics_file") || command_rc=$?
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

windows_prepare_runtime_mountpoint() {
  local runtime mount_path
  runtime=$(windows_runtime_dir_path) || return 1
  mount_path=$(windows_runtime_mount_path) || return 1
  if [[ ! -e "$runtime" && ! -L "$runtime" ]]; then
    install -d -m 700 "$runtime" || return 1
  fi
  validate_private_control_directory "$runtime" || return 1
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
  local rc="$1" cleanup_rc=0
  trap - EXIT INT TERM HUP
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

windows_verify_target_loader() {
  if ! (
    local mount_path expected_mount_id="" expected_mount_access=ro
    _windows_owned_mount_active=false
    _windows_owned_mount_path=""
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
    windows_verify_loader_file "$mount_path" "$_windows_target_mount_id" || exit 1
    windows_target_mount_is_valid \
      "$mount_path" "$_windows_target_mount_id" "$expected_mount_access" || exit 1
  ); then
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
