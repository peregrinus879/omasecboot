#!/bin/bash
# The firmware half: reading signature lists, the backup, the enrollment plan
# and its proofs, the per-variable enrollment, and setup's one step per run.
# shellcheck disable=SC2329 # Case functions are called through run_case.
# shellcheck disable=SC2154 # The plan arrays belong to lib/firmware.sh.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init firmware

# The stub's owner GUID 01020304-0506-0708-090a-0b0c0d0e0f10 as its bytes are stored.
readonly LOCAL_OWNER=0403020106050807090a0b0c0d0e0f10

# A machine whose boot files are set up and whose PK is still the factory's.
prepared_machine() {
  run_cli setup || fail_test "first setup failed: $(<"$FIX/run/output")"
}

count_rows() { grep -c . <<<"$1"; }

signature_lists_are_read_entry_by_entry() {
  local file=$FIX/run/lists rows binary=$FIX/run/binary-payload
  # What real certificates are made of: NULs, newlines, percent signs,
  # backslashes and bytes above 0x7f.
  hex_bytes 3082000a255c00ff80fe0a0a00 >"$binary"
  {
    printf '\x27\x00\x00\x00'
    x509_list "$OEM_OWNER" 'first certificate'
    sha256_list "$MICROSOFT_OWNER" "$(printf 'a%.0s' {1..64})" "$(printf 'b%.0s' {1..64})"
    # A list of a type this tool has no name for, with a six-byte header.
    hex_bytes ffffffffffffffffffffffffffffffff
    le32 $((28 + 6 + 16 + 13))
    le32 6
    le32 $((16 + 13))
    printf 'header'
    hex_bytes "$OEM_OWNER"
    cat "$binary"
  } >"$file"
  rows=$(list_signature_entries "$file" 4) || fail_test "a well-formed variable was refused"
  [[ $(count_rows "$rows") == 4 ]] || fail_test "rows: ${rows}"
  [[ $rows == *"$(x509_row "$OEM_OWNER" 'first certificate')"* ]] || fail_test "the certificate row is wrong: ${rows}"
  [[ $rows == *"${ESL_SHA256_TYPE} ${MICROSOFT_OWNER} $(hex_bytes "$(printf 'a%.0s' {1..64})" | sha256sum | cut -d' ' -f1)"* ]] || fail_test "a hash row is wrong: ${rows}"
  [[ $rows == *"ffffffffffffffffffffffffffffffff ${OEM_OWNER} $(sha256sum <"$binary" | cut -d' ' -f1)"* ]] ||
    fail_test "binary data behind a list header was not carried byte for byte: ${rows}"
  [[ $rows == "$(LC_ALL=C sort <<<"$rows")" ]] || fail_test "rows are not sorted"

  head -c 60 "$file" >"$FIX/run/truncated"
  ! list_signature_entries "$FIX/run/truncated" 4 >/dev/null || fail_test "a truncated list was accepted"
  { cat "$file"; printf 'ten stray!'; } >"$FIX/run/trailing"
  ! list_signature_entries "$FIX/run/trailing" 4 >/dev/null || fail_test "bytes after the last list were ignored"
  { printf '\x27\x00\x00\x00'; hex_bytes "$ESL_X509_TYPE"; le32 44; le32 0; le32 16; head -c 16 /dev/zero; } >"$FIX/run/no-data"
  ! list_signature_entries "$FIX/run/no-data" 4 >/dev/null || fail_test "an entry without data was accepted"
  ! list_signature_entries "$FIX/run/missing" 0 >/dev/null 2>&1 || fail_test "an unreadable file read as empty"
  : >"$FIX/run/empty"
  [[ -z $(list_signature_entries "$FIX/run/empty" 0) ]] || fail_test "an empty file has entries"
  # A list of a header and no entry is a list of nothing, not a malformed one.
  { printf '\x27\x00\x00\x00'; hex_bytes "$ESL_X509_TYPE"; le32 34; le32 6; le32 44; printf 'header'; } >"$FIX/run/header-only"
  rows=$(list_signature_entries "$FIX/run/header-only" 4) || fail_test "a header-only list was refused"
  [[ -z $rows ]] || fail_test "a header-only list has entries: ${rows}"
}

backup_is_taken_once_and_complete() {
  local first second name
  first=$(take_firmware_backup) || fail_test "backup"
  for name in PK KEK db dbx; do
    cmp -s "$first/$name" "$(key_variable_path "$name")" || fail_test "${name} is not a byte-for-byte copy"
  done
  grep -qx 'SetupMode=0' "$first/modes" || fail_test "modes"
  second=$(take_firmware_backup) || fail_test "second backup"
  [[ $second == "$first" ]] || fail_test "an unchanged firmware was backed up again"

  # The PK goes: a new backup records the absence, and the newest complete
  # one is what counts; a directory without verified sums is not a backup.
  delete_platform_key
  sleep 1
  second=$(take_firmware_backup) || fail_test "backup in Setup Mode"
  [[ $second != "$first" && ! -e $second/PK && -e $second/KEK ]] || fail_test "absence was not recorded"
  [[ $(latest_firmware_backup) == "$second" ]] || fail_test "latest"
  printf 'tampered' >>"$second/db"
  [[ $(latest_firmware_backup) == "$first" ]] || fail_test "a backup that fails its sums still counted"
  rm "$first/SHA256SUMS"
  ! latest_firmware_backup >/dev/null || fail_test "a backup without sums counted"
}

