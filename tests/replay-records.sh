#!/bin/bash
# Replays two checks that read limine.conf over every state the hardware
# records captured, as the release checklist asks of a deferred change that
# reads limine.conf: that the files Omarchy's OS entries name are on the ESP
# (list_missing_os_files, against the EFI files the same state lists), and
# that limine.conf holds menu entries (lacks_menu_entries on what status
# reads). A new reader of limine.conf joins them here. Every recorded state is
# one the machine was in, so any hit is printed for judgment and fails the run.
# A control then leaves the kernel images off the rebuilt ESP, and every state
# whose OS entries name a boot():/ file must report it missing: the replay can
# fail. On demand, outside the hermetic suites; the records are data: no
# recorded command is run, and no path they list is written outside the
# temporary ESP.
#
# Usage: bash tests/replay-records.sh [RECORDS_DIR]
# Without RECORDS_DIR it downloads the records published with v0.1.0 and
# checks their sha256 first.
# Exit 0: every state clean and the control hit every state it can; 1: a hit,
# a check that could not read a state, or a control that missed; 2: records
# that cannot be fetched or used.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
readonly ASSET_URL=https://github.com/peregrinus879/omasecboot/releases/download/v0.1.0/omasecboot-records-2a8d324.tgz
readonly ASSET_SHA256=aa0abfdfc595a2a857a85ccaff1c404d64e8caac98602c10f39f9493b8f840de

unusable() {
  printf 'replay: %s\n' "$*" >&2
  exit 2
}

{ work=$(mktemp -d) && work=$(realpath -- "$work"); } || unusable "could not make a temporary directory"
trap 'rm -rf "$work"' EXIT

if (( $# == 1 )); then
  records=$1
elif (( $# == 0 )); then
  records=$work/records
  mkdir -p "$records"
  curl -fsSL -o "$work/records.tgz" "$ASSET_URL" || unusable "could not download ${ASSET_URL}"
  printf '%s  %s\n' "$ASSET_SHA256" "$work/records.tgz" | sha256sum -c --status - ||
    unusable "the downloaded records do not match their pinned sha256"
  tar -xzf "$work/records.tgz" -C "$records" --no-same-owner || unusable "could not unpack the records"
else
  unusable "usage: bash tests/replay-records.sh [RECORDS_DIR]"
fi
[[ -d $records ]] || unusable "${records} is not a directory"

for module in common checks files firmware windows limine sign status; do
  # shellcheck source=/dev/null
  source "$ROOT_DIR/lib/${module}.sh"
done
esp_path() { printf '%s/esp\n' "$work"; }
limine_config_path() { printf '%s/esp/limine.conf\n' "$work"; }

# split RECORD: one pair of files per "## " section of RECORD in
# $work/states, N.efi (the paths its EFI files block lists) and N.conf (its
# limine.conf). A block's own lines come first: limine.conf holds lines that
# begin "###".
split() {
  rm -rf "$work/states"
  mkdir -p "$work/states"
  awk -v out="$work/states" '
    inside && /^```$/ { inside = 0; mode = ""; next }
    inside && mode == "efi" {
      if (first && /^\$ /) { first = 0; next }
      first = 0
      print $2 > (out "/" section ".efi"); next
    }
    inside && mode == "conf" { print > (out "/" section ".conf"); next }
    inside { next }
    /^## / { section++; mode = ""; next }
    /^### EFI files$/ { mode = "efi"; next }
    /^### limine.conf$/ { mode = "conf"; next }
    /^### / { mode = ""; next }
    mode != "" && /^```text$/ { inside = 1; first = 1; next }
  ' "$1"
}

# replay CONTROL: prints "states named missing empty unread" for every
# record, and each hit when CONTROL is false. With CONTROL true the kernel
# images, the files under EFI/Linux, are left off the rebuilt ESP.
replay() {
  local control=$1 record name conf efi path target states=0 named=0 missing=0 empty=0 unread=0
  local result paths content scanned
  for record in "$records"/*.md; do
    [[ -f $record ]] || continue
    name=$(basename "$record")
    split "$record" || unusable "could not read ${record}"
    for conf in "$work"/states/*.conf; do
      [[ -f $conf ]] || continue
      efi=${conf%.conf}.efi
      [[ -s $efi ]] || unusable "${name}: a limine.conf without the EFI files of the same state"
      { rm -rf -- "$work/esp" && mkdir -p -- "$work/esp"; } || unusable "could not make the temporary ESP"
      while IFS= read -r path; do
        [[ $path == /boot/* ]] || continue
        target=$(realpath -m -- "$work/esp/${path#/boot/}")
        [[ $target == "$work/esp/"* ]] || unusable "${name}: ${path} lies outside the ESP"
        [[ $control == false || $target != "$work/esp/EFI/Linux/"* ]] || continue
        { mkdir -p -- "$(dirname -- "$target")" && : >"$target"; } || unusable "${name}: could not make ${path}"
      done <"$efi"
      cp -- "$conf" "$work/esp/limine.conf" || unusable "could not make the temporary limine.conf"
      states=$((states + 1))
      # Captured first: grep -q would end the pipe early, which pipefail reads
      # as a failure.
      paths=$(list_generated_os_paths) || unusable "${name}: limine.conf could not be read"
      [[ $paths != *'boot():/'* ]] || named=$((named + 1))
      result=$(list_missing_os_files) || unusable "${name}: limine.conf could not be read"
      if [[ -n $result ]]; then
        missing=$((missing + 1))
        [[ $control == true ]] || printf 'MISSING %s, section %s:\n%s\n' "$name" "$(basename "$conf" .conf)" "$result" >&2
      fi
      # As status reads it: status 1 is this tool's comment misplaced, and the
      # rest is still read; a higher one could not read limine.conf at all.
      scanned=0
      content=$(scan_windows_entries without 2>/dev/null) || scanned=$?
      if (( scanned > 1 )); then
        unread=$((unread + 1))
        [[ $control == true ]] || printf 'COULD NOT READ %s, section %s\n' "$name" "$(basename "$conf" .conf)" >&2
      elif lacks_menu_entries "$content"; then
        empty=$((empty + 1))
        [[ $control == true ]] || printf 'NO MENU ENTRIES %s, section %s\n' "$name" "$(basename "$conf" .conf)" >&2
      fi
    done
  done
  printf '%s %s %s %s %s\n' "$states" "$named" "$missing" "$empty" "$unread"
}

# In a command substitution, so a refusal inside ends the run with its status.
counts=$(replay false) || exit "$?"
read -r states named missing empty unread <<<"$counts"
(( states > 0 )) || unusable "no state with a limine.conf in ${records}"
printf 'replay: %s states, %s whose OS entries name a boot():/ file; %s with a missing file, %s without menu entries, %s the menu check could not read\n' "$states" "$named" "$missing" "$empty" "$unread"
counts=$(replay true) || exit "$?"
read -r _ control_named control_missing _ _ <<<"$counts"
printf 'control: %s of %s states report a kernel image left off\n' "$control_missing" "$control_named"
(( missing == 0 && empty == 0 && unread == 0 )) || exit 1
(( control_named > 0 && control_missing == control_named )) || {
  printf 'replay: the control missed, so a clean replay proves nothing\n' >&2
  exit 1
}
