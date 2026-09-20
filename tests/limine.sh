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

originals_are_recorded_once() {
  { save_settings_originals && apply_managed_settings; } || fail_test "apply"
  save_settings_originals || fail_test "second save"
  grep -q $'^ENABLE_VERIFICATION\tabsent$' "$(settings_originals_file)" || fail_test "a second save overwrote the originals"
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

# Snapshot entries carry upstream's hashes of history files (D1): they are
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
  local before=$FIX/run/primary-before
  : >"$FIX/sbctl/keys"
  cp "$(primary_loader_path)" "$before"
  printf 'not a tar archive' >"$(loader_backup_path)"
  ! ensure_primary_loader 2>/dev/null || fail_test "a corrupt backup produced a loader"
  cmp -s "$(primary_loader_path)" "$before" || fail_test "the primary changed"
  [[ -z $(find "$FIX/esp/EFI/limine" -name '.omasecboot-loader.*') ]] || fail_test "a staging file was left on the ESP"
}

# Left behind by a pass that was killed; ESP space is scarce.
stale_staging_files_are_swept() {
  : >"$FIX/esp/EFI/limine/.omasecboot-loader.abc123"
  : >"$FIX/esp/EFI/BOOT/.omasecboot-loader.def456"
  remove_stale_staging || fail_test "sweep"
  [[ -z $(find "$FIX/esp" -name '.omasecboot-loader.*') ]] || fail_test "staging files remain"
  [[ -e $(primary_loader_path) && -e $(fallback_loader_path) ]] || fail_test "the sweep removed a loader"
}

# systemd merges changes that arrive while the watcher's service runs (C5).
change_during_the_rebuild_is_caught() {
  : >"$FIX/sbctl/keys"
  : >"$FIX/run/config-changes-during-enroll"
  converge_primary_loader || fail_test "a change during the first round failed the pass"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader carries the checksum from before the change"
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
  limine enroll-config "$fallback" "$(config_checksum)"
  [[ $(fallback_state) == altered ]] || fail_test "a sealed fallback is not altered"
  write_raw_loader "$fallback" 12.5.2
  [[ $(fallback_state) == raw ]] || fail_test "an older raw Limine copy is upstream's business"
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

run_case settings-round-trip-from-stock settings_round_trip_from_stock
run_case original-values-come-back-verbatim original_values_come_back_verbatim
run_case failed-write-keeps-the-settings-file failed_write_keeps_the_settings_file
run_case originals-are-recorded-once originals_are_recorded_once
run_case stale-os-hashes-are-found stale_os_hashes_are_found
run_case snapshot-hashes-are-upstreams snapshot_hashes_are_upstreams
run_case primary-is-sealed-signed-and-reproved primary_is_sealed_signed_and_reproved
run_case failed-rebuild-keeps-the-old-loader failed_rebuild_keeps_the_old_loader
run_case rebuild-uses-the-loader-upstream-deployed rebuild_uses_the_loader_upstream_deployed
run_case corrupt-backup-publishes-nothing corrupt_backup_publishes_nothing
run_case stale-staging-files-are-swept stale_staging_files_are_swept
run_case change-during-the-rebuild-is-caught change_during_the_rebuild_is_caught
run_case fallback-states fallback_states
run_case watch-units-are-template-instances watch_units_are_template_instances
run_case shadowing-configs-are-listed shadowing_configs_are_listed
finish_suite