# The local certificates are the entries sbctl owns (C4), found the same way
# whether or not the firmware holds them and whether or not sbctl's append
# adds them a second time.
local_certificates_are_found_by_owner() {
  local name
  : >"$FIX/sbctl/keys"
  [[ $(local_owner) == "$LOCAL_OWNER" ]] || fail_test "owner bytes: $(local_owner)"
  read_enrollment_plan || fail_test "plan"
  local_certificates_are_identified || fail_test "not identified with factory keys in place"
  for name in db KEK PK; do
    [[ ${_local[$name]} == "$(x509_row "$LOCAL_OWNER" "local ${name} certificate")" ]] || fail_test "${name}: ${_local[$name]}"
  done
  platform_key_is_present || fail_test "the factory PK was not seen"
  ! firmware_is_enrolled || fail_test "factory keys read as enrolled"
  [[ $(count_foreign_entries) == 5 ]] || fail_test "foreign entries: $(count_foreign_entries)"

  delete_platform_key
  { read_enrollment_plan && enroll_local_keys append; } >/dev/null || fail_test "fixture enrollment"
  for idempotent in false true; do
    [[ $idempotent == false ]] || : >"$FIX/run/sbctl-append-is-idempotent"
    { read_enrollment_plan && local_certificates_are_identified && firmware_is_enrolled; } ||
      fail_test "an enrolled firmware was not recognised (idempotent sbctl: ${idempotent})"
    [[ $(count_foreign_entries) == 5 ]] || fail_test "the local certificates counted as foreign"
  done

  # The owner goes into a pattern, so only a well-formed GUID is one.
  : >"$FIX/run/sbctl-owner-malformed"
  ! local_owner >/dev/null || fail_test "a malformed owner GUID was accepted"
  rm "$FIX/run/sbctl-owner-malformed"
  rm "$FIX/sbctl/keys"
  ! read_enrollment_plan 2>/dev/null || fail_test "a plan was read without keys"
}

plan_proofs_refuse_what_was_not_asked_for() {
  local backup
  : >"$FIX/sbctl/keys"
  backup=$(take_firmware_backup) || fail_test "backup"
  delete_platform_key
  read_enrollment_plan || fail_test "plan"
  { append_is_safe "$backup" && append_plan_is_sound; } || fail_test "a PK-only delete with a plain plan was refused"

  # The plan must be the current entries plus the local certificate.
  : >"$FIX/run/sbctl-plans-a-stowaway"
  read_enrollment_plan || fail_test "plan"
  ! append_plan_is_sound || fail_test "a plan that adds a second entry was accepted"
  rm "$FIX/run/sbctl-plans-a-stowaway"
  read_enrollment_plan || fail_test "plan"
  _planned['db']=${_local['db']}
  ! append_plan_is_sound || fail_test "a plan that drops db entries was accepted"
  read_enrollment_plan || fail_test "plan"
  _planned['PK']+=$'\n'"$(x509_row "$OEM_OWNER" 'second platform key')"
  ! append_plan_is_sound || fail_test "a PK with two entries was accepted"

  # The rebuild: KEK and db get the local certificate, the PK nothing else.
  write_key_variable KEKDefault "$(x509_list "$OEM_OWNER" 'OEM KEK' | base64 -w0)"
  write_key_variable dbDefault "$(x509_list "$OEM_OWNER" 'OEM db' | base64 -w0)"
  { read_enrollment_plan && read_rebuild_plan && rebuild_plan_is_sound; } || fail_test "a plain rebuild plan was judged unsound"
  _planned['PK']+=$'\n'"$(x509_row "$OEM_OWNER" 'second platform key')"
  ! rebuild_plan_is_sound || fail_test "a rebuild with two PK entries was accepted"
  # An sbctl that no longer honours --microsoft exports the local keys alone.
  { read_enrollment_plan && read_rebuild_plan; } || fail_test "plan"
  _planned['KEK']=${_local['KEK']}
  ! rebuild_plan_is_sound || fail_test "a rebuild of the local keys alone was accepted"
}

# Appending to an empty KEK or db would enroll the local keys alone, so empty
# never means append, whatever the backup says.
empty_never_means_append() {
  local backup
  : >"$FIX/sbctl/keys"
  delete_platform_key
  rm "$(key_variable_path db)"
  backup=$(take_firmware_backup) || fail_test "backup"
  read_enrollment_plan || fail_test "plan"
  [[ -z $(list_lost_entries "$backup" current) ]] || fail_test "fixture: the late backup shows a loss"
  ! append_is_safe "$backup" || fail_test "append was judged safe with an empty db"
  { read_rebuild_plan && ! rebuild_applies; } 2>/dev/null || fail_test "a half-cleared firmware was judged rebuildable"
  ! reference_backup >/dev/null || fail_test "a backup without a PK served as the reference"

  # A db that holds nothing but the local certificate, even twice, is empty
  # for this purpose.
  write_key_variable db "$({ x509_list "$LOCAL_OWNER" 'local db certificate'; x509_list "$LOCAL_OWNER" 'local db certificate'; } | base64 -w0)"
  read_enrollment_plan || fail_test "plan"
  [[ -z $(foreign_entries db) ]] || fail_test "a second copy of the local certificate counted as another party's entry"
  ! append_is_safe "$backup" || fail_test "append was judged safe for a db with the local certificate alone"

  # Without its flags a rebuild would write the local keys alone.
  : >"$FIX/run/calls"
  _rebuild_flags=()
  ! enroll_local_keys rebuild >/dev/null 2>&1 || fail_test "a rebuild without flags went on"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "a rebuild without flags wrote: $(<"$FIX/run/calls")"
}

