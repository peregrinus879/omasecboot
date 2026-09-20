#!/bin/bash
# The Windows entry: the target read from the firmware's boot entries, the
# managed entry in limine.conf and when it may be touched, the BootNext
# request, and the encryption acknowledgment before anything changes what
# Windows measures at boot.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init windows

readonly WINDOWS_FILE='\EFI\Microsoft\Boot\bootmgfw.efi'
entry_count() { grep -cxF -e "    $WINDOWS_ENTRY_COMMENT" "$FIX/esp/limine.conf"; }
row() { printf '%s\x1f%s\x1f%s\x1f%s' "$@"; }

set_up_with_windows() {
  add_windows
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  run_cli windows setup || fail_test "windows setup failed: $(<"$FIX/run/output")"
}

boot_entries_are_read_from_the_firmware() {
  local entries
  write_boot_entry 0000 active 'Windows Boot Manager' "$WINDOWS_FILE"
  write_boot_entry 001A inactive 'Überlänge ✓' '\EFI\other\loader.efi'
  write_boot_entry 0003 active 'Not in BootOrder' '\EFI\third\loader.efi'
  # 0009 is a hole: firmware keeps the number after the entry is gone.
  write_boot_order 0001 0009 0000 001A
  entries=$(list_boot_entries) || fail_test "the boot entries were refused"
  [[ $entries == "$(row 0001 active Limine '\EFI\limine\limine_x64.efi')"$'\n'"$(row 0000 active 'Windows Boot Manager' "$WINDOWS_FILE")"$'\n'"$(row 001A inactive 'Überlänge ✓' '\EFI\other\loader.efi')"$'\n'"$(row 0003 active 'Not in BootOrder' '\EFI\third\loader.efi')" ]] ||
    fail_test "entries: ${entries}"

  # A firmware that names its variables in lower case still shows its entries.
  mv "$FIX/efivars/Boot001A-8be4df61-93ca-11d2-aa0d-00e098032b8c" "$FIX/efivars/Boot001a-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  [[ $(list_boot_entries) == *"$(row 001A inactive 'Überlänge ✓' '\EFI\other\loader.efi')"* ]] || fail_test "a lower-case variable name hid its entry"
  mv "$FIX/efivars/Boot001a-8be4df61-93ca-11d2-aa0d-00e098032b8c" "$FIX/efivars/Boot001A-8be4df61-93ca-11d2-aa0d-00e098032b8c"

  # Only the first device path is the boot target: a second one that names
  # bootmgfw.efi does not make an entry Windows.
  write_boot_entry 0003 active 'Decoy' '\EFI\third\loader.efi' "$(file_path_node "$WINDOWS_FILE")7fff0400"
  [[ $(list_boot_entries) == *"$(row 0003 active Decoy '\EFI\third\loader.efi')" ]] || fail_test "a second device path was read as the target"
  # A control character cannot forge or split a row.
  write_boot_entry 0003 active $'Two\nlines' '\EFI\third\loader.efi'
  [[ $(list_boot_entries) == *"$(row 0003 active 'Two#lines' '\EFI\third\loader.efi')" ]] || fail_test "a newline in a label was kept"

  head -c 20 "$FIX/efivars/Boot0000-8be4df61-93ca-11d2-aa0d-00e098032b8c" >"$FIX/efivars/Boot001A-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  ! list_boot_entries >/dev/null || fail_test "a truncated boot entry was accepted"
  # A node of length zero must end the walk, not repeat it for ever.
  {
    printf '\x07\x00\x00\x00\x01\x00\x00\x00\x08\x00Z\x00\x00\x00'
    hex_bytes 0404000004040000
  } >"$FIX/efivars/Boot001A-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  local rc=0
  # shellcheck disable=SC2016 # The child shell expands its own ROOT_DIR.
  timeout 10 bash -c 'source "$ROOT_DIR/tests/lib/harness.sh"; load_library; list_boot_entries' >/dev/null 2>&1 || rc=$?
  (( rc == 1 )) || fail_test "a zero-length node: status ${rc} (124 is a walk that never ends)"
}

