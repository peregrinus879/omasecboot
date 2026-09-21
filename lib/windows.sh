#!/bin/bash
# OmaSecBoot: the Windows entry. The target is derived from the firmware's own
# boot entries on every use and never recorded, so it survives the firmware
# renumbering them; no foreign filesystem is mounted or read. A BootNext that
# points at a loader which has gone missing falls through to the next boot
# entry, so the worst outcome of a wrong guess is an ordinary boot.

readonly WINDOWS_LOADER='\efi\microsoft\boot\bootmgfw.efi'
readonly WINDOWS_ENTRY_COMMENT='comment: Windows Boot Manager through the firmware, managed by OmaSecBoot'

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

# Whether the firmware holds an active entry whose file is the primary loader.
# A machine without one starts through the fallback path (upstream's
# --skip-uefi boards, or a registration that failed), and the fallback stays
# raw (D2): turning Secure Boot on would stop it. Status 1: no such entry;
# status 2: the entries could not be read.
firmware_starts_primary() {
  local LC_ALL=C entries entry rest state file wanted
  entries=$(list_boot_entries) || return 2
  wanted=$(primary_loader_path)
  wanted=${wanted#"$(esp_path)"}
  wanted=${wanted//\//\\}
  while IFS= read -r entry; do
    rest=${entry#*$'\x1f'}
    state=${rest%%$'\x1f'*}
    file=${rest##*$'\x1f'}
    [[ $state != active || ${file,,} != "${wanted,,}" ]] || return 0
  done <<<"$entries"
  return 1
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

# --- The managed entry in limine.conf --------------------------------------------------

# Upstream owns limine.conf; this entry is the one exception. It is written
# only inside a pass that holds the boot lock and seals the loader afterwards,
# or while the loader carries no checksum at all, because a loader sealed over
# another limine.conf does not boot (C1). Upstream's tools keep a foreign
# top-level entry and its body through their rewrites and drop comment lines
# beside it (C8), so nothing but the entry itself says that it is this tool's:
# the header "/Windows" and a body of this tool's three keys, its comment
# among them.

windows_entry() {
  printf '/Windows\n    %s\n    protocol: efi_boot_entry\n    entry: %s\n' "$WINDOWS_ENTRY_COMMENT" "$1"
}

# scan_windows_entries without|entries: limine.conf without the managed
# entries, or those entries alone. An entry is a top-level header and the
# indented lines under it. Status 1: this tool's comment stands somewhere else,
# in an entry that holds more than this tool writes or under another header.
# Such an entry is never deleted, because it may be the user's own.
scan_windows_entries() {
  awk -v mode="$1" -v signature="$WINDOWS_ENTRY_COMMENT" '
    function finish_entry(   i, ours) {
      ours = (count > 0 && entry[1] == "/Windows" && signed && !foreign)
      if (signed && !ours) misplaced = 1
      if (ours && mode == "without" && kept > 0 && out[kept] == "") kept--
      for (i = 1; i <= count; i++) {
        if (ours && mode == "entries") print entry[i]
        if (!ours) out[++kept] = entry[i]
      }
      count = 0; signed = 0; foreign = 0
    }
    /^\/[^\/]/ { finish_entry(); entry[++count] = $0; next }
    count > 0 && /^[ \t]+[^ \t]/ {
      entry[++count] = $0
      line = $0; sub(/^[ \t]+/, "", line)
      if (line == signature) signed = 1
      else if (line !~ /^(protocol|entry): /) foreign = 1
      next
    }
    {
      if (count > 0 && /^\/\//) foreign = 1
      finish_entry()
      line = $0; sub(/^[ \t]+/, "", line)
      if (line == signature) misplaced = 1
      out[++kept] = $0
    }
    END {
      finish_entry()
      if (mode == "without") for (i = 1; i <= kept; i++) print out[i]
      exit misplaced
    }
  ' "$(limine_config_path)"
}

# absent, current (exactly the entry for LABEL, once), stale (another entry of
# this tool, or several), misplaced (see scan_windows_entries) or unknown
# (limine.conf unreadable).
windows_entry_state() {
  local entries status=0
  entries=$(scan_windows_entries entries 2>/dev/null) || status=$?
  if (( status == 1 )); then
    printf 'misplaced\n'
  elif (( status != 0 )); then
    printf 'unknown\n'
  elif [[ -z $entries ]]; then
    printf 'absent\n'
  elif [[ $entries == "$(windows_entry "$1")" ]]; then
    printf 'current\n'
  else
    printf 'stale\n'
  fi
}

readonly WINDOWS_ENTRY_MISPLACED="limine.conf holds this tool's Windows comment in an entry this tool did not write that way; remove that comment line, or the entry, by hand"

# write_windows_entry [LABEL]: limine.conf with exactly the entry for LABEL,
# or with none. Nothing is touched when it already reads that way. Omarchy
# replaces limine.conf outside any lock (C7), so the file must still be what
# was read when the new content goes in.
write_windows_entry() {
  local label=${1:-} config mode content before
  config=$(limine_config_path)
  case $(windows_entry_state "$label") in
    current) [[ -z $label ]] || return 0 ;;
    absent) [[ -n $label ]] || return 0 ;;
    misplaced)
      warn "$WINDOWS_ENTRY_MISPLACED"
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
  # A warning, as every refusal here: the pass goes on without the entry.
  esp_room_is_enough || {
    warn "Less than 2 MiB free on the ESP, so the Windows entry in ${config} stays as it is"
    return 1
  }
  mode=$(stat -Lc '%a' "$config") || return 1
  before=$(config_checksum) || return 1
  content=$(scan_windows_entries without && printf x) || return 1
  content=${content%x}
  if [[ -n $label ]]; then
    [[ -z $content || $content == *$'\n\n' ]] || content+=$'\n'
    content+=$(windows_entry "$label")$'\n'
  fi
  [[ $(config_checksum) == "$before" ]] || {
    warn "limine.conf changed while the Windows entry was being written; the next pass writes it"
    return 1
  }
  printf '%s' "$content" | atomic_write "$config" "$mode"
}

# Inside every pass, before the loader is sealed: the entry is in limine.conf
# exactly when the opt-in flag exists. Whatever keeps it from getting there (no
# clear target in the firmware, entries that cannot be read just now, a
# misplaced comment, a limine.conf that changed meanwhile) is said and left
# to the status report, never made the pass's failure: the loader is sealed
# over what limine.conf holds, and Omarchy boots.
converge_windows_entry() {
  local status=0
  if [[ ! -e $(windows_flag) ]]; then
    [[ $(windows_entry_state '') == absent ]] || qact "Taking the Windows entry out of limine.conf"
    write_windows_entry || :
    return 0
  fi
  resolve_windows_target || status=$?
  case $status in
    0) ;;
    1) qnote "The Windows entry is enabled, but the firmware has no single active Windows Boot Manager entry with a name of its own; see: sudo omasecboot status" ;;
    *) qnote "The Windows entry is enabled, but the firmware's boot entries cannot be read right now" ;;
  esac
  (( status == 0 )) || return 0
  [[ $(windows_entry_state "$(windows_target_label)") == current ]] || qact "Writing the Windows entry to limine.conf"
  write_windows_entry "$(windows_target_label)" || :
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
