#!/bin/bash
# The report: what it counts as a problem, which next step it names and its
# exit status.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init status

set_up_machine() {
  : >"$FIX/sbctl/keys"
  write_limine_conf unhashed
  { save_settings_originals && QUIET=true sign_boot_files && : >"$(enabled_marker)"; } || fail_test "fixture setup"
}

not_set_up_is_not_a_problem() {
  local output
  output=$(show_status 2>&1) || fail_test "status failed on a machine that was never set up"
  [[ $output == *'sudo omasecboot setup'* ]] || fail_test "no next step: ${output}"
}

clean_machine_names_the_firmware_step() {
  local output
  set_up_machine
  output=$(show_status 2>&1) || fail_test "a clean machine reported problems: ${output}"
  [[ $output == *'rescue loader'* && $output == *'not enrolled in the firmware yet'* ]] || fail_test "report: ${output}"
  [[ $output == *'Next: sudo omasecboot setup for the firmware step'* ]] || fail_test "next step: ${output}"
}

# The firmware half, as status sees it after each step of setup.
enrollment_state_chooses_the_next_step() {
  local output
  set_up_machine
  delete_platform_key
  { read_enrollment_plan && enroll_local_keys append; } >/dev/null || fail_test "fixture enrollment"
  output=$(show_status 2>&1) || fail_test "a freshly enrolled machine reported problems: ${output}"
  [[ $output == *'Next: reboot, then run'* ]] || fail_test "the enrollment's own boot: ${output}"
  set_mode_variable SetupMode 0
  output=$(show_status 2>&1) || fail_test "an enrolled machine reported problems: ${output}"
  [[ $output == *'Your keys are enrolled in the firmware'* && $output == *'Next: turn Secure Boot on'* ]] || fail_test "report: ${output}"
  set_mode_variable SecureBoot 1
  output=$(show_status 2>&1) || fail_test "a complete machine reported problems: ${output}"
  [[ $output == *'Secure Boot is on'* && $output == *'Nothing to do'* ]] || fail_test "report: ${output}"

  # A firmware update or a CMOS reset put the factory keys back.
  write_key_variable PK "$(x509_list "$OEM_OWNER" 'OEM platform key' | base64 -w0)"
  output=$(show_status 2>&1) && fail_test "Secure Boot on without the local keys passed"
  [[ $output == *'does not hold your keys'* && $output == *'Next: resolve what is marked above'* ]] || fail_test "report: ${output}"
  : >"$FIX/run/sbctl-owner-changed"
  output=$(show_status 2>&1) && fail_test "unidentifiable certificates passed"
  [[ $output == *'which certificates are yours'* ]] || fail_test "report: ${output}"
}

problems_set_exit_status() {
  local output
  set_up_machine
  printf 'new unsigned uki' >"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  output=$(show_status 2>&1) && fail_test "an unsigned UKI was not a problem"
  [[ $output == *"Not signed: $FIX/esp/EFI/Linux/omarchy_linux.efi"* ]] || fail_test "report: ${output}"
  [[ $output == *'Next: sudo omasecboot sign'* && $output == *'Do not reboot with Secure Boot on'* ]] || fail_test "next step: ${output}"
}

# Each of these is something "sign" repairs.
sign_repairs_these() {
  local output
  set_up_machine
  sbctl sign "$(fallback_loader_path)"
  # One watcher of the two is not enough.
  rm "$FIX/systemd/$(watch_units | tail -n 1)"
  sed -i 's/^ENABLE_VERIFICATION=no$/ENABLE_VERIFICATION=yes/' "$FIX/etc/default-limine"
  printf 'timeout: 9\n' >>"$FIX/esp/limine.conf"
  output=$(show_status 2>&1) && fail_test "four problems passed"
  [[ $output == *'fallback loader is signed or sealed'* && $output == *'are not both active'* &&
    $output == *'ENABLE_VERIFICATION=no is not in effect'* && $output == *'loader is not sealed'* ]] || fail_test "report: ${output}"
  [[ $output == *'Next: sudo omasecboot sign'* ]] || fail_test "next step: ${output}"
  # A loader that is not sealed over limine.conf does not start at all (C1).
  [[ $output == *'Do not reboot, with Secure Boot on or off'* ]] || fail_test "the closing warning is the weaker one: ${output}"
  QUIET=true sign_boot_files || fail_test "sign"
  show_status >/dev/null 2>&1 || fail_test "sign did not repair what status told it to"
}

# Only limine-mkinitcpio rewrites a path hash, and setup runs it; "sign" would
# be the wrong advice.
stale_os_hash_needs_setup() {
  local output
  set_up_machine
  write_limine_conf hashed
  printf 'changed' >>"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  sbctl sign "$FIX/esp/EFI/Linux/omarchy_linux.efi"
  QUIET=true ensure_primary_loader || fail_test "fixture reseal"
  output=$(show_status 2>&1) && fail_test "a stale OS hash passed"
  [[ $output == *'Stale path hash in limine.conf line 7 (entry: linux)'* ]] || fail_test "stale hash line: ${output}"
  [[ $output == *'Next: sudo omasecboot setup'* ]] || fail_test "next step: ${output}"
}

