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
  : >"$(enabled_file)"
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
  [[ ! -e $(attention_file) ]] || fail_test "a clean pass left needs-attention"
  # Nothing is ever registered in sbctl's file list (D7).
  [[ ! -s $FIX/sbctl/files ]] || fail_test "the pass registered files with sbctl: $(<"$FIX/sbctl/files")"
  : >"$FIX/run/calls"
  sign_boot_files || fail_test "second pass"
  ! grep -qE '^(sbctl sign|limine enroll-config|systemctl enable)' "$FIX/run/calls" || fail_test "a second pass changed something: $(<"$FIX/run/calls")"
}

# The pass runs inside package transactions: a history file is neither
# changed nor read, whatever its name's case and whatever limine.conf says
# about it (D5 and the hook's time budget).
# Windows' own boot files and the 32-bit loader are no file of this tool's
# (D4): never listed, never signed, never handed to a tool.
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

# Rows that someone registered with sbctl sign -s: sbctl's pacman hook would
# sign these files in place (D7), and a row signs whatever stands at its path,
# so every Limine executable's row is one, the primary's too. Rows outside the
# ESP are the user's.
harmful_rows_are_found_and_removed() {
  local history=$FIX/esp/machine/limine_history/old.efi_sha256_abc uki=$FIX/esp/EFI/Linux/omarchy_linux.efi
  local stray=$FIX/esp/EFI/arch-limine/BOOTX64.EFI primary rows
  prepared_machine
  primary=$(primary_loader_path)
  mkdir -p "${history%/*}" "${stray%/*}" "$FIX/elsewhere" && : >"$history" && : >"$FIX/elsewhere/keep.efi"
  cp "$FIX/share/BOOTX64.EFI" "$stray"
  printf '%s\n' "$history" "$(fallback_loader_path)" "$uki" "$FIX/elsewhere/keep.efi" "$primary" "$stray" >"$FIX/sbctl/files"
  rows=$(list_harmful_sbctl_rows)
  [[ $rows == "$history"$'\n'"$(fallback_loader_path)"$'\n'"$primary"$'\n'"$stray" ]] || fail_test "listed: ${rows}"
  remove_harmful_sbctl_rows || fail_test "remove"
  [[ $(<"$FIX/sbctl/files") == "$uki"$'\n'"$FIX/elsewhere/keep.efi" ]] || fail_test "rows left: $(<"$FIX/sbctl/files")"
  # Another system's loader at the fallback path is no Limine executable, and
  # its row is harmful all the same (D6).
  printf 'another system' >"$(fallback_loader_path)"
  printf '%s\n' "$(fallback_loader_path)" >>"$FIX/sbctl/files"
  [[ $(list_harmful_sbctl_rows) == "$(fallback_loader_path)" ]] || fail_test "a foreign fallback's row: $(list_harmful_sbctl_rows)"
  remove_harmful_sbctl_rows || fail_test "remove the foreign fallback's row"
  # A tracked file that cannot be read to tell counts as harmful: no row is
  # ever needed.
  printf '%s\n' "$uki" >"$FIX/sbctl/files"
  eval "original_$(declare -f limine_seal)"
  limine_seal() { [[ $1 != "$uki" ]] || return 1; original_limine_seal "$@"; }
  [[ $(list_harmful_sbctl_rows) == "$uki" ]] || fail_test "an unreadable tracked file: $(list_harmful_sbctl_rows)"
  eval "$(declare -f original_limine_seal | sed '1s/original_limine_seal/limine_seal/')"
  printf '' >"$FIX/sbctl/files"
  # sbctl's word that a row went is read back from its list.
  printf '%s\n' "$primary" >>"$FIX/sbctl/files"
  eval "original_$(declare -f run_sbctl)"
  run_sbctl() { [[ $1 == remove-file ]] || original_run_sbctl "$@"; }
  ! remove_harmful_sbctl_rows 2>/dev/null || fail_test "a row that stayed was taken as removed"
  unset -f run_sbctl
  eval "$(declare -f original_run_sbctl | sed '1s/original_run_sbctl/run_sbctl/')"
  : >"$FIX/run/sbctl-list-fails"
  ! remove_harmful_sbctl_rows 2>/dev/null || fail_test "an unreadable list read as clean"
}