# The same through the command: a machine that meets this tool half-cleared
# has nothing the loss could be read from, and is refused with the reason.
half_cleared_firmware_is_refused() {
  delete_platform_key
  rm "$(key_variable_path db)"
  run_cli setup || fail_test "first setup failed: $(<"$FIX/run/output")"
  run_cli setup && fail_test "setup wrote to a half-cleared firmware"
  [[ $(<"$FIX/run/output") == *'db holds no entries besides yours'* && $(<"$FIX/run/output") == *'Restore the factory keys'* ]] || fail_test "report: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "a refused enrollment wrote to the firmware"
}

# sbctl rotate-keys keeps the owner GUID: the firmware then holds an older
# certificate of sbctl's own next to the one to enroll, before, during and
# after the enrollment.
rotated_keys_are_enrolled_beside_the_old_ones() {
  prepared_machine
  write_key_variable KEK "$({ tail -c +5 "$(key_variable_path KEK)"; x509_list "$LOCAL_OWNER" 'local KEK certificate before the rotation'; } | base64 -w0)"
  write_key_variable db "$({ tail -c +5 "$(key_variable_path db)"; x509_list "$LOCAL_OWNER" 'local db certificate before the rotation'; } | base64 -w0)"
  sleep 1 # Backups are named by the second.
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  delete_platform_key
  : >"$FIX/run/sbctl-enroll-fails-at-KEK"
  run_cli setup && fail_test "a failed KEK write reported success"
  rm "$FIX/run/sbctl-enroll-fails-at-KEK"
  run_cli setup || fail_test "the enrollment was not finished beside the old certificates: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'Your keys are enrolled'* ]] || fail_test "report: $(<"$FIX/run/output")"
  grep -aqF 'local db certificate before the rotation' "$(key_variable_path db)" || fail_test "append removed an entry"
  set_mode_variable SetupMode 0
  run_cli status || fail_test "status after the enrollment: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'Your keys are enrolled in the firmware'* ]] || fail_test "status: $(<"$FIX/run/output")"
}

enrollment_appends_and_reads_back() {
  local backup name
  : >"$FIX/sbctl/keys"
  backup=$(take_firmware_backup) || fail_test "backup"
  delete_platform_key
  read_enrollment_plan || fail_test "plan"
  append_is_safe "$backup" || fail_test "a PK-only delete was not judged safe to append to"
  : >"$FIX/run/calls"
  enroll_local_keys append >/dev/null || fail_test "enrollment"

  [[ $(grep -c 'enroll-keys --append --partial' "$FIX/run/calls") == 3 ]] || fail_test "calls: $(<"$FIX/run/calls")"
  [[ $(grep 'enroll-keys --append --partial' "$FIX/run/calls" | awk '{print $5}' | tr '\n' ' ') == 'db KEK PK ' ]] || fail_test "write order"
  ! grep 'enroll-keys --append --partial' "$FIX/run/calls" | grep -qv -- '--ignore-immutable' || fail_test "a write without --ignore-immutable"
  # Independent of the reader under test: every backup byte is still there,
  # followed by exactly one list with the local certificate.
  for name in KEK db; do
    cmp -s <(head -c "$(stat -c %s "$backup/$name")" "$(key_variable_path "$name")") "$backup/$name" || fail_test "${name} lost bytes of the backup"
    cmp -s <(tail -c +"$(($(stat -c %s "$backup/$name") + 1))" "$(key_variable_path "$name")") <(x509_list "$LOCAL_OWNER" "local ${name} certificate") ||
      fail_test "${name} does not end with the local certificate alone"
  done
  cmp -s <(tail -c +5 "$(key_variable_path PK)") <(x509_list "$LOCAL_OWNER" 'local PK certificate') || fail_test "the PK is not the local certificate alone"
  cmp -s "$(key_variable_path dbx)" "$backup/dbx" || fail_test "dbx was touched"
  { read_enrollment_plan && firmware_is_enrolled; } || fail_test "the enrolled firmware does not read as enrolled"
}

# sbctl's append adds the certificate again on every run (C4), and it stops at
# the first error without rolling back.
interrupted_enrollment_is_finished_without_duplicates() {
  : >"$FIX/sbctl/keys"
  delete_platform_key
  read_enrollment_plan || fail_test "plan"
  : >"$FIX/run/sbctl-enroll-fails-at-KEK"
  ! enroll_local_keys append >"$FIX/run/output" 2>&1 || fail_test "a failed KEK write reported success"
  grep -q 'sbctl could not write KEK' "$FIX/run/output" || fail_test "message: $(<"$FIX/run/output")"
  rm "$FIX/run/sbctl-enroll-fails-at-KEK"
  read_enrollment_plan || fail_test "second plan"
  ! firmware_is_enrolled || fail_test "a half-written firmware read as enrolled"
  : >"$FIX/run/calls"
  enroll_local_keys append >/dev/null || fail_test "the second run did not finish"
  ! grep -q -- '--partial db' "$FIX/run/calls" || fail_test "db was written a second time"
  [[ $(grep -aoF 'local db certificate' "$(key_variable_path db)" | wc -l) == 1 ]] || fail_test "db holds the local certificate twice"
  { read_enrollment_plan && firmware_is_enrolled; } || fail_test "not enrolled after the second run"
}

