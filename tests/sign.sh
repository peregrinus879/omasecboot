#!/bin/bash
# Converge and verify: one idempotent pass, what it never touches, and how it
# reports a pass that could not finish.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init sign

# Keys exist and the OS entry carries no hash, as after setup's regeneration.
prepared_machine() {
  : >"$FIX/sbctl/keys"
  write_limine_conf unhashed
  # shellcheck disable=SC2034 # The output helpers read it.
  QUIET=true
}

converges_and_is_idempotent() {
  prepared_machine
  sign_boot_files || fail_test "first pass"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "primary"
  file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "the unsigned UKI was not signed"
  [[ $(effective_setting ENABLE_VERIFICATION) == no && $(effective_setting ENABLE_ENROLL_LIMINE_CONFIG) == yes ]] || fail_test "settings"
  [[ $(enabled_watchers) == 2 ]] || fail_test "the watchers were not enabled: $(ls "$FIX/systemd")"
  [[ ! -e $(attention_marker) ]] || fail_test "a clean pass left the marker"
  : >"$FIX/run/calls"
  sign_boot_files || fail_test "second pass"
  ! grep -qE '^(sbctl sign|limine enroll-config|systemctl enable)' "$FIX/run/calls" || fail_test "a second pass changed something: $(<"$FIX/run/calls")"
}

# The pass runs inside package transactions: a history file is neither
# changed nor read, whatever its name's case and whatever limine.conf says
# about it (spec D1 and the hook's time budget).
# Windows' own boot files and the 32-bit loader are no file of this tool's
# (spec section 4): never listed, never signed, never handed to a tool.
other_systems_files_are_never_touched() {
  local windows=$FIX/esp/EFI/Microsoft/Boot/bootmgfw.efi odd=$FIX/esp/efi/MICROSOFT/Recovery/x.EFI ia32=$FIX/esp/EFI/BOOT/BOOTIA32.EFI file
  prepared_machine
  mkdir -p "${windows%/*}" "${odd%/*}"
  for file in "$windows" "$odd" "$ia32"; do printf 'another system' >"$file"; done
  [[ $(list_signable_files) != *[Mm][Ii][Cc][Rr][Oo]* && $(list_signable_files) != *BOOTIA32* ]] || fail_test "listed as signable: $(list_signable_files)"
  sign_boot_files || fail_test "pass"
  for file in "$windows" "$odd" "$ia32"; do
    [[ $(<"$file") == 'another system' ]] || fail_test "${file} was changed"
  done
  ! grep -qi -e microsoft -e bootia32 "$FIX/run/calls" || fail_test "a tool was run on another system's file: $(grep -i -e microsoft -e bootia32 "$FIX/run/calls")"
}

history_files_are_never_touched() {
  local history=$FIX/esp/machine/limine_history/old.efi_sha256_abc
  local odd=$FIX/esp/machine/LIMINE_HISTORY/OLD.EFI_SHA256_DEF
  prepared_machine
  mkdir -p "${history%/*}" "${odd%/*}"
  printf 'unsigned snapshot image' | tee "$history" "$odd" "$FIX/run/history-before" >/dev/null
  printf '  //snapshot 7\n    protocol: efi\n    path: boot():/machine/limine_history/old.efi_sha256_abc#%0128d\n' 0 >>"$FIX/esp/limine.conf"
  sign_boot_files || fail_test "pass"
  { cmp -s "$history" "$FIX/run/history-before" && cmp -s "$odd" "$FIX/run/history-before"; } || fail_test "a history file was modified"
  ! grep -qiE 'limine_history' "$FIX/run/calls" || fail_test "a tool was run on a history file: $(grep -i limine_history "$FIX/run/calls")"
  ! grep -q '^sbctl list-files' "$FIX/run/calls" || fail_test "the pass made sbctl read every tracked file"
}

fallback_is_returned_to_raw() {
  local fallback
  prepared_machine
  fallback=$(fallback_loader_path)
  sbctl sign "$fallback"
  sign_boot_files || fail_test "pass"
  cmp -s "$fallback" "$FIX/share/BOOTX64.EFI" || fail_test "the signed fallback was not restored to raw"
}