# A Limine executable that is not sealed is never signed, wherever it stands
# (D4): signed, it would start under Secure Boot and read whatever limine.conf
# it finds without checking it, and unsigned the firmware refuses it, so the
# pass leaves it quietly. Omarchy 3 left such a copy at EFI/arch-limine. A
# sealed one of another system is signed like any other loader.
unsealed_limine_is_never_signed() {
  local stray=$FIX/esp/EFI/arch-limine/BOOTX64.EFI sealed=$FIX/esp/EFI/other/limine.efi
  prepared_machine
  mkdir -p "${stray%/*}" "${sealed%/*}"
  cp "$FIX/share/BOOTX64.EFI" "$stray"
  write_raw_loader "$sealed"
  limine enroll-config "$sealed" "$(printf 'another limine.conf' | b2sum | cut -d' ' -f1)"
  sign_boot_files || fail_test "the pass failed beside a loader it leaves unsigned"
  cmp -s "$stray" "$FIX/share/BOOTX64.EFI" || fail_test "an unsealed Limine was signed"
  file_is_fixture_signed "$sealed" || fail_test "another system's sealed Limine was not signed"
}

# A file whose checksum slot does not tell whether it checks limine.conf, or
# one that cannot be read to tell, is not signed either, and the pass says so
# and fails: a kernel image among them would not start with Secure Boot on.
untold_seal_is_not_signed_and_fails_the_pass() {
  local odd=$FIX/esp/EFI/next/BOOTX64.EFI output
  prepared_machine
  mkdir -p "${odd%/*}"
  write_loader_with_slot "$odd" "$(printf '0%.0s' {1..100})"
  cp "$odd" "$FIX/run/odd-before"
  output=$(sign_boot_files 2>&1) && fail_test "the pass passed beside a seal it cannot tell"
  [[ $output == *"Not signing ${odd}: it carries Limine's marker"* ]] || fail_test "report: ${output}"
  cmp -s "$odd" "$FIX/run/odd-before" || fail_test "a Limine whose seal cannot be told was signed"
  rm "$odd"
  sign_boot_files >/dev/null 2>&1 || fail_test "the pass after the odd file went"
  write_uki "$FIX/esp/EFI/Linux/omarchy_linux.efi" 'a new unsigned image'
  eval "original_$(declare -f limine_seal)"
  limine_seal() { [[ $1 != *omarchy_linux.efi ]] || return 1; original_limine_seal "$@"; }
  output=$(sign_boot_files 2>&1) && fail_test "the pass passed beside a file it could not read"
  [[ $output == *"Not signing $FIX/esp/EFI/Linux/omarchy_linux.efi"* ]] || fail_test "report: ${output}"
  ! file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "fixture: the image was signed"
}

foreign_fallback_is_left_alone() {
  prepared_machine
  printf 'someone else' >"$(fallback_loader_path)"
  sign_boot_files || fail_test "pass"
  [[ $(<"$(fallback_loader_path)") == 'someone else' ]] || fail_test "a foreign BOOTX64.EFI was replaced"
}

# Another system writes the fallback path in lower case (C2, C10), and vfat
# compares names without case. The fixture's filesystem does not, so only the
# name comparison is proved here: the file is neither listed nor signed.
lower_case_foreign_fallback_is_left_alone() {
  local lower=$FIX/esp/EFI/BOOT/bootx64.efi
  prepared_machine
  rm "$(fallback_loader_path)"
  printf 'another system' >"$lower"
  [[ $(list_signable_files) != *bootx64.efi* ]] || fail_test "listed as signable: $(list_signable_files)"
  sign_boot_files >/dev/null 2>&1 || :
  [[ $(<"$lower") == 'another system' ]] || fail_test "a foreign bootx64.efi was changed"
}

