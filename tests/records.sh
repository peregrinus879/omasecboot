#!/bin/bash
# The shareable copies of acceptance records: what identifies a machine or a
# person is renamed the same way in every record, what is the same on every
# machine stays, and nothing else changes.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init records

readonly PARTITION=a1b2c3d4-1111-2222-3333-444455556666
readonly LUKS=0f0e0d0c-aaaa-bbbb-cccc-ddddeeeeffff
readonly MACHINE_ID=0123456789abcdef0123456789abcdef
readonly UEFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
FILE_HASH=$(printf 'a%.0s' {1..64})
readonly FILE_HASH

# Two records as the recorder writes them, with every kind of value that names
# the machine or the person, one of them in the other letter case.
write_records() {
  local SESSION_MARK
  # The mark sudo and systemd print at the start of a session (OSC 3008).
  SESSION_MARK=$(printf '\033]3008;start=abc;user=root;hostname=testhost;machineid=%s\033%s' "$MACHINE_ID" "\\")
  mkdir -p "$FIX/records"
  cat >"$FIX/records/20260102T030405Z-1-setup.md" <<RECORD
# Acceptance record 1-setup
\$ bash -c git -C '/home/tester/omasecboot' rev-parse HEAD
Boot0000* Limine	HD(6,GPT,${PARTITION},0x800,0x400001)/\\EFI\\limine\\limine_x64.efi
      dp: 04 01 2a 00 06 00 d4 c3 b2 a1 11 11 22 22
SecureBoot-${UEFI_GLOBAL}
${FILE_HASH}  /boot/${MACHINE_ID}/limine_history/omarchy_linux.efi_sha256_${FILE_HASH}
cmdline: cryptdevice=UUID=${LUKS}:omarchy_root
2026-01-02T03:04:05+00:00 testhost sudo[12]:   tester : TTY=pts/0 ; PWD=/home/tester/omasecboot ; USER=root ; COMMAND=/usr/bin/omasecboot setup
${SESSION_MARK}Signing keys created
RECORD
  cat >"$FIX/records/20260102T040506Z-1-status.md" <<RECORD
# Acceptance record 1-status
HD(6,GPT,${PARTITION^^},0x800,0x400001)
path: boot():/${MACHINE_ID}/limine_history/omarchy_linux.efi_sha256_${FILE_HASH}
2026-01-02T04:05:06+00:00 testhost systemd[1]: Started the tester's session
RECORD
}

share() { bash "$ROOT_DIR/tests/acceptance-share.sh" "$FIX/records" >"$FIX/run/output" 2>&1; }

identifiers_are_renamed_and_the_rest_stays() {
  local first=$FIX/records/share/20260102T030405Z-1-setup.md second=$FIX/records/share/20260102T040506Z-1-status.md value
  write_records
  share || fail_test "the share step failed: $(<"$FIX/run/output")"
  for value in "$PARTITION" "${PARTITION^^}" "$LUKS" "$MACHINE_ID" /home/tester 'testhost sudo' 'hostname=testhost' '3008;' 'dp: 04'; do
    ! grep -q -F -- "$value" "$first" "$second" || fail_test "still in the copies: ${value}"
  done
  grep -q -F "HD(6,GPT,uuid-1,0x800,0x400001)" "$first" || fail_test "the partition is not uuid-1: $(grep HD "$first")"
  grep -q -F "HD(6,GPT,uuid-1,0x800,0x400001)" "$second" || fail_test "the same value in the other case got another name: $(grep HD "$second")"
  grep -q -F "cryptdevice=UUID=uuid-2:omarchy_root" "$first" || fail_test "the second UUID is not uuid-2"
  { grep -q -F "/boot/id-1/limine_history/" "$first" && grep -q -F "boot():/id-1/limine_history/" "$second"; } || fail_test "the machine-id is not id-1 in both"
  grep -q -F "SecureBoot-${UEFI_GLOBAL}" "$first" || fail_test "a UUID that every machine shares was renamed"
  [[ $(grep -c -F "$FILE_HASH" "$first") == 1 && $(grep -o -F "$FILE_HASH" "$first" | wc -l) == 2 ]] || fail_test "a file hash was changed"
  grep -q -F "2026-01-02T03:04:05+00:00 host sudo[12]:   user : TTY=pts/0 ; PWD=/home/user/omasecboot" "$first" || fail_test "the journal line: $(grep sudo "$first")"
  grep -q -x 'Signing keys created' "$first" || fail_test "text beside a session sequence was lost"
  # A name inside text the recorder did not place is left alone and pointed at.
  grep -q -F "the tester's session" "$second" || fail_test "free text was rewritten"
  [[ $(<"$FIX/run/output") == *'The name "tester" still occurs 1 times'* ]] || fail_test "the remaining name was not pointed at: $(<"$FIX/run/output")"
  [[ $(tar -tzf "$FIX/records/share/omasecboot-records.tgz" | sort | tr '\n' ' ') == '20260102T030405Z-1-setup.md 20260102T040506Z-1-status.md ' ]] || fail_test "archive: $(tar -tzf "$FIX/records/share/omasecboot-records.tgz")"
  cmp -s <(tar -xOzf "$FIX/records/share/omasecboot-records.tgz" 20260102T030405Z-1-setup.md) "$first" || fail_test "the archive does not hold the copy"
}

originals_stay_and_a_second_run_gives_the_same_names() {
  local before
  write_records
  before=$(sha256sum "$FIX"/records/*.md)
  share || fail_test "first run"
  cp -r "$FIX/records/share" "$FIX/run/first-share"
  share || fail_test "second run"
  [[ $(sha256sum "$FIX"/records/*.md) == "$before" ]] || fail_test "the records themselves were changed"
  diff -r -x '*.tgz' "$FIX/run/first-share" "$FIX/records/share" >/dev/null || fail_test "a second run named values differently, or copied its own copies"
}

nothing_to_share_is_a_usage_error() {
  local status=0
  mkdir -p "$FIX/records"
  share || status=$?
  (( status == 2 )) || fail_test "an empty directory: status ${status}"
  status=0
  bash "$ROOT_DIR/tests/acceptance-share.sh" "$FIX/no-such-directory" >/dev/null 2>&1 || status=$?
  (( status == 2 )) || fail_test "a missing directory: status ${status}"
}

run_case identifiers-are-renamed-and-the-rest-stays identifiers_are_renamed_and_the_rest_stays
run_case originals-stay-and-a-second-run-gives-the-same-names originals_stay_and_a_second_run_gives_the_same_names
run_case nothing-to-share-is-a-usage-error nothing_to_share_is_a_usage_error
finish_suite