# One active Windows Boot Manager entry whose name no other entry shares, or
# no target at all: this tool never guesses and never touches firmware entries.
target_is_one_clear_entry_or_none() {
  local status=0
  resolve_windows_target || status=$?
  (( status == 1 )) || fail_test "a machine without Windows: status ${status}"
  add_windows
  resolve_windows_target || fail_test "the plain dual-boot machine was refused"
  [[ $(windows_target_number) == 0000 && $(windows_target_label) == 'Windows Boot Manager' ]] || fail_test "target: $(windows_target_number) $(windows_target_label)"

  write_boot_entry 0002 active 'Windows on the second disk' '\EFI\Microsoft\Boot\BOOTMGFW.EFI'
  write_boot_order 0001 0000 0002
  ! resolve_windows_target || fail_test "two Windows entries resolved to one"
  [[ -z $(windows_target_label) ]] || fail_test "a refused target was left behind"
  write_boot_entry 0002 inactive 'Second disk' "$WINDOWS_FILE"
  resolve_windows_target || fail_test "an inactive second entry hid the target"
  # The name must be the entry's alone among everything the firmware holds,
  # in BootOrder or not, whatever the case.
  write_boot_entry 0002 active 'windows boot manager' '\EFI\other\loader.efi'
  write_boot_order 0001 0000
  ! resolve_windows_target || fail_test "a label another entry shares, in other case and outside BootOrder, was accepted"
  write_boot_entry 0002 active 'Windows Boot Manager 2' '\EFI\other\loader.efi'
  resolve_windows_target || fail_test "a longer label counted as the same"
  for label in 'Windows # one' $'Windows\x01Manager' ''; do
    write_boot_entry 0000 active "$label" "$WINDOWS_FILE"
    ! resolve_windows_target || fail_test "a label that limine.conf cannot carry was accepted: '${label}'"
  done

  rm "$FIX/efivars/BootOrder-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  status=0
  resolve_windows_target || status=$?
  (( status == 2 )) || fail_test "unreadable entries: status ${status}"
}

entry_is_written_once_and_taken_out_whole() {
  local before=$FIX/run/limine-before inode
  # Writing and taking out again leaves the file it started from.
  cp "$FIX/esp/limine.conf" "$before"
  { write_windows_entry 'Windows Boot Manager' && write_windows_entry; } || fail_test "round trip"
  cmp -s "$FIX/esp/limine.conf" "$before" || fail_test "a round trip changed limine.conf: $(diff "$before" "$FIX/esp/limine.conf")"
  # A last line without its newline, as an editor may leave it.
  printf '/Mine\n    protocol: efi\n    path: boot():/EFI/mine.efi' >>"$FIX/esp/limine.conf"
  cp "$FIX/esp/limine.conf" "$before"
  write_windows_entry || fail_test "taking nothing out failed"
  cmp -s "$FIX/esp/limine.conf" "$before" || fail_test "a file without the entry was rewritten"

  write_windows_entry 'Windows Boot Manager' || fail_test "write"
  [[ $(windows_entry_state 'Windows Boot Manager') == current ]] || fail_test "state after writing"
  grep -qx '    protocol: efi_boot_entry' "$FIX/esp/limine.conf" || fail_test "protocol line"
  grep -qx '    entry: Windows Boot Manager' "$FIX/esp/limine.conf" || fail_test "entry line"
  printf '\n/After\n    protocol: efi\n' >>"$FIX/esp/limine.conf"
  inode=$(stat -c %i "$FIX/esp/limine.conf")
  write_windows_entry 'Windows Boot Manager' || fail_test "second write"
  [[ $(entry_count) == 1 ]] || fail_test "a second write added a second entry"
  [[ $(stat -c %i "$FIX/esp/limine.conf") == "$inode" ]] || fail_test "limine.conf was replaced although nothing changed"
  [[ $(windows_entry_state 'Another name') == stale ]] || fail_test "an entry for another label read as current"
  write_windows_entry 'Another name' || fail_test "rewrite"
  [[ $(entry_count) == 1 && $(windows_entry_state 'Another name') == current ]] || fail_test "a stale entry was not replaced"
  grep -qx '/After' "$FIX/esp/limine.conf" || fail_test "the user's entry after this tool's was lost"
  write_windows_entry || fail_test "removal"
  [[ $(windows_entry_state '') == absent ]] || fail_test "state after removal"
  { grep -qx '/Mine' "$FIX/esp/limine.conf" && grep -qx '/After' "$FIX/esp/limine.conf"; } || fail_test "removal took more than the entry"
  cmp -s <(head -c "$(stat -c %s "$before")" "$FIX/esp/limine.conf") "$before" || fail_test "the lines before the entry changed"
  # Two entries of this tool, as a restored file could hold: one remains.
  { windows_entry 'Windows Boot Manager'; windows_entry 'Windows Boot Manager'; } >>"$FIX/esp/limine.conf"
  [[ $(windows_entry_state 'Windows Boot Manager') == stale ]] || fail_test "a doubled entry read as $(windows_entry_state 'Windows Boot Manager')"
  write_windows_entry 'Windows Boot Manager' || fail_test "rewrite of a doubled entry"
  [[ $(entry_count) == 1 && $(windows_entry_state 'Windows Boot Manager') == current ]] || fail_test "a doubled entry was not settled"
}