failure_writes_needs_attention() {
  local output
  prepared_machine
  : >"$FIX/run/sbctl-sign-fails"
  output=$(sign_boot_files 2>&1) && fail_test "a failed pass reported success"
  [[ -s $(attention_file) ]] || fail_test "no needs-attention after a failed pass"
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
  [[ -s $(attention_file) ]] || fail_test "a seal-only pass cleared what a full pass had found"
  sign_boot_files && [[ ! -e $(attention_file) ]] || fail_test "a later clean pass kept needs-attention"
  # Written under the lock, so a watcher's pass started by this pass's own
  # renames cannot interleave with it.
  eval "original_$(declare -f set_attention)"
  # shellcheck disable=SC2154 # _boot_lock belongs to lib/common.sh.
  set_attention() { [[ $_boot_lock != false ]] || : >"$FIX/run/written-unlocked"; original_set_attention "$@"; }
  printf 'timeout: 6\n' >>"$FIX/esp/limine.conf"
  : >"$FIX/run/sbctl-sign-fails"
  sign_boot_files 2>/dev/null && fail_test "a pass that could not seal the loader over a changed limine.conf passed"
  rm "$FIX/run/sbctl-sign-fails"
  [[ ! -e $FIX/run/written-unlocked ]] || fail_test "needs-attention was written after the lock was released"
  eval "$(declare -f original_set_attention | sed '1s/original_set_attention/set_attention/')"
  sign_boot_files >/dev/null 2>&1 || fail_test "the pass after the lock check"
  # A full pass's finding and the watchers' own stand side by side, and each
  # kind of pass clears only its own.
  : >"$FIX/run/sbctl-sign-fails"
  printf 'an unsigned arrival' >"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  sign_boot_files 2>/dev/null && fail_test "fixture: the full pass passed"
  printf 'timeout: 4\n' >>"$FIX/esp/limine.conf"
  sign_boot_files seal-only 2>/dev/null && fail_test "a seal-only pass passed over a limine.conf the loader is not sealed over"
  [[ $(grep -c . "$(attention_file)") == 2 ]] || fail_test "a seal-only pass replaced what a full pass had found: $(<"$(attention_file)")"
  rm "$FIX/run/sbctl-sign-fails"
  sign_boot_files seal-only || fail_test "clean seal-only pass"
  [[ $(<"$(attention_file)") == "${ATTENTION_PASS} on "* ]] || fail_test "a clean seal-only pass left: $(cat "$(attention_file)" 2>&1)"
  sign_boot_files >/dev/null && [[ ! -e $(attention_file) ]] || fail_test "a clean full pass kept: $(cat "$(attention_file)" 2>&1)"
  set_attention "$ATTENTION_SEAL"
  sign_boot_files seal-only && [[ ! -e $(attention_file) ]] || fail_test "a clean seal-only pass kept a needs-attention about the seal"
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
  [[ -s $(attention_file) ]] || fail_test "no needs-attention"
}

# A stale hash on an OS entry whose image is already signed fails the pass by
# itself, not only through the refusal to sign a hashed file (section 7.1).
stale_hash_alone_fails_the_pass() {
  local output
  prepared_machine
  sign_boot_files || fail_test "first pass"
  write_limine_conf hashed
  printf 'changed' >>"$FIX/esp/EFI/Linux/omarchy_linux.efi"
  sbctl sign "$FIX/esp/EFI/Linux/omarchy_linux.efi"
  output=$(sign_boot_files 2>&1) && fail_test "a stale OS hash passed"
  [[ $output != *'Not signing'* ]] || fail_test "the pass failed through the signing refusal: ${output}"
  [[ $output == *'Stale path hash'* ]] || fail_test "no word of the stale hash: ${output}"
}