# Firmware that reports success and keeps the old value: only the readback
# can tell.
write_is_judged_by_reading_back() {
  : >"$FIX/sbctl/keys"
  delete_platform_key
  read_enrollment_plan || fail_test "plan"
  : >"$FIX/run/firmware-ignores-writes"
  ! enroll_local_keys append >"$FIX/run/output" 2>&1 || fail_test "a write the firmware ignored passed"
  grep -q 'db does not read back as planned' "$FIX/run/output" || fail_test "message: $(<"$FIX/run/output")"
}

# Append skips sbctl's own check of what the machine needs (C4), so the tool
# proves that the key menu removed nothing but the PK.
lost_entries_are_named() {
  local backup lost
  : >"$FIX/sbctl/keys"
  backup=$(take_firmware_backup) || fail_test "backup"
  delete_platform_key
  write_key_variable KEK "$(x509_list "$OEM_OWNER" 'OEM KEK' | base64 -w0)"
  read_enrollment_plan || fail_test "plan"
  lost=$(list_lost_entries "$backup" current)
  [[ $lost == "KEK $(x509_row "$MICROSOFT_OWNER" 'Microsoft KEK')" ]] || fail_test "lost: ${lost}"
  # shellcheck disable=SC2086 # The row's three fields are the three arguments.
  [[ $(describe_entry ${lost#KEK }) == "certificate with SHA-256 fingerprint $(printf 'Microsoft KEK' | sha256sum | cut -d' ' -f1)" ]] || fail_test "description"
  rm "$(key_variable_path dbx)"
  ! dbx_equals_backup "$backup" || fail_test "a cleared dbx equalled the backup"
}

# Once the PK is the user's, the manufacturer can no longer add Microsoft's
# 2023 KEK certificate (C9): the last moment to say so is before it is deleted.
missing_2023_kek_is_asked_about_before_the_pk_goes() {
  [[ -z $(missing_microsoft_2023 KEK) && -z $(missing_microsoft_2023 db) ]] || fail_test "the stock fixture lacks a certificate: $(missing_microsoft_2023 KEK; missing_microsoft_2023 db)"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") != *'CA 2023'* ]] || fail_test "asked although KEK holds the certificate: $(<"$FIX/run/output")"
  write_key_variable KEK "$(x509_list "$OEM_OWNER" 'OEM KEK' | base64 -w0)"
  sleep 1 # Backups are named by the second, and the changed KEK asks for a new one.
  [[ $(missing_microsoft_2023 KEK) == 'Microsoft Corporation KEK 2K CA 2023' ]] || fail_test "missing: $(missing_microsoft_2023 KEK)"
  CONFIRM_ANSWER=no run_cli setup && fail_test "setup went on although the question was declined"
  [[ $(<"$FIX/run/output") == *'KEK does not hold Microsoft Corporation KEK 2K CA 2023'*'QUESTION: Go on without'* ]] || fail_test "no warning or no question: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") != *'delete only the Platform Key'* ]] || fail_test "the instruction was given although the question was declined"
  run_cli setup || fail_test "setup failed after a yes: $(<"$FIX/run/output")"
  grep -n 'QUESTION: Go on without\|delete only the Platform Key' "$FIX/run/output" | head -1 | grep -q QUESTION || fail_test "the instruction came before the question: $(<"$FIX/run/output")"
  printf 'garbage' >"$(key_variable_path KEK)"
  missing_microsoft_2023 KEK >/dev/null 2>&1 && fail_test "an unreadable KEK was read as holding everything"
  return 0
}

setup_asks_for_the_pk_then_enrolls_then_confirms() {
  local backup
  prepared_machine
  [[ $(<"$FIX/run/output") == *'delete only the Platform Key (PK)'*'leave Secure Boot disabled when you save'*'set it back to disabled'* ]] || fail_test "no firmware instruction, or it lets Secure Boot come on by itself: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") != *QUESTION* ]] || fail_test "a machine without Windows was asked about it: $(<"$FIX/run/output")"
  backup=$(latest_firmware_backup) || fail_test "no backup before the firmware instruction"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "the first run wrote to the firmware"

  delete_platform_key
  # No PK but no Setup Mode either is a state this tool does not understand.
  set_mode_variable SetupMode 0
  run_cli setup && fail_test "setup went on although the firmware does not report Setup Mode"
  [[ $(<"$FIX/run/output") == *'does not report Setup Mode'* && $(<"$FIX/run/output") != *QUESTION* ]] || fail_test "report: $(<"$FIX/run/output")"
  set_mode_variable SetupMode 1
  CONFIRM_ANSWER=no run_cli setup && fail_test "a declined enrollment went on"
  grep -q '^QUESTION: The Platform Key becomes yours. Write your keys to the firmware?' "$FIX/run/output" || fail_test "question: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "a declined enrollment wrote to the firmware"
  run_cli setup || fail_test "enrollment failed: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'Your keys are enrolled'* && $(<"$FIX/run/output") == *"$backup"* ]] || fail_test "report: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'taken back only in the firmware'"'"'s key menu'*'QUESTION: The Platform Key becomes yours'* ]] || fail_test "the way back is not named before the question: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'systemctl reboot'*'then run'* ]] || fail_test "no reboot instruction"
  [[ $(latest_firmware_backup) == "$backup" ]] || fail_test "the backup from before the delete was replaced"

  # Same boot: SetupMode still reads 1 (C10). Nothing is written again.
  : >"$FIX/run/calls"
  run_cli setup || fail_test "setup in the enrollment's boot failed"
  [[ $(<"$FIX/run/output") == *'systemctl reboot'*'then run'* ]] || fail_test "same boot: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "an enrolled firmware was written again"
  set_mode_variable SetupMode 0
  # A machine that starts through the fallback path would stop with Secure
  # Boot on, because the fallback stays raw (D6): no instruction without an
  # active entry for the primary loader.
  write_boot_entry 0001 inactive 'Limine' '\EFI\limine\limine_x64.efi'
  run_cli setup && fail_test "setup told a machine without a Limine boot entry to turn Secure Boot on"
  [[ $(<"$FIX/run/output") == *'no active boot entry for the Limine loader'* && $(<"$FIX/run/output") != *'turn Secure Boot on'* ]] || fail_test "without a boot entry: $(<"$FIX/run/output")"
  write_boot_entry 0001 active 'Limine' '\efi\LIMINE\limine_x64.efi'
  run_cli setup || fail_test "setup after the reboot failed"
  [[ $(<"$FIX/run/output") == *'turn Secure Boot on'* ]] || fail_test "next boot: $(<"$FIX/run/output")"
  set_mode_variable SecureBoot 1
  run_cli setup || fail_test "setup with Secure Boot on failed"
  [[ $(<"$FIX/run/output") == *'Setup is complete'* ]] || fail_test "complete: $(<"$FIX/run/output")"
}

