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
  { save_settings_originals && QUIET=true sign_boot_files && : >"$(enabled_file)"; } || fail_test "fixture setup"
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
  [[ $output == *'Next: restart (systemctl reboot), then run'* ]] || fail_test "the enrollment's own boot: ${output}"
  set_mode_variable SetupMode 0
  output=$(show_status 2>&1) || fail_test "an enrolled machine reported problems: ${output}"
  [[ $output == *'Your keys are enrolled in the firmware'* && $output == *'Next: sudo omasecboot setup for the last step'* ]] || fail_test "report: ${output}"
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
  [[ $output == *'sbctl has no signing keys'* && $output == *'The Limine hook '*' is missing'* ]] || fail_test "report: ${output}"
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

needs_attention_is_a_problem() {
  local output
  set_up_machine
  set_attention "hook failed"
  output=$(show_status 2>&1) && fail_test "a pass that could not finish was not a problem"
  [[ $output == *'hook failed'* ]] || fail_test "report: ${output}"
}

# A stock machine passes, and the report names the command that starts.
stock_machine_is_sent_to_setup() {
  local output
  output=$(show_status 2>&1) || fail_test "a stock machine does not pass: ${output}"
  [[ $output == *'is not set up on this machine'* && $output == *'Next:'*'omasecboot setup'* ]] || fail_test "no next step on a stock machine: ${output}"
}

old_snapshots_are_a_note_not_a_problem() {
  local output history=$FIX/esp/machine/limine_history/old.efi_sha256_abc
  set_up_machine
  mkdir -p "${history%/*}" && printf 'unsigned snapshot image' >"$history"
  output=$(show_status 2>&1) || fail_test "an old snapshot image was a problem: ${output}"
  [[ $output == *'1 snapshot image(s) predate'*'snapper -c root delete'* ]] || fail_test "no note: ${output}"
}

# A loader sealed over another limine.conf does not start at all (C1); one
# that is sealed and not signed starts while Secure Boot is off. Two warnings.
sealed_but_unsigned_is_not_called_unsealed() {
  local output
  set_up_machine
  write_raw_loader "$(primary_loader_path)"
  limine enroll-config "$(primary_loader_path)" "$(config_checksum)"
  output=$(show_status 2>&1) && fail_test "an unsigned loader read as healthy"
  [[ $output == *'sealed over the current limine.conf but not signed'* && $output == *'Next: sudo omasecboot sign'* ]] || fail_test "report: ${output}"
  [[ $output != *'with Secure Boot on or off'* ]] || fail_test "an unsigned loader got the warning of an unsealed one: ${output}"
  printf 'timeout: 9\n' >>"$FIX/esp/limine.conf"
  output=$(show_status 2>&1) && fail_test "a stale seal read as healthy"
  [[ $output == *'is not sealed over the current limine.conf'*'with Secure Boot on or off'* ]] || fail_test "report: ${output}"
}

# Without an active entry for the primary loader the machine starts through
# the fallback path, which stays raw (D6) and is refused with Secure Boot on.
missing_limine_boot_entry_blocks() {
  local output
  set_up_machine
  output=$(show_status 2>&1) || fail_test "a clean machine reported problems: ${output}"
  rm "$FIX/efivars/Boot0001-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  output=$(show_status 2>&1) && fail_test "a machine without a Limine boot entry read as healthy"
  [[ $output == *'no active boot entry for the Limine loader'*'resolve what is marked above'* ]] || fail_test "report: ${output}"
  write_boot_entry 0001 active 'Limine' '\EFI\limine\limine_x64.efi'
  printf 'garbage' >"$FIX/efivars/BootOrder-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  output=$(show_status 2>&1) || fail_test "boot entries outside a broken BootOrder were not read: ${output}"
  printf 'x' >"$FIX/efivars/Boot0001-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  output=$(show_status 2>&1) && fail_test "unreadable boot entries read as healthy"
  [[ $output == *"Could not read the firmware's boot entries"* ]] || fail_test "report: ${output}"
}