# On an ESP that others can write the pass seals and signs nothing (fail
# closed), says what that costs and records it; once only root can write, the
# next pass does its work.
unsafe_esp_mount_writes_nothing() {
  local output before
  prepared_machine
  sign_boot_files || fail_test "first pass"
  printf '259:1 %s rw,relatime,fmask=0000,dmask=0000,codepage=437\n' "$FIX/esp" >"$FIX/run/mounts"
  printf 'timeout: 7\n' >>"$FIX/esp/limine.conf"
  write_uki "$FIX/esp/EFI/Linux/omarchy_linux.efi" 'a new unsigned image'
  before=$(find "$FIX/esp" -type f -exec b2sum {} + | sort)
  for scope in full seal-only; do
    output=$(sign_boot_files "$scope" 2>&1) && fail_test "${scope}: a pass on an unsafe ESP passed"
    [[ $output == *"The ESP must be writable by root alone, but users other than root can write to it through $FIX/esp ("*'with Secure Boot on, meanwhile leaves a machine that does not start'*'fmask=0022,dmask=0022'*"sudo umount $FIX/esp && sudo mount $FIX/esp"*'sudo omasecboot sign'* ]] || fail_test "${scope}: ${output}"
    [[ $(find "$FIX/esp" -type f -exec b2sum {} + | sort) == "$before" ]] || fail_test "${scope}: the pass wrote to an unsafe ESP"
  done
  grep -q "^${ATTENTION_PASS} on " "$(attention_file)" || fail_test "not recorded"
  printf '259:1 %s rw,relatime,fmask=0077,dmask=0077,codepage=437\n' "$FIX/esp" >"$FIX/run/mounts"
  sign_boot_files >/dev/null 2>&1 || fail_test "the pass once only root can write"
  { loader_is_sealed_and_signed "$(primary_loader_path)" && file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi"; } || fail_test "the pass did not do its work afterwards"
}

# A pass that cannot sync the ESP cannot say that its boot files are what a
# restart finds, even when it wrote nothing itself. It records an incident,
# which every later pass leaves standing and only the full pass fails on,
# until the operator acknowledges it (7.3).
unsynced_esp_is_said() {
  local output dir incident
  prepared_machine
  sign_boot_files || fail_test "first pass"
  sync_path() { [[ $1 != "$FIX/esp" ]] || return 1; }
  output=$(sign_boot_files 2>&1) && fail_test "a pass whose ESP did not sync passed"
  incident=$(esp_incident)
  [[ -n $incident && $output == *"The ESP reported a write error at ${FIX}/esp (incident ${incident%% *})"*'The ESP reported a write error, so a restart'*"(incident ${incident%% *}) that stands until you acknowledge it"* ]] || fail_test "report: ${output}"
  sync_path() { :; }
  sign_boot_files seal-only || fail_test "the watchers' pass failed over an earlier incident"
  output=$(sign_boot_files 2>&1) && fail_test "a full pass passed while an incident stands"
  [[ $output == *"on ${incident#* } (incident ${incident%% *}) that stands until you acknowledge it"* ]] || fail_test "a full pass beside the incident: ${output}"
  [[ $(esp_incident) == "$incident" ]] || fail_test "a later pass changed the incident: $(esp_incident)"
  # Beside another failure the incident is said too, with its own risk.
  mkdir -p "$FIX/esp/EFI/odd"
  write_loader_with_slot "$FIX/esp/EFI/odd/x.efi" "$(printf '0%.0s' {1..100})"
  output=$(sign_boot_files 2>&1) && fail_test "a pass with another failure passed"
  [[ $output == *'could not finish. Do not reboot, with Secure Boot on or off'*"(incident ${incident%% *}) that stands until you acknowledge it"* ]] || fail_test "beside another failure: ${output}"
  rm "$FIX/esp/EFI/odd/x.efi"
  clear_attention "$ATTENTION_SYNC"
  # A loader rebuilt or a fallback restored whose rename the sync did not
  # confirm is said the same way, even beside another failure.
  mkdir -p "$FIX/esp/EFI/odd"
  for dir in "$(dirname "$(primary_loader_path)")" "$(dirname "$(fallback_loader_path)")"; do
    printf 'timeout: 5\n' >>"$FIX/esp/limine.conf"
    sbctl sign "$(fallback_loader_path)"
    # Another failure of the pass, which must not hide the stronger warning.
    write_loader_with_slot "$FIX/esp/EFI/odd/x.efi" "$(printf '0%.0s' {1..100})"
    rm -f "$FIX/run/dir-sync-failed"
    sync_path() {
      if [[ $1 == "$dir" && ! -e $FIX/run/dir-sync-failed ]]; then
        : >"$FIX/run/dir-sync-failed"
        return 1
      fi
    }
    output=$(sign_boot_files 2>&1) && fail_test "${dir}: a rename whose sync failed passed"
    [[ -n $(esp_incident) && $output == *'The ESP reported a write error'*'with Secure Boot on or off'* ]] || fail_test "${dir}: ${output}"
    rm "$FIX/esp/EFI/odd/x.efi"
    sync_path() { :; }
    clear_attention "$ATTENTION_SYNC"
    sign_boot_files >/dev/null 2>&1 || fail_test "${dir}: the pass after"
  done
  # A file signed in place whose sync fails.
  write_uki "$FIX/esp/EFI/Linux/omarchy_linux.efi" 'a new unsigned image'
  rm -f "$FIX/run/file-sync-failed"
  sync_path() {
    if [[ $1 == "$FIX/esp/EFI/Linux/omarchy_linux.efi" && ! -e $FIX/run/file-sync-failed ]]; then
      : >"$FIX/run/file-sync-failed"
      return 1
    fi
  }
  output=$(sign_boot_files 2>&1) && fail_test "a signature whose sync failed passed"
  [[ -n $(esp_incident) && $output == *'The ESP reported a write error'* ]] || fail_test "a signature in place: ${output}"
  sync_path() { :; }
}

# The full pass fails beside an ESP incident, and says it, also where it
# leaves the boot files alone or stops early; the watchers' pass answers for
# its own work. A record that cannot be told counts as an incident (7.3).
full_pass_says_an_incident_wherever_it_ends() {
  local output
  prepared_machine
  sign_boot_files || fail_test "first pass"
  set_attention "$ATTENTION_SYNC" || fail_test "fixture incident"
  : >"$(restore_lock_path)"
  output=$(sign_boot_files 2>&1) && fail_test "a restore beside an incident passed"
  [[ $output == *'stands until you acknowledge it'* ]] || fail_test "restore: ${output}"
  sign_boot_files seal-only || fail_test "the watchers' pass failed beside a restore"
  rm "$(restore_lock_path)"
  : >"$FIX/run/esp-unmounted"
  output=$(sign_boot_files 2>&1) && fail_test "an unmounted ESP passed"
  [[ $output == *'stands until you acknowledge it'* ]] || fail_test "unmounted: ${output}"
  rm "$FIX/run/esp-unmounted"
  # What changes while the pass waits for the lock.
  output=$(rm "$(enabled_file)" && sign_boot_files 2>&1) && fail_test "a removed machine beside an incident passed"
  : >"$(enabled_file)"
  [[ $output == *'stands until you acknowledge it'* ]] || fail_test "removed: ${output}"
  output=$(
    restore_in_progress() { [[ -e $FIX/run/looked ]] || { : >"$FIX/run/looked"; return 1; }; }
    sign_boot_files 2>&1
  ) && fail_test "a restore that began during the wait passed"
  rm "$FIX/run/looked"
  [[ $output == *'stands until you acknowledge it'* ]] || fail_test "restore after the wait: ${output}"
  output=$(
    esp_is_mounted_vfat() { [[ ! -e $FIX/run/looked ]] && : >"$FIX/run/looked"; }
    sign_boot_files 2>&1
  ) && fail_test "an ESP that went away during the wait passed"
  rm "$FIX/run/looked"
  [[ $output == *'stands until you acknowledge it'* ]] || fail_test "unmounted after the wait: ${output}"
  printf '259:1 %s rw,relatime,fmask=0000,dmask=0000,codepage=437\n' "$FIX/esp" >"$FIX/run/mounts"
  output=$(sign_boot_files 2>&1) && fail_test "an unsafe ESP passed"
  [[ $output == *'stands until you acknowledge it'* ]] || fail_test "unsafe: ${output}"
  printf '259:1 %s rw,relatime,fmask=0077,dmask=0077,codepage=437\n' "$FIX/esp" >"$FIX/run/mounts"
  # A record of an incident in a form the tool does not write, beside a pass
  # that leaves the boot files alone and beside one that works.
  printf '%s on a day\n' "$ATTENTION_SYNC" >"$(attention_file)"
  : >"$(restore_lock_path)"
  output=$(sign_boot_files 2>&1) && fail_test "a restore beside an unknown incident passed"
  [[ $output == *'holds a line OmaSecBoot does not write'* ]] || fail_test "restore beside unknown: ${output}"
  rm "$(restore_lock_path)"
  output=$(sign_boot_files 2>&1) && fail_test "a full pass beside an unknown incident passed"
  [[ $output == *'holds a line OmaSecBoot does not write'* ]] || fail_test "unknown: ${output}"
  sign_boot_files seal-only || fail_test "the watchers' pass failed beside an unknown incident"
  # A record that becomes unknown while the pass works.
  rm "$(attention_file)"
  output=$(
    check_os_files_exist() { printf '%s on a day\n' "$ATTENTION_SYNC" >"$(attention_file)"; }
    sign_boot_files 2>&1
  ) && fail_test "a record that became unknown during the pass passed"
  [[ $output == *'holds a line OmaSecBoot does not write'* ]] || fail_test "unknown at the end: ${output}"
}

# The tools this pass delegates to hide their failures (CONTRIBUTING), so a
# signature sbctl reported is read back before the pass counts it.
claimed_signature_is_proved() {
  prepared_machine
  sign_boot_files || fail_test "first pass"
  write_uki "$FIX/esp/EFI/Linux/omarchy_linux.efi" 'a new unsigned image'
  : >"$FIX/run/sbctl-sign-does-nothing"
  ! sign_boot_files 2>/dev/null || fail_test "a signature that was never written counted"
  ! file_is_fixture_signed "$FIX/esp/EFI/Linux/omarchy_linux.efi" || fail_test "fixture: the image was signed"
}

# sbctl answers for the file it was asked about (C4); an answer about another
# file says nothing about this one.
answer_about_another_file_is_no_answer() {
  local rc=0
  prepared_machine
  run_sbctl() { printf '[{"file_name":"/elsewhere.efi","is_signed":1}]\n'; }
  signature_state "$FIX/esp/EFI/Linux/omarchy_linux.efi" || rc=$?
  (( rc == 2 )) || fail_test "an answer about another file read as ${rc}"
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

busy_lock_writes_no_needs_attention() {
  local rc=0
  prepared_machine
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  sign_boot_files 2>/dev/null || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "busy returned ${rc}"
  [[ ! -e $(attention_file) ]] || fail_test "a busy lock wrote needs-attention"
}

restore_in_progress_is_left_alone() {
  prepared_machine
  : >"$(restore_lock_path)"
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
# the primary loader after upstream has sealed and signed it (C6). The loader's
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
  : >"$(enabled_file)"
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

# What the pass observed before it waited for pacman and the lock can have
# changed by then: remove finished, a restore began, the ESP went away. The
# pass looks again once it holds the lock, and a pass that finds the machine
# removed does nothing (D2).
pass_looks_again_after_its_wait() {
  prepared_machine
  sign_boot_files || fail_test "first pass"
  printf '# edit\n' >>"$FIX/esp/limine.conf"
  wait_for_pacman() { rm -f -- "$(enabled_file)"; }
  : >"$FIX/run/calls"
  sign_boot_files seal-only || fail_test "a pass on a removed machine failed"
  ! grep -q 'enroll-config' "$FIX/run/calls" || fail_test "the pass sealed the loader after remove"
  : >"$(enabled_file)"
  wait_for_pacman() { : >"$(restore_lock_path)"; }
  sign_boot_files seal-only || fail_test "a pass beside a restore failed"
  ! grep -q 'enroll-config' "$FIX/run/calls" || fail_test "the pass sealed the loader while a restore began"
  rm "$(restore_lock_path)"
  wait_for_pacman() { : >"$FIX/run/esp-unmounted"; }
  sign_boot_files seal-only || fail_test "a pass whose ESP went away failed"
  ! grep -q 'enroll-config' "$FIX/run/calls" || fail_test "the pass wrote to an unmounted ESP"
  rm "$FIX/run/esp-unmounted"
  wait_for_pacman() { :; }
  sign_boot_files seal-only || fail_test "the pass after the drills failed"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader was not sealed once the way was clear"
}

# A file that limine.conf hashes under another spelling of its path is the
# same file: the guard resolves both before it compares (D4).
# FAT names have no case: the primary loader under another spelling is the
# same file, and it is only ever replaced through the staged rebuild (section
# 4), never signed in place, where a torn write would leave no loader. The
# copy here is sealed, so the rule for unsealed Limine executables (D4) does
# not decide it.
primary_under_another_case_is_never_signed_in_place() {
  local other=$FIX/esp/EFI/limine/LIMINE_X64.EFI
  prepared_machine
  cp "$FIX/share/BOOTX64.EFI" "$other"
  limine enroll-config "$other" "$(config_checksum)"
  cp "$other" "$FIX/run/other-before"
  sign_boot_files >/dev/null 2>&1 || :
  cmp -s "$other" "$FIX/run/other-before" || fail_test "the primary under another case was signed in place"
}

hashed_alias_is_not_signed() {
  local file=$FIX/esp/EFI/Linux/custom.efi output
  prepared_machine
  printf 'custom loader' >"$file"
  printf '\n/Custom\n    protocol: efi\n    path: boot():/EFI/Linux/./custom.efi#%s\n' "$(b2sum <"$file" | cut -d' ' -f1)" >>"$FIX/esp/limine.conf"
  output=$(sign_boot_files 2>&1) && fail_test "the pass passed beside a file it must not sign"
  [[ $output == *"Not signing ${file}"* ]] || fail_test "the refusal: ${output}"
  [[ $(<"$file") == 'custom loader' ]] || fail_test "the aliased file was signed in place"
  [[ -z $(list_stale_os_hashes) ]] || fail_test "a hash went stale: $(list_stale_os_hashes)"
  # Under a resource that is not boot() (C1): the file the entry may mean
  # stays as it is, and the refusal comes before any write.
  write_limine_conf unhashed
  printf '\n/Custom\n    protocol: efi\n    path: guid(0a1b2c3d-1111-2222-3333-444455556666):/EFI/Linux/custom.efi#%s\n' "$(b2sum <"$file" | cut -d' ' -f1)" >>"$FIX/esp/limine.conf"
  output=$(sign_boot_files 2>&1) && fail_test "the pass passed beside a file named under guid()"
  [[ $output == *"Not signing ${file}"* ]] || fail_test "the refusal under guid(): ${output}"
  [[ $(<"$file") == 'custom loader' ]] || fail_test "the file named under guid() was signed in place"
  # The hash under guid() is said as one that cannot be checked, not as stale:
  # only the firmware resolves that volume (C1).
  [[ $(list_stale_os_hashes) == unchecked$'\t'*'guid('* ]] || fail_test "the guid() hash was not listed as unchecked: $(list_stale_os_hashes)"
  # An inventory that cannot be read answers nothing, and nothing is signed on it.
  list_hashed_paths() { return 2; }
  output=$(sign_boot_files 2>&1) && fail_test "the pass passed with an unreadable limine.conf"
  [[ $output == *"Not signing ${file}: limine.conf cannot be read"* ]] || fail_test "no word about the unread inventory: ${output}"
  [[ $(<"$file") == 'custom loader' ]] || fail_test "the file was signed on an unread inventory"
}

run_case converges-and-is-idempotent converges_and_is_idempotent
run_case history-files-are-never-touched history_files_are_never_touched
run_case other-systems-files-are-never-touched other_systems_files_are_never_touched
run_case fallback-is-returned-to-raw fallback_is_returned_to_raw
run_case harmful-rows-are-found-and-removed harmful_rows_are_found_and_removed
run_case unsealed-limine-is-never-signed unsealed_limine_is_never_signed
run_case untold-seal-is-not-signed-and-fails-the-pass untold_seal_is_not_signed_and_fails_the_pass
run_case unproved-state-fails-the-pass unproved_state_fails_the_pass
run_case stale-hash-alone-fails-the-pass stale_hash_alone_fails_the_pass
run_case foreign-fallback-is-left-alone foreign_fallback_is_left_alone
run_case lower-case-foreign-fallback-is-left-alone lower_case_foreign_fallback_is_left_alone
run_case failure-writes-needs-attention failure_writes_needs_attention
run_case claimed-signature-is-proved claimed_signature_is_proved
run_case unsynced-esp-is-said unsynced_esp_is_said
run_case unsafe-esp-mount-writes-nothing unsafe_esp_mount_writes_nothing
run_case answer-about-another-file-is-no-answer answer_about_another_file_is_no_answer
run_case full-esp-is-not-written-to full_esp_is_not_written_to
run_case busy-lock-writes-no-needs-attention busy_lock_writes_no_needs_attention
run_case restore-in-progress-is-left-alone restore_in_progress_is_left_alone
run_case full-pass-says-an-incident-wherever-it-ends full_pass_says_an_incident_wherever_it_ends
run_case seal-only-reseals-and-stops seal_only_reseals_and_stops
run_case seal-only-waits-for-pacman-to-finish seal_only_waits_for_pacman_to_finish
run_case pass-looks-again-after-its-wait pass_looks_again_after_its_wait
run_case hashed-alias-is-not-signed hashed_alias_is_not_signed
run_case primary-under-another-case-is-never-signed-in-place primary_under_another_case_is_never_signed_in_place
finish_suite