# A machine that is already in Setup Mode gets its boot files first; firmware
# writes never share a run with them.
first_run_never_writes_to_the_firmware() {
  delete_platform_key
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "the first run wrote to the firmware"
  [[ $(<"$FIX/run/output") == *'again to enroll your keys'* ]] || fail_test "report: $(<"$FIX/run/output")"
  run_cli setup || fail_test "second setup failed: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'taken in Setup Mode'* ]] || fail_test "no warning about the late backup"
  grep -q -- '--partial PK' "$FIX/run/calls" || fail_test "the second run did not enroll"
}

partial_loss_is_refused() {
  prepared_machine
  delete_platform_key
  write_key_variable db "$(x509_list "$OEM_OWNER" 'OEM db' | base64 -w0)"
  run_cli setup && fail_test "setup enrolled although the key menu removed db entries"
  [[ $(<"$FIX/run/output") == *'will not write to'* && $(<"$FIX/run/output") == *'Restore the factory keys'* ]] || fail_test "report: $(<"$FIX/run/output")"
  [[ $(grep -c 'db: certificate with SHA-256 fingerprint' "$FIX/run/output") == 2 ]] || fail_test "the lost entries were not named"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "a refused enrollment wrote to the firmware"
}

# dbx is never written by this tool, so a dbx that changed since the backup is
# something it cannot account for.
changed_dbx_is_refused() {
  prepared_machine
  delete_platform_key
  write_key_variable dbx "$(sha256_list "$MICROSOFT_OWNER" "$(printf 'c%.0s' {1..64})" | base64 -w0)"
  run_cli setup && fail_test "setup enrolled although dbx differs from the backup"
  # KEK and db are whole: the refusal says that only dbx differs, and why.
  [[ $(<"$FIX/run/output") == *'KEK and db hold every entry of the backup; only the revocation list (dbx) differs'*'dbx update Windows applied'* ]] || fail_test "report: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "a refused enrollment wrote to the firmware"
}

# A built-in default that is non-volatile could have been written by anyone:
# sbctl refuses it (C4), so the rebuild plans Microsoft's certificates alone.
non_volatile_defaults_are_not_used() {
  prepared_machine
  delete_platform_key
  rm "$(key_variable_path KEK)" "$(key_variable_path db)" "$(key_variable_path dbx)"
  { printf '\x27\x00\x00\x00'; x509_list "$OEM_OWNER" 'OEM KEK'; } >"$(key_variable_path KEKDefault)"
  { printf '\x27\x00\x00\x00'; x509_list "$OEM_OWNER" 'OEM db'; } >"$(key_variable_path dbDefault)"
  firmware_has_builtin_defaults && fail_test "non-volatile defaults counted as the firmware's"
  run_cli setup || fail_test "the rebuild failed: $(<"$FIX/run/output")"
  grep -q 'enroll-keys --microsoft --partial KEK --ignore-immutable' "$FIX/run/calls" || fail_test "calls: $(<"$FIX/run/calls")"
  ! grep -q -- '--firmware-builtin' "$FIX/run/calls" || fail_test "a non-volatile default was handed to sbctl"
}

