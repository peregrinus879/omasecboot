#!/bin/bash
# OmaSecBoot: shared constants and output helpers

readonly ESP="/boot"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly OMASECBOOT_VERSION="1.0.0"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly SUPPORTED_LIMINE_MKINITCPIO_VERSION=1.38.0-1
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly SUPPORTED_SBCTL_VERSION=0.18-2
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly LIMINE_CONF="${ESP}/limine.conf"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly STATE_DIR="/var/lib/omasecboot"
# Must match BOOT_PARTITION_LOCK in limine-entry-tool and limine-snapper-sync,
# which own this mutex.
readonly LIMINE_LOCK_FILE="/run/lock/boot-partition.lock"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly WINDOWS_EFIBOOTMGR_MINIMUM_VERSION=18
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly WINDOWS_EFIBOOTMGR_EXECUTABLE="/usr/bin/efibootmgr"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly WINDOWS_BOOTNEXT_LOADER_PATH='\EFI\Microsoft\Boot\bootmgfw.efi'

# --- Colors ------------------------------------------------------------------

readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly DIM='\033[2m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# --- Output helpers ----------------------------------------------------------

header() { echo -e "\n${BOLD}OmaSecBoot${NC} ${DIM}-${NC} ${BOLD}$*${NC}\n"; }
pass()   { echo -e "  ${GREEN}✓${NC} $*"; }
fail()   { echo -e "  ${RED}✗${NC} $*"; }
warn()   { echo -e "  ${YELLOW}!${NC} $*"; }
act()    { echo -e "  ${BLUE}→${NC} $*"; }
die()    { fail "$*"; exit 1; }

# Quiet mode: only show errors
QUIET=false
qpass() { [[ "$QUIET" == true ]] || pass "$@"; }
qact()  { [[ "$QUIET" == true ]] || act "$@"; }
qheader() { [[ "$QUIET" == true ]] || header "$@"; }

# --- Shared jq definitions --------------------------------------------------

# Prepended to every jq program that validates lifecycle documents.
# shellcheck disable=SC2034 # Consumed by the sourced lib modules.
# shellcheck disable=SC2016 # jq variables, not shell expansions.
readonly OMASECBOOT_JQ_DEFS='
  def uuid:
    type == "string" and
    test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$");
  def timestamp:
    type == "string" and
    test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
  def digest: type == "string" and test("^[0-9a-f]{64}$");
  def checksum: type == "string" and test("^[0-9a-f]{128}$");
  def identity: type == "string" and test("^[0-9]+:[0-9]+$");
  def boot_number: type == "string" and test("^[0-9A-F]{4}$");
  def absolute_path:
    type == "string" and length > 1 and length <= 4096 and startswith("/") and
    (explode | all(.[]; . >= 32 and . != 127));
  def operation:
    type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9-]*$");
  def phase:
    type == "string" and length <= 128 and test("^[a-z0-9][a-z0-9-]*$");
  def artifact_reference:
    type == "object" and keys == ["path","schema_version","sha256"] and
    (.path | absolute_path) and
    (.schema_version | type == "number" and . >= 1 and floor == .) and
    (.sha256 | digest);
  def incident_reference($max_attempts):
    type == "object" and
    keys == ["id","kind","operation","ordinal","path","sha256","status"] and
    (.id | uuid) and (.operation | operation) and (.path | absolute_path) and
    (.sha256 | digest) and
    (if .kind == "root" then
      .ordinal == 0 and
      (.status == "failed" or .status == "stale" or .status == "publication-uncertain")
    elif .kind == "attempt" then
      (.ordinal | type == "number" and . >= 1 and . <= $max_attempts and floor == .) and
      (.status == "failed" or .status == "stale" or .status == "completed")
    else false end);
  def failure:
    type == "object" and keys == ["exit_code","phase","reason","recorded_at"] and
    (.exit_code | type == "number" and . >= 0 and . <= 255 and floor == .) and
    (.phase == null or (.phase | phase)) and
    (.reason | type == "string" and length > 0 and length <= 1024) and
    (.recorded_at | timestamp);
  def phase_sequence_valid($phases):
    (.completed_phases | length) as $done |
    .completed_phases == $phases[0:$done] and $done <= ($phases | length) and
    (if .current_phase == null then true
     else $done < ($phases | length) and .current_phase == $phases[$done] end) and
    (if .status == "completed" then
       .completed_phases == $phases and .current_phase == null
     else true end);
  def firmware_write_resolved($old; $new):
    $new.hierarchy == $old.hierarchy and $new.started_at == $old.started_at and
    $new.command_exit_code == $old.command_exit_code and
    ($new.readback_status == "unchanged" or $new.readback_status == "verified" or
      $new.readback_status == "failed") and $new.completed_at != null;
