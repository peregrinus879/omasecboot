#!/bin/bash
# Limine: managed settings and their originals, path hashes, the primary
# loader proof and staged rebuild, the fallback loader, the watchers' unit names.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init limine

settings_round_trip_from_stock() {
  local before=$FIX/run/default-limine-before
  cp "$FIX/etc/default-limine" "$before"
  { save_settings_originals && apply_managed_settings; } || fail_test "apply"
  [[ $(effective_setting ENABLE_VERIFICATION) == no && $(effective_setting ENABLE_ENROLL_LIMINE_CONFIG) == yes ]] || fail_test "the managed values are not in effect"
  grep -qx 'ENABLE_VERIFICATION=no' "$FIX/etc/default-limine" || fail_test "verification line"
  { apply_managed_settings && [[ $(grep -c '^ENABLE_' "$FIX/etc/default-limine") == 2 ]]; } || fail_test "a second apply added lines"
  restore_settings_originals || fail_test "restore"
  cmp -s "$FIX/etc/default-limine" "$before" || fail_test "the stock file did not come back byte for byte"
}

# Backslashes, tabs, spacing and blank lines at the end are the user's; awk,
# read and a command substitution would each rewrite them if given the chance.
original_values_come_back_verbatim() {
  local before=$FIX/run/default-limine-before
  printf '\tENABLE_VERIFICATION = "yes"  # C:\\new\\table\t\n\n\n' >>"$FIX/etc/default-limine"
  cp "$FIX/etc/default-limine" "$before"
  { save_settings_originals && apply_managed_settings; } || fail_test "apply"
  [[ $(effective_setting ENABLE_VERIFICATION) == no ]] || fail_test "not applied"
  restore_settings_originals || fail_test "restore"
  cmp -s "$FIX/etc/default-limine" "$before" || fail_test "the original line did not come back byte for byte: $(<"$FIX/etc/default-limine")"
}

# A failed rendering must never replace the file: it holds the kernel command
# line.
failed_write_keeps_the_settings_file() {
  local before=$FIX/run/default-limine-before
  cp "$FIX/etc/default-limine" "$before"
  awk() { return 1; }
  ! write_default_setting ENABLE_VERIFICATION ENABLE_VERIFICATION=no || fail_test "a failed rendering reported success"
  cmp -s "$FIX/etc/default-limine" "$before" || fail_test "a failed rendering replaced the settings file"
}

# /etc/default/limine holds the kernel command line: a line saved by hand
# between the read and the rename is never lost (section 7.1).
settings_file_changed_meanwhile_is_not_overwritten() {
  local output
  sync_path() { [[ $1 != "$FIX"/etc/.default-limine.* ]] || printf 'USER_LINE=kept\n' >>"$FIX/etc/default-limine"; }
  output=$(write_default_setting ENABLE_VERIFICATION ENABLE_VERIFICATION=no 2>&1) && fail_test "the write went over a newer file"
  [[ $output == *'changed while a managed setting was being written'* ]] || fail_test "no word: ${output}"
  grep -qx 'USER_LINE=kept' "$FIX/etc/default-limine" || fail_test "the line saved meanwhile was lost"
  ! grep -q '^ENABLE_VERIFICATION=no' "$FIX/etc/default-limine" || fail_test "the managed line was written over the newer file"
  sync_path() { :; }
  write_default_setting ENABLE_VERIFICATION ENABLE_VERIFICATION=no || fail_test "the next write failed"
  { grep -qx 'USER_LINE=kept' "$FIX/etc/default-limine" && grep -qx 'ENABLE_VERIFICATION=no' "$FIX/etc/default-limine"; } || fail_test "the next write lost a line"
}

originals_are_recorded_once() {
  { save_settings_originals && apply_managed_settings; } || fail_test "apply"
  save_settings_originals || fail_test "second save"
  grep -q $'^ENABLE_VERIFICATION\tabsent$' "$(settings_originals_file)" || fail_test "a second save overwrote the originals"
}