# A UEFI 2.5 firmware in Audit Mode leaves it for Deployed Mode when the PK is
# written: a state without a record is refused before anything is written.
audit_mode_is_refused() {
  prepared_machine
  delete_platform_key
  set_mode_variable AuditMode 1
  run_cli setup && fail_test "setup enrolled a firmware in Audit Mode"
  [[ $(<"$FIX/run/output") == *'Audit Mode'*'Deployed Mode'*'nothing was written'* && $(<"$FIX/run/output") != *QUESTION* ]] || fail_test "report: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "a refused enrollment wrote to the firmware"
  printf 'garbage' >"$FIX/efivars/AuditMode-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  run_cli setup && fail_test "setup enrolled with an unreadable AuditMode"
  [[ $(<"$FIX/run/output") == *'Could not read the firmware'"'"'s AuditMode variable'* ]] || fail_test "unreadable: $(<"$FIX/run/output")"
  set_mode_variable AuditMode 0
  run_cli setup || fail_test "enrollment failed with AuditMode 0: $(<"$FIX/run/output")"
  grep -q -- '--partial' "$FIX/run/calls" || fail_test "AuditMode 0 was not written past"
}

# What sbctl would write is checked where it matters: right before the
# question, and before the user is asked to delete anything.
unsound_answers_from_sbctl_stop_setup() {
  prepared_machine
  : >"$FIX/run/sbctl-owner-changed"
  run_cli setup && fail_test "setup went on without knowing the local certificates"
  [[ $(<"$FIX/run/output") == *'exactly one certificate of yours'* && $(<"$FIX/run/output") != *'delete only'* ]] || fail_test "report: $(<"$FIX/run/output")"
  rm "$FIX/run/sbctl-owner-changed"
  : >"$FIX/run/sbctl-enroll-keys-fails"
  run_cli setup && fail_test "setup went on although sbctl's export failed"
  [[ $(<"$FIX/run/output") == *'stub: enroll-keys failed'* ]] || fail_test "sbctl's reason was not shown: $(<"$FIX/run/output")"
  rm "$FIX/run/sbctl-enroll-keys-fails"

  delete_platform_key
  : >"$FIX/run/sbctl-plans-a-stowaway"
  run_cli setup && fail_test "setup accepted a plan with an entry nobody asked for"
  [[ $(<"$FIX/run/output") == *"not the firmware's entries plus your certificates"* ]] || fail_test "report: $(<"$FIX/run/output")"
  rm "$(key_variable_path KEK)" "$(key_variable_path db)"
  run_cli setup && fail_test "setup accepted a rebuild plan with a second PK entry"
  [[ $(<"$FIX/run/output") == *'rebuild plan does not hold your certificates'* ]] || fail_test "report: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "an unsound plan was written"
}

# Firmware whose key menu clears everything: sbctl can put back the local
# keys, Microsoft's and the firmware's defaults; what it cannot is named, and
# an interrupted rebuild is finished by the next run.
cleared_firmware_is_rebuilt_with_the_loss_named() {
  prepared_machine
  delete_platform_key
  rm "$(key_variable_path KEK)" "$(key_variable_path db)" "$(key_variable_path dbx)"
  write_key_variable KEKDefault "$(x509_list "$OEM_OWNER" 'OEM KEK' | base64 -w0)"
  write_key_variable dbDefault "$(x509_list "$OEM_OWNER" 'OEM db' | base64 -w0)"
  CONFIRM_ANSWER=no run_cli setup && fail_test "a declined rebuild went on"
  grep -q '^QUESTION: Rebuild KEK and db as described above' "$FIX/run/output" || fail_test "the rebuild was not asked about in its own words: $(<"$FIX/run/output")"
  ! grep -q -- '--partial' "$FIX/run/calls" || fail_test "a declined rebuild wrote to the firmware"
  : >"$FIX/run/sbctl-enroll-fails-at-KEK"
  run_cli setup && fail_test "a failed KEK write reported success"
  rm "$FIX/run/sbctl-enroll-fails-at-KEK"
  : >"$FIX/run/calls"
  run_cli setup || fail_test "the rebuild was not finished by the next run: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'cleared KEK and db together with the Platform Key'* ]] || fail_test "report: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'cannot be put back'* && $(<"$FIX/run/output") == *'revocation list (dbx) differs'* ]] || fail_test "the loss was not named: $(<"$FIX/run/output")"
  ! grep -q -- '--partial db' "$FIX/run/calls" || fail_test "db was written a second time"
  grep -q 'enroll-keys --microsoft --firmware-builtin --partial KEK --ignore-immutable' "$FIX/run/calls" || fail_test "calls: $(<"$FIX/run/calls")"
  cmp -s <(tail -c +5 "$(key_variable_path PK)") <(x509_list "$LOCAL_OWNER" 'local PK certificate') || fail_test "the PK is not the local certificate alone"
  [[ $(grep -aoF 'local db certificate' "$(key_variable_path db)" | wc -l) == 1 ]] || fail_test "db holds the local certificate twice"
  [[ $(<"$FIX/run/output") == *'Your keys are enrolled'* ]] || fail_test "not enrolled: $(<"$FIX/run/output")"
  [[ ! -e $(key_variable_path dbx) ]] || fail_test "the rebuild wrote dbx, which nothing here ever writes"
}

