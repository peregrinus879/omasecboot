#!/bin/bash
# OmaSecBoot: constants, output, file safety, Limine settings lookup, the boot lock.

# shellcheck disable=SC2034 # Read by the dispatcher and other modules.
readonly OMASECBOOT_VERSION="0.1.0"

# Locations are functions so the test suites can point them at fixtures.
state_dir() { printf '/var/lib/omasecboot\n'; }
efivars_dir() { printf '/sys/firmware/efi/efivars\n'; }
limine_default_config() { printf '/etc/default/limine\n'; }
restore_marker_path() { printf '/run/lock/limine-snapper-restore.lock\n'; }
# Shared with limine-entry-tool and limine-snapper-sync, which own this mutex.
boot_lock_path() { printf '/run/lock/boot-partition.lock\n'; }
# Seconds a command waits for the lock; a kernel install holds it for a minute.
boot_lock_wait() { printf '90\n'; }
# Seconds the Limine hook waits for it: that time is spent inside a package
# transaction.
hook_lock_wait() { printf '5\n'; }
pacman_lock_path() { printf '/var/lib/pacman/db.lck\n'; }
# Post-transaction hooks that build kernel images take a minute or two.
pacman_wait() { printf '300\n'; }
# Files under the state directory and the config layers belong to this user.
owner_uid() { printf '0\n'; }

# --- Output -------------------------------------------------------------------

output_supports_color() {
  [[ -t 1 && -n ${TERM:-} && ${TERM:-} != dumb && -z ${NO_COLOR:-} ]]
}

if output_supports_color && [[ -t 2 ]]; then
  readonly GREEN=$'\033[0;32m' RED=$'\033[0;31m' YELLOW=$'\033[1;33m'
  readonly BLUE=$'\033[0;34m' DIM=$'\033[2m' BOLD=$'\033[1m' NC=$'\033[0m'
else
  readonly GREEN='' RED='' YELLOW='' BLUE='' DIM='' BOLD='' NC=''
fi

