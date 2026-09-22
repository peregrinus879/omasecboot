#!/bin/bash
# OmaSecBoot: what is on the ESP, whose file it is, and what sbctl knows about it.

primary_loader_path() { printf '%s/EFI/limine/limine_x64.efi\n' "$(esp_path)"; }
fallback_loader_path() { printf '%s/EFI/BOOT/BOOTX64.EFI\n' "$(esp_path)"; }
loader_backup_path() { printf '%s/EFI/limine/limine_x64.bak\n' "$(esp_path)"; }
package_loader_path() { printf '/usr/share/limine/BOOTX64.EFI\n'; }

# Writes the raw Limine executable, neither sealed nor signed, to stdout.
# limine-install keeps the one it deployed as a one-member tar beside the
# primary loader and restores it from there before every operation; that can
# be an older Limine than the package holds, because upstream refuses majors
# it does not know (C2). A machine without that backup gets the package's
# executable. A backup that is there but cannot be read is upstream's file,
# never repaired here: the way out is named, and nothing is built.
raw_loader() {
  local backup
  backup=$(loader_backup_path)
  if [[ -f $backup ]]; then
    tar -tf "$backup" limine_x64.efi >/dev/null 2>&1 || {
      fail "Upstream's copy of the raw loader, ${backup}, cannot be read as the archive limine-install writes. Move it aside, ${BOLD}sudo mv ${backup} ${backup}.damaged${NC}, then run ${BOLD}sudo limine-install${NC}, which deploys the package's loader and writes a fresh copy; until then the loader is built from the package's $(package_loader_path)"
      return 1
    }
    tar -xOf "$backup" limine_x64.efi
  else
    cat -- "$(package_loader_path)"
  fi
}

# Every EFI executable under the ESP except Microsoft's and the 32-bit loader.
# Snapshot history files carry a content hash after ".efi" in their name; that
# suffix is part of the filename, not a Limine path hash.
list_efi_files() {
  local root discovered
  root=$(esp_path) || return 1
  [[ -d $root && ! -L $root ]] || return 1
  discovered=$(find "$root" -xdev -type f \( \
    -iname '*.efi' -o -iname '*.efi_sha1_*' -o -iname '*.efi_sha256_*' -o \
    -iname '*.efi_b3_*' -o -iname '*.efi_blake3_*' -o \
    -iname '*.efi_xxh_*' -o -iname '*.efi_xxhash_*' \) \
    ! -ipath '*/Microsoft/*' ! -iname 'BOOTIA32.EFI' \
    -print 2>/dev/null) || return 1
  [[ -z $discovered ]] || LC_ALL=C sort <<<"$discovered"
}

# limine-snapper-sync owns these and stores their hashes; they are never
# modified (D5). FAT names are case-insensitive, and the listing above matches
# them that way, so this does too.
is_history_file() {
  local path=${1,,}
  [[ $path == */limine_history/* || ${path##*/} =~ \.efi_(sha1|sha256|b3|blake3|xxh|xxhash)_ ]]
}

is_fallback_loader() {
  local fallback
  fallback=$(fallback_loader_path)
  [[ ${1,,} == "${fallback,,}" ]]
}

# Files this tool may sign: everything discovered except history files and
# the fallback loader.
list_signable_files() {
  local file files
  files=$(list_efi_files) || return 1
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    is_history_file "$file" || is_fallback_loader "$file" || printf '%s\n' "$file"
  done <<<"$files"
}

list_history_files() {
  local file files
  files=$(list_efi_files) || return 1
  while IFS= read -r file; do
    [[ -z $file ]] || ! is_history_file "$file" || printf '%s\n' "$file"
  done <<<"$files"
}

# sbctl confines itself to the ESP it detects and answers null for a file
# anywhere else; ESP_PATH names the one Limine's configuration resolves, so the
# two tools cannot disagree on a machine with a second ESP (C4).
run_sbctl() {
  local esp
  esp=$(esp_path) || return 1
  ESP_PATH=$esp sbctl "$@"
}

sbctl_keys_exist() {
  local status
  status=$(run_sbctl status --json 2>/dev/null) || return 1
  jq -e '.installed == true' <<<"$status" >/dev/null 2>&1
}

# 0 signed with the local db key, 1 not, 2 could not tell. sbctl exits 0
# whatever it found and answers with an array of one entry whose is_signed is
# 1, 0 or -1 (no such file), or with null for a file it may not read
# (C4).
signature_state() {
  local file=$1 output state
  output=$(run_sbctl verify --json "$file" 2>/dev/null) || return 2
  state=$(jq -er --arg file "$file" '
    if type == "array" and length == 1 and .[0].file_name == $file and
      (.[0].is_signed == 1 or .[0].is_signed == 0 or .[0].is_signed == -1)
    then .[0].is_signed else empty end' <<<"$output") || return 2
  [[ $state == 1 ]]
}

# Source paths sbctl tracks, one per line. Its pacman hook re-signs every
# tracked file in place, so a tracked history file or fallback loader is
# damage waiting to happen. sbctl verifies each tracked file to answer, which
# reads it whole, and leaves out rows whose file is gone (C4). Status 2:
# unreadable answer.
sbctl_tracked_files() {
  local json
  json=$(run_sbctl list-files --json 2>/dev/null) || return 2
  [[ -n $json && $json != null ]] || return 0
  jq -r 'if type == "array" then .[] | .file | strings else error("shape") end' \
    <<<"$json" 2>/dev/null || return 2
}