# The entry is this tool's only when it is the header "/Windows" over nothing
# but this tool's keys. Its comment anywhere else may stand in the user's own
# entry, so nothing is deleted and the reason is given.
misplaced_comment_is_never_deleted() {
  local before=$FIX/run/limine-before output misplaced
  for misplaced in \
    "/Omarchy rescue"$'\n'"    ${WINDOWS_ENTRY_COMMENT}"$'\n'"    protocol: efi_boot_entry"$'\n' \
    "/Windows"$'\n'"    ${WINDOWS_ENTRY_COMMENT}"$'\n'"    protocol: efi"$'\n'"    path: boot():/EFI/mine.efi"$'\n' \
    "/Windows"$'\n'"    ${WINDOWS_ENTRY_COMMENT}"$'\n'"//Child"$'\n'"    protocol: efi"$'\n' \
    "    ${WINDOWS_ENTRY_COMMENT}"$'\n'; do
    write_limine_conf unhashed
    printf '\n%s' "$misplaced" >>"$FIX/esp/limine.conf"
    cp "$FIX/esp/limine.conf" "$before"
    [[ $(windows_entry_state x) == misplaced ]] || fail_test "state: $(windows_entry_state x) for: ${misplaced}"
    output=$(write_windows_entry 'Windows Boot Manager' 2>&1) && fail_test "limine.conf was rewritten around a misplaced comment"
    [[ $output == *'by hand'* ]] || fail_test "no reason: ${output}"
    output=$(write_windows_entry 2>&1) && fail_test "an entry that is not this tool's was taken out"
    cmp -s "$FIX/esp/limine.conf" "$before" || fail_test "a refused rewrite changed limine.conf"
  done
}

# What the hardware showed (C8): when upstream rewrites limine.conf it drops a
# comment line that stands between its own entries and a foreign one, and keeps
# the foreign entry. The entry must still be this tool's afterwards, for the
# report and for taking it out.
entry_survives_upstreams_rewrite() {
  set_up_with_windows
  sed -i 's|^/Windows$|# a comment line above the entry\n/Windows|' "$FIX/esp/limine.conf"
  run_cli sign || fail_test "sign failed: $(<"$FIX/run/output")"
  run_unlocked limine-mkinitcpio || fail_test "upstream's rewrite"
  ! grep -q '^# a comment line above the entry$' "$FIX/esp/limine.conf" || fail_test "the stub kept the comment line, unlike upstream"
  [[ $(windows_entry_state 'Windows Boot Manager') == current ]] || fail_test "after upstream's rewrite the entry reads as $(windows_entry_state 'Windows Boot Manager')"
  run_cli status || fail_test "status after upstream's rewrite: $(<"$FIX/run/output")"
  run_cli windows remove || fail_test "windows remove after upstream's rewrite: $(<"$FIX/run/output")"
  [[ $(entry_count) == 0 ]] || fail_test "the entry stayed"
}