# remove restores what the originals say; a record it cannot read is no
# answer, never a guess about what stood there.
malformed_originals_record_is_no_answer() {
  local before=$FIX/run/default-limine-before
  { save_settings_originals && apply_managed_settings; } || fail_test "apply"
  printf 'ENABLE_VERIFICATION\tsomething else\n' >"$(settings_originals_file)"
  cp "$FIX/etc/default-limine" "$before"
  ! restore_settings_originals || fail_test "a malformed record was restored"
  cmp -s "$FIX/etc/default-limine" "$before" || fail_test "a malformed record changed the settings"
}

# Upstream copies the fallback in place and hides a failed copy (C2), so
# there must be room before it is asked to.
fallback_is_not_added_without_room() {
  rm "$(fallback_loader_path)"
  free_bytes() { printf '4096\n'; }
  : >"$FIX/run/calls"
  ! add_fallback_loader 2>/dev/null || fail_test "a fallback was added to a full ESP"
  [[ ! -e $(fallback_loader_path) ]] || fail_test "a fallback stands on a full ESP"
  ! grep -q '^limine-install' "$FIX/run/calls" || fail_test "upstream's install ran on a full ESP"
}

stale_os_hashes_are_found() {
  local stale
  [[ -z $(list_stale_os_hashes) ]] || fail_test "a fresh hash read as stale"
  os_entries_carry_hashes || fail_test "the hashed OS entry was not seen"
  # What the pass asks before it signs a file in place; FAT names have no case.
  file_has_path_hash "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "the hashed UKI was not recognised"
  file_has_path_hash "$FIX/esp/efi/LINUX/OMARCHY_LINUX.EFI" || fail_test "the hashed UKI was not recognised under another case"
  ! file_has_path_hash "$(primary_loader_path)" || fail_test "the primary loader read as hashed"
  printf 'changed' >>"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  stale=$(list_stale_os_hashes)
  [[ $stale == *'path: boot():/EFI/Linux/omarchy_linux.efi#'* ]] || fail_test "the stale OS hash was not listed"
  sed -i 's|boot():/EFI/Linux/|boot():/../outside/|' "$FIX/esp/limine.conf"
  [[ -n $(list_stale_os_hashes) ]] || fail_test "a path that leaves the ESP read as current"
}

# Snapshot entries carry upstream's hashes of history files (D5): they are
# neither an OS entry's hashes nor read, whatever they say.
snapshot_hashes_are_upstreams() {
  local history=$FIX/esp/machine/limine_history/snap.efi_sha256_abc
  write_limine_conf unhashed
  mkdir -p "${history%/*}" && printf 'old uki' >"$history"
  printf '  //snapshot 7\n    protocol: efi\n    path: boot():/machine/limine_history/snap.efi_sha256_abc#%0128d\n' 0 >>"$FIX/esp/limine.conf"
  [[ $(list_hashed_paths) == *'limine_history'* ]] || fail_test "the snapshot's hashed path was not parsed"
  ! os_entries_carry_hashes || fail_test "a snapshot's hash counted as an OS entry's"
  [[ -z $(list_stale_os_hashes) ]] || fail_test "a snapshot's stale hash was listed"
}

primary_is_sealed_signed_and_reproved() {
  : >"$FIX/sbctl/keys"
  ! primary_is_proved || fail_test "a raw loader read as proved"
  ensure_primary_loader || fail_test "seal and sign"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader is not sealed and signed"
  : >"$FIX/run/calls"
  { ensure_primary_loader && [[ ! -s $FIX/run/calls || $(grep -c 'enroll-config' "$FIX/run/calls") == 0 ]]; } || fail_test "a proved loader was rebuilt"
  printf 'timeout: 9\n' >>"$FIX/esp/limine.conf"
  ! primary_is_proved || fail_test "a changed limine.conf still read as sealed"
  { ensure_primary_loader && loader_is_sealed_and_signed "$(primary_loader_path)"; } || fail_test "re-seal after an edit"
}

