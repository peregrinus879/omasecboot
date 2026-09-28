#!/bin/bash
# OmaSecBoot: constants, output, file safety, syncs and the ESP incident,
# needs-attention, Limine settings lookup, the boot lock.

# shellcheck disable=SC2034 # Read by the dispatcher and other modules.
readonly OMASECBOOT_VERSION="0.1.0"

# Locations are functions so the test suites can point them at fixtures.
state_dir() { printf '/var/lib/omasecboot\n'; }
efivars_dir() { printf '/sys/firmware/efi/efivars\n'; }
limine_default_config() { printf '/etc/default/limine\n'; }
restore_lock_path() { printf '/run/lock/limine-snapper-restore.lock\n'; }
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
sync_path() { sync -f "$1"; }

# Set when a sync of the ESP failed in this command, also when its incident
# could not be recorded. The one subshell that syncs the ESP, in
# publish_limine_conf, passes it on in its status.
_esp_sync_failed=false

# Whether PATH is the ESP or lies on it.
path_is_on_esp() {
  local esp path
  esp=$(esp_path 2>/dev/null) || return 1
  esp=$(realpath -m -- "$esp") path=$(realpath -m -- "$1")
  [[ $path == "$esp" || $path == "$esp"/* ]]
}

# sync_path, and on the ESP an incident when it fails: syncfs reports a
# writeback error of any file on the filesystem, and not to a file opened after
# another caller saw it, so no later sync shows whether a write was lost (C2).
# The incident is recorded and said the moment the sync fails, under the lock
# every writer of the ESP holds, and only the operator's acknowledgement clears
# it. A path that is gone fails the sync without a writeback error.
durable_sync() {
  local incident
  sync_path "$1" && return 0
  if [[ -e $1 ]] && path_is_on_esp "$1"; then
    _esp_sync_failed=true
    if ! set_attention "$ATTENTION_SYNC"; then
      warn "The ESP reported a write error at ${1}, which could not be recorded in $(attention_file), so status cannot show it. Do not reboot, with Secure Boot on or off; follow the README's \"If the ESP reports a write error\""
    elif incident=$(esp_incident) && [[ -n $incident ]]; then
      warn "The ESP reported a write error at ${1} (incident ${incident%% *}). Do not reboot, with Secure Boot on or off; run ${BOLD}sudo omasecboot status${NC}"
    else
      warn "The ESP reported a write error at ${1}, recorded in $(attention_file) beside a line OmaSecBoot does not write. Do not reboot, with Secure Boot on or off; run ${BOLD}sudo omasecboot status${NC}"
    fi
  fi
  return 1
}

# atomic_write DESTINATION MODE [GUARD...]: writes stdin to the destination
# through a temporary file in the same directory, synced before and after the
# rename. FAT rename is not atomic across power loss; this only guarantees no
# reader sees a partial file. A GUARD command runs right before the rename and
# refuses the write when it fails: the last moment to see that the destination
# changed while the content was being staged.
atomic_write() {
  local destination=$1 mode=$2 parent temporary
  shift 2
  parent=$(dirname "$destination")
  [[ -d $parent ]] || return 1
  temporary=$(umask 077 && mktemp "${parent}/.${destination##*/}.XXXXXX") || return 1
  if cat >"$temporary" && chmod "$mode" "$temporary" && durable_sync "$temporary" &&
    { (( $# == 0 )) || "$@"; } && mv -f -- "$temporary" "$destination"; then
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

# --- needs-attention ----------------------------------------------------------------

attention_file() { printf '%s/needs-attention\n' "$(state_dir)"; }

# One dated line per kind of finding. Any pass writes the kinds it finds, and
# clears only the kinds it judges: the seal; only a full pass clears what a
# pass could not finish, so the watchers' pass never clears what a full pass
# found. An ESP incident, a sync of the ESP that failed, is cleared by the
# operator's acknowledgement alone: the error may concern any file on the ESP,
# and no sync that opens the ESP after it was seen reports it (C2).
readonly ATTENTION_PASS='sign could not finish'
readonly ATTENTION_SEAL='the loader could not be sealed'
readonly ATTENTION_SYNC='the ESP reported a write error'

# The lines of needs-attention, nothing when there is none, or a failure when
# it cannot be read: what cannot be read is never taken for no finding.
attention_lines() {
  local file
  file=$(attention_file)
  [[ -e $file || -L $file ]] || return 0
  cat -- "$file"
}

# The lines of needs-attention that are not of KIND, or a failure when it
# cannot be read, so that no rewrite drops the lines it could not read.
attention_without() {
  local lines line
  lines=$(attention_lines) || return 1
  while IFS= read -r line; do
    [[ -z $line || $line == "$1" || $line == "$1 "* ]] || printf '%s\n' "$line"
  done <<<"$lines"
}

# A fresh ID for an ESP incident: two failures within a second, or a clock
# that ran back, still get different ones.
new_incident_id() { od -An -N6 -tx1 /dev/urandom | tr -d ' \n'; }

# set_attention KIND: records KIND with the time, in place of an older one; an
# ESP incident gets a fresh ID, so an acknowledgement names the one it means.
set_attention() {
  local kept line id
  ensure_state_dir || return 1
  kept=$(attention_without "$1") || return 1
  line="$1 on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ $1 == "$ATTENTION_SYNC" ]]; then
    # esp_incident reads no other form, so nothing else may be written.
    id=$(new_incident_id) && [[ $id =~ ^[0-9a-f]{12}$ ]] || return 1
    line+=", incident ${id}"
  fi
  { [[ -z $kept ]] || printf '%s\n' "$kept"; printf '%s\n' "$line"; } |
    atomic_write "$(attention_file)" 644
}

# The ESP incident that stands, as "ID TIME", or nothing when none stands; a
# failure when needs-attention cannot be read, or holds any line set_attention
# does not write or a second incident: a damaged line is never taken for no
# incident.
esp_incident() {
  local lines line incident=''
  local finding="^(${ATTENTION_PASS}|${ATTENTION_SEAL}) on [^,]+\$"
  local pattern="^${ATTENTION_SYNC} on ([^,]+), incident ([0-9a-f]{12})\$"
  lines=$(attention_lines) || return 1
  while IFS= read -r line; do
    if [[ -z $line || $line =~ $finding ]]; then
      continue
    elif [[ -z $incident && $line =~ $pattern ]]; then
      incident="${BASH_REMATCH[2]} ${BASH_REMATCH[1]}"
    else
      return 1
    fi
  done <<<"$lines"
  [[ -z $incident ]] || printf '%s\n' "$incident"
}

# esp_incident, or "unknown" where whether one stands cannot be told.
esp_incident_or_unknown() { esp_incident || printf 'unknown\n'; }

# incident_clause INCIDENT: what an incident, as esp_incident_or_unknown
# prints it, means for the operator.
incident_clause() {
  if [[ $1 == unknown ]]; then
    printf '%s cannot be read, or holds a line OmaSecBoot does not write, so whether the ESP reported a write error cannot be told\n' "$(attention_file)"
  else
    printf 'the ESP reported a write error on %s (incident %s) that stands until you acknowledge it\n' "${1#* }" "${1%% *}"
  fi
}

# clear_attention KIND
clear_attention() {
  local file kept
  file=$(attention_file)
  [[ -e $file || -L $file ]] || return 0
  is_safe_directory "$(state_dir)" || return 1
  kept=$(attention_without "$1") || return 1
  if [[ -z $kept ]]; then
    rm -f -- "$file"
  else
    printf '%s\n' "$kept" | atomic_write "$file" 644
  fi
}

# --- Limine settings lookup ------------------------------------------------------

# limine-entry-tool reads four layers, a later assignment winning (C3).
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
  # Upstream accepts "/boot/" and "//boot" (C3). Paths are compared as text
  # here, and a fallback loader that is not recognised would be signed.
  while [[ $path == *//* ]]; do path=${path//\/\//\/}; done
  [[ $path == / ]] || path=${path%/}
  printf '%s\n' "$path"
}

esp_is_mounted_vfat() {
  local esp
  esp=$(esp_path) || return 1
  mountpoint -q "$esp" && [[ $(findmnt -n -T "$esp" -o FSTYPE 2>/dev/null) == vfat ]]
}

# Every mount of the ESP's device, by device number, as "TARGET OPTIONS": the
# ESP mounted a second time writes the same files. findmnt sees the mounts of
# this mount namespace; -r keeps its columns free of the padding it adds
# otherwise, and writes a blank in a target as \x20 (C2).
esp_mounts() {
  local esp device
  esp=$(esp_path) || return 1
  device=$(findmnt -rn -o MAJ:MIN -T "$esp" 2>/dev/null) && [[ -n $device ]] || return 1
  findmnt -rn -o MAJ:MIN,TARGET,OPTIONS 2>/dev/null | awk -v device="$device" '$1 == device { print $2, $3 }'
}

# vfat keeps no owner or mode per file: every file takes the mount's uid and
# fmask, every directory its dmask, and the kernel prints uid only when it is
# not root and fmask and dmask always. The options belong to the device, so
# every mount of it shows the same; a mount alone can add an idmapping, which
# maps who writes (C2). So the mounts say who can write the ESP, and the rule
# is mode_is_safe's: owned by root, no write for group or others, whatever the
# group, and no idmapping. A mount that lets anyone else write would have the
# pass seal and sign what they wrote. Prints why the first mount that fails the
# rule fails it; one that cannot be read, or shows no masks, fails it too.
esp_mount_is_safe() {
  local mounts target options uid fmask dmask
  mounts=$(esp_mounts) || {
    printf 'its mount at %s could not be read\n' "$(esp_path 2>/dev/null)"
    return 1
  }
  while read -r target options; do
    uid=0 fmask='' dmask=''
    [[ ,$options, =~ ,uid=([0-9]+), ]] && uid=${BASH_REMATCH[1]}
    [[ ,$options, =~ ,fmask=([0-7]+), ]] && fmask=${BASH_REMATCH[1]}
    [[ ,$options, =~ ,dmask=([0-7]+), ]] && dmask=${BASH_REMATCH[1]}
    if [[ -z $fmask || -z $dmask ]]; then
      printf 'its mount at %s shows no fmask and dmask (%s)\n' "$target" "$options"
      return 1
    elif [[ $uid != 0 || ,$options, == *,idmapped,* ]] || (( (8#$fmask & 022) != 022 || (8#$dmask & 022) != 022 )); then
      printf 'users other than root can write to it through %s (%s)\n' "$target" "$options"
      return 1
    fi
  done <<<"$mounts"
}

# How to give the ESP a mount that only root can write. vfat keeps its options
# on a remount, so the ESP is mounted afresh (C2).
unsafe_esp_remedy() {
  local esp
  esp=$(printf '%q' "$(esp_path 2>/dev/null)")
  printf "Take any uid= off the ESP's line in /etc/fstab and give it an fmask and a dmask without write for group and others, as Omarchy's fmask=0022,dmask=0022 have, and unmount any idmapped mount of it. vfat keeps its options on a remount, so then mount the ESP afresh: %s" \
    "${BOLD}sudo systemctl daemon-reload && sudo umount ${esp} && sudo mount ${esp}${NC}"
}

limine_config_path() { printf '%s/limine.conf\n' "$(esp_path)"; }

free_bytes() { df --output=avail -B1 -- "$1" | tail -n 1; }

# FAT has no journal to survive a write that ran out of space, so nothing is
# written to a nearly full ESP. A Limine executable is well under a megabyte
# and a signature a few kilobytes.
esp_has_room() {
  esp_room_is_enough || {
    fail "Less than 2 MiB free on the ESP; free some space first"
    return 1
  }
}

esp_room_is_enough() {
  local available
  available=$(free_bytes "$(esp_path)") && (( available > 2 * 1024 * 1024 ))
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
# descriptor the hook inherited; locking that descriptor again succeeds at
# once, while a fresh open would deadlock against the hook's own parent. The
# tools carry on unlocked after their own timeout, so an inherited descriptor
# that cannot be locked at once means someone else is at work on the boot
# files, and the wait is the hook's short one. Status 75 means busy, as
# sysexits defines it.
boot_lock_acquire() {
  local lock rc=0
  [[ $_boot_lock == false ]] || return 0
  lock=$(boot_lock_path)
  if fd_is_lock_file; then
    flock -E 75 -w "$(hook_lock_wait)" 200 || rc=$?
    (( rc == 0 )) && _boot_lock=inherited
  else
    exec 200>&-
    if ! exec 200>>"$lock"; then
      fail "Could not open the boot lock ${lock}; look at the owner and mode of its directory"
      return 1
    fi
    flock -E 75 -w "$(boot_lock_wait)" 200 || rc=$?
    if (( rc == 0 )) && fd_is_lock_file; then
      _boot_lock=local
    else
      exec 200>&-
      (( rc != 0 )) || rc=1
    fi
  fi
  if (( rc == 75 )); then
    warn "Boot files are busy: another tool holds $(boot_lock_path). When it has finished, run this command again; after an update that is ${BOLD}sudo omasecboot sign${NC}"
  elif (( rc != 0 )); then
    fail "Could not take the boot lock ${lock}; look at the owner and mode of its directory"
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
# own timeout (C2), so one that this tool runs gets the lock released and
# descriptor 200 closed, and the lock is taken again afterwards. The caller
# proves state anew.
run_unlocked() {
  local held=$_boot_lock rc=0
  [[ $held != inherited ]] || return 1
  boot_lock_release
  "$@" 200>&- || rc=$?
  [[ $held == false ]] || boot_lock_acquire || return "$?"
  return "$rc"
}

# A full limine-snapper-restore works without the boot lock and holds one of
# its own (C2).
restore_in_progress() {
  local lock
  lock=$(restore_lock_path)
  [[ -e $lock || -L $lock ]]
}