'

# --- Locking ----------------------------------------------------------------

_OMASECBOOT_LIMINE_LOCK_OWNED=false
_OMASECBOOT_REPAIR_LOCK_OWNED=false
_OMASECBOOT_REPAIR_LOCK_MODE=false

state_dir_path() {
  printf '%s\n' "$STATE_DIR"
}

esp_path() {
  printf '%s\n' "$ESP"
}

limine_config_path() {
  printf '%s/limine.conf\n' "$(esp_path)"
}

limine_lock_path() {
  printf '%s\n' "$LIMINE_LOCK_FILE"
}

control_owner_uid() {
  printf '0\n'
}

require_control_root() {
  [[ $EUID -eq 0 ]] || {
    fail "Root is required to modify OmaSecBoot lifecycle state"
    return 1
  }
}

mode_is_control_safe() {
  local mode="$1"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0022) == 0 ))
}

# Readable and writable by the owner only.
mode_is_private() {
  local mode="$1"
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 0077) == 0 ))
}

# The ESP is mounted at its path as a FAT filesystem.
esp_is_mounted_vfat() {
  local esp
  esp=$(esp_path)
  mountpoint -q "$esp" || return 1
  [[ $(findmnt -n -T "$esp" -o FSTYPE 2>/dev/null) == vfat ]]
}

efivars_path() {
  printf '/sys/firmware/efi/efivars\n'
}

windows_bootnext_variable_path() {
  printf '%s/BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c\n' \
    "$(efivars_path)"
}

# The EFI variable filesystem is the exact efivarfs mount at its canonical path.
efivarfs_mount_is_valid() {
  local root target fstype extra
  root=$(efivars_path) || return 1
  path_has_no_symlink_components "$root" || return 1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  read -r target fstype extra < <(findmnt -rn -T "$root" -o TARGET,FSTYPE 2>/dev/null) \
    || return 1
  [[ -z "$extra" && "$target" == "$root" && "$fstype" == efivarfs ]]
}

path_has_no_symlink_components() {
  local path="$1" resolved
  [[ "$path" =~ ^/[^[:cntrl:]]+$ ]] || return 1
  resolved=$(readlink -m -- "$path" 2>/dev/null) || return 1
  [[ "$resolved" == "$path" ]]
}

validate_control_directory() {
  local path="$1" uid mode
  path_has_no_symlink_components "$path" || return 1
  [[ -d "$path" && ! -L "$path" ]] || return 1
  read -r uid mode < <(stat -Lc '%u %a' "$path" 2>/dev/null) || return 1
  [[ "$uid" == "$(control_owner_uid)" ]] || return 1
  mode_is_control_safe "$mode"
}

validate_control_file() {
  local path="$1" uid mode links
  path_has_no_symlink_components "$path" || return 1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  read -r uid mode links < <(stat -Lc '%u %a %h' "$path" 2>/dev/null) || return 1
  [[ "$uid" == "$(control_owner_uid)" && "$links" == 1 ]] || return 1
  mode_is_control_safe "$mode"
}

# pacman's vercmp prints -1, 0, or 1. A missing tool or unusable input must
# fail the comparison instead of reading as 0.
version_at_least() {
  local result
  result=$(vercmp "$1" "$2" 2>/dev/null) || return 1
  [[ "$result" == 0 || "$result" == 1 ]]
}

# True only when the jq expression is true for the document. A jq failure or a
# null result is false, so callers fail closed.
json_is() {
  jq -e "$1" <<< "$2" >/dev/null 2>&1
}