# Rows from an earlier version of this tool: sbctl's pacman hook would sign
# these files in place. Rows outside the ESP are the user's.
harmful_rows_are_found_and_removed() {
  local history=$FIX/esp/machine/limine_history/old.efi_sha256_abc uki=$FIX/esp/EFI/Linux/omarchy_linux.efi
  prepared_machine
  mkdir -p "${history%/*}" "$FIX/elsewhere" && : >"$history" && : >"$FIX/elsewhere/keep.efi"
  printf '%s\n' "$history" "$(fallback_loader_path)" "$uki" "$FIX/elsewhere/keep.efi" >"$FIX/sbctl/files"
  [[ $(list_harmful_sbctl_rows) == "$history"$'\n'"$(fallback_loader_path)" ]] || fail_test "listed: $(list_harmful_sbctl_rows)"
  remove_harmful_sbctl_rows || fail_test "remove"
  [[ $(<"$FIX/sbctl/files") == "$uki"$'\n'"$FIX/elsewhere/keep.efi" ]] || fail_test "rows left: $(<"$FIX/sbctl/files")"
  : >"$FIX/run/sbctl-list-fails"
  ! remove_harmful_sbctl_rows 2>/dev/null || fail_test "an unreadable list read as clean"
}

foreign_fallback_is_left_alone() {
  prepared_machine
  printf 'someone else' >"$(fallback_loader_path)"
  sign_boot_files || fail_test "pass"
  [[ $(<"$(fallback_loader_path)") == 'someone else' ]] || fail_test "a foreign BOOTX64.EFI was replaced"
}

failure_leaves_the_marker() {
  local output
  prepared_machine
  : >"$FIX/run/sbctl-sign-fails"
  output=$(sign_boot_files 2>&1) && fail_test "a failed pass reported success"
  [[ -s $(attention_marker) ]] || fail_test "no marker after a failed pass"
  # A loader that is not sealed over limine.conf does not start at all (C1),
  # which is a different warning from an unsigned file.
  [[ $output == *'Do not reboot, with Secure Boot on or off'* ]] || fail_test "an unsealed loader was reported like any failure: ${output}"
  rm "$FIX/run/sbctl-sign-fails"
  sign_boot_files >/dev/null 2>&1 || fail_test "recovery pass"
  printf 'an unsigned arrival' >"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  : >"$FIX/run/sbctl-sign-fails"
  output=$(sign_boot_files 2>&1) && fail_test "a failed signing reported success"
  [[ $output == *'Do not reboot with Secure Boot on'* ]] || fail_test "report: ${output}"
  rm "$FIX/run/sbctl-sign-fails"
  # The watchers' pass looks at the seal alone and cannot vouch for the rest.
  sign_boot_files seal-only || fail_test "seal-only pass"
  [[ -s $(attention_marker) ]] || fail_test "a seal-only pass cleared what a full pass had found"
  sign_boot_files && [[ ! -e $(attention_marker) ]] || fail_test "a later clean pass kept the marker"
  set_attention 'the loader could not be sealed on a day'
  sign_boot_files seal-only && [[ ! -e $(attention_marker) ]] || fail_test "a clean seal-only pass kept a marker about the seal"
}

# What cannot be proved is a failure, never a pass: sbctl answers null for a
# file it may not read (C4), and only limine-mkinitcpio can rewrite a stale
# hash on an OS entry.
unproved_state_fails_the_pass() {
  prepared_machine
  : >"$FIX/run/sbctl-cannot-read"
  ! sign_boot_files 2>/dev/null || fail_test "an unreadable signature state passed"
  rm "$FIX/run/sbctl-cannot-read"
  write_limine_conf hashed
  printf 'changed' >>"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  ! sign_boot_files 2>/dev/null || fail_test "a stale OS hash passed"
  [[ -s $(attention_marker) ]] || fail_test "no marker"
}

# sbctl rewrites a file in place, which a full ESP would tear (C4).
full_esp_is_not_written_to() {
  local before
  prepared_machine
  sbctl sign "$(fallback_loader_path)"
  : >"$FIX/run/calls"
  before=$(find "$FIX/esp" -type f -exec sha256sum {} + | sort)
  free_bytes() { printf '4096\n'; }
  ! sign_boot_files 2>/dev/null || fail_test "a pass on a full ESP reported success"
  ! grep -qE '^(sbctl sign|limine enroll-config)' "$FIX/run/calls" || fail_test "a tool was run to write: $(<"$FIX/run/calls")"
  [[ $(find "$FIX/esp" -type f -exec sha256sum {} + | sort) == "$before" ]] || fail_test "a full ESP was written to"
}

