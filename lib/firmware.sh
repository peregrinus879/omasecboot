#!/bin/bash
# OmaSecBoot: the firmware's Secure Boot variables, read from efivarfs directly
# (sbctl's status output hides read errors, C4); the backup taken before any
# firmware instruction; and the enrollment of the local keys by appending,
# which removes nothing the machine trusted (D9).

readonly EFI_GLOBAL_GUID="8be4df61-93ca-11d2-aa0d-00e098032b8c"
readonly EFI_SECURITY_DATABASE_GUID="d719b2cb-3d3a-4596-a3bc-dad00e67656f"
# EFI_CERT_X509_GUID as its sixteen bytes are stored.
readonly EFI_CERT_X509_TYPE="a159c0a5e494a74a87b5ab155c2bf072"
# In the order sbctl writes them: the PK last, because it ends Setup Mode (C4).
readonly -a KEY_VARIABLES=(db KEK PK)

firmware_variable_path() {
  case $1 in
    db | dbx) printf '%s/%s-%s\n' "$(efivars_dir)" "$1" "$EFI_SECURITY_DATABASE_GUID" ;;
    *) printf '%s/%s-%s\n' "$(efivars_dir)" "$1" "$EFI_GLOBAL_GUID" ;;
  esac
}

# A mode variable is four attribute bytes and one value byte. Prints 0 or 1;
# an absent variable, any other content or a read error fails instead of
# guessing, so no caller can mistake "unknown" for "off".
read_mode_variable() {
  local dump
  local -a bytes=()
  dump=$(od -An -v -tu1 -- "$(firmware_variable_path "$1")" 2>/dev/null) || return 1
  read -r -a bytes <<<"$dump"
  [[ ${#bytes[@]} == 5 && ${bytes[4]} =~ ^[01]$ ]] || return 1
  printf '%s\n' "${bytes[4]}"
}

# --- Signature lists ---------------------------------------------------------------

# The bytes a string of hex digits stands for, NULs included.
# shellcheck disable=SC2001 # Every pair of digits gets a prefix; no expansion does that.
hex_to_bytes() { printf '%b' "$(sed 's/../\\x&/g' <<<"$1")"; }

# Little-endian uint32 at a byte offset of a hex dump; sets _le32.
_le32=0
read_le32() {
  local word=${1:$(($2 * 2)):8}
  [[ ${#word} == 8 ]] || return 1
  _le32=$((16#${word:6:2}${word:4:2}${word:2:2}${word:0:2}))
}

# Prints one "type owner sha256-of-data" row per signature entry of FILE,
# sorted, reading signature lists from byte OFFSET to the end: 4 for a copy of
# an efivarfs file, which starts with its attributes, 0 for an sbctl export.
# The file is read once, so a variable is seen in one state.
#
# EFI_SIGNATURE_LIST (UEFI 2.10, 32.4.1): a 16-byte type, three little-endian
# uint32 (list size, header size, entry size), the header, then entries of
# entry size: a 16-byte owner followed by the data. The type is carried, never
# interpreted, so a list this tool has no name for is kept like any other.
list_signature_entries() {
  local file=$1 offset=${2:-0}
  local hex total list_size header_size entry_size entry data digest rows=''
  hex=$(od -An -v -tx1 -- "$file") || return 1
  hex=${hex//[[:space:]]/}
  total=$((${#hex} / 2))
  (( offset <= total )) || return 1
  while (( offset < total )); do
    (( total - offset >= 28 )) || return 1
    read_le32 "$hex" $((offset + 16)) || return 1
    list_size=$_le32
    read_le32 "$hex" $((offset + 20)) || return 1
    header_size=$_le32
    read_le32 "$hex" $((offset + 24)) || return 1
    entry_size=$_le32
    (( list_size >= 28 + header_size && list_size <= total - offset && entry_size > 16 )) || return 1
    (( (list_size - 28 - header_size) % entry_size == 0 )) || return 1
    for ((entry = offset + 28 + header_size; entry < offset + list_size; entry += entry_size)); do
      data=${hex:$(((entry + 16) * 2)):$(((entry_size - 16) * 2))}
      digest=$(hex_to_bytes "$data" | sha256sum) || return 1
      rows+="${hex:$((offset * 2)):32} ${hex:$((entry * 2)):32} ${digest%% *}"$'\n'
    done
    offset=$((offset + list_size))
  done
  [[ -z $rows ]] || LC_ALL=C sort <<<"${rows%$'\n'}"
}

# Entries of a key variable as the firmware holds it now; none when absent.
variable_entries() {
  local path
  path=$(firmware_variable_path "$1")
  [[ ! -e $path ]] || list_signature_entries "$path" 4
}

# Microsoft's 2023 certificates (C9), as "VARIABLE SHA256-OF-THE-DER NAME": the
# KEK certificate that signs Microsoft's db and dbx updates from 2026 on, and
# the three db certificates that replace the 2011 ones.
microsoft_2023_certificates() {
  printf '%s\n' \
    'KEK 3cd3f0309edae228767a976dd40d9f4affc4fbd5218f2e8cc3c9dd97e8ac6f9d Microsoft Corporation KEK 2K CA 2023' \
    'db 076f1fea90ac29155ebf77c17682f75f1fdd1be196da302dc8461e350a9ae330 Windows UEFI CA 2023' \
    'db f6124e34125bee3fe6d79a574eaa7b91c0e7bd9d929c1a321178efd611dad901 Microsoft UEFI CA 2023' \
    'db e5be3e64c6e66a281457ecdece0d6d0787577aad2a3a0144262c10c14ba8d8f1 Microsoft Option ROM UEFI CA 2023'
}

# missing_microsoft_2023 VARIABLE: the names of the 2023 certificates that the
# firmware's VARIABLE lacks, one per line. Status 1 when it cannot be read.
missing_microsoft_2023() {
  local entries variable digest name
  entries=$(variable_entries "$1") || return 1
  while read -r variable digest name; do
    [[ $variable != "$1" ]] || grep -q " ${digest}\$" <<<"$entries" || printf '%s\n' "$name"
  done < <(microsoft_2023_certificates)
}

# Once the Platform Key is the user's, only the user can sign a KEK update. The
# last moment the manufacturer's updates can still bring Microsoft's 2023 KEK
# certificate is therefore before the PK is deleted (C9).
acknowledge_missing_microsoft_kek() {
  local missing
  missing=$(missing_microsoft_2023 KEK) || {
    fail "Could not read the firmware's KEK"
    return 1
  }
  [[ -n $missing ]] || return 0
  warn "KEK does not hold ${missing}. Microsoft signs its db and dbx updates with it from 2026 on, and once the Platform Key is yours the manufacturer can no longer add it. Install the pending Windows and firmware updates first, then run ${BOLD}sudo omasecboot setup${NC} again"
  confirm "the firmware step" "Go on without Microsoft's 2023 KEK certificate?"
}

# Rows of the first list that are missing from the second, as multisets.
entries_missing_from() { LC_ALL=C comm -23 <(printf '%s' "$1") <(printf '%s' "$2"); }

# --- The backup ---------------------------------------------------------------------

firmware_backup_root() { printf '%s/firmware-backup\n' "$(state_dir)"; }

# A backup is complete when its SHA256SUMS, written last, verifies.
backup_is_complete() {
  [[ -f $1/SHA256SUMS ]] && (cd -- "$1" && sha256sum --check --quiet --strict SHA256SUMS) >/dev/null 2>&1
}

# The newest complete backup; the directory names are UTC times and sort as text.
latest_firmware_backup() {
  local directory newest=''
  for directory in "$(firmware_backup_root)"/*/; do
    ! backup_is_complete "${directory%/}" || newest=${directory%/}
  done
  [[ -n $newest ]] && printf '%s\n' "$newest"
}

# The backup the enrollment is proved against: the newest one taken while a PK
# was in place, because only that one can show what the key menu removed.
reference_backup() {
  local directory newest=''
  for directory in "$(firmware_backup_root)"/*/; do
    ! { backup_is_complete "${directory%/}" && [[ -e ${directory}PK ]]; } || newest=${directory%/}
  done
  [[ -n $newest ]] && printf '%s\n' "$newest"
}

# Entries a backup recorded for a key variable; none when it was absent.
backup_entries() {
  [[ ! -e $1/$2 ]] || list_signature_entries "$1/$2" 4
}

backup_matches_firmware() {
  local directory=$1 name path
  for name in "${KEY_VARIABLES[@]}" dbx; do
    path=$(firmware_variable_path "$name")
    if [[ -e ${directory}/${name} ]]; then
      cmp -s -- "$path" "${directory}/${name}" || return 1
    else
      [[ ! -e $path ]] || return 1
    fi
  done
}

# Records PK, KEK, db and dbx byte for byte, attributes included, with the two
# mode variables, and prints the directory. The newest backup is reused while
# the firmware still equals it. This is the set the machine trusted before
# this tool asked for any change; it is never called the factory set.
take_firmware_backup() {
  local directory name path
  if directory=$(latest_firmware_backup) && backup_matches_firmware "$directory"; then
    printf '%s\n' "$directory"
    return 0
  fi
  ensure_state_dir || return 1
  mkdir -p -- "$(firmware_backup_root)" || return 1
  directory=$(firmware_backup_root)/$(date -u +%Y%m%dT%H%M%SZ)
  # A plain mkdir: a name that exists belongs to another backup.
  mkdir -- "$directory" || return 1
  for name in "${KEY_VARIABLES[@]}" dbx; do
    path=$(firmware_variable_path "$name")
    [[ -e $path ]] || continue
    # A second read proves the copy: efivarfs has no snapshot to copy from.
    { cat -- "$path" >"${directory}/${name}" && cmp -s -- "$path" "${directory}/${name}"; } || return 1
  done
  printf 'SetupMode=%s\nSecureBoot=%s\n' "$(read_mode_variable SetupMode)" "$(read_mode_variable SecureBoot)" \
    >"${directory}/modes" || return 1
  (cd -- "$directory" && sha256sum -- * >.SHA256SUMS && mv .SHA256SUMS SHA256SUMS) || return 1
  durable_sync "$directory" || return 1
  printf '%s\n' "$directory"
}

# --- The enrollment plan --------------------------------------------------------------

# sbctl writes every entry of its own under its owner GUID, which its status
# reports (C4). Printed as the sixteen bytes are stored: the first three
# fields little-endian.
local_owner() {
  local guid
  guid=$(sbctl status --json 2>/dev/null | jq -er '.guid | ascii_downcase') || return 1
  [[ $guid =~ ^([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})-([0-9a-f]{2})([0-9a-f]{2})-([0-9a-f]{2})([0-9a-f]{2})-([0-9a-f]{4})-([0-9a-f]{12})$ ]] || return 1
  printf '%s%s%s%s%s%s%s%s%s%s\n' "${BASH_REMATCH[4]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[6]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[8]}" "${BASH_REMATCH[7]}" "${BASH_REMATCH[9]}" "${BASH_REMATCH[10]}"
}

# What sbctl would write, asked of sbctl itself: its ESL export is a faithful
# dry run that works with a PK in place (C4). Sets, per key variable:
#   _current[NAME]  the entries the firmware holds
#   _local[NAME]    the local certificate's row
#   _planned[NAME]  the entries an append would write
# The local certificate is the X.509 entry sbctl owns in an export that does
# not read the firmware, so it is the same before, during and after an
# enrollment, and when rotated keys left an older one of sbctl's behind.
# --microsoft keeps sbctl from refusing a plain export over option ROMs. The
# certificate is never read from sbctl's key directory, whose layout is
# sbctl's business. (-g: the suites source this file from inside a function.)
declare -gA _current=() _planned=() _local=()
read_enrollment_plan() {
  local name owner
  owner=$(local_owner) || return 1
  export_planned_entries --microsoft || return 1
  for name in "${KEY_VARIABLES[@]}"; do
    _local[$name]=$(grep -x "${EFI_CERT_X509_TYPE} ${owner} [0-9a-f]*" <<<"${_planned[$name]}") || _local[$name]=''
    _current[$name]=$(variable_entries "$name") || return 1
  done
  export_planned_entries --append
}

# For firmware whose key menu cleared KEK and db together with the PK: the
# local keys with Microsoft's certificates and the firmware's built-in
# defaults, which is all sbctl can put back. Firmware that does not expose
# both KEKDefault and dbDefault gets Microsoft's alone. Replaces _planned and
# sets _rebuild_flags.
_rebuild_flags=()
read_rebuild_plan() {
  _rebuild_flags=(--microsoft)
  ! firmware_has_builtin_defaults || _rebuild_flags+=(--firmware-builtin)
  export_planned_entries "${_rebuild_flags[@]}"
}

firmware_has_builtin_defaults() {
  [[ -e $(firmware_variable_path KEKDefault) && -e $(firmware_variable_path dbDefault) ]]
}

describe_rebuild_sources() {
  if firmware_has_builtin_defaults; then
    printf "your certificates, Microsoft's and the firmware's built-in defaults\n"
  else
    printf "your certificates and Microsoft's; this firmware does not expose its built-in defaults\n"
  fi
}

# export_planned_entries SBCTL-FLAGS...: fills _planned from a dry run in a
# private directory, because sbctl writes its export into the current one.
# The lists hold public certificates only.
export_planned_entries() {
  local work name output status=0
  work=$(mktemp -d) || return 1
  if output=$(cd -- "$work" && run_sbctl enroll-keys "$@" --export esl 2>&1); then
    for name in "${KEY_VARIABLES[@]}"; do
      _planned[$name]=$(list_signature_entries "${work}/${name}.esl") || status=1
    done
  else
    warn "sbctl enroll-keys $* --export esl failed: ${output}"
    status=1
  fi
  rm -rf -- "$work"
  return "$status"
}

# Exactly one certificate of sbctl's own per key variable. Everything below
# rests on this, so it is checked before the user is asked to delete anything.
local_certificates_are_identified() {
  local name
  for name in "${KEY_VARIABLES[@]}"; do
    [[ -n ${_local[$name]} && ${_local[$name]} != *$'\n'* ]] || return 1
  done
}

variable_holds_local_certificate() {
  [[ -n ${_local[$1]} && -z $(entries_missing_from "${_local[$1]}" "${_current[$1]}") ]]
}

# Judged by the variables, never by SetupMode, which keeps reading 1 in the
# boot that wrote the PK (C10).
firmware_is_enrolled() {
  local name
  for name in "${KEY_VARIABLES[@]}"; do
    variable_holds_local_certificate "$name" || return 1
  done
}

platform_key_is_present() { [[ -n ${_current[PK]} ]]; }

# What a key variable holds besides the local certificate, however often
# that one appears.
foreign_entries() { grep -vxF -- "${_local[$1]}" <<<"${_current[$1]}" || :; }

count_foreign_entries() {
  local rows
  rows=$(foreign_entries KEK; foreign_entries db)
  if [[ -z $rows ]]; then printf '0\n'; else wc -l <<<"$rows"; fi
}

# list_lost_entries BACKUP current|planned: prints "NAME entry" for every KEK
# and db entry of the backup that the firmware no longer holds, or that the
# plan would not write. Append skips sbctl's option-ROM check (C4), so this is
# the tool's own proof that nothing but the PK goes missing.
list_lost_entries() {
  local backup=$1 against=$2 name entries against_entries entry
  for name in KEK db; do
    entries=$(backup_entries "$backup" "$name") || return 1
    if [[ $against == planned ]]; then
      against_entries=${_planned[$name]}
    else
      against_entries=${_current[$name]}
    fi
    while IFS= read -r entry; do
      [[ -z $entry ]] || printf '%s %s\n' "$name" "$entry"
    done < <(entries_missing_from "$entries" "$against_entries")
  done
}

# dbx must equal the backup byte for byte: this tool never writes it.
dbx_equals_backup() {
  local backup=$1 path
  path=$(firmware_variable_path dbx)
  if [[ -e ${backup}/dbx ]]; then
    cmp -s -- "$path" "${backup}/dbx"
  else
    [[ ! -e $path ]]
  fi
}

# An append plan is sound when it is the current entries plus the local
# certificate for every key variable, and the PK the local certificate alone:
# firmware rejects a PK with two entries (C4). sbctl's append adds the
# certificate again to a variable that already holds it (C4); such a variable
# is skipped by the enrollment, so a second copy in its plan is accepted here.
append_plan_is_sound() {
  local name added
  [[ ${_planned[PK]} == "${_local[PK]}" ]] || return 1
  for name in KEK db; do
    [[ -z $(entries_missing_from "${_current[$name]}" "${_planned[$name]}") ]] || return 1
    added=$(entries_missing_from "${_planned[$name]}" "${_current[$name]}")
    [[ $added == "${_local[$name]}" ]] || { [[ -z $added ]] && variable_holds_local_certificate "$name"; } || return 1
  done
}

# A rebuild plan is sound when KEK and db get the local certificate and the PK
# nothing else.
rebuild_plan_is_sound() {
  local name
  [[ ${_planned[PK]} == "${_local[PK]}" ]] || return 1
  for name in KEK db; do
    [[ -z $(entries_missing_from "${_local[$name]}" "${_planned[$name]}") ]] || return 1
    # The local keys alone would be what empty never means (D9): an sbctl that
    # stopped honouring --microsoft still exports without complaint.
    [[ -n $(entries_missing_from "${_planned[$name]}" "${_local[$name]}") ]] || return 1
  done
}

# How Setup Mode firmware gets the local keys. Appending to an empty KEK or db
# would enroll the local keys alone, without the certificates option ROMs and
# Windows need, so empty never means append.

# KEK and db both hold other parties' entries, none of the backup's is missing
# and dbx is the backup's: adding the local certificates removes nothing.
append_is_safe() {
  local backup=$1 lost
  lost=$(list_lost_entries "$backup" current) || return 1
  [[ -z $lost && -n $(foreign_entries KEK) && -n $(foreign_entries db) ]] && dbx_equals_backup "$backup"
}

# The key menu cleared KEK and db: each is empty, or already what the rebuild
# writes because an earlier run was interrupted. Expects the rebuild plan.
rebuild_applies() {
  local name
  for name in KEK db; do
    [[ -z ${_current[$name]} || ${_current[$name]} == "${_planned[$name]}" ]] || return 1
  done
}

# A row as a person can compare it: a certificate's SHA-256 fingerprint is what
# firmware menus and openssl show.
describe_entry() {
  local type=$1 digest=$3
  if [[ $type == "$EFI_CERT_X509_TYPE" ]]; then
    printf 'certificate with SHA-256 fingerprint %s\n' "$digest"
  else
    printf 'entry of type %s with SHA-256 %s\n' "$type" "$digest"
  fi
}

# --- The enrollment --------------------------------------------------------------------

# enroll_local_keys append|rebuild: one variable per sbctl call, skipping what
# already holds the local certificate, so a run that was interrupted between
# db, KEK and PK is finished by the next one without adding a certificate
# twice. Each write is judged by reading the variable back against the plan.
# --ignore-immutable only skips sbctl's pre-check; its write path clears the
# flag itself (C4).
enroll_local_keys() {
  local name
  local -a flags=(--append)
  if [[ $1 == rebuild ]]; then
    # Without flags sbctl would write the local keys alone.
    (( ${#_rebuild_flags[@]} > 0 )) || return 1
    flags=("${_rebuild_flags[@]}")
  fi
  for name in "${KEY_VARIABLES[@]}"; do
    if variable_holds_local_certificate "$name"; then
      qnote "${name} already holds your certificate"
      continue
    fi
    act "Writing ${name}"
    run_visible run_sbctl enroll-keys "${flags[@]}" --partial "$name" --ignore-immutable || {
      fail "sbctl could not write ${name}"
      return 1
    }
    [[ $(variable_entries "$name") == "${_planned[$name]}" ]] || {
      fail "${name} does not read back as planned"
      return 1
    }
    _current[$name]=${_planned[$name]}
  done
}