# Version of an installed package from one exact `pacman -Q` line.
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

producer_file_owner_package() {
  local path="$1"
  validate_control_file /usr/bin/pacman || return 1
  /usr/bin/pacman -Qqo "$path" 2>/dev/null
}

control_file_identity() {
  stat -Lc '%d:%i' "$1" 2>/dev/null
}

prepare_control_lock_file() {
  local path="$1" mode="$2" parent
  parent=$(dirname "$path")
  validate_control_directory "$parent" || return 1

  if [[ -e "$path" || -L "$path" ]]; then
    validate_control_file "$path" || return 1
  else
    (umask 077; : > "$path") || return 1
    chmod "$mode" "$path" || return 1
  fi

  validate_control_file "$path"
}

process_effective_uid() {
  local pid="$1" effective
  effective=$(awk '/^Uid:/ { print $3; exit }' "/proc/${pid}/status" 2>/dev/null) \
    || return 1
  [[ "$effective" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$effective"
}

fd_matches_path() {
  local fd="$1" path="$2" fd_identity path_identity
  [[ -e "/proc/self/fd/${fd}" ]] || return 1
  fd_identity=$(control_file_identity "/proc/self/fd/${fd}") || return 1
  path_identity=$(control_file_identity "$path") || return 1
  [[ "$fd_identity" == "$path_identity" ]]
}

# An inherited lock descriptor is valid when it names the current lock file
# and the parent, running as the control owner, holds the same open file.
inherited_fd_is_valid() {
  local fd="$1" path="$2" parent_uid self_identity parent_identity
  validate_control_file "$path" || return 1
  fd_matches_path "$fd" "$path" || return 1
  parent_uid=$(process_effective_uid "$PPID") || return 1
  [[ "$parent_uid" == "$(control_owner_uid)" && -e "/proc/${PPID}/fd/${fd}" ]] \
    || return 1
  self_identity=$(control_file_identity "/proc/self/fd/${fd}") || return 1
  parent_identity=$(control_file_identity "/proc/${PPID}/fd/${fd}") || return 1
  [[ "$self_identity" == "$parent_identity" ]]
}

inherited_limine_fd_is_valid() {
  inherited_fd_is_valid 200 "$(limine_lock_path)"
}

lock_inherited_limine_fd() {
  command -v flock >/dev/null 2>&1 || return 1
  inherited_limine_fd_is_valid || return 1
  flock -w 30 200 || return 1
  inherited_limine_fd_is_valid || return 1
  _OMASECBOOT_LIMINE_LOCK_OWNED=inherited
}

inherited_repair_fd_is_valid() {
  inherited_fd_is_valid 201 "$(state_dir_path)/repair.lock"
}

with_repair_lock() {
  [[ "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] && return 0
  command -v flock >/dev/null 2>&1 || {
    fail "flock not installed. Run: ${BOLD}sudo pacman -S util-linux${NC}"
    return 1
  }
  ensure_state_layout || return 1

  if inherited_repair_fd_is_valid \
    && flock -n 201 \
    && inherited_repair_fd_is_valid; then
    _OMASECBOOT_REPAIR_LOCK_OWNED=true
    _OMASECBOOT_REPAIR_LOCK_MODE=inherited
    return 0
  fi

  local lock_file
  exec 201>&- || true
  lock_file="$(state_dir_path)/repair.lock"
  prepare_control_lock_file "$lock_file" 644 || {
    fail "Unsafe repair lock path: ${lock_file}"
    return 1
  }
  exec 201>> "$lock_file" || return 1
  fd_matches_path 201 "$lock_file" || {
    exec 201>&-
    return 1
  }
  flock -w 30 201 || {
    exec 201>&-
    fail "Could not acquire repair lock"
    return 1
  }
  fd_matches_path 201 "$lock_file" || {
    exec 201>&-
    return 1
  }
  _OMASECBOOT_REPAIR_LOCK_OWNED=true
  _OMASECBOOT_REPAIR_LOCK_MODE=local
}

with_limine_lock() {
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false ]] && return 0
  command -v flock >/dev/null 2>&1 || {
    fail "flock not installed. Run: ${BOLD}sudo pacman -S util-linux${NC}"
    return 1
  }

  if lock_inherited_limine_fd; then
    return 0
  fi

  exec 200>&- || true
  local lock_file
  lock_file=$(limine_lock_path)
  prepare_control_lock_file "$lock_file" 644 || {
    fail "Unsafe Limine lock path: ${lock_file}"
    return 1
  }
  exec 200>> "$lock_file" || return 1
  fd_matches_path 200 "$lock_file" || {
    exec 200>&-
    return 1
  }
  flock -w 30 200 || {
    exec 200>&-
    fail "Could not acquire Limine global lock"
    return 1
  }
  fd_matches_path 200 "$lock_file" || {
    exec 200>&-
    return 1
  }
  _OMASECBOOT_LIMINE_LOCK_OWNED=local
}

# Assigns one input line per named variable; the line count must match, so
# a missing or multi-line value fails instead of shifting later fields.
read_lines() {
  local index=0 name
  local -a lines=()
  mapfile -t lines
  (( ${#lines[@]} == $# )) || return 1
  for name in "$@"; do
    printf -v "$name" '%s' "${lines[$index]}"
    index=$((index + 1))
  done
}

boot_locks_are_held() {
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]]
}

with_boot_repair_lock() {
  with_limine_lock || return 1
  with_repair_lock || {
    release_limine_lock
    return 1
  }
}

with_delegated_limine_lock() {
  local child_rc=0 lock_rc=0
  [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == local \
    && "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] || return 1

  release_limine_lock
  "$@" || child_rc=$?
  with_limine_lock || lock_rc=$?
  [[ $lock_rc -eq 0 ]] || return "$lock_rc"
  return "$child_rc"
}

with_limine_lock_handoff() {
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

release_repair_lock() {
  if [[ "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]]; then
    if [[ "$_OMASECBOOT_REPAIR_LOCK_MODE" == local ]]; then
      flock -u 201 2>/dev/null || true
    fi
    exec 201>&- || true
  fi
  _OMASECBOOT_REPAIR_LOCK_OWNED=false
  _OMASECBOOT_REPAIR_LOCK_MODE=false
}

release_limine_lock() {
  if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" == local ]]; then
    flock -u 200 2>/dev/null || true
  fi
  if [[ "$_OMASECBOOT_LIMINE_LOCK_OWNED" != false ]]; then
    exec 200>&- || true
  fi
  _OMASECBOOT_LIMINE_LOCK_OWNED=false
}

release_boot_repair_lock() {
  release_repair_lock
  release_limine_lock
}

durable_sync() {
  sync -f "$1"
}

# --- Pacman hook directories --------------------------------------------------

# pacman always reads /usr/share/libalpm/hooks/ and then every configured
# HookDir; a same-named hook in a later directory replaces the earlier one.
pacman_system_hook_dir() {
  printf '/usr/share/libalpm/hooks\n'
}

pacman_configured_hook_dirs() {
  validate_control_file /usr/bin/pacman-conf || return 1
  /usr/bin/pacman-conf HookDir
}

# Succeeds when a same-named file in a configured hook directory would shadow
# the packaged hook at the given system path, or when the directories cannot
# be determined. Callers treat success as "not proven unshadowed".
pacman_hook_is_shadowed() {
  local path="$1" name dirs dir
  name=${path##*/}
  dirs=$(pacman_configured_hook_dirs) || return 0
  while IFS= read -r dir; do
    dir=${dir%/}
    [[ -n "$dir" && "$dir" != "$(pacman_system_hook_dir)" ]] || continue
    [[ ! -e "${dir}/${name}" && ! -L "${dir}/${name}" ]] || return 0
  done <<< "$dirs"
  return 1
}

limine_version() {
  command -v limine >/dev/null 2>&1 || return 1

  local output
  output=$(limine --version 2>/dev/null) || return 1
  [[ "$output" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  printf '%s.%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

limine_major_version() {
  local version
  version=$(limine_version) || return 1
  printf '%s\n' "${version%%.*}"
}
