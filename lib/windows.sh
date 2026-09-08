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
_windows_dp_exact=false
_windows_dp_valid=false
_windows_dp_partuuid=""
_windows_dp_partition=""
_windows_dp_start=""
_windows_dp_size=""
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
_windows_runtime_mount_override=""
_windows_preflight_result=""
_windows_preflight_firmware_state=absent
_windows_preflight_bitlocker_state=absent
_windows_preflight_loader_state=absent
_windows_preflight_gum=""
_windows_bootnext_record_json=""
_windows_bootnext_record_path=""
_windows_efibootmgr_fd=""
_windows_efibootmgr_hash=""
_windows_efibootmgr_package=""
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
declare -ag _windows_preflight_loader_devices=()
declare -ag _windows_preflight_unknown_reasons=()

windows_bootnext_failpoint() {
  return 0
}

windows_recovery_failpoint() {
  return 0
}

windows_efibootmgr_executable_path() {
  printf '%s\n' "$WINDOWS_EFIBOOTMGR_EXECUTABLE"
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

# Test seam: suites point this at a fixture configuration.
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
      *) [[ "$stage" == prefix ]] || sequence_valid=false ;;
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
    def uint: . == null or
      (type == "number" and . >= 0 and . <= 9007199254740991 and floor == .);
    def text: . == null or type == "string";
    (.blockdevices | type) == "array" and
    all(.blockdevices[];
      type == "object" and
      (keys == ["fstype", "log-sec", "maj:min", "partn", "parttype", "partuuid", "path", "size", "start", "type"]) and
      (.path | type) == "string" and (."maj:min" | type) == "string" and
      (.type | type) == "string" and (.partn | uint) and (.partuuid | text) and
      (.parttype | text) and (.start | uint) and (.size | uint) and
      (."log-sec" | uint) and (.fstype | text))
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
    (.partn | type) == "number" and (.partuuid | type) == "string" and
    (.parttype | type) == "string" and (.start | type) == "number" and
    (.size | type) == "number" and (."log-sec" | type) == "number" and
    (.fstype | type) == "string"
  ' <<< "$row" >/dev/null || {
    windows_reject "Windows ESP mapping is incomplete"
    return 1
  }
  read_lines path maj_min partn partuuid parttype start size log_sec fstype \
    < <(jq -r '.path, ."maj:min", .partn, .partuuid, .parttype, .start, .size,
      ."log-sec", .fstype' <<< "$row") || return 1

  [[ "$path" =~ ^/dev/[A-Za-z0-9._/+:-]+$ \
    && "$maj_min" =~ ^[0-9]+:[0-9]+$ \
    && "$partn" == "$_windows_partition_number" \
    && "${partuuid,,}" == "$_windows_partuuid" \
    && "${parttype,,}" == "$WINDOWS_ESP_PARTTYPE" \
    && "$fstype" == vfat ]] || {
    windows_reject "Windows target does not map to the expected FAT ESP"
    return 1
  }
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

# Reuses the one whole-filesystem mount of the target ESP when it exists;
# more than one is ambiguous, and none means a private read-only mount.
windows_find_reusable_mount() {
  local owned json targets
  local -a candidates=()
  _windows_reusable_mount=""
  owned=$(windows_runtime_mount_path) || return 1
  json=$(LC_ALL=C findmnt --json --list --output TARGET,MAJ:MIN,FSTYPE,FSROOT \
    2>/dev/null) || {
    windows_reject "Could not read mount inventory"
    return 1
  }
  targets=$(jq -r --arg maj "$_windows_maj_min" --arg owned "$owned" '
    .filesystems[] |
    select(."maj:min" == $maj and .target != $owned
      and .fstype == "vfat" and .fsroot == "/") | .target
  ' <<< "$json" 2>/dev/null) || {
    windows_reject "Mount inventory has an unsupported JSON shape"
    return 1
  }
  [[ -z "$targets" ]] || mapfile -t candidates <<< "$targets"
  (( ${#candidates[@]} <= 1 )) || {
    windows_reject "Windows ESP has multiple reusable mounts"
    return 1
  }
  (( ${#candidates[@]} == 1 )) || return 0
  if [[ ! "${candidates[0]}" =~ ^/[^[:cntrl:]]+$ || ! -d "${candidates[0]}" ]] \
    || ! path_has_no_symlink_components "${candidates[0]}"; then
    windows_reject "Windows ESP mount path is unsafe"
    return 1
  fi
  _windows_reusable_mount="${candidates[0]}"
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
  local mount_path="$1" json
  json=$(LC_ALL=C findmnt --json --list --mountpoint "$mount_path" \
    --output TARGET,MAJ:MIN,FSTYPE,FSROOT 2>/dev/null) || return 1
  jq -e --arg target "$mount_path" --arg maj "$_windows_maj_min" '
    (.filesystems | length) == 1 and
    (.filesystems[0] | .target == $target and ."maj:min" == $maj
      and .fstype == "vfat" and .fsroot == "/")
  ' <<< "$json" >/dev/null
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

# The mounted target holds a PE image at the Windows loader path on the
# mapped device; the read follows no symlink and leaves the access time alone.
windows_verify_loader_file() {
  local mount_path="$1" loader loader_fd maj_min size magic rc=1
  loader="${mount_path}${WINDOWS_LOADER_POSIX}"
  [[ -f "$loader" && ! -L "$loader" ]] || return 1
  exec {loader_fd}< "$loader" || return 1
  if read -r maj_min size \
      < <(stat -Lc '%Hd:%Ld %s' "/proc/${BASHPID}/fd/${loader_fd}" 2>/dev/null) \
    && [[ "$maj_min" == "$_windows_maj_min" && "$size" =~ ^[0-9]+$ ]] \
    && (( size >= 64 )) \
    && magic=$(dd bs=2 count=1 iflag=fullblock,noatime status=none \
      <&"$loader_fd" 2>/dev/null | od -An -tx1 | tr -d '[:space:]') \
    && [[ "$magic" == 4d5a ]]; then
    rc=0
  fi
  exec {loader_fd}<&-
  return "$rc"
}

windows_with_target_mount() {
  local callback="$1" mount_override="${2:-}"
  (
    local mount_path callback_rc=0
    _windows_runtime_mount_override="$mount_override"
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
    else
      windows_prepare_runtime_mountpoint || exit 1
      mount_path=$(windows_runtime_mount_path) || exit 1
      _windows_owned_mount_active=true
      _windows_owned_mount_path="$mount_path"
      mount -t vfat -o ro,nosuid,nodev,noexec,noatime,dmask=0077,fmask=0177 -- \
        "$_windows_device_path" "$mount_path" || exit 1
    fi
    windows_target_mount_is_valid "$mount_path" || exit 1
    "$callback" "$mount_path" || callback_rc=$?
    case "$callback_rc" in
      0|2) ;;
      *) exit "$callback_rc" ;;
    esac
    windows_target_mount_is_valid "$mount_path" || exit 1
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
  for command in dd efibootmgr findmnt install jq lsblk mount od rmdir stat tr \
    umount; do
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
  _windows_preflight_gum=""
  _windows_preflight_bitlocker_devices=()
  _windows_preflight_loader_devices=()
  _windows_preflight_esp_candidates=()
  _windows_preflight_unknown_reasons=()
}

# A detector ends as present when it saw its signal, unknown when any probe
# was inconclusive, and absent otherwise; unknown wins over present.
windows_preflight_mark_seen() {
  local variable="_windows_preflight_${1}_state"
  [[ "${!variable}" == unknown ]] || printf -v "$variable" '%s' present
}

windows_preflight_mark_unknown() {
  local detector="$1" reason="$2"
  case "$detector" in
    firmware|bitlocker|loader) ;;
    *) return 1 ;;
  esac
  printf -v "_windows_preflight_${detector}_state" '%s' unknown
  _windows_preflight_unknown_reasons+=("$reason")
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
      windows_preflight_mark_seen firmware
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
    read_lines path maj_min parttype removable transport subsystems \
      < <(jq -r '.path, ."maj:min", (.parttype // ""), .rm, (.tran // ""),
        (.subsystems // "")' <<< "$row") || return 1
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
        windows_preflight_mark_seen bitlocker
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

# 0: a Microsoft loader is present on the mounted ESP; 2: none; 1: unsafe.
windows_preflight_inspect_loader() {
  local mount_path="$1" loader
  loader="${mount_path}${WINDOWS_LOADER_POSIX}"
  [[ -e "$loader" || -L "$loader" ]] || return 2
  windows_verify_loader_file "$mount_path"
}

windows_preflight_scan_esps() {
  local prior_limine="$_OMASECBOOT_LIMINE_LOCK_OWNED"
  local prior_repair="$_OMASECBOOT_REPAIR_LOCK_OWNED"
  local acquired_limine=false acquired_repair=false candidate device maj_min
  local mount_path rc=0 scan_rc=0
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
    windows_with_target_mount windows_preflight_inspect_loader "$mount_path" || rc=$?
    if ! windows_block_device_matches "$device" "$maj_min"; then
      windows_preflight_mark_unknown loader \
        "ESP ${device} changed identity during loader inspection"
      continue
    fi
    case "$rc" in
      0)
        windows_preflight_mark_seen loader
        _windows_preflight_loader_devices+=("$device")
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
  windows_preflight_reset
  windows_preflight_detect_firmware
  if ! windows_preflight_read_block_inventory; then
    windows_preflight_mark_unknown bitlocker \
      "Block-device inventory processing failed safely"
    windows_preflight_mark_unknown loader \
      "ESP inventory processing failed safely"
  fi
  windows_preflight_scan_esps
}

windows_preflight_print_summary() {
  local device
  printf '  Detection summary:\n'
  printf '    Firmware option: %s\n' "$_windows_preflight_firmware_state"
  printf '    BitLocker signature: %s\n' "$_windows_preflight_bitlocker_state"
  printf '    Microsoft loader on ESP: %s\n' "$_windows_preflight_loader_state"
  for device in "${_windows_preflight_bitlocker_devices[@]}"; do
    printf '    BitLocker-format volume: %s\n' "$device"
  done
  for device in "${_windows_preflight_loader_devices[@]}"; do
    printf '    Boot manager: %s\n' "$device"
  done
  echo
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
    --arg loader "$WINDOWS_LOADER_UEFI" \
    --argjson schema "$WINDOWS_STATE_SCHEMA_VERSION" '{
      schema_version: $schema,
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
  local directory path uid mode size bytes_text number present=false
  local -a bytes=()
  windows_validate_efivarfs_mount || return 1
  directory=$(windows_bootnext_efivars_dir) || return 1
  path=$(windows_bootnext_variable_path) || return 1
  [[ "$path" == "${directory}/BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c" ]] \
    || return 1
  validate_control_directory "$directory" || {
    windows_reject "EFI variable filesystem permissions are unsafe"
    return 1
  }
  [[ ! -e "$path" && ! -L "$path" ]] || present=true
  windows_validate_efivarfs_mount || {
    windows_reject "EFI variable filesystem changed while it was scanned"
    return 1
  }
  if [[ "$present" == false ]]; then
    jq -cn '{boot_number:null,present:false}'
    return
  fi
  [[ -f "$path" && ! -L "$path" ]] || {
    windows_reject "BootNext EFI variable is not a safe regular file"
    return 1
  }
  read -r uid mode size < <(stat -Lc '%u %a %s' "$path" 2>/dev/null) || {
    windows_reject "Cannot inspect the BootNext EFI variable"
    return 1
  }
  if [[ "$uid" != "$(control_owner_uid)" || ! "$mode" =~ ^[0-7]{3,4}$ || "$size" != 6 ]] \
    || (( (8#$mode & 0022) != 0 )); then
    windows_reject "BootNext EFI variable metadata is invalid"
    return 1
  fi
  bytes_text=$(od -An -v -tu1 -N 6 "$path" 2>/dev/null) || {
    windows_reject "Cannot read the BootNext EFI variable"
    return 1
  }
  read -r -a bytes <<< "$bytes_text"
  if [[ ${#bytes[@]} -ne 6 ]] \
    || (( bytes[0] != 7 || bytes[1] != 0 || bytes[2] != 0 || bytes[3] != 0 )); then
    windows_reject "BootNext EFI variable attributes are unsupported"
    return 1
  fi
  printf -v number '%04X' "$((bytes[4] + (bytes[5] << 8)))"
  jq -cn --arg number "$number" '{boot_number:$number,present:true}'
}

validate_windows_efibootmgr_boundary() {
  local package owner path path_uid path_mode path_device path_inode
  local fd_path fd_uid fd_mode fd_device fd_inode executable_hash
  close_windows_efibootmgr_boundary
  path=$(windows_efibootmgr_executable_path) || return 1
  package=$(producer_package_version efibootmgr) || {
    windows_reject "Cannot verify the installed efibootmgr package"
    return 1
  }
  version_at_least "$package" "$WINDOWS_EFIBOOTMGR_MINIMUM_VERSION" || {
    windows_reject "Unsupported efibootmgr package: efibootmgr ${package}"
    return 1
  }
  _windows_efibootmgr_package="efibootmgr ${package}"
  owner=$(producer_file_owner_package "$path") || {
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

capture_windows_bootnext_variable_evidence() {
  local path state before_identity after_identity before_hash after_hash
  path=$(windows_bootnext_variable_path) || return 1
  state=$(read_windows_bootnext_state) || return 1
  json_is '.present == true' "$state" || return 1
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
    ]] && json_is '.present == false' "$observed"; then
    action=none
    outcome=consumed-unknown
  elif jq -e --argjson prior "$prior" '. == $prior' <<< "$observed" >/dev/null; then
    action=none
    outcome="prior-unchanged"
  elif jq -e --arg target "$target" \
    '.present == true and .boot_number == $target' <<< "$observed" >/dev/null; then
    outcome="prior-restored"
    if json_is '.present == true' "$prior"; then
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

# Removes the BootNext variable through GNU rm; a wrapper so tests can observe
# and fail the call.
remove_windows_bootnext_variable() {
  [[ "$1" == "$(windows_bootnext_variable_path)" ]] || return 1
  rm -f -- "$1"
}

execute_windows_recovery_action() {
  local action recovery_boot_id current_state rc=0
  load_windows_recovery_record || return 1
  action=$(jq -r '.action' <<< "$_windows_recovery_record_json") || return 1
  recovery_boot_id=$(jq -r '.recovery_boot_id' <<< "$_windows_recovery_record_json") \
    || return 1
  [[ "$recovery_boot_id" == "$(boot_id_value)" ]] || {
    windows_reject "The system boot changed during Windows recovery"
    return 1
  }
  if [[ "$action" == none ]]; then
    _windows_recovery_command_rc=null
    return 0
  fi
  case "$action" in
    set-prior)
      validate_windows_efibootmgr_boundary || return 1
      windows_recovery_set_prior || rc=$?
      close_windows_efibootmgr_boundary
      ;;
    delete) windows_recovery_delete || rc=$? ;;
    *) return 1 ;;
  esac
  [[ $rc -eq 0 ]] || return "$rc"
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

# BootNext must still read exactly as the recovery record observed it.
windows_recovery_state_is_observed() {
  local current_state
  current_state=$(read_windows_bootnext_state) || {
    windows_reject "BootNext became unreadable before Windows recovery mutation"
    windows_report_error
    return 1
  }
  jq -e --argjson expected "$(jq -c '.observed' <<< "$_windows_recovery_record_json")" \
    '. == $expected' <<< "$current_state" >/dev/null || {
    windows_reject "BootNext changed after Windows recovery evidence was recorded"
    windows_report_error
    return 1
  }
}

# Runs with the efibootmgr boundary open; the caller closes it.
windows_recovery_set_prior() {
  local prior_number command_rc=0
  [[ "$(hash_bound_windows_efibootmgr)" == \
    "$(jq -r '.tool.executable_sha256' <<< "$_windows_recovery_record_json")" ]] \
    || return 1
  windows_recovery_state_is_observed || return 1
  prior_number=$(jq -r '.prior.boot_number' <<< "$_windows_recovery_record_json") \
    || return 1
  run_windows_efibootmgr -n "$prior_number" || command_rc=$?
  windows_recovery_failpoint "after-recovery-command" || return 1
  _windows_recovery_command_rc="$command_rc"
}

windows_recovery_delete() {
  local command_rc=0
  windows_recovery_state_is_observed || return 1
  [[ "$(jq -Sc . <<< "$(capture_windows_bootnext_variable_evidence)")" == \
    "$(jq -Sc '.variable' <<< "$_windows_recovery_record_json")" ]] || return 1
  remove_windows_bootnext_variable "$(windows_bootnext_variable_path)" || command_rc=$?
  windows_recovery_failpoint "after-recovery-command" || return 1
  _windows_recovery_command_rc="$command_rc"
}

persist_windows_recovery_proof() {
  local timestamp outcome final_state document record_reference
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
  persist_transaction_domain_record final_proof windows-recovery-proof.json \
    "$WINDOWS_RECOVERY_PROOF_SCHEMA_VERSION" validate_windows_recovery_proof_json \
    '["proved_at"]' "$document"
}

windows_recovery_transaction() {
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
  local stale_attempt_id=""
  boot_locks_are_held || return 1
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
  run_recovery_attempt_locked windows-recovery windows_recovery_attempt "Windows recovery"
}

# The recovery transaction with the efibootmgr boundary closed afterwards and
# the Windows diagnostic carried into the rollback reason.
windows_recovery_attempt() {
  local rc=0
  windows_recovery_transaction || rc=$?
  close_windows_efibootmgr_boundary
  (( rc == 0 )) || _transaction_failure_reason=${_windows_error:-Windows BootNext recovery failed}
  return "$rc"
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
    --arg package "$_windows_efibootmgr_package" \
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
  local prior executable_hash rc=0
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
  validate_windows_efibootmgr_boundary || {
    windows_report_error
    return 1
  }
  write_windows_bootnext_bound || rc=$?
  close_windows_efibootmgr_boundary
  [[ $rc -eq 0 ]] || {
    windows_report_error
    return "$rc"
  }
  transaction_phase_complete "set-bootnext"
}

# The open efibootmgr inode still matches the record and this is still the
# boot the record was published in.
windows_bootnext_record_matches_boundary() {
  local record="$1" current_hash boot_id
  current_hash=$(hash_bound_windows_efibootmgr) || return 1
  boot_id=$(boot_id_value) || return 1
  jq -e --arg hash "$current_hash" --arg boot_id "$boot_id" \
    '.efibootmgr.executable_sha256 == $hash and .boot_id == $boot_id' \
    <<< "$record" >/dev/null || {
    windows_reject "The efibootmgr executable or the system boot changed before the BootNext write"
    return 1
  }
}

# Runs with the efibootmgr boundary open; the caller closes it. Every proof
# is repeated immediately before the only write, and the write is accepted
# only on exact direct readback.
write_windows_bootnext_bound() {
  local record="$_windows_bootnext_record_json" target_number prior observed
  local command_rc=0
  windows_bootnext_failpoint "before-target-revalidation" || return 1
  windows_bootnext_exact_target_is_current "$record" || return 1
  windows_bootnext_record_matches_boundary "$record" || return 1
  prior=$(read_windows_bootnext_state) || return 1
  jq -e --argjson prior "$prior" '.prior == $prior' <<< "$record" >/dev/null || {
    windows_reject "BootNext changed after its prior value was recorded"
    return 1
  }
  target_number=$(jq -r '.target.boot_number' <<< "$record") || return 1
  run_windows_efibootmgr -n "$target_number" || command_rc=$?
  windows_bootnext_failpoint "after-bootnext-command" || return 1
  observed=$(read_windows_bootnext_state) || return 1
  [[ $command_rc -eq 0 ]] || {
    windows_reject "efibootmgr failed while setting BootNext"
    return "$command_rc"
  }
  jq -e --arg target "$target_number" \
    '.present == true and .boot_number == $target' <<< "$observed" >/dev/null || {
    windows_reject "BootNext readback does not match the requested Windows target"
    return 1
  }
}

run_windows_bootnext() {
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

windows_legacy_managed_block_label() {
  local config index legacy_index=-1 legacy_count=0 suspicious_count=0 next_index
  local comment label entry
  local -a lines=()
  config=$(windows_limine_config_path) || return 1
  [[ -f "$config" && ! -L "$config" ]] || return 1
  mapfile -t lines < "$config" || return 1
  for ((index=0; index < ${#lines[@]}; index++)); do
    case "${lines[$index]}" in
      "$WINDOWS_LEGACY_ENTRY_MARKER")
        legacy_count=$((legacy_count + 1))
        legacy_index=$index
        ;;
      "$WINDOWS_ENTRY_MARKER"|"$WINDOWS_ENTRY_END_MARKER"|\
      "$WINDOWS_ENTRY_MARKER"*|"$WINDOWS_ENTRY_END_MARKER"*|\
      "$WINDOWS_LEGACY_ENTRY_MARKER"*)
        suspicious_count=$((suspicious_count + 1))
        ;;
    esac
  done
  (( legacy_count == 1 && suspicious_count == 0 \
    && legacy_index + 4 < ${#lines[@]} )) || return 1
  [[ "${lines[legacy_index + 1]}" == /Windows \
    && "${lines[legacy_index + 2]}" == '    comment: '* \
    && "${lines[legacy_index + 3]}" == '    protocol: efi_boot_entry' \
    && "${lines[legacy_index + 4]}" == '    entry: '* ]] || return 1
  comment=${lines[legacy_index + 2]#'    comment: '}
  entry=${lines[legacy_index + 4]#'    entry: '}
  [[ "$comment" == "$entry" ]] || return 1
  label="$comment"
  windows_label_is_safe "$label" || return 1
  next_index=$((legacy_index + 5))
  if (( next_index < ${#lines[@]} )); then
    [[ -z "${lines[$next_index]}" || "${lines[$next_index]}" != [[:space:]]* ]] \
      || return 1
  fi
  printf '%s\n' "$label"
}

windows_unconfigure_preflight() {
  local label=""
  windows_classify_target_state || return 1
  if [[ "$_windows_state_kind" == current ]]; then
    label="$_windows_state_label"
  elif [[ "$_windows_state_kind" == legacy-empty ]]; then
    if ! label=$(windows_legacy_managed_block_label); then
      windows_managed_block_state "" || return 1
      [[ "$_windows_block_state" == absent ]]
      return
    fi
    _windows_state_label="$label"
  elif [[ "$_windows_state_kind" != absent ]]; then
    return 1
  fi
  windows_managed_block_state "$label" || return 1
  if [[ "$_windows_state_kind" == absent ]]; then
    [[ "$_windows_block_state" == absent ]]
  else
    [[ "$_windows_block_state" == absent || "$_windows_block_state" == canonical \
      || "$_windows_block_state" == legacy ]]
  fi
}

remove_windows_managed_block_for_unconfigure() {
  local label=""
  windows_unconfigure_preflight || return 1
  [[ "$_windows_block_state" == absent ]] && return 0
  label="$_windows_state_label"
  windows_rewrite_managed_block remove "$label" || return 1
  windows_managed_block_state "$label" || return 1
  [[ "$_windows_block_state" == absent ]]
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