# Only setup removes sbctl rows: listing them makes sbctl read every tracked
# file, which the hook's pass must not do.
harmful_sbctl_rows_need_setup() {
  local output history=$FIX/esp/machine/limine_history/old.efi_sha256_abc
  set_up_machine
  mkdir -p "${history%/*}" && sbctl sign "$FIX/esp/EFI/Linux/omarchy_linux.efi" && cp "$FIX/esp/EFI/Linux/omarchy_linux.efi" "$history"
  printf '%s\n' "$history" >"$FIX/sbctl/files"
  output=$(show_status 2>&1) && fail_test "a harmful sbctl row passed"
  [[ $output == *"sbctl would sign this file in place at the next update: ${history}"* ]] || fail_test "harmful row: ${output}"
  [[ $output == *'Next: sudo omasecboot setup'* ]] || fail_test "next step: ${output}"
}

# Nothing this tool runs repairs these, and the report must not pretend so.
blocking_problems_name_no_repair_command() {
  local output
  set_up_machine
  rm "$FIX/sbctl/keys" "$FIX/bin/limine-hook"
  output=$(show_status 2>&1) && fail_test "lost keys and a missing hook passed"
  [[ $output == *'sbctl has no signing keys'* && $output == *'Limine hook is missing'* ]] || fail_test "report: ${output}"
  [[ $output == *'Next: resolve what is marked above'* ]] || fail_test "next step: ${output}"

  : >"$FIX/run/esp-unmounted"
  output=$(show_status 2>&1) && fail_test "an unmounted ESP passed"
  [[ $output == *'EFI system partition is not mounted'* && $output != *'loader is not sealed'* ]] || fail_test "report: ${output}"
}

# What could not be read is not something "sign" repairs, and the report must
# not send the user around in circles.
unknown_states_block() {
  local output
  set_up_machine
  : >"$FIX/run/sbctl-cannot-read"
  output=$(show_status 2>&1) && fail_test "an unreadable signature state passed"
  [[ $output == *'could not tell whether this file is signed'* && $output == *'Next: resolve what is marked above'* ]] || fail_test "report: ${output}"
  rm "$FIX/run/sbctl-cannot-read"
  : >"$FIX/run/sbctl-list-fails"
  output=$(show_status 2>&1) && fail_test "an unreadable sbctl list passed"
  [[ $output == *"Could not read sbctl's file list"* && $output == *'Next: resolve what is marked above'* ]] || fail_test "report: ${output}"
}

unreadable_firmware_is_a_problem() {
  local output
  rm "$FIX/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  output=$(show_status 2>&1) && fail_test "an unreadable SecureBoot variable passed"
  [[ $output == *"Could not read the firmware's Secure Boot variables"* ]] || fail_test "report: ${output}"
}

marker_and_leftovers_are_problems() {
  local output
  set_up_machine
  set_attention "hook failed"
  mkdir -p "$FIX/old/hooks"
  ln -s /nonexistent "$FIX/old/hooks/zzz-omasecboot.hook"
  output=$(show_status 2>&1) && fail_test "marker and leftovers were not problems"
  [[ $output == *'hook failed'* && $output == *'/old/hooks/zzz-omasecboot.hook'* ]] || fail_test "report: ${output}"
  [[ $output != *'/old/omasecboot'* ]] || fail_test "an absent file was reported as a leftover"
}

# Before setup is where a leftover matters most: setup refuses beside it, and
# the report is what tells the user why.
leftovers_are_named_before_setup() {
  local output
  mkdir -p "$FIX/old/hooks"
  ln -s /nonexistent "$FIX/old/hooks/zzz-omasecboot.hook"
  output=$(show_status 2>&1) && fail_test "status passed over a leftover on a machine that is not set up"
  [[ $output == *'is not set up on this machine'* && $output == *'/old/hooks/zzz-omasecboot.hook'* ]] || fail_test "report: ${output}"
  rm "$FIX/old/hooks/zzz-omasecboot.hook"
  output=$(show_status 2>&1) || fail_test "a stock machine does not pass: ${output}"
  [[ $output == *'Next:'*'omasecboot setup'* ]] || fail_test "no next step on a stock machine: ${output}"
}

old_snapshots_are_a_note_not_a_problem() {
  local output history=$FIX/esp/machine/limine_history/old.efi_sha256_abc
  set_up_machine
  mkdir -p "${history%/*}" && printf 'unsigned snapshot image' >"$history"
  output=$(show_status 2>&1) || fail_test "an old snapshot image was a problem: ${output}"
  [[ $output == *'1 snapshot image(s) predate'* ]] || fail_test "no note: ${output}"
}

run_case not-set-up-is-not-a-problem not_set_up_is_not_a_problem
run_case clean-machine-names-the-firmware-step clean_machine_names_the_firmware_step
run_case enrollment-state-chooses-the-next-step enrollment_state_chooses_the_next_step
run_case problems-set-exit-status problems_set_exit_status
run_case sign-repairs-these sign_repairs_these
run_case stale-os-hash-needs-setup stale_os_hash_needs_setup
run_case harmful-sbctl-rows-need-setup harmful_sbctl_rows_need_setup
run_case blocking-problems-name-no-repair-command blocking_problems_name_no_repair_command
run_case unknown-states-block unknown_states_block
run_case unreadable-firmware-is-a-problem unreadable_firmware_is_a_problem
run_case marker-and-leftovers-are-problems marker_and_leftovers_are_problems
run_case leftovers-are-named-before-setup leftovers_are_named_before_setup
run_case old-snapshots-are-a-note-not-a-problem old_snapshots_are_a_note_not_a_problem
finish_suite