# limine.conf is only written when that is safe: by root alone, with room on
# the ESP, and still the file that was read (Omarchy replaces it outside any
# lock, C7).
unsafe_writes_are_refused() {
  local before=$FIX/run/limine-before
  cp "$FIX/esp/limine.conf" "$before"
  chmod 666 "$FIX/esp/limine.conf"
  ! write_windows_entry 'Windows Boot Manager' 2>/dev/null || fail_test "a world-writable limine.conf was rewritten"
  chmod 644 "$FIX/esp/limine.conf"
  (
    free_bytes() { printf '4096\n'; }
    ! write_windows_entry 'Windows Boot Manager' 2>/dev/null
  ) || fail_test "limine.conf was rewritten on a full ESP"
  (
    scan_windows_entries() {
      cat "$FIX/esp/limine.conf"
      [[ $1 != without ]] || printf 'timeout: 1\n' >>"$FIX/esp/limine.conf"
    }
    ! write_windows_entry 'Windows Boot Manager' 2>/dev/null
  ) || fail_test "a limine.conf that changed meanwhile was overwritten"
  sed -i '$d' "$FIX/esp/limine.conf"
  cmp -s "$FIX/esp/limine.conf" "$before" || fail_test "a refused write changed limine.conf"
  rm "$FIX/esp/limine.conf"
  [[ $(windows_entry_state x) == unknown ]] || fail_test "a missing limine.conf: $(windows_entry_state x)"
}

# Omarchy replaces limine.conf from its template (C7); the opt-in brings the
# entry back with the next pass, and the loader is sealed over the result.
entry_comes_back_after_limine_conf_is_replaced() {
  set_up_with_windows
  [[ -e $(windows_flag) && $(entry_count) == 1 ]] || fail_test "flag or entry missing"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader is not sealed over the new limine.conf"
  run_cli windows available || fail_test "the menu guard refuses a working entry"
  [[ ! -s $FIX/run/output ]] || fail_test "the guard printed: $(<"$FIX/run/output")"
  run_cli windows status || fail_test "windows status failed"
  [[ $(<"$FIX/run/output") == *'Target: Boot0000, Windows Boot Manager'* && $(<"$FIX/run/output") == *'is current'* ]] || fail_test "windows status: $(<"$FIX/run/output")"
  run_cli status || fail_test "status: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'restarts the machine into Windows Boot Manager'* ]] || fail_test "status does not show the entry"

  write_limine_conf unhashed
  run_cli status && fail_test "status passed without the entry"
  [[ $(<"$FIX/run/output") == *'Windows entry is missing from limine.conf'* && $(<"$FIX/run/output") == *'Next: sudo omasecboot sign'* ]] || fail_test "status: $(<"$FIX/run/output")"
  run_cli sign --quiet --seal-only || fail_test "the watcher's pass failed: $(<"$FIX/run/output")"
  [[ $(entry_count) == 1 ]] || fail_test "the entry did not come back"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader is not sealed over the restored entry"
}

# Taking the entry out is an edit of a sealed file too: under the lock, sealed
# in the same pass, or only while the loader carries no checksum.
entry_is_only_taken_out_when_the_loader_follows() {
  local rc=0
  set_up_with_windows
  flock -o "$(boot_lock_path)" sleep 5 &
  sleep 0.3
  run_cli windows remove || rc=$?
  kill %1 2>/dev/null
  (( rc == 75 )) || fail_test "busy: ${rc}"
  [[ -e $(windows_flag) && $(entry_count) == 1 ]] || fail_test "a busy windows remove changed something"
  : >"$(restore_marker_path)"
  run_cli windows remove && fail_test "windows remove ran during a snapshot restore"
  [[ $(entry_count) == 1 && -e $(windows_flag) ]] || fail_test "something changed during a restore"
  [[ $(<"$FIX/run/output") == *'snapshot restore is running'* ]] || fail_test "report: $(<"$FIX/run/output")"
  rm "$(restore_marker_path)"

  # Not set up, but the loader is still sealed (a remove that stopped half way).
  rm "$(enabled_marker)"
  run_cli windows remove && fail_test "limine.conf was edited under a sealed loader nobody re-seals"
  [[ $(<"$FIX/run/output") == *'sealed over the current limine.conf'* && $(entry_count) == 1 ]] || fail_test "report: $(<"$FIX/run/output")"
  : >"$(enabled_marker)"
  run_cli windows remove || fail_test "windows remove failed: $(<"$FIX/run/output")"
  [[ ! -e $(windows_flag) && $(entry_count) == 0 ]] || fail_test "flag or entry left"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader is not sealed after the removal"
  run_cli windows available && fail_test "the guard accepts a removed entry"

  # Not set up and the loader raw: nothing to seal, the edit is safe.
  run_cli remove || fail_test "remove failed: $(<"$FIX/run/output")"
  write_windows_entry 'Windows Boot Manager' || fail_test "fixture entry"
  run_cli windows remove || fail_test "windows remove on a raw loader failed: $(<"$FIX/run/output")"
  [[ $(entry_count) == 0 ]] || fail_test "the entry stayed"
}