failed_rebuild_keeps_the_old_loader() {
  local before=$FIX/run/primary-before
  : >"$FIX/sbctl/keys"
  cp "$(primary_loader_path)" "$before"
  : >"$FIX/run/limine-enroll-fails"
  ! ensure_primary_loader 2>/dev/null || fail_test "a failed enrollment reported success"
  cmp -s "$(primary_loader_path)" "$before" || fail_test "the target changed although the build failed"
  [[ -z $(find "$FIX/esp/EFI/limine" -name '.omasecboot-loader.*') ]] || fail_test "a staging file was left on the ESP"
  rm "$FIX/run/limine-enroll-fails"
  : >"$FIX/run/calls"
  free_bytes() { printf '4096\n'; }
  ! ensure_primary_loader 2>/dev/null || fail_test "a rebuild started without room for it"
  ! grep -q 'enroll-config' "$FIX/run/calls" || fail_test "a full ESP did not stop the rebuild before it wrote"
}

# Upstream can hold a new Limine major back; the rebuild must keep the version
# upstream deployed, and only a machine without upstream's backup gets the
# package's executable (C2).
rebuild_uses_the_loader_upstream_deployed() {
  : >"$FIX/sbctl/keys"
  write_raw_loader "$FIX/share/BOOTX64.EFI" 13.0.0
  ensure_primary_loader || fail_test "rebuild"
  grep -aq 'LIMINE-12.8.0' "$(primary_loader_path)" || fail_test "the rebuild deployed the package's newer Limine"
  rm "$(loader_backup_path)"
  printf 'timeout: 9\n' >>"$FIX/esp/limine.conf"
  ensure_primary_loader || fail_test "rebuild without a backup"
  grep -aq 'LIMINE-13.0.0' "$(primary_loader_path)" || fail_test "no backup and the package's executable was not used"
}

# A backup that is not upstream's tar must stop the rebuild, never reach the
# primary.
corrupt_backup_publishes_nothing() {
  local before=$FIX/run/primary-before output
  : >"$FIX/sbctl/keys"
  cp "$(primary_loader_path)" "$before"
  printf 'not a tar archive' >"$(loader_backup_path)"
  output=$(ensure_primary_loader 2>&1) && fail_test "a corrupt backup produced a loader"
  cmp -s "$(primary_loader_path)" "$before" || fail_test "the primary changed"
  [[ -z $(find "$FIX/esp/EFI/limine" -name '.omasecboot-loader.*') ]] || fail_test "a staging file was left on the ESP"
  # Upstream's file is never repaired here; the way out is named, and once
  # the damaged copy is aside the package's executable serves (docs/recovery.md).
  [[ $output == *"$(loader_backup_path), cannot be read"*"sudo mv $(loader_backup_path) $(loader_backup_path).damaged"* ]] || fail_test "the way out was not named: ${output}"
  mv "$(loader_backup_path)" "$(loader_backup_path).damaged"
  ensure_primary_loader >/dev/null || fail_test "the rebuild failed with the damaged copy aside"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader built from the package's executable is not sealed and signed"
}

