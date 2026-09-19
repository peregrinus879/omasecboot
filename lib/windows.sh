#!/bin/bash
# OmaSecBoot: the Windows entry. The target is derived from the firmware's own
# boot entries on every use and never recorded, so it survives the firmware
# renumbering them; no foreign filesystem is mounted or read. A BootNext that
# points at a loader which has gone missing falls through to the next boot
# entry, so the worst outcome of a wrong guess is an ordinary boot.

readonly WINDOWS_LOADER='\efi\microsoft\boot\bootmgfw.efi'
readonly WINDOWS_BLOCK_BEGIN='# omasecboot:windows begin'
readonly WINDOWS_BLOCK_END='# omasecboot:windows end'

# The zero-byte opt-in: Omarchy replaces limine.conf from its template, and
# this is how "sign" knows the entry belongs back (upstream-contracts C7).
windows_flag() { printf '%s/windows-enabled\n' "$(state_dir)"; }

# --- The firmware's boot entries ---------------------------------------------------

utf16_text() { hex_to_bytes "$1" | iconv -f UTF-16LE -t UTF-8; }

# Prints NUMBER, active|inactive, LABEL and FILE, separated by the ASCII unit
# separator, for a Boot#### variable. After the four attribute bytes of the
# efivarfs file comes an EFI_LOAD_OPTION (UEFI 2.10, 3.1.3): uint32 attributes
# (bit 0: active), the uint16 length of the device path list, the description
# as NUL-terminated UTF-16, then device path nodes of type, subtype and uint16
# length. Only the first path is the boot target, so the walk stops at its end
# node; a file path node is type 4, subtype 4, and FILE is empty for an entry
# without one. A control character in a label becomes "#", which no label
# this tool accepts may hold, so rows stay one line and cannot be forged.
read_boot_entry() {
  local number=$1 hex total path_length position label='' file='' node_length state=inactive
  hex=$(od -An -v -tx1 -- "$(firmware_variable_path "Boot${number}")" 2>/dev/null) || return 1
  number=${number^^}
  hex=${hex//[[:space:]]/}
  total=$((${#hex} / 2))
  (( total >= 12 )) || return 1
  read_le32 "$hex" 4 || return 1
  # shellcheck disable=SC2154 # read_le32 of firmware.sh sets _le32.
  (( (_le32 & 1) == 0 )) || state=active
  path_length=$((16#${hex:18:2}${hex:16:2}))
  for ((position = 10; position + 2 <= total; position += 2)); do
    [[ ${hex:$((position * 2)):4} != 0000 ]] || break
    label+=${hex:$((position * 2)):4}
  done
  position=$((position + 2))
  (( position + path_length <= total )) || return 1
  while (( path_length >= 4 )) && [[ ${hex:$((position * 2)):2} != 7f ]]; do
    node_length=$((16#${hex:$((position * 2 + 6)):2}${hex:$((position * 2 + 4)):2}))
    (( node_length >= 4 && node_length <= path_length )) || return 1
    [[ ${hex:$((position * 2)):4} != 0404 ]] || file=${hex:$(((position + 4) * 2)):$(((node_length - 4) * 2))}
    position=$((position + node_length))
    path_length=$((path_length - node_length))
  done
  label=$(utf16_text "$label") || return 1
  file=$(utf16_text "${file%0000}") || return 1
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$number" "$state" "${label//[[:cntrl:]]/#}" "${file//[[:cntrl:]]/#}"
}

# Every boot entry the firmware holds, the ones in BootOrder first and in its
# order. Firmware leaves numbers in BootOrder whose variable is gone, after a
# USB stick was removed for instance; those are skipped. An entry that exists
# and cannot be read fails the listing. The names carry the number in
# upper-case hex (C8); lower case is looked for as well, because a firmware
# that writes it would otherwise hide a Windows entry from the encryption check.
list_boot_entries() {
  local hex position number name path listed=' '
  hex=$(od -An -v -tx1 -- "$(firmware_variable_path BootOrder)" 2>/dev/null) || return 1
  hex=${hex//[[:space:]]/}
  for ((position = 8; position + 4 <= ${#hex}; position += 4)); do
    number=${hex:$((position + 2)):2}${hex:position:2}
    for name in "${number^^}" "$number"; do
      [[ -e $(firmware_variable_path "Boot${name}") && $listed != *" ${name^^} "* ]] || continue
      read_boot_entry "$name" || return 1
      listed+="${name^^} "
    done
  done
  for path in "$(efivars_dir)"/Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-"$EFI_GLOBAL_GUID"; do
    name=${path##*/Boot}
    name=${name%%-*}
    [[ ! -e $path || $listed == *" ${name^^} "* ]] || read_boot_entry "$name" || return 1
  done
}

# Sets _windows_number and _windows_label when the firmware holds exactly one
# active entry whose file is bootmgfw.efi and whose label no other entry
# shares: Limine's efi_boot_entry protocol finds the entry by name (C8). The
# label must fit one line of limine.conf. Status 1: no such entry; status 2:
# the entries could not be read. Case is folded for ASCII only, in every
# locale, so a pass inside a package transaction decides as a terminal does.
_windows_number='' _windows_label=''
resolve_windows_target() {
  local LC_ALL=C entries entry state label file rest target_number='' target_label='' targets=0 same=0
  _windows_number='' _windows_label=''
  entries=$(list_boot_entries) || return 2
  while IFS= read -r entry; do
    rest=${entry#*$'\x1f'}
    state=${rest%%$'\x1f'*} rest=${rest#*$'\x1f'}
    label=${rest%%$'\x1f'*} file=${rest#*$'\x1f'}
    [[ $state == active && ${file,,} == "$WINDOWS_LOADER" ]] || continue
    targets=$((targets + 1))
    target_number=${entry%%$'\x1f'*} target_label=$label
  done <<<"$entries"
  (( targets == 1 )) || return 1
  while IFS= read -r entry; do
    label=${entry#*$'\x1f'*$'\x1f'}
    label=${label%%$'\x1f'*}
    [[ ${label,,} != "${target_label,,}" ]] || same=$((same + 1))
  done <<<"$entries"
  [[ $same == 1 && -n $target_label && $target_label != *'#'* ]] || return 1
  _windows_number=$target_number _windows_label=$target_label
}

windows_target_label() { printf '%s\n' "$_windows_label"; }
windows_target_number() { printf '%s\n' "$_windows_number"; }

# Any entry for Windows Boot Manager, active or not: is Windows installed?
# Status 2: the entries could not be read.
firmware_lists_windows() {
  local LC_ALL=C entries
  entries=$(list_boot_entries) || return 2
  [[ ${entries,,} == *"$WINDOWS_LOADER"* ]]
}

# --- The managed block in limine.conf -------------------------------------------------

# Upstream owns limine.conf; this block is the one exception. It is written
# only inside a pass that holds the boot lock and seals the loader afterwards,
# or while the loader carries no checksum at all, because a loader sealed over
# another limine.conf does not boot (C1). Upstream's tools keep a trailing
# entry and the comment lines around it through their rewrites (C8).

windows_block() {
  printf '%s\n/Windows\n    comment: Reboot into Windows Boot Manager through the firmware\n    protocol: efi_boot_entry\n    entry: %s\n%s\n' \
    "$WINDOWS_BLOCK_BEGIN" "$1" "$WINDOWS_BLOCK_END"
}

# Prints limine.conf without any managed block. Fails on markers that do not
# pair up: deleting from a begin marker to the end of the file could take the
# user's own entries with it.
limine_conf_without_blocks() {
  awk -v begin="$WINDOWS_BLOCK_BEGIN" -v end="$WINDOWS_BLOCK_END" '
    $0 == begin { if (inside) broken = 1; inside = 1; next }
    $0 == end { if (!inside) broken = 1; inside = 0; next }
    !inside { print }
    END { exit (inside || broken) }
  ' "$(limine_config_path)"
}

# absent, current (exactly the block for LABEL, once), stale (another block),
# broken (markers that do not pair up) or unknown (limine.conf unreadable).
windows_block_state() {
  local config markers
  config=$(limine_config_path)
  # grep counts to stdout and says nothing there when it cannot read the file.
  markers=$(grep -cxF -e "$WINDOWS_BLOCK_BEGIN" -e "$WINDOWS_BLOCK_END" -- "$config" 2>/dev/null) || :
  if [[ -z $markers ]]; then
    printf 'unknown\n'
  elif [[ $markers == 0 ]]; then
    printf 'absent\n'
  elif ! limine_conf_without_blocks >/dev/null; then
    printf 'broken\n'
  elif [[ $markers == 2 && $(sed -n "/^${WINDOWS_BLOCK_BEGIN}\$/,/^${WINDOWS_BLOCK_END}\$/p" "$config") == "$(windows_block "$1")" ]]; then
    printf 'current\n'
  else
    printf 'stale\n'
  fi
}

# write_windows_block [LABEL]: limine.conf with exactly the block for LABEL,
# or with none. Nothing is touched when it already reads that way. Omarchy
# replaces limine.conf outside any lock (C7), so the file must still be what
# was read when the new content goes in.
write_windows_block() {
  local label=${1:-} config mode content before
  config=$(limine_config_path)
  case $(windows_block_state "$label") in
    current) [[ -z $label ]] || return 0 ;;
    absent) [[ -n $label ]] || return 0 ;;
    broken)
      warn "limine.conf holds a \"${WINDOWS_BLOCK_BEGIN}\" or \"${WINDOWS_BLOCK_END}\" line without its partner; remove that line by hand"
      return 1
      ;;
    unknown)
      warn "Could not read ${config}"
      return 1
      ;;
  esac
  is_safe_file "$config" || {
    warn "${config} is not a plain file that only root can write"
    return 1
  }
  esp_has_room || return 1
  mode=$(stat -Lc '%a' "$config") || return 1
  before=$(config_checksum) || return 1
  content=$(limine_conf_without_blocks && printf x) || return 1
  content=${content%x}
  if [[ -n $label ]]; then
    [[ -z $content || $content == *$'\n\n' ]] || content+=$'\n'
    content+=$(windows_block "$label")$'\n'
  fi
  [[ $(config_checksum) == "$before" ]] || {
    warn "limine.conf changed while the Windows entry was being written; the next pass writes it"
    return 1
  }
  printf '%s' "$content" | atomic_write "$config" "$mode"
}

# Inside every pass, before the loader is sealed: the entry is in limine.conf
# exactly when the opt-in flag exists. Whatever keeps it from getting there (no
# clear target in the firmware, entries that cannot be read just now, markers
# that do not pair up, a limine.conf that changed meanwhile) is said and left
# to the status report, never made the pass's failure: the loader is sealed
# over what limine.conf holds, and Omarchy boots.
converge_windows_block() {
  local status=0
  if [[ ! -e $(windows_flag) ]]; then
    [[ $(windows_block_state '') == absent ]] || qact "Taking the Windows entry out of limine.conf"
    write_windows_block || :
    return 0
  fi
  resolve_windows_target || status=$?
  case $status in
    0) ;;
    1) qnote "The Windows entry is enabled, but the firmware has no single active Windows Boot Manager entry with a name of its own; see: sudo omasecboot status" ;;
    *) qnote "The Windows entry is enabled, but the firmware's boot entries cannot be read right now" ;;
  esac
  (( status == 0 )) || return 0
  [[ $(windows_block_state "$(windows_target_label)") == current ]] || qact "Writing the Windows entry to limine.conf"
  write_windows_block "$(windows_target_label)" || :
}

# --- The BootNext request ----------------------------------------------------------------

# Asks the firmware to boot the resolved target once, at the next start.
# Judged by reading the variable back; it says nothing about what the
# firmware or Windows do then.
request_windows_boot() {
  local hex
  [[ -n $_windows_number ]] || return 1
  efibootmgr --bootnext "$_windows_number" >/dev/null || return 1
  hex=$(od -An -v -tx1 -- "$(firmware_variable_path BootNext)" 2>/dev/null) || return 1
  hex=${hex//[[:space:]]/}
  [[ ${hex:10:2}${hex:8:2} == "${_windows_number,,}" ]]
}

# --- Encryption ----------------------------------------------------------------------------

# Volumes that carry a BitLocker signature; Device Encryption on Windows Home
# uses the same format. Status 2: the block devices could not be listed.
list_bitlocker_volumes() {
  local devices
  devices=$(lsblk --raw --noheadings --output PATH,FSTYPE 2>/dev/null) || return 2
  awk '$2 == "BitLocker" { print $1 }' <<<"$devices"
}

# windows_encryption_state: prints absent, present or unknown. "absent" is a
# bounded observation (no Windows Boot Manager entry and no BitLocker volume),
# never a clearance of the firmware.
windows_encryption_state() {
  local volumes listed=0
  volumes=$(list_bitlocker_volumes) || {
    printf 'unknown\n'
    return 0
  }
  firmware_lists_windows || listed=$?
  if [[ -n $volumes || $listed == 0 ]]; then
    printf 'present\n'
  elif [[ $listed == 2 ]]; then
    printf 'unknown\n'
  else
    printf 'absent\n'
  fi
}

# print_encryption_guidance VOLUMES
print_encryption_guidance() {
  local volume
  while IFS= read -r volume; do
    [[ -z $volume ]] || note "BitLocker-format volume: ${volume}"
  done <<<"$1"
  warn "Changing Secure Boot keys or its state can make Windows ask for the BitLocker recovery key"
  print_message "
    ${BOLD}Windows Pro, Enterprise or Education${NC}
      1. Back up and verify every recovery key (account.microsoft.com/devices/recoverykey, or your organisation).
      2. In an administrator PowerShell: Suspend-BitLocker -MountPoint \$env:SystemDrive -RebootCount 0
      3. After Secure Boot is on and Windows has started once: Resume-BitLocker -MountPoint \$env:SystemDrive
    ${BOLD}Windows Home${NC}
      1. Back up and verify the recovery key if Device Encryption is on.
      2. Settings > Privacy & security > Device encryption: turn it off and wait until decryption has finished.
      3. Turn it on again after Secure Boot is on and Windows has started once.
    A device managed by an organisation needs its administrator's approval first.
"
}

# Asked before the two steps the user cannot take back, deleting the PK and
# writing keys; setup takes one such step per run. Nothing is asked of a
# machine without Windows.
acknowledge_windows_encryption() {
  case $(windows_encryption_state) in
    absent) return 0 ;;
    unknown) warn "Could not tell whether Windows or a BitLocker volume is on this machine" ;;
  esac
  print_encryption_guidance "$(list_bitlocker_volumes)"
  confirm "the Secure Boot change" "Is Windows encryption suspended or off, or its recovery key at hand?"
}

# Turning Secure Boot on changes what Windows measures once more.
remind_of_windows_encryption() {
  [[ $(windows_encryption_state) == absent ]] ||
    warn "If Windows is encrypted, suspend BitLocker or Device Encryption again before you turn Secure Boot on (omasecboot windows preflight shows how)"
}