# remove must leave a machine that boots at every point it can stop at: the
# entry goes only after the loader is proved raw.
failed_remove_keeps_limine_conf_and_loader_together() {
  set_up_with_windows
  : >"$FIX/run/limine-install-fails"
  run_cli remove && fail_test "a failed Limine tool went unnoticed"
  [[ $(entry_count) == 1 && -e $(windows_flag) ]] || fail_test "the entry went before the loader was unsealed"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "limine.conf and the sealed loader were torn apart"
  rm "$FIX/run/limine-install-fails"
  run_cli remove || fail_test "second remove failed: $(<"$FIX/run/output")"
  [[ $(entry_count) == 0 && ! -e $(windows_flag) ]] || fail_test "remove left the Windows entry behind"
  cmp -s "$(primary_loader_path)" "$FIX/share/BOOTX64.EFI" || fail_test "the primary is not raw"
}

# The entry is a matter for the report, never a reason to fail a pass that
# runs inside a kernel update: the loader is sealed and Omarchy boots.
entry_problems_are_reported_not_failed() {
  local output
  add_windows
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  # This tool's comment in somebody's entry, on a machine that never enabled ours.
  printf '    %s\n' "$WINDOWS_ENTRY_COMMENT" >>"$FIX/esp/limine.conf"
  run_cli sign --quiet || fail_test "a misplaced comment failed the pass: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") == *'by hand'* && ! -e $(attention_marker) ]] || fail_test "pass: $(<"$FIX/run/output")"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader is not sealed over limine.conf as it stands"
  run_cli status && fail_test "status passed over a misplaced comment"
  [[ $(<"$FIX/run/output") == *'by hand'* && $(<"$FIX/run/output") == *'Next: resolve what is marked above'* ]] || fail_test "status: $(<"$FIX/run/output")"
  sed -i '$d' "$FIX/esp/limine.conf"

  # An entry without the opt-in: the next pass takes it out, and status says so.
  { boot_lock_acquire && write_windows_entry 'Windows Boot Manager' && ensure_primary_loader >/dev/null && boot_lock_release; } || fail_test "fixture entry"
  run_cli status && fail_test "status passed over an entry that is not enabled"
  [[ $(<"$FIX/run/output") == *'although the entry is not enabled'* && $(<"$FIX/run/output") == *'Next: sudo omasecboot sign'* ]] || fail_test "status: $(<"$FIX/run/output")"
  run_cli sign || fail_test "sign failed: $(<"$FIX/run/output")"
  [[ $(entry_count) == 0 && $(<"$FIX/run/output") == *'Taking the Windows entry out'* ]] || fail_test "the pass did not take the entry out: $(<"$FIX/run/output")"

  # Enabled, with an entry for another name, then with entries that cannot be read.
  run_cli windows setup || fail_test "windows setup failed: $(<"$FIX/run/output")"
  sed -i 's/^    entry: Windows Boot Manager$/    entry: Another name/' "$FIX/esp/limine.conf"
  output=$(show_windows_status 2>&1)
  [[ $output == *'is not the one for Windows Boot Manager'* ]] || fail_test "stale: ${output}"
  mv "$FIX/efivars/BootOrder-8be4df61-93ca-11d2-aa0d-00e098032b8c" "$FIX/run/BootOrder"
  output=$(show_windows_status 2>&1)
  [[ $output == *'boot entries could not be read'* ]] || fail_test "unreadable entries: ${output}"
  run_cli windows status || fail_test "windows status failed"
  [[ $(<"$FIX/run/output") == *"Could not read the firmware's boot entries"* ]] || fail_test "windows status: $(<"$FIX/run/output")"
  run_cli windows bootnext && fail_test "bootnext ran without readable entries"
  [[ $(<"$FIX/run/output") == *'Could not read'* ]] || fail_test "bootnext: $(<"$FIX/run/output")"
  local rc=0
  run_cli windows available || rc=$?
  (( rc == 1 )) || fail_test "the guard's status for unreadable entries: ${rc}"
}

