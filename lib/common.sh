#!/bin/bash
# OmaSecBoot: shared constants and output helpers

readonly ESP="/boot"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly OMASECBOOT_VERSION="1.0.0"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly LIMINE_CONF="${ESP}/limine.conf"
# shellcheck disable=SC2034 # Used by sourced lib files.
readonly STATE_DIR="/var/lib/omasecboot"
# Must match BOOT_PARTITION_LOCK in limine-entry-tool and limine-snapper-sync,
# which own this mutex.
readonly LIMINE_LOCK_FILE="/run/lock/boot-partition.lock"

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

# --- Locking ----------------------------------------------------------------

_OMASECBOOT_LIMINE_LOCK_OWNED=false
_OMASECBOOT_REPAIR_LOCK_OWNED=false

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

inherited_limine_fd_is_valid() {
  local path parent_uid self_identity parent_identity
  path=$(limine_lock_path)
  validate_control_file "$path" || return 1
  fd_matches_path 200 "$path" || return 1

  parent_uid=$(process_effective_uid "$PPID") || return 1
  [[ "$parent_uid" == "$(control_owner_uid)" ]] || return 1
  [[ -e "/proc/${PPID}/fd/200" ]] || return 1
  self_identity=$(control_file_identity /proc/self/fd/200) || return 1
  parent_identity=$(control_file_identity "/proc/${PPID}/fd/200") || return 1
  [[ "$self_identity" == "$parent_identity" ]]
}

lock_inherited_limine_fd() {
  command -v flock >/dev/null 2>&1 || return 1
  inherited_limine_fd_is_valid || return 1
  flock -w 30 200 || return 1
  inherited_limine_fd_is_valid || return 1
  _OMASECBOOT_LIMINE_LOCK_OWNED=inherited
}

with_repair_lock() {
  [[ "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]] && return 0
  command -v flock >/dev/null 2>&1 || {
    fail "flock not installed. Run: ${BOLD}sudo pacman -S util-linux${NC}"
    return 1
  }
  ensure_state_layout || return 1

  local lock_file
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

release_repair_lock() {
  if [[ "$_OMASECBOOT_REPAIR_LOCK_OWNED" == true ]]; then
    flock -u 201 2>/dev/null || true
    exec 201>&- || true
  fi
  _OMASECBOOT_REPAIR_LOCK_OWNED=false
}

release_limine_lock() {
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

# --- File helpers -----------------------------------------------------------

backup_file() {
  local file="$1" backup
  [[ -f "$file" ]] || return 1
  backup=$(mktemp "/tmp/omasecboot.$(basename "$file").XXXXXX") || return 1
  cp -p "$file" "$backup" || {
    rm -f "$backup"
    return 1
  }
  printf '%s\n' "$backup"
}

restore_file_backup() {
  local backup="$1" file="$2"
  cp -p "$backup" "$file"
}

discard_file_backup() {
  rm -f "$1"
}