# The same firmware meeting this tool for the first time: the only backup is
# an empty one, which must not read as "nothing was lost".
firmware_cleared_before_the_first_setup_is_rebuilt() {
  delete_platform_key
  rm "$(key_variable_path KEK)" "$(key_variable_path db)"
  run_cli setup || fail_test "first setup failed: $(<"$FIX/run/output")"
  run_cli setup || fail_test "second setup failed: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'taken in Setup Mode'* && $(<"$FIX/run/output") == *'cleared KEK and db'* ]] || fail_test "report: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'does not expose its built-in defaults'* ]] || fail_test "the missing defaults were not named: $(<"$FIX/run/output")"
  grep -q 'enroll-keys --microsoft --partial db --ignore-immutable' "$FIX/run/calls" || fail_test "calls: $(<"$FIX/run/calls")"
  ! grep -q 'enroll-keys --append --partial' "$FIX/run/calls" || fail_test "empty variables were appended to"
  grep -aqF 'Microsoft db as sbctl ships it' "$(key_variable_path db)" || fail_test "db got the local certificate alone"
}

# A later backup taken in Setup Mode never replaces the one that shows what
# the key menu removed.
proof_uses_the_backup_taken_with_the_pk_in_place() {
  local first
  prepared_machine
  first=$(latest_firmware_backup)
  run_cli remove || fail_test "remove failed: $(<"$FIX/run/output")"
  delete_platform_key
  write_key_variable db "$(x509_list "$OEM_OWNER" 'OEM db' | base64 -w0)"
  sleep 1
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  [[ $(reference_backup) == "$first" ]] || fail_test "reference: $(reference_backup)"
  run_cli setup && fail_test "the loss went unnoticed behind a later backup"
  [[ $(<"$FIX/run/output") == *'db: certificate with SHA-256 fingerprint'* && $(<"$FIX/run/output") != *'taken in Setup Mode'* ]] || fail_test "report: $(<"$FIX/run/output")"
}