busy_lock_writes_no_marker() {
  local rc=0
  prepared_machine
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  sign_boot_files 2>/dev/null || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "busy returned ${rc}"
  [[ ! -e $(attention_marker) ]] || fail_test "a busy lock wrote the marker"
}

restore_in_progress_is_left_alone() {
  prepared_machine
  : >"$(restore_marker_path)"
  : >"$FIX/run/calls"
  sign_boot_files || fail_test "status"
  [[ ! -s $FIX/run/calls ]] || fail_test "sign worked during a restore"
}

seal_only_reseals_and_stops() {
  prepared_machine
  sign_boot_files || fail_test "prepare"
  printf 'unsigned again' >"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  printf 'timeout: 1\n' >>"$FIX/esp/limine.conf"
  sign_boot_files seal-only || fail_test "seal-only pass"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader was not re-sealed"
  ! file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "seal-only signed a UKI"
  : >"$FIX/run/esp-unmounted"
  sign_boot_files seal-only || fail_test "an unmounted ESP must be a quiet no-op for the watchers"
}

# Omarchy's installer leaves a pacman hook that copies the raw executable over
# the primary after upstream has sealed and signed it (C7). The loader's
# watcher fires at some point of that transaction; its pass must judge what
# the last hook left behind.
seal_only_waits_for_pacman_to_finish() {
  prepared_machine
  sign_boot_files || fail_test "prepare"
  : >"$(pacman_lock_path)"
  : >"$FIX/run/pacman-is-running"
  (
    sleep 1
    cp "$FIX/share/BOOTX64.EFI" "$(primary_loader_path)"
    rm "$(pacman_lock_path)" "$FIX/run/pacman-is-running"
  ) &
  sign_boot_files seal-only || fail_test "seal-only pass"
  wait
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the pass judged the loader before pacman's last hook replaced it"

  # A crashed pacman's lock is nobody's: a limine.conf edit is sealed at once.
  : >"$(pacman_lock_path)"
  printf 'timeout: 2\n' >>"$FIX/esp/limine.conf"
  SECONDS=0
  sign_boot_files seal-only || fail_test "seal-only pass under a stale lock"
  (( SECONDS < 3 )) || fail_test "the pass waited ${SECONDS}s for a lock without a pacman"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "not sealed under a stale lock"

  # A pacman that never ends is waited for no longer than the bound, which is
  # five seconds on the fixture. The pass runs as a process, so a wait without
  # a bound fails this case instead of hanging it.
  : >"$FIX/run/pacman-is-running"
  : >"$(enabled_marker)"
  printf 'timeout: 3\n' >>"$FIX/esp/limine.conf"
  start_cli sign --quiet --seal-only
  for _ in {1..12}; do
    kill -0 "$CLI_PID" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$CLI_PID" 2>/dev/null; then
    kill -KILL "$CLI_PID"
    fail_test "the wait for pacman has no bound"
  fi
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "not sealed after the bound: $(<"$FIX/run/output")"
  # The hook's pass runs inside the transaction and never waits for it.
  SECONDS=0
  pacman_wait() { printf '30\n'; }
  sign_boot_files || fail_test "full pass"
  (( SECONDS < 3 )) || fail_test "the full pass waited for pacman"
}

run_case converges-and-is-idempotent converges_and_is_idempotent
run_case history-files-are-never-touched history_files_are_never_touched
run_case other-systems-files-are-never-touched other_systems_files_are_never_touched
run_case fallback-is-returned-to-raw fallback_is_returned_to_raw
run_case harmful-rows-are-found-and-removed harmful_rows_are_found_and_removed
run_case unproved-state-fails-the-pass unproved_state_fails_the_pass
run_case foreign-fallback-is-left-alone foreign_fallback_is_left_alone
run_case failure-leaves-the-marker failure_leaves_the_marker
run_case full-esp-is-not-written-to full_esp_is_not_written_to
run_case busy-lock-writes-no-marker busy_lock_writes_no_marker
run_case restore-in-progress-is-left-alone restore_in_progress_is_left_alone
run_case seal-only-reseals-and-stops seal_only_reseals_and_stops
run_case seal-only-waits-for-pacman-to-finish seal_only_waits_for_pacman_to_finish
finish_suite
