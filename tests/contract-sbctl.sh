#!/bin/bash
# The sbctl contract (docs/upstream-contracts.md C4) checked against the real
# tool, because the hermetic suites only know a stub of it. sbctl runs in the
# sandbox of tests/lib/sandbox.sh with keys made for the run and a fixture
# directory in place of the firmware's variables.
#
# A plain directory keeps the authentication header that efivarfs strips from
# a written variable, so reading a write back cannot be checked here; that
# belongs to hardware acceptance. What a write contains can: it ends with the
# exported list, byte for byte.
# shellcheck disable=SC2329 # Case functions are called through run_case.
# shellcheck disable=SC2154 # The plan arrays belong to lib/firmware.sh.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
SUITE_NAME=contract-sbctl
# shellcheck source=tests/lib/sandbox.sh
source "$ROOT_DIR/tests/lib/sandbox.sh" || exit 1

if ! in_sandbox; then
  require_command sbctl jq
  require_file /usr/share/limine/BOOTX64.EFI limine
  enter_sandbox "${BASH_SOURCE[0]}"
fi

# shellcheck source=tests/lib/esl.sh
source "$ROOT_DIR/tests/lib/esl.sh"
for module in common checks files firmware; do
  # shellcheck source=/dev/null
  source "$ROOT_DIR/lib/${module}.sh"
done

readonly OEM_OWNER=11111111111111111111111111111111
readonly MICROSOFT_OWNER=bd9afa775903324dbd6028f4e78f784b

# write_variable NAME LISTS-FILE: four attribute bytes, then the lists.
write_variable() { { printf '\x27\x00\x00\x00'; cat "$2"; } >"$(firmware_variable_path "$1")"; }