# Windows was removed, or a second entry appeared: Omarchy still boots, so the
# pass goes on quietly and the report names the way out.
lost_target_is_left_to_the_report() {
  set_up_with_windows
  write_boot_order 0001
  rm "$FIX/efivars/Boot0000-8be4df61-93ca-11d2-aa0d-00e098032b8c"
  write_limine_conf unhashed
  run_cli sign --quiet || fail_test "a lost Windows target failed the pass: $(<"$FIX/run/output")"
  [[ ! -s $FIX/run/output && ! -e $(attention_marker) ]] || fail_test "the quiet pass spoke or left the marker: $(<"$FIX/run/output")"
  loader_is_sealed_and_signed "$(primary_loader_path)" || fail_test "the loader is not sealed"
  run_cli windows available && fail_test "the guard accepts an entry without a target"
  run_cli status && fail_test "status passed"
  [[ $(<"$FIX/run/output") == *'windows remove'* ]] || fail_test "status does not name the way out: $(<"$FIX/run/output")"
  ! run_cli windows setup || fail_test "windows setup ran without a target"
}

# The pass goes on without the entry when it cannot read the firmware at that
# moment, so the command looks at limine.conf before it reports success.
setup_reports_what_reached_limine_conf() {
  add_windows
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  : >"$FIX/run/pass-cannot-read-the-boot-entries"
  run_cli windows setup && fail_test "windows setup reported an entry that is not in limine.conf"
  [[ $(<"$FIX/run/output") == *'did not reach limine.conf'* ]] || fail_test "report: $(<"$FIX/run/output")"
}

setup_without_a_target_changes_nothing() {
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  cp "$FIX/esp/limine.conf" "$FIX/run/limine-before"
  run_cli windows setup && fail_test "windows setup ran without a target"
  [[ $(<"$FIX/run/output") == *'never creates or renames firmware entries'* ]] || fail_test "report: $(<"$FIX/run/output")"
  [[ ! -e $(windows_flag) ]] || fail_test "a refused windows setup left the flag"
  cmp -s "$FIX/esp/limine.conf" "$FIX/run/limine-before" || fail_test "a refused windows setup changed limine.conf"
  local rc=0
  run_cli windows nonsense || rc=$?
  (( rc == 2 )) || fail_test "an unknown windows command is not a usage error"
}

bootnext_is_judged_by_reading_back() {
  local variable=$FIX/efivars/BootNext-8be4df61-93ca-11d2-aa0d-00e098032b8c
  run_cli windows bootnext && fail_test "a request without a target reported success"
  [[ $(<"$FIX/run/output") == *'no request was made'* ]] || fail_test "report: $(<"$FIX/run/output")"
  ! grep -q '^efibootmgr' "$FIX/run/calls" || fail_test "efibootmgr ran without a target"
  write_boot_entry 00A0 active 'Windows Boot Manager' "$WINDOWS_FILE"
  write_boot_order 0001 00A0
  run_cli windows bootnext || fail_test "bootnext failed: $(<"$FIX/run/output")"
  grep -qx 'efibootmgr --bootnext 00A0' "$FIX/run/calls" || fail_test "calls: $(<"$FIX/run/calls")"
  cmp -s "$variable" <(printf '\x07\x00\x00\x00\xa0\x00') || fail_test "BootNext bytes"
  [[ $(<"$FIX/run/output") == *'holds the request'* ]] || fail_test "wording: $(<"$FIX/run/output")"
  # Firmware that reports success and keeps an older request.
  printf '\x07\x00\x00\x00\x01\x00' >"$variable"
  : >"$FIX/run/firmware-ignores-bootnext"
  run_cli windows bootnext && fail_test "a request the firmware ignored reported success"
  [[ $(<"$FIX/run/output") == *'does not read back'* ]] || fail_test "report: $(<"$FIX/run/output")"
}