# What Microsoft can still deliver to the machine, not what it boots (C9).
missing_2023_certificates_are_notes() {
  local output
  set_up_machine
  output=$(show_status 2>&1) || fail_test "a clean machine reported problems: ${output}"
  [[ $output != *'CA 2023'* ]] || fail_test "a note on a machine that holds them: ${output}"
  write_key_variable KEK "$(x509_list "$OEM_OWNER" 'OEM KEK' | base64 -w0)"
  write_key_variable db "$({ x509_list "$MICROSOFT_OWNER" 'Microsoft Windows CA'; x509_list "$OEM_OWNER" 'OEM db'; } | base64 -w0)"
  output=$(show_status 2>&1) || fail_test "a note changed the exit status: ${output}"
  [[ $output == *'KEK does not hold Microsoft Corporation KEK 2K CA 2023'* ]] || fail_test "no note on KEK: ${output}"
  [[ $output == *'db does not hold Microsoft UEFI CA 2023:'* && $output != *'Windows UEFI CA 2023'* ]] || fail_test "the note on db: ${output}"
}

# Not a problem of the boot chain, so it leaves the exit status alone.
full_esp_is_a_note() {
  local output
  set_up_machine
  output=$(show_status 2>&1) || fail_test "a clean machine reported problems: ${output}"
  [[ $output != *'MiB free'* ]] || fail_test "a note on a clean machine: ${output}"
  free_bytes() { printf '4\n'; }
  output=$(show_status 2>&1) || fail_test "a note changed the exit status: ${output}"
  [[ $output == *'less than its largest boot file'* ]] || fail_test "no note on a full ESP: ${output}"
}

# The pass stays quiet beside a snapshot restore, so the report names a restore
# lock that is there, whether the restore runs or was cut short.
restore_lock_is_said() {
  local output
  set_up_machine
  output=$(show_status 2>&1) || fail_test "a clean machine reported problems: ${output}"
  [[ $output != *'snapshot restore'* ]] || fail_test "the restore lock was reported on a clean machine: ${output}"
  : >"$(restore_lock_path)"
  output=$(show_status 2>&1) && fail_test "a present restore lock left the report clean"
  [[ $output == *'snapshot restore is running or was cut short'*'sudo rm'*'Next: sudo omasecboot sign'* ]] || fail_test "the lock, the way to remove one left behind, or the next step is missing: ${output}"
  # The next step must repair: with the lock gone, the report is clean again.
  rm "$(restore_lock_path)"
  output=$(show_status 2>&1) || fail_test "the report stayed unclean after the lock went: ${output}"
}

# Upstream never refreshes the fallback of a machine installed beside another
# system (C6); the note names the command that does.
old_rescue_loader_is_a_note() {
  local output
  set_up_machine
  output=$(show_status 2>&1) || fail_test "a clean machine reported problems: ${output}"
  [[ $output != *'another Limine build'* ]] || fail_test "a note on a clean machine: ${output}"
  write_raw_loader "$(fallback_loader_path)" 12.5.2
  output=$(show_status 2>&1) || fail_test "a note changed the exit status: ${output}"
  [[ $output == *'another Limine build than the primary loader'*'limine-install --fallback'* ]] || fail_test "no note on an old rescue loader: ${output}"
  # While upstream holds the packaged Limine back, its step refreshes nothing (C2).
  write_raw_loader "$FIX/share/BOOTX64.EFI" 13.0.0
  output=$(show_status 2>&1) || fail_test "a held-back major changed the exit status: ${output}"
  [[ $output != *'another Limine build'* ]] || fail_test "advice that upstream's step cannot follow: ${output}"
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
run_case needs-attention-is-a-problem needs_attention_is_a_problem
run_case stock-machine-is-sent-to-setup stock_machine_is_sent_to_setup
run_case old-snapshots-are-a-note-not-a-problem old_snapshots_are_a_note_not_a_problem
run_case sealed-but-unsigned-is-not-called-unsealed sealed_but_unsigned_is_not_called_unsealed
run_case missing-limine-boot-entry-blocks missing_limine_boot_entry_blocks
run_case full-esp-is-a-note full_esp_is_a_note
run_case missing-2023-certificates-are-notes missing_2023_certificates_are_notes
run_case old-rescue-loader-is-a-note old_rescue_loader_is_a_note
run_case restore-lock-is-said restore_lock_is_said
finish_suite