# Upstream's tools hide their failures (C2), so the staged copy is proved
# before it replaces the primary: a seal or a signature that was reported and
# never written publishes nothing.
unwritten_seal_or_signature_publishes_nothing() {
  local before=$FIX/run/primary-before flag
  : >"$FIX/sbctl/keys"
  cp "$(primary_loader_path)" "$before"
  for flag in limine-enroll-does-nothing sbctl-sign-does-nothing; do
    : >"$FIX/run/${flag}"
    ! ensure_primary_loader >/dev/null 2>&1 || fail_test "${flag}: a loader that was not proved passed"
    cmp -s "$(primary_loader_path)" "$before" || fail_test "${flag}: the unproved copy replaced the primary"
    [[ -z $(find "$FIX/esp/EFI/limine" -name '.omasecboot-loader.*') ]] || fail_test "${flag}: a staging file was left on the ESP"
    rm "$FIX/run/${flag}"
  done
  # The staged copy is sealed and signed, but its sync fails: it is never
  # renamed over the primary, and the failure stands as an incident.
  sync_path() { [[ ${1##*/} != "$LOADER_STAGING_PREFIX"* ]]; }
  ! ensure_primary_loader >/dev/null 2>&1 || fail_test "a staged copy whose sync failed passed"
  cmp -s "$(primary_loader_path)" "$before" || fail_test "a staged copy whose sync failed replaced the primary"
  [[ -z $(find "$FIX/esp/EFI/limine" -name '.omasecboot-loader.*') ]] || fail_test "a staging file was left after its failed sync"
  [[ -n $(esp_incident) ]] || fail_test "the failed sync of the staged copy was not recorded"
  sync_path() { :; }
}

# Left behind by a pass that was killed; ESP space is scarce.
stale_staging_files_are_swept() {
  : >"$FIX/esp/EFI/limine/.omasecboot-loader.abc123"
  : >"$FIX/esp/EFI/BOOT/.omasecboot-loader.def456"
  : >"$FIX/esp/.limine.conf.ghi789"
  remove_stale_staging || fail_test "sweep"
  [[ -z $(find "$FIX/esp" -name '.omasecboot-loader.*' -o -name '.limine.conf.*') ]] || fail_test "staging files remain: $(find "$FIX/esp" -name '.*')"
  [[ -e $(primary_loader_path) && -e $(fallback_loader_path) && -e $FIX/esp/limine.conf ]] || fail_test "the sweep removed a loader or limine.conf"
}

# systemd merges changes that arrive while the watcher's service runs (C5).
change_during_the_rebuild_is_caught() {
  : >"$FIX/sbctl/keys"
  : >"$FIX/run/config-changes-during-enroll"
  converge_primary_loader || fail_test "a change during the first round failed the pass"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader carries the checksum from before the change"
}

# A limine.conf that changes after every proof exhausts the rounds (D8): the
# pass reports that it could not seal, never a seal it does not have. The
# change is made by the proof of the primary, which ensure_primary_loader
# repeats after it installs a loader.
restless_limine_conf_is_not_reported_sealed() {
  : >"$FIX/sbctl/keys"
  eval "original_$(declare -f signature_state)"
  signature_state() {
    local status=0
    original_signature_state "$@" || status=$?
    [[ $1 != "$(primary_loader_path)" ]] || printf 'timeout: %s\n' "$RANDOM" >>"$FIX/esp/limine.conf"
    return "$status"
  }
  ! converge_primary_loader >/dev/null 2>&1 || fail_test "the pass reported a seal while limine.conf kept changing"
}

# The seal is the slot after Limine's marker, which occurs once (C1): 128
# digits in the releases, 256 on the development branch, where zeros in the
# upper half keep BLAKE2b in the lower half and anything else is BLAKE3. Only
# BLAKE2b is proved here; a slot of any other form is no answer about a seal.
seal_classes_follow_the_slot() {
  local file=$FIX/run/loader sum zeros
  sum=$(printf 'config' | b2sum | cut -d' ' -f1)
  zeros=$(printf '0%.0s' {1..128})
  write_raw_loader "$file"
  [[ $(limine_seal "$file") == unsealed ]] || fail_test "a raw 12.x loader: $(limine_seal "$file")"
  limine enroll-config "$file" "$sum"
  [[ $(limine_seal "$file") == "blake2b $sum" ]] || fail_test "an enrolled 12.x loader: $(limine_seal "$file")"
  write_loader_with_slot "$file" "${zeros}${zeros}"
  [[ $(limine_seal "$file") == unsealed ]] || fail_test "a raw loader with a 256-digit slot: $(limine_seal "$file")"
  write_loader_with_slot "$file" "${sum}${zeros}"
  [[ $(limine_seal "$file") == "blake2b $sum" ]] || fail_test "BLAKE2b in a 256-digit slot: $(limine_seal "$file")"
  write_loader_with_slot "$file" "${zeros}${sum}"
  [[ $(limine_seal "$file") == blake3 ]] || fail_test "a non-zero upper half: $(limine_seal "$file")"
  write_loader_with_slot "$file" "${sum:0:100}"
  [[ $(limine_seal "$file") == unsupported ]] || fail_test "a short slot: $(limine_seal "$file")"
  write_loader_with_slot "$file" "${zeros}${zeros}0"
  [[ $(limine_seal "$file") == unsupported ]] || fail_test "a run of 257 digits: $(limine_seal "$file")"
  write_raw_loader "$file"
  printf '%s%s\n' "$FIXTURE_MARKER" "$zeros" >>"$file"
  [[ $(limine_seal "$file") == unsupported ]] || fail_test "two markers: $(limine_seal "$file")"
  printf 'not a loader' >"$file"
  [[ $(limine_seal "$file") == none ]] || fail_test "a file without the marker: $(limine_seal "$file")"
  ! limine_seal "$FIX/run/missing" >/dev/null 2>&1 || fail_test "a file that cannot be read gave an answer"
}

fallback_states() {
  local fallback
  fallback=$(fallback_loader_path)
  : >"$FIX/sbctl/keys"
  [[ $(fallback_state) == raw ]] || fail_test "stock fallback is not raw"
  sbctl sign "$fallback"
  [[ $(fallback_state) == altered ]] || fail_test "a signed, unsealed fallback is not altered"
  { restore_raw_fallback && [[ $(fallback_state) == raw ]]; } || fail_test "restore"
  cmp -s "$fallback" "$FIX/share/BOOTX64.EFI" || fail_test "the fallback is not the raw executable"
  # A raw copy whose sync fails is not put in place, and stands as an incident.
  sbctl sign "$fallback"
  sync_path() { [[ ${1##*/} != "$LOADER_STAGING_PREFIX"* ]]; }
  ! restore_raw_fallback || fail_test "a raw copy whose sync failed was put in place"
  [[ $(fallback_state) == altered && -n $(esp_incident) ]] || fail_test "after a failed sync of the raw copy: $(fallback_state), $(esp_incident)"
  sync_path() { :; }
  restore_raw_fallback || fail_test "restore after the failed sync"
  limine enroll-config "$fallback" "$(config_checksum)"
  [[ $(fallback_state) == altered ]] || fail_test "a sealed fallback is not altered"
  write_raw_loader "$fallback" 12.5.2
  [[ $(fallback_state) == raw ]] || fail_test "an older raw Limine copy is upstream's business"
  # A slot whose seal cannot be told is nobody's to rewrite on a guess.
  write_loader_with_slot "$fallback" "$(printf '0%.0s' {1..100})"
  [[ $(fallback_state) == foreign ]] || fail_test "a fallback whose seal cannot be told is $(fallback_state)"
  printf 'Windows boot manager copy' >"$fallback"
  [[ $(fallback_state) == foreign ]] || fail_test "a foreign BOOTX64.EFI was not recognised"
  # Upstream's step copies over whatever is there (C2), so it is used only
  # while nothing is.
  add_fallback_loader >/dev/null 2>&1 && fail_test "upstream's step was run over a foreign loader"
  [[ $(<"$fallback") == 'Windows boot manager copy' ]] || fail_test "a foreign loader was replaced"
  rm "$fallback"
  [[ $(fallback_state) == absent ]] || fail_test "absent"
  # Upstream copies in place and hides a failed copy (C2): no room, no attempt.
  : >"$FIX/run/calls"
  (
    free_bytes() { printf '4096\n'; }
    add_fallback_loader >/dev/null 2>&1
  ) && fail_test "upstream's step was run on a full ESP"
  [[ ! -e $fallback && ! -s $FIX/run/calls ]] || fail_test "a full ESP did not stop the step: $(<"$FIX/run/calls")"
  : >"$FIX/run/fallback-copy-is-torn"
  add_fallback_loader >/dev/null 2>&1 && fail_test "a torn copy was taken for the fallback"
  rm "$fallback" "$FIX/run/fallback-copy-is-torn"
  add_fallback_loader >/dev/null || fail_test "the fallback was not added"
  cmp -s "$fallback" "$FIX/share/BOOTX64.EFI" || fail_test "the added fallback is not the packaged raw loader"
}

watch_units_are_template_instances() {
  esp_path() { printf '/boot\n'; }
  [[ $(watch_units) == $'omasecboot-watch@boot-limine.conf.path\nomasecboot-watch@boot-EFI-limine-limine_x64.efi.path' ]] || fail_test "unit names: $(watch_units)"
}

shadowing_configs_are_listed() {
  [[ -z $(list_shadowing_configs) ]] || fail_test "a clean ESP listed a shadow"
  cp "$FIX/esp/limine.conf" "$FIX/esp/EFI/limine/limine.conf"
  [[ $(list_shadowing_configs) == "$FIX/esp/EFI/limine/limine.conf" ]] || fail_test "the shadowing copy was not listed"
  # The fallback, the rescue loader, reads a limine.conf beside itself first (C1).
  : >"$FIX/esp/EFI/BOOT/limine.conf"
  [[ $(list_shadowing_configs) == *"$FIX/esp/EFI/BOOT/limine.conf"* ]] || fail_test "a limine.conf beside the fallback was not listed"
}

# The guard and the stale-hash reader resolve a hashed path the same way, so
# "./", "//" and ".." name the file they name (D4).
hashed_paths_are_resolved_before_they_compare() {
  local file=$FIX/esp/EFI/Linux/omarchy_linux.efi spelling
  for spelling in 'EFI/Linux/./omarchy_linux.efi' 'EFI//Linux/omarchy_linux.efi' 'EFI/../EFI/Linux/omarchy_linux.efi' 'efi/linux/OMARCHY_LINUX.EFI'; do
    write_limine_conf unhashed
    printf '\n/Other\n    protocol: efi\n    path: boot():/%s#%s\n' "$spelling" "$(b2sum <"$file" | cut -d' ' -f1)" >>"$FIX/esp/limine.conf"
    file_has_path_hash "$file" || fail_test "the guard missed the spelling ${spelling}"
    # The fixture's filesystem has case, a FAT ESP has none: the stale reader
    # resolves the name on disk, so only the exact-case spellings are checked.
    [[ $spelling == *OMARCHY* || -z $(list_stale_os_hashes) ]] || fail_test "a fresh hash read as stale under ${spelling}"
    ! file_has_path_hash "$FIX/esp/EFI/Linux/other.efi" || fail_test "another file read as hashed under ${spelling}"
  done
  # The path counts under whatever resource the entry names (C1): which
  # volume the firmware resolves guid() or fslabel() to is not known here, so
  # the file the entry may mean is not signed on a guess.
  for spelling in 'guid(0a1b2c3d-1111-2222-3333-444455556666):/EFI/Linux/omarchy_linux.efi' 'uuid(0A1B2C3D-1111-2222-3333-444455556666):/EFI/Linux/omarchy_linux.efi' 'fslabel(ESP):/EFI/Linux/omarchy_linux.efi' 'fslabel(a):/b):/EFI/Linux/omarchy_linux.efi' 'boot(1):/EFI/Linux/omarchy_linux.efi' 'hdd(0:1):/EFI/Linux/omarchy_linux.efi' '/EFI/Linux/omarchy_linux.efi'; do
    write_limine_conf unhashed
    printf '\n/Other\n    protocol: efi\n    path: %s#%s\n' "$spelling" "$(b2sum <"$file" | cut -d' ' -f1)" >>"$FIX/esp/limine.conf"
    file_has_path_hash "$file" || fail_test "the guard missed the resource in ${spelling}"
    ! file_has_path_hash "$FIX/esp/EFI/Linux/other.efi" || fail_test "another file read as hashed under ${spelling}"
  done
}

# No limine.conf names nothing; one that cannot be read answers nothing, and
# the pass signs nothing on that.
unreadable_limine_conf_is_no_answer_about_hashes() {
  local file=$FIX/esp/EFI/Linux/omarchy_linux.efi status=0
  rm "$FIX/esp/limine.conf"
  file_has_path_hash "$file" || status=$?
  (( status == 1 )) || fail_test "without a limine.conf the file answered ${status}, not 1"
  write_limine_conf hashed
  # Root reads a file whatever its mode; the pass's own use is proved in the sign suite.
  (( EUID != 0 )) || return 0
  chmod 000 "$FIX/esp/limine.conf"
  status=0
  file_has_path_hash "$file" 2>/dev/null || status=$?
  chmod 644 "$FIX/esp/limine.conf"
  (( status == 2 )) || fail_test "a limine.conf that cannot be read answered ${status}, not 2"
}

# What remove asks of limine-mkinitcpio is proved by the OS entries upstream
# writes, marked by their order-priority comment after the machine id (C2):
# each of their paths carries a hash. A hash anywhere else proves nothing.
remove_proof_counts_only_upstreams_os_entries() {
  write_limine_conf hashed
  generated_os_entries_carry_hashes || fail_test "the hashed OS entry was not proved"
  # Limine strips leading blanks, so an indented top-level entry of the user's
  # is its own entry, not part of the OS entry above it.
  printf '\n  /Custom\n    protocol: efi\n    path: boot():/EFI/Linux/custom.efi\n' >>"$FIX/esp/limine.conf"
  generated_os_entries_carry_hashes || fail_test "an indented entry of the user's was counted as the OS entry's"
  write_limine_conf unhashed
  ! generated_os_entries_carry_hashes || fail_test "an unhashed OS entry passed"
  printf '\n/Custom\n    protocol: efi\n    path: boot():/EFI/Linux/custom.efi#%0128d\n' 0 >>"$FIX/esp/limine.conf"
  os_entries_carry_hashes || fail_test "the custom entry's hash was not seen"
  ! generated_os_entries_carry_hashes || fail_test "a custom entry's hash stood in for Omarchy's"
  # The real shape: two kernels under one OS entry, the snapshot block nested
  # under it with upstream's hashes, then upstream's EFI entries.
  write_omarchy_limine_conf 2
  [[ $(list_generated_os_paths | wc -l) == 2 ]] || fail_test "generated paths: $(list_generated_os_paths)"
  ! generated_os_entries_carry_hashes || fail_test "snapshot hashes stood in for the kernels'"
  sed -i "s|^\(  path: boot():/EFI/Linux/omarchy_linux[^#]*\)\$|\1#$(printf '0%.0s' {1..128})|" "$FIX/esp/limine.conf"
  generated_os_entries_carry_hashes || fail_test "two hashed kernels were not proved: $(list_generated_os_paths)"
  write_omarchy_limine_template
  ! generated_os_entries_carry_hashes || fail_test "the template, without an OS entry, passed"
  rm "$FIX/esp/limine.conf"
  ! generated_os_entries_carry_hashes || fail_test "no limine.conf passed"
}

run_case settings-round-trip-from-stock settings_round_trip_from_stock
run_case original-values-come-back-verbatim original_values_come_back_verbatim
run_case failed-write-keeps-the-settings-file failed_write_keeps_the_settings_file
run_case originals-are-recorded-once originals_are_recorded_once
run_case settings-file-changed-meanwhile-is-not-overwritten settings_file_changed_meanwhile_is_not_overwritten
run_case malformed-originals-record-is-no-answer malformed_originals_record_is_no_answer
run_case fallback-is-not-added-without-room fallback_is_not_added_without_room
run_case stale-os-hashes-are-found stale_os_hashes_are_found
run_case snapshot-hashes-are-upstreams snapshot_hashes_are_upstreams
run_case primary-is-sealed-signed-and-reproved primary_is_sealed_signed_and_reproved
run_case failed-rebuild-keeps-the-old-loader failed_rebuild_keeps_the_old_loader
run_case rebuild-uses-the-loader-upstream-deployed rebuild_uses_the_loader_upstream_deployed
run_case corrupt-backup-publishes-nothing corrupt_backup_publishes_nothing
run_case unwritten-seal-or-signature-publishes-nothing unwritten_seal_or_signature_publishes_nothing
run_case stale-staging-files-are-swept stale_staging_files_are_swept
run_case change-during-the-rebuild-is-caught change_during_the_rebuild_is_caught
run_case restless-limine-conf-is-not-reported-sealed restless_limine_conf_is_not_reported_sealed
run_case seal-classes-follow-the-slot seal_classes_follow_the_slot
run_case fallback-states fallback_states
run_case watch-units-are-template-instances watch_units_are_template_instances
run_case shadowing-configs-are-listed shadowing_configs_are_listed
run_case hashed-paths-are-resolved-before-they-compare hashed_paths_are_resolved_before_they_compare
run_case unreadable-limine-conf-is-no-answer-about-hashes unreadable_limine_conf_is_no_answer_about_hashes
run_case remove-proof-counts-only-upstreams-os-entries remove_proof_counts_only_upstreams_os_entries
finish_suite