# Deleting the PK and writing keys both change what Windows measures, so each
# is preceded by the question; turning Secure Boot on gets a reminder; a
# machine without Windows is asked nothing, and what cannot be told is said.
encryption_is_acknowledged_before_the_firmware_changes() {
  add_windows
  CONFIRM_ANSWER=no run_cli setup && fail_test "setup went on although the acknowledgment was declined"
  [[ $(<"$FIX/run/output") == *'BitLocker-format volume: /dev/nvme0n1p3'* && $(<"$FIX/run/output") == *'Suspend-BitLocker'* ]] || fail_test "guidance: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") != *nvme0n1p5* && $(<"$FIX/run/output") != *'delete only the Platform Key'* ]] || fail_test "the instruction was given without the acknowledgment, or another volume was listed"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  [[ $(grep -c '^QUESTION: Is Windows encryption' "$FIX/run/output") == 1 ]] || fail_test "asked more than once in a run"
  grep -n 'QUESTION: Is Windows\|delete only' "$FIX/run/output" | head -1 | grep -q QUESTION || fail_test "the question came after the instruction"

  delete_platform_key
  : >"$FIX/run/calls"
  run_cli setup || fail_test "enrollment failed: $(<"$FIX/run/output")"
  grep -n 'QUESTION: Is Windows\|QUESTION: Write your keys' "$FIX/run/output" | head -1 | grep -q 'Is Windows' || fail_test "keys were written without the question: $(<"$FIX/run/output")"
  set_mode_variable SetupMode 0
  run_cli setup || fail_test "setup after the reboot failed"
  grep -n 'suspend BitLocker\|turn Secure Boot on' "$FIX/run/output" | head -1 | grep -q 'suspend BitLocker' || fail_test "no reminder before turning Secure Boot on: $(<"$FIX/run/output")"

  run_cli windows preflight || fail_test "preflight failed on a machine it could read"
  [[ $(<"$FIX/run/output") == *'Windows Home'* ]] || fail_test "preflight guidance"
  : >"$FIX/run/lsblk-fails"
  run_cli windows preflight && fail_test "preflight passed although the volumes could not be listed"
  [[ $(<"$FIX/run/output") == *'Could not tell'* ]] || fail_test "unknown: $(<"$FIX/run/output")"
}

unknown_encryption_state_is_asked_about() {
  : >"$FIX/run/lsblk-fails"
  CONFIRM_ANSWER=no run_cli setup && fail_test "an unknown encryption state was treated as none"
  [[ $(<"$FIX/run/output") == *'Could not tell'* && $(<"$FIX/run/output") != *'delete only the Platform Key'* ]] || fail_test "unknown at setup: $(<"$FIX/run/output")"
  rm "$FIX/run/lsblk-fails"
  run_cli windows preflight || fail_test "preflight failed on a machine without Windows"
  [[ $(<"$FIX/run/output") == *'not a clearance'* ]] || fail_test "absent: $(<"$FIX/run/output")"
  run_cli setup || fail_test "setup failed: $(<"$FIX/run/output")"
  [[ $(<"$FIX/run/output") != *QUESTION* ]] || fail_test "a machine without Windows was asked about it"
}

run_case boot-entries-are-read-from-the-firmware boot_entries_are_read_from_the_firmware
run_case target-is-one-clear-entry-or-none target_is_one_clear_entry_or_none
run_case entry-is-written-once-and-taken-out-whole entry_is_written_once_and_taken_out_whole
run_case misplaced-comment-is-never-deleted misplaced_comment_is_never_deleted
run_case entry-survives-upstreams-rewrite entry_survives_upstreams_rewrite
run_case unsafe-writes-are-refused unsafe_writes_are_refused
run_case entry-comes-back-after-limine-conf-is-replaced entry_comes_back_after_limine_conf_is_replaced
run_case entry-is-only-taken-out-when-the-loader-follows entry_is_only_taken_out_when_the_loader_follows
run_case failed-remove-keeps-limine-conf-and-loader-together failed_remove_keeps_limine_conf_and_loader_together
run_case entry-problems-are-reported-not-failed entry_problems_are_reported_not_failed
run_case lost-target-is-left-to-the-report lost_target_is_left_to_the_report
run_case setup-reports-what-reached-limine-conf setup_reports_what_reached_limine_conf
run_case setup-without-a-target-changes-nothing setup_without_a_target_changes_nothing
run_case bootnext-is-judged-by-reading-back bootnext_is_judged_by_reading_back
run_case encryption-is-acknowledged-before-the-firmware-changes encryption_is_acknowledged_before_the_firmware_changes
run_case unknown-encryption-state-is-asked-about unknown_encryption_state_is_asked_about
finish_suite
