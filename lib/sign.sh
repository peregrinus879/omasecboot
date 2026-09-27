#!/bin/bash
# OmaSecBoot: converge and verify. One idempotent pass that people, the Limine
# hook and the watchers all run; an interrupted pass is finished by the next
# one.

# Rows that make sbctl's pacman hook sign a history file, the fallback loader
# or any Limine executable in place (D7): a row signs whatever stands at its
# path after every transaction, and a Limine executable there can be one that
# is not sealed, as the raw copy Omarchy's installer hook leaves over the
# primary (C6). OmaSecBoot adds no rows; these come from the user, from
# `sbctl sign -s` for example. Listing them makes sbctl read every tracked
# file, so this belongs to setup and status, never to the hook's pass.
list_harmful_sbctl_rows() {
  local esp tracked file seal
  esp=$(esp_path) || return 1
  tracked=$(sbctl_tracked_files) || return 1
  while IFS= read -r file; do
    [[ $file == "${esp}/"* ]] || continue
    # A file that cannot be read to tell counts as one: a row is never needed.
    seal=$(limine_seal "$file") || seal=unreadable
    if is_history_file "$file" || is_fallback_loader "$file" || [[ $seal != none ]]; then
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
    run_sbctl remove-file "$file" >/dev/null || {
      warn "sbctl could not remove ${file} from its list; its pacman hook would sign that file in place"
      return 1
    }
  done <<<"$rows"
  # sbctl's word that a row went is checked against its list (CONTRIBUTING).
  [[ -n $rows ]] || return 0
  rows=$(list_harmful_sbctl_rows) || {
    warn "Could not read sbctl's file list after removing rows from it"
    return 1
  }
  [[ -z $rows ]] || {
    warn "sbctl still lists files its pacman hook would sign in place: ${rows//$'\n'/, }"
    return 1
  }
}

