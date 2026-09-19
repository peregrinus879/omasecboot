#!/bin/bash
# OmaSecBoot: converge and verify. One idempotent pass that people, the Limine
# hook and the limine.conf watcher all run; an interrupted pass is finished by
# the next one.

# Rows that make sbctl's pacman hook sign a history file or the fallback loader
# in place. OmaSecBoot adds no rows; these come from an earlier version of this
# tool or from the user. Listing them makes sbctl read every tracked file, so
# this belongs to setup and status, never to the hook's pass.
list_harmful_sbctl_rows() {
  local esp tracked file
  esp=$(esp_path) || return 1
  tracked=$(sbctl_tracked_files) || return 1
  while IFS= read -r file; do
    [[ $file == "${esp}/"* ]] || continue
    if is_history_file "$file" || is_fallback_loader "$file"; then
      printf '%s\n' "$file"
    fi
  done <<<"$tracked"
}

remove_harmful_sbctl_rows() {
  local rows file
  rows=$(list_harmful_sbctl_rows) || {
    warn "Could not read sbctl's file list"
    return 1
  }
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    qnote "Removing ${file} from sbctl's list, so sbctl never signs it in place"
    run_sbctl remove-file "$file" >/dev/null || return 1
  done <<<"$rows"
}

# UKIs normally arrive signed by sbctl's mkinitcpio hook. One that did not is
# signed where it is: staging a copy of a 267 MB image can exhaust a small ESP.
# sbctl truncates the file and writes it back with the signature (C4), so
# room is checked first. Every file is read once, and a pass that returns 0
# has proved each of them signed.
sign_unsigned_arrivals() {
  local files file primary state failed=0
  files=$(list_signable_files) || return 1
  primary=$(primary_loader_path)
  while IFS= read -r file; do
    [[ -n $file && $file != "$primary" ]] || continue
    state=0
    signature_state "$file" || state=$?
    case $state in
      0) ;;
      1)
        qact "Signing ${file}"
        { esp_has_room && run_visible run_sbctl sign "$file" && durable_sync "$file" && signature_state "$file"; } || {
          fail "Could not sign ${file}"
          failed=1
        }
        ;;
      *)
        fail "Could not read the signature state of ${file}"
        failed=1
        ;;
    esac
  done <<<"$files"
  return "$failed"
}

# A stale hash stops its OS entry once Secure Boot is on, and only
# limine-mkinitcpio can rewrite it, which setup runs.
check_os_path_hashes() {
  local stale line failed=0
  stale=$(list_stale_os_hashes) || return 1
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    fail "Stale path hash in limine.conf, line ${line}"
    failed=1
  done <<<"$stale"
  return "$failed"
}

# sign_boot_files [config-only]
# config-only stops after the loader proof: the watcher's job is the seal.
sign_boot_files() {
  local scope=${1:-full} rc=0 sealed=true
  if restore_in_progress; then
    qnote "A snapshot restore is running; leaving the boot files to it"
    return 0
  fi
  if ! esp_is_mounted_vfat; then
    [[ $scope != config-only ]] || return 0
    fail "The EFI system partition is not mounted"
    return 1
  fi
  boot_lock_acquire || return "$?"

  remove_stale_staging || rc=1
  apply_managed_settings || rc=1
  converge_windows_block
  converge_primary_loader || sealed=false
  if [[ $scope == full ]]; then
    if [[ $(fallback_state) == altered ]]; then
      qact "Restoring the fallback loader to upstream's raw copy (it is the rescue loader)"
      restore_raw_fallback || rc=1
    fi
    sign_unsigned_arrivals || rc=1
    check_os_path_hashes || rc=1
    watch_is_active || enable_watch || rc=1
  fi
  boot_lock_release

  if [[ $sealed == false ]]; then
    # A loader sealed over another limine.conf does not start at all (C1).
    set_attention "the loader could not be sealed on $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
    fail "The Limine loader is not sealed with the current limine.conf. Do not reboot, with Secure Boot on or off; run: sudo omasecboot status"
    return 1
  elif (( rc != 0 )); then
    set_attention "sign could not finish on $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
    fail "OmaSecBoot could not finish. Do not reboot with Secure Boot on; run: sudo omasecboot status"
    return 1
  fi
  clear_attention
  qpass "Boot files are sealed and signed"
}