# Messages are printed literally: paths and upstream text are never interpreted.
print_message() {
  local text=$* decoration
  if ! output_supports_color; then
    for decoration in "$GREEN" "$RED" "$YELLOW" "$BLUE" "$DIM" "$BOLD" "$NC"; do
      [[ -z $decoration ]] || text=${text//"$decoration"/}
    done
  fi
  printf '%s\n' "$text"
}

header() { print_message $'\n'"${BOLD}OmaSecBoot${NC} ${DIM}-${NC} ${BOLD}$*${NC}"$'\n'; }
pass() { print_message "  ${GREEN}✓${NC} $*"; }
note() { print_message "  ${DIM}·${NC} $*"; }
act() { print_message "  ${BLUE}→${NC} $*"; }
warn() { print_message "  ${YELLOW}!${NC} $*" >&2; }
fail() { print_message "  ${RED}✗${NC} $*" >&2; }
die() {
  fail "$*"
  exit 1
}

# Quiet mode drops progress, never warnings, failures or required guidance.
QUIET=false
qheader() { [[ $QUIET == true ]] || header "$@"; }
qpass() { [[ $QUIET == true ]] || pass "$@"; }
qnote() { [[ $QUIET == true ]] || note "$@"; }
qact() { [[ $QUIET == true ]] || act "$@"; }

# Runs a tool whose own progress output belongs to the user, unless quiet.
run_visible() {
  if [[ $QUIET == true ]]; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

# --- File safety --------------------------------------------------------------

path_has_no_symlink_components() {
  local path=$1 resolved
  [[ $path =~ ^/[^[:cntrl:]]+$ ]] || return 1
  resolved=$(readlink -m -- "$path" 2>/dev/null) || return 1
  [[ $resolved == "$path" ]]
}

# Owned by the control user and not writable by anyone else.
mode_is_safe() {
  [[ $1 =~ ^[0-7]{3,4}$ ]] && (( (8#$1 & 0022) == 0 ))
}

is_safe_directory() {
  local path=$1 uid mode
  path_has_no_symlink_components "$path" || return 1
  [[ -d $path && ! -L $path ]] || return 1
  read -r uid mode < <(stat -Lc '%u %a' "$path" 2>/dev/null) || return 1
  [[ $uid == "$(owner_uid)" ]] && mode_is_safe "$mode"
}

is_safe_file() {
  local path=$1 uid mode links
  path_has_no_symlink_components "$path" || return 1
  [[ -f $path && ! -L $path ]] || return 1
  read -r uid mode links < <(stat -Lc '%u %a %h' "$path" 2>/dev/null) || return 1
  [[ $uid == "$(owner_uid)" && $links == 1 ]] && mode_is_safe "$mode"
}

file_identity() { stat -Lc '%d:%i' "$1" 2>/dev/null; }

b2sum_file() {
  local output
  output=$(b2sum -- "$1") || return 1
  [[ ${output%% *} =~ ^[0-9a-f]{128}$ ]] || return 1
  printf '%s\n' "${output%% *}"
}

# syncfs of the filesystem that holds the path: the ESP is FAT, where a file's
# data and its directory entry are only durable together.
durable_sync() { sync -f "$1"; }

# Writes stdin to the destination through a temporary file in the same
# directory, synced before and after the rename. FAT rename is not atomic
# across power loss; this only guarantees no reader sees a partial file.
atomic_write() {
  local destination=$1 mode=$2 parent temporary
  parent=$(dirname "$destination")
  [[ -d $parent ]] || return 1
  temporary=$(umask 077 && mktemp "${parent}/.${destination##*/}.XXXXXX") || return 1
  if cat >"$temporary" && chmod "$mode" "$temporary" && durable_sync "$temporary" &&
    mv -f -- "$temporary" "$destination"; then
    durable_sync "$parent"
  else
    rm -f -- "$temporary"
    return 1
  fi
}

# The package ships no state directory, so removing it never touches what is
# kept there; the first command that records something creates it.
ensure_state_dir() {
  local dir
  dir=$(state_dir)
  is_safe_directory "$(dirname "$dir")" || return 1
  if [[ ! -e $dir && ! -L $dir ]]; then
    install -d -m 755 "$dir" || return 1
  fi
  is_safe_directory "$dir"
}

# --- The needs-attention marker -------------------------------------------------

attention_marker() { printf '%s/needs-attention\n' "$(state_dir)"; }

set_attention() {
  ensure_state_dir || return 1
  printf '%s\n' "$*" | atomic_write "$(attention_marker)" 644
}

clear_attention() {
  local marker
  marker=$(attention_marker)
  [[ ! -e $marker ]] || rm -f -- "$marker"
}

# --- Limine settings lookup ------------------------------------------------------

# limine-entry-tool reads four layers, a later assignment winning
# (docs/upstream-contracts.md C3).
limine_config_layers() {
  local file
  for file in /usr/share/limine-entry-tool.d/*.conf; do
    [[ ! -f $file ]] || printf '%s\n' "$file"
  done
  [[ ! -f /etc/limine-entry-tool.conf ]] || printf '/etc/limine-entry-tool.conf\n'
  for file in /etc/limine-entry-tool.d/*.conf; do
    [[ ! -f $file ]] || printf '%s\n' "$file"
  done
  file=$(limine_default_config)
  [[ ! -f $file ]] || printf '%s\n' "$file"
}

# Prints the last assignment of KEY in one file exactly as upstream's
# load_key_value_config reads it: one trailing and one leading double quote
# are dropped. Status 1 means the file does not assign the key.
setting_in_file() {
  local file=$1 key=$2 line value found=false
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    [[ ${BASH_REMATCH[1]} == "$key" ]] || continue
    value=${BASH_REMATCH[2]}
    value=${value%\"}
    value=${value#\"}
    found=true
  done <"$file"
  [[ $found == true ]] || return 1
  printf '%s\n' "$value"
}

# The effective value of KEY across the layers, empty when no layer sets it.
# ENABLE_ENROLL_LIMINE_CONFIG counts only in /etc/default/limine, as upstream
# resets it before reading that last layer.
effective_setting() {
  local key=$1 file value='' candidate default
  default=$(limine_default_config)
  while IFS= read -r file; do
    [[ $key != ENABLE_ENROLL_LIMINE_CONFIG || $file == "$default" ]] || continue
    if candidate=$(setting_in_file "$file" "$key"); then
      value=$candidate
    fi
  done < <(limine_config_layers)
  printf '%s\n' "$value"
}

# The ESP as upstream resolves it: ESP_PATH, else the first of upstream's
# candidate mount points that is vfat.
esp_path() {
  local path
  path=$(effective_setting ESP_PATH)
  if [[ -z ${path// /} ]]; then
    for path in /efi /boot /boot/efi /limine; do
      [[ -d $path && $(findmnt -no FSTYPE "$path" 2>/dev/null) == vfat ]] || continue
      printf '%s\n' "$path"
      return 0
    done
    return 1
  fi
  printf '%s\n' "$path"
}

esp_is_mounted_vfat() {
  local esp
  esp=$(esp_path) || return 1
  mountpoint -q "$esp" && [[ $(findmnt -n -T "$esp" -o FSTYPE 2>/dev/null) == vfat ]]
}

limine_config_path() { printf '%s/limine.conf\n' "$(esp_path)"; }

free_bytes() { df --output=avail -B1 -- "$1" | tail -n 1; }

# FAT has no journal to survive a write that ran out of space, so nothing is
# written to a nearly full ESP. A Limine executable is well under a megabyte
# and a signature a few kilobytes.
esp_has_room() {
  local available
  available=$(free_bytes "$(esp_path)") || return 1
  (( available > 2 * 1024 * 1024 )) || {
    fail "Less than 2 MiB free on the ESP; free some space first"
    return 1
  }
}

# --- The boot lock ---------------------------------------------------------------

# false, inherited (a Limine tool passed descriptor 200 down) or local.
_boot_lock=false

fd_is_lock_file() {
  local lock
  lock=$(boot_lock_path)
  [[ -e /proc/self/fd/200 && -e $lock ]] &&
    [[ $(file_identity /proc/self/fd/200) == "$(file_identity "$lock")" ]]
}

# Takes the lock. Inside a Limine hook the calling tool already holds it on the
# descriptor we inherited; locking that descriptor again succeeds at once,
# while a fresh open would deadlock against our own parent. The tools carry on
# unlocked after their own timeout, so an inherited descriptor that is not
# ours at once means someone else is at work on the boot files, and the wait
# is the hook's short one. Status 75 means busy, as sysexits defines it.
boot_lock_acquire() {
  local lock rc=0
  [[ $_boot_lock == false ]] || return 0
  lock=$(boot_lock_path)
  if fd_is_lock_file; then
    flock -E 75 -w "$(hook_lock_wait)" 200 || rc=$?
    (( rc == 0 )) && _boot_lock=inherited
  else
    exec 200>&-
    exec 200>>"$lock" || return 1
    flock -E 75 -w "$(boot_lock_wait)" 200 || rc=$?
    if (( rc == 0 )) && fd_is_lock_file; then
      _boot_lock=local
    else
      exec 200>&-
      (( rc != 0 )) || rc=1
    fi
  fi
  if (( rc == 75 )); then
    warn "Boot files are busy: another tool holds $(boot_lock_path). Run this again when it has finished."
  elif (( rc != 0 )); then
    fail "Could not take the boot lock ${lock}"
  fi
  return "$rc"
}

boot_lock_release() {
  if [[ $_boot_lock == local ]]; then
    flock -u 200 2>/dev/null || true
    exec 200>&-
  fi
  _boot_lock=false
}

# The Limine tools open the lock themselves and carry on unlocked after their
# own timeout (C2), so one that this tool runs gets our lock released and descriptor
# 200 closed, and the lock is taken again afterwards. The caller proves state
# anew.
run_unlocked() {
  local held=$_boot_lock rc=0
  [[ $held != inherited ]] || return 1
  boot_lock_release
  "$@" 200>&- || rc=$?
  [[ $held == false ]] || boot_lock_acquire || return "$?"
  return "$rc"
}

# A full limine-snapper-restore runs without the lock and holds this marker.
restore_in_progress() {
  local marker
  marker=$(restore_marker_path)
  [[ -e $marker || -L $marker ]]
}
