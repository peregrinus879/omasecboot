#!/bin/bash
# The parts of the mutation check that CI runs as parallel jobs: whatever
# their number, they hold every entry of tests/mutations.sh once and none is
# empty, and a part outside them is refused before anything runs.
# shellcheck disable=SC2329 # Case functions are called through run_case.
set -uo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init parts

mutations() { bash "$ROOT_DIR/tests/mutations.sh" "$@"; }

# The entries as the list writes them, read without the script.
listed() { sed -n 's/^m \([^ ]*\) .*/\1/p' "$ROOT_DIR/tests/mutations.sh"; }

parts_hold_every_entry_once() {
  local total count part chosen size smallest largest
  local -a held
  total=$(listed | wc -l)
  (( total > 1 )) || fail_test "no list read from tests/mutations.sh"
  [[ $(mutations --list) == "$(listed)" ]] || fail_test "--list without a part is not the whole list in order"
  for count in 1 2 3 4 7 "$total"; do
    held=() smallest=$total largest=0
    for (( part = 1; part <= count; part++ )); do
      chosen=$(mutations --list --part "${part}/${count}") || fail_test "part ${part}/${count} was refused"
      mapfile -t -O "${#held[@]}" held <<<"$chosen"
      size=$(grep -c . <<<"$chosen")
      (( size < smallest )) && smallest=$size
      (( size > largest )) && largest=$size
    done
    [[ $(printf '%s\n' "${held[@]}" | LC_ALL=C sort) == "$(listed | LC_ALL=C sort)" ]] ||
      fail_test "the ${count} parts do not hold every entry once"
    (( smallest >= 1 && largest - smallest <= 1 )) ||
      fail_test "the ${count} parts hold between ${smallest} and ${largest} entries"
  done
}

parts_outside_the_list_are_refused() {
  local total rc part
  total=$(listed | wc -l)
  for part in 0/3 4/3 3/2 1/0 01/3 1/03 a/3 1/3/3 ' 1/3' 1/ /3 '' 1000/1000 "1/$(( total + 1 ))"; do
    # Without --list: a part that got through would start the check itself.
    timeout 60 bash "$ROOT_DIR/tests/mutations.sh" --part "$part" >"$FIX/run/out" 2>"$FIX/run/err"
    rc=$?
    (( rc == 2 )) || fail_test "part '${part}' ended with ${rc}, not 2"
    grep -q '^Usage: ' "$FIX/run/err" || fail_test "part '${part}' was refused without the usage line"
    [[ ! -s $FIX/run/out ]] || fail_test "part '${part}' ran: $(head -n 1 "$FIX/run/out")"
  done
  for args in '--part' '--part 1/3 F01' '--list --part 1/3 --list' 'F01 --part 1/3'; do
    # shellcheck disable=SC2086 # The words are the arguments.
    timeout 60 bash "$ROOT_DIR/tests/mutations.sh" $args >"$FIX/run/out" 2>/dev/null
    rc=$?
    (( rc == 2 )) || fail_test "'${args}' ended with ${rc}, not 2"
    [[ ! -s $FIX/run/out ]] || fail_test "'${args}' ran: $(head -n 1 "$FIX/run/out")"
  done
}

run_case parts-hold-every-entry-once parts_hold_every_entry_once
run_case parts-outside-the-list-are-refused parts_outside_the_list_are_refused
finish_suite