# What every case starts from: the settings, sbctl's keys, and the firmware
# after a PK-only delete, where KEK and db hold the manufacturer's and
# Microsoft's entries and Setup Mode is on. create-keys leaves existing keys
# alone (C4), so the cases share one set.
machine_in_setup_mode() {
  sandbox_settings
  sbctl create-keys >/dev/null 2>&1 || fail_test "create-keys"
  rm -f /sys/firmware/efi/efivars/*
  { x509_list "$OEM_OWNER" 'OEM KEK'; x509_list "$MICROSOFT_OWNER" 'Microsoft KEK'; } >/tmp/KEK.lists
  { x509_list "$MICROSOFT_OWNER" 'Microsoft Windows CA'; x509_list "$OEM_OWNER" 'OEM db'; } >/tmp/db.lists
  write_variable KEK /tmp/KEK.lists
  write_variable db /tmp/db.lists
  printf '\x06\x00\x00\x00\x01' >"$(firmware_variable_path SetupMode)"
  printf '\x06\x00\x00\x00\x00' >"$(firmware_variable_path SecureBoot)"
}

count() { if [[ -z $1 ]]; then printf '0\n'; else wc -l <<<"$1"; fi; }

keys_and_owner() {
  local owner
  machine_in_setup_mode
  sbctl_keys_exist || fail_test "status --json does not report installed keys"
  owner=$(local_owner)
  [[ $owner =~ ^[0-9a-f]{32}$ ]] || fail_test "status --json carries no usable guid: '${owner}'"
  sbctl create-keys >/dev/null 2>&1 || fail_test "create-keys over existing keys"
  [[ $(local_owner) == "$owner" ]] || fail_test "create-keys replaced existing keys: recheck C4"
}

plan_is_the_firmware_plus_the_local_certificate() {
  local name
  machine_in_setup_mode
  read_enrollment_plan || fail_test "the export failed with no PK and SetupMode 1"
  local_certificates_are_identified || fail_test "the local certificates were not found by sbctl's owner GUID"
  append_plan_is_sound || fail_test "the append plan is not the firmware's entries plus the local certificate"
  firmware_is_enrolled && fail_test "firmware without the local certificate reads as enrolled"
  for name in KEK db; do
    [[ $(count "${_planned[$name]}") == 3 && $(count "${_current[$name]}") == 2 ]] || fail_test "${name}: planned $(count "${_planned[$name]}"), current $(count "${_current[$name]}")"
  done
  [[ $(count "${_planned[PK]}") == 1 ]] || fail_test "the planned PK has $(count "${_planned[PK]}") entries"
}

export_is_what_a_write_produces() {
  local size
  machine_in_setup_mode
  { mkdir -p /tmp/export && cd /tmp/export; } || fail_test "scratch"
  sbctl enroll-keys --append --export esl >/dev/null 2>&1 || fail_test "export"
  run_sbctl enroll-keys --append --partial db --ignore-immutable >/dev/null 2>&1 || fail_test "--partial with --append and --ignore-immutable was refused"
  size=$(stat -c %s db.esl)
  cmp -s <(tail -c "$size" "$(firmware_variable_path db)") db.esl || fail_test "the written variable does not end with the exported list"
  cmp -s "$(firmware_variable_path KEK)" <(printf '\x27\x00\x00\x00'; cat /tmp/KEK.lists) || fail_test "--partial db wrote KEK too"
  [[ ! -e $(firmware_variable_path PK) ]] || fail_test "--partial db wrote the PK"
}

# The firmware's view after an enrollment is the attributes plus the exported
# lists. sbctl's append then plans the certificate a second time and, with a
# PK in place, a PK of two entries; the tool recognises the enrolled state and
# writes nothing.
enrolled_state_is_recognised_and_left_alone() {
  local name
  machine_in_setup_mode
  { mkdir -p /tmp/enrolled && cd /tmp/enrolled; } || fail_test "scratch"
  sbctl enroll-keys --append --export esl >/dev/null 2>&1 || fail_test "export"
  for name in db KEK PK; do write_variable "$name" "${name}.esl"; done
  read_enrollment_plan || fail_test "the export failed with a PK in place"
  { local_certificates_are_identified && firmware_is_enrolled; } || fail_test "the enrolled firmware was not recognised"
  [[ $(count "${_planned[db]}") == $(($(count "${_current[db]}") + 1)) ]] || fail_test "append no longer adds the certificate again: recheck C4 and the skip rule"
  [[ $(count "${_planned[PK]}") == 2 ]] || fail_test "an append export with a PK in place shows $(count "${_planned[PK]}") PK entries"
  cp "$(firmware_variable_path db)" /tmp/db.before
  enroll_local_keys append >/dev/null || fail_test "enroll_local_keys failed on an enrolled firmware"
  cmp -s "$(firmware_variable_path db)" /tmp/db.before || fail_test "an enrolled variable was written again"
}

rebuild_plan_for_cleared_firmware() {
  machine_in_setup_mode
  rm -f "$(firmware_variable_path KEK)" "$(firmware_variable_path db)"
  { read_enrollment_plan && local_certificates_are_identified; } || fail_test "plan on cleared firmware"
  { read_rebuild_plan && rebuild_plan_is_sound; } || fail_test "the rebuild plan does not hold the local certificates, or its PK is not the local certificate alone"
  [[ $(count "${_planned[db]}") -gt 1 && $(count "${_planned[KEK]}") -gt 1 ]] || fail_test "--microsoft added nothing"
  { mkdir -p /tmp/rebuild && cd /tmp/rebuild; } || fail_test "scratch"
  sbctl enroll-keys "${_rebuild_flags[@]}" --export esl >/dev/null 2>&1 || fail_test "export"
  run_sbctl enroll-keys "${_rebuild_flags[@]}" --partial db --ignore-immutable >/dev/null 2>&1 || fail_test "--partial with ${_rebuild_flags[*]} was refused: recheck C4"
  cmp -s <(tail -c "$(stat -c %s db.esl)" "$(firmware_variable_path db)") db.esl || fail_test "the rebuilt variable does not end with the exported list"
}

signature_answers() {
  local loader=/boot/EFI/Linux/contract.efi status
  machine_in_setup_mode
  mkdir -p /boot/EFI/Linux
  cp /usr/share/limine/BOOTX64.EFI "$loader" || fail_test "fixture executable"
  signature_state "$loader"
  (( $? == 1 )) || fail_test "an unsigned file did not read as not signed"
  run_sbctl sign "$loader" >/dev/null 2>&1 || fail_test "sign"
  signature_state "$loader" || fail_test "a signed file did not read as signed"
  run_sbctl sign "$loader" >/dev/null 2>&1 || fail_test "signing a signed file again is an error"
  signature_state /boot/EFI/Linux/missing.efi
  status=$?
  (( status == 1 )) || fail_test "a missing file read as status ${status}, not as not signed (is_signed -1): recheck C4"
  cp /usr/share/limine/BOOTX64.EFI /tmp/outside.efi
  signature_state /tmp/outside.efi
  status=$?
  (( status == 2 )) || fail_test "a file outside the ESP read as status ${status}, not as could not tell (null): recheck C4"
}

# tracked_files_are EXPECTED: an answer that could not be read is not an empty list.
tracked_files_are() {
  local tracked
  tracked=$(sbctl_tracked_files) || fail_test "list-files gave no readable answer"
  [[ $tracked == "$1" ]]
}

file_list_answers() {
  local loader=/boot/EFI/Linux/tracked.efi
  machine_in_setup_mode
  tracked_files_are '' || fail_test "a fresh file list is not empty"
  mkdir -p /boot/EFI/Linux
  cp /usr/share/limine/BOOTX64.EFI "$loader" || fail_test "fixture executable"
  run_sbctl sign -s "$loader" >/dev/null 2>&1 || fail_test "sign -s"
  tracked_files_are "$loader" || fail_test "list-files: $(sbctl_tracked_files)"
  rm "$loader"
  tracked_files_are '' || fail_test "list-files no longer leaves out a row whose file is gone: recheck C4"
  run_sbctl remove-file "$loader" >/dev/null 2>&1 || fail_test "remove-file"
}

run_case keys-and-owner keys_and_owner
run_case plan-is-the-firmware-plus-the-local-certificate plan_is_the_firmware_plus_the_local_certificate
run_case export-is-what-a-write-produces export_is_what_a_write_produces
run_case enrolled-state-is-recognised-and-left-alone enrolled_state_is_recognised_and_left_alone
run_case rebuild-plan-for-cleared-firmware rebuild_plan_for_cleared_firmware
run_case signature-answers signature_answers
run_case file-list-answers file_list_answers
finish_suite "sbctl $(sbctl version 2>/dev/null | head -n 1)"