# The backup is root's alone whatever the caller's umask, holds no mode value
# it did not read, and is refused when an existing backup is later than the
# clock: a name from a clock that ran ahead would keep the reference at an
# old backup (C10).
# A backup that somebody else could have written serves nobody, whatever its
# sums say (D9), and the root of the backups is judged as it is, never set
# right through a link.
unsafe_backups_are_passed_over() {
  local backup root target
  printf 0 >"$FIX/run/clock"
  date() { local n; n=$(($(<"$FIX/run/clock") + 1)); printf '%s' "$n" >"$FIX/run/clock"; printf '20260101T00000%sZ\n' "$n"; }
  root=$(firmware_backup_root)
  backup=$(take_firmware_backup) || fail_test "backup"
  [[ $(latest_firmware_backup) == "$backup" && $(reference_backup) == "$backup" ]] || fail_test "a fresh backup does not serve"
  chmod 777 "$backup"
  { ! latest_firmware_backup >/dev/null && ! reference_backup >/dev/null; } || fail_test "a world-writable backup served"
  chmod 700 "$backup"
  chmod 666 "$backup/db"
  { ! latest_firmware_backup >/dev/null && ! reference_backup >/dev/null; } || fail_test "a backup with a world-writable file served"
  chmod 600 "$backup/db"
  [[ $(take_firmware_backup) == "$backup" ]] || fail_test "the backup did not serve again once it was root's alone"
  # What earlier builds of the tool wrote as root under umask 022 stays usable.
  chmod 755 "$backup" && chmod 644 "$backup"/*
  [[ $(latest_firmware_backup) == "$backup" && $(reference_backup) == "$backup" ]] || fail_test "a 755/644 backup, root's alone, was passed over"
  target=$FIX/run/elsewhere
  mkdir -m 700 "$target"
  mv "$root" "$FIX/run/backups-aside"
  ln -s "$target" "$root"
  ! take_firmware_backup >/dev/null 2>&1 || fail_test "a backup was taken through a link"
  [[ $(stat -c %a "$target") == 700 && -z $(command ls -A "$target") ]] || fail_test "the link's target was touched: mode $(stat -c %a "$target"), $(command ls -A "$target" | wc -l) entries"
  rm "$root"
  mv "$FIX/run/backups-aside" "$root"
  [[ $(reference_backup) == "$backup" ]] || fail_test "the backup does not serve with its root back"
}

backup_is_root_only_complete_and_ordered() {
  local backup db
  # Names come from the clock, one per second; the case takes several backups
  # in a row, so it hands out ascending names of its own, counted in a file
  # because the backups are taken in subshells.
  printf 0 >"$FIX/run/clock"
  date() { local n; n=$(($(<"$FIX/run/clock") + 1)); printf '%s' "$n" >"$FIX/run/clock"; printf '20260101T00000%sZ\n' "$n"; }
  backup=$(umask 000; take_firmware_backup) || fail_test "backup"
  [[ $(stat -c %a "$(firmware_backup_root)") == 755 && $(stat -c %a "$backup") == 700 && $(stat -c %a "$backup/db") == 600 && $(stat -c %a "$backup/modes") == 600 ]] || fail_test "modes: $(stat -c %a "$(firmware_backup_root)" "$backup" "$backup/db" "$backup/modes" | tr '\n' ' ')"
  backup_is_complete "$backup" || fail_test "the backup is not complete"
  grep -qx 'SetupMode=0' "$backup/modes" || fail_test "modes file: $(<"$backup/modes")"
  db=$(key_variable_path db)
  printf 'changed' >>"$db"
  ( read_mode_variable() { return 1; }; take_firmware_backup >/dev/null 2>&1 ) && fail_test "a backup was taken with unread mode variables"
  rm -rf "$(firmware_backup_root)/20260101T000002Z"
  # An incomplete directory with a later name is nobody's reference and is passed over.
  mkdir "$(firmware_backup_root)/20990101T000000Z"
  take_firmware_backup >/dev/null 2>&1 || fail_test "an incomplete directory with a later name stopped the backup"
  rmdir "$(firmware_backup_root)/20990101T000000Z"
  mv "$backup" "$(firmware_backup_root)/20990101T000000Z"
  printf 'changed again' >>"$db"
  take_firmware_backup >/dev/null 2>"$FIX/run/backup-error" && fail_test "a backup was taken beside one later than the clock"
  { grep -q 'later than the clock reads now' "$FIX/run/backup-error" && grep -q 'move it out of' "$FIX/run/backup-error"; } || fail_test "no reason: $(<"$FIX/run/backup-error")"
  [[ $(basename "$(reference_backup)") == 20990101T000000Z ]] || fail_test "the reference: $(reference_backup)"
}

# A rebuild plan that holds only the local certificate, even twice, promises
# nothing of what the key menu cleared (D9).
rebuild_plan_needs_more_than_the_local_entry() {
  prepared_machine
  read_enrollment_plan || fail_test "plan"
  _planned[PK]=${_local[PK]}
  _planned[KEK]=$(printf '%s\n%s\n' "${_local[KEK]}" "${_local[KEK]}")
  _planned[db]=$(printf '%s\n%s\n' "${_local[db]}" "${_local[db]}")
  rebuild_plan_is_sound && fail_test "a plan of local entries alone read as sound"
  _planned[KEK]=$(printf '%s\n%s\n' "${_local[KEK]}" "${_current[KEK]}" | sort -u)
  _planned[db]=$(printf '%s\n%s\n' "${_local[db]}" "${_current[db]}" | sort -u)
  rebuild_plan_is_sound || fail_test "a plan with the firmware's entries read as unsound"
}

# The firmware step reads the mode variables once and stops when it cannot,
# instead of taking an empty value for "off".
firmware_step_needs_readable_modes() {
  local output
  prepared_machine
  # The step is the dispatcher's, so it runs as the CLI process runs, in a
  # process of its own with the fixture's overrides and one reader that fails.
  # shellcheck disable=SC2016 # The process expands its own variables.
  output=$(ROOT_DIR=$ROOT_DIR bash -c '
    source "$ROOT_DIR/tests/lib/harness.sh"
    source "$ROOT_DIR/bin/omasecboot"
    fixture_overrides
    read_mode_variable() { return 1; }
    setup_firmware_step false' 2>&1) && fail_test "the firmware step went on without the mode variables"
  [[ $output == *"Could not read the firmware's SecureBoot and SetupMode variables"* ]] || fail_test "no reason: ${output}"
}

run_case signature-lists-are-read-entry-by-entry signature_lists_are_read_entry_by_entry
run_case backup-is-taken-once-and-complete backup_is_taken_once_and_complete
run_case local-certificates-are-found-by-owner local_certificates_are_found_by_owner
run_case plan-proofs-refuse-what-was-not-asked-for plan_proofs_refuse_what_was_not_asked_for
run_case empty-never-means-append empty_never_means_append
run_case half-cleared-firmware-is-refused half_cleared_firmware_is_refused
run_case rotated-keys-are-enrolled-beside-the-old-ones rotated_keys_are_enrolled_beside_the_old_ones
run_case enrollment-appends-and-reads-back enrollment_appends_and_reads_back
run_case interrupted-enrollment-is-finished-without-duplicates interrupted_enrollment_is_finished_without_duplicates
run_case write-is-judged-by-reading-back write_is_judged_by_reading_back
run_case lost-entries-are-named lost_entries_are_named
run_case setup-asks-for-the-pk-then-enrolls-then-confirms setup_asks_for_the_pk_then_enrolls_then_confirms
run_case missing-2023-kek-is-asked-about-before-the-pk-goes missing_2023_kek_is_asked_about_before_the_pk_goes
run_case first-run-never-writes-to-the-firmware first_run_never_writes_to_the_firmware
run_case partial-loss-is-refused partial_loss_is_refused
run_case changed-dbx-is-refused changed_dbx_is_refused
run_case audit-mode-is-refused audit_mode_is_refused
run_case non-volatile-defaults-are-not-used non_volatile_defaults_are_not_used
run_case unsound-answers-from-sbctl-stop-setup unsound_answers_from_sbctl_stop_setup
run_case cleared-firmware-is-rebuilt-with-the-loss-named cleared_firmware_is_rebuilt_with_the_loss_named
run_case firmware-cleared-before-the-first-setup-is-rebuilt firmware_cleared_before_the_first_setup_is_rebuilt
run_case proof-uses-the-backup-taken-with-the-pk-in-place proof_uses_the_backup_taken_with_the_pk_in_place
run_case backup-is-root-only-complete-and-ordered backup_is_root_only_complete_and_ordered
run_case unsafe-backups-are-passed-over unsafe_backups_are_passed_over
run_case rebuild-plan-needs-more-than-the-local-entry rebuild_plan_needs_more_than_the_local_entry
run_case firmware-step-needs-readable-modes firmware_step_needs_readable_modes
finish_suite