# UKIs normally arrive signed by sbctl's mkinitcpio hook. One that did not is
# signed where it is: staging a copy of an image of a few hundred megabytes
# can exhaust a small ESP. A Limine executable that is not sealed is never
# signed (D4): signed, it would start under Secure Boot and read whatever
# limine.conf it finds without checking it, while unsigned the firmware
# refuses it, so it is left quietly and status names it. One whose seal
# cannot be told, or a file that cannot be read to tell, is not signed either,
# and fails the pass: a kernel image among them would not start.
# sbctl truncates the file and writes it back with the signature (C4), so
# room is checked first. Every file is read once, and a pass that returns 0
# has proved each of them signed.
sign_unsigned_arrivals() {
  local files file primary state seal hashed failed=0
  files=$(list_signable_files) || return 1
  primary=$(primary_loader_path)
  while IFS= read -r file; do
    # FAT names have no case: the primary is only ever replaced through the
    # staged rebuild (section 4), never signed in place.
    [[ -n $file && ${file,,} != "${primary,,}" ]] || continue
    state=0
    signature_state "$file" || state=$?
    case $state in
      0) ;;
      1)
        seal=$(limine_seal "$file") || seal=unreadable
        case $seal in
          unsealed)
            qnote "Not signing ${file}: a Limine loader that is not sealed, which the firmware refuses unsigned"
            continue
            ;;
          unsupported)
            fail "Not signing ${file}: it carries Limine's marker, and its checksum slot does not tell whether it checks limine.conf. Delete it if nothing starts from it"
            failed=1
            continue
            ;;
          unreadable)
            fail "Not signing ${file}: it cannot be read to tell whether it is a Limine loader that is not sealed. Check the ESP, then run ${BOLD}sudo omasecboot sign${NC}"
            failed=1
            continue
            ;;
        esac
        hashed=0
        file_has_path_hash "$file" || hashed=$?
        case $hashed in
          0)
            # setup regenerates the entries without hashes before anything is
            # signed. A build that failed without saying so (C2) leaves this, and
            # so does an entry written by hand; setup names the way out of both.
            fail "Not signing ${file}: limine.conf holds a path hash for it, which a signature would break. Run ${BOLD}sudo omasecboot setup${NC}"
            failed=1
            ;;
          1)
            qact "Signing ${file}"
            # A signature the ESP's sync did not confirm is said by the pass.
            # shellcheck disable=SC2015 # The assignment cannot fail.
            { esp_has_room && run_visible run_sbctl sign "$file" && { durable_sync "$file" || _esp_write_unconfirmed=true; } && signature_state "$file"; } || {
              # A kernel image is upstream's to build (section 7.3); any other
              # file is the user's.
              if [[ ${file,,} == */efi/linux/* ]]; then
                fail "Could not sign ${file}; a file that stays unsigned fails every pass, so rebuild it with ${BOLD}sudo limine-mkinitcpio${NC}, which signs it as it builds it"
              else
                fail "Could not sign ${file}; a file that stays unsigned fails every pass, so sign it by hand with sbctl or take it off the ESP"
              fi
              failed=1
            }
            ;;
          *)
            fail "Not signing ${file}: limine.conf cannot be read, so nothing shows whether it holds a path hash for it"
            failed=1
            ;;
        esac
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
# limine-mkinitcpio can rewrite it, which setup runs. A hash under a resource
# other than boot():/ names a volume only the firmware resolves (C1): it is
# said, not failed, because nothing here can prove or break it.
check_os_path_hashes() {
  local stale kind line failed=0
  stale=$(list_stale_os_hashes) || return 1
  while IFS=$'\t' read -r kind line; do
    [[ -n $line ]] || continue
    if [[ $kind == unchecked ]]; then
      qnote "Path hash in limine.conf that cannot be checked, line ${line}: the path is not under boot():/, so only the firmware can tell which volume it names"
    else
      fail "Stale path hash in limine.conf, line ${line}"
      failed=1
    fi
  done <<<"$stale"
  return "$failed"
}

# Set when a write of the pass reached the ESP without the sync confirming it.
_esp_write_unconfirmed=false

# sign_boot_files [seal-only]
# seal-only is the watchers' pass: it starts when a running pacman is done and
# stops after the loader proof, because the watchers' job is the seal.
sign_boot_files() {
  local scope=${1:-full} rc=0 sealed=true synced=true
  _esp_write_unconfirmed=false
  if restore_in_progress; then
    qnote "A snapshot restore is running; leaving the boot files to it"
    return 0
  fi
  if ! esp_is_mounted_vfat; then
    [[ $scope != seal-only ]] || return 0
    fail "The EFI system partition is not mounted"
    return 1
  fi
  [[ $scope != seal-only ]] || wait_for_pacman
  boot_lock_acquire || return "$?"
  # What was observed before the wait and the lock can have changed by now:
  # remove may have finished, a restore may have started, the ESP may be gone.
  # A pass that went on regardless would seal a loader nobody watches (D2).
  if ! is_set_up; then
    qnote "OmaSecBoot was removed while this pass waited; nothing to do"
    boot_lock_release
    return 0
  fi
  if restore_in_progress; then
    qnote "A snapshot restore started while this pass waited; leaving the boot files to it"
    boot_lock_release
    return 0
  fi
  if ! esp_is_mounted_vfat; then
    boot_lock_release
    [[ $scope != seal-only ]] || return 0
    fail "The EFI system partition is not mounted"
    return 1
  fi

  remove_stale_staging || rc=1
  apply_managed_settings || {
    fail "Could not write the managed settings to $(limine_default_config)"
    rc=1
  }
  converge_windows_entry
  # Sealed but not signed starts with Secure Boot off; not sealed never does.
  converge_primary_loader || { primary_is_sealed && rc=1; } || sealed=false
  if [[ $scope == full ]]; then
    if [[ $(fallback_state) == altered ]]; then
      qact "Restoring the fallback loader to upstream's raw copy (it is the rescue loader)"
      restore_raw_fallback || rc=1
    fi
    sign_unsigned_arrivals || rc=1
    check_os_path_hashes || rc=1
    watch_is_active || enable_watch || {
      fail "Could not enable the watchers of limine.conf and the loader (without a running systemd, as inside a chroot, the first pass after a boot enables them)"
      rc=1
    }
  fi
  # Each kind of finding is written or cleared under the lock, so a watcher's
  # pass that the renames above start cannot interleave with it: any pass
  # writes what it found and clears the seal and, once it has synced the ESP
  # itself, an unconfirmed write; only a full pass clears the rest.
  if [[ $_esp_write_unconfirmed == false ]] && durable_sync "$(esp_path)"; then
    clear_attention "$ATTENTION_SYNC"
  else
    synced=false
    set_attention "$ATTENTION_SYNC" || true
  fi
  if [[ $sealed == false ]]; then
    set_attention "$ATTENTION_SEAL" || true
  else
    clear_attention "$ATTENTION_SEAL"
  fi
  if (( rc != 0 )); then
    set_attention "$ATTENTION_PASS" || true
  elif [[ $scope == full ]]; then
    clear_attention "$ATTENTION_PASS"
  fi
  boot_lock_release

  if [[ $sealed == false ]]; then
    # A loader sealed over another limine.conf does not start at all (C1).
    fail "The Limine loader is not sealed over the current limine.conf. Do not reboot, with Secure Boot on or off; run ${BOLD}sudo omasecboot status${NC}"
    return 1
  elif [[ $synced == false ]]; then
    fail "The ESP did not confirm a write, so a restart may not find the boot files as they are now. Do not reboot, with Secure Boot on or off, until ${BOLD}sudo omasecboot sign${NC} finishes cleanly"
    return 1
  elif (( rc != 0 )); then
    fail "OmaSecBoot could not finish. Do not reboot with Secure Boot on; run ${BOLD}sudo omasecboot status${NC}"
    return 1
  fi
  qpass "Boot files are sealed and signed"
}
