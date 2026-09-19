#!/usr/bin/env bash
# Run the publication-journal suite as one process per registered case through a
# pool. Every registered case must run exactly once and pass; the aggregate
# result is the conjunction. Usage: publication-records-parallel.sh [JOBS]
set -euo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/../..")
suite=$ROOT_DIR/tests/integration/publication-records.sh
jobs=${1:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { printf 'usage: %s [JOBS]\n' "${BASH_SOURCE[0]##*/}" >&2; exit 64; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-publication-parallel.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
# The suite lists its registrations, loop-generated names included; the slow
# recovery groups are registered last, so reverse order starts them first.
PUBLICATION_RECORDS_LIST=1 bash "$suite" | sort -u >"$scratch/registered"
tac "$scratch/registered" >"$scratch/queue"
registered=$(wc -l <"$scratch/registered")
(( registered > 0 )) || { printf 'no registered publication-journal cases\n' >&2; exit 1; }
mkdir -p "$scratch/logs"
run_one() {
  local name=$1 status=0
  PUBLICATION_RECORDS_CASE=$name bash "$suite" >"$scratch/logs/$name.log" 2>&1 || status=$?
  printf '%s %s\n' "$name" "$status" >>"$scratch/statuses"
}
export -f run_one
export suite scratch
# shellcheck disable=SC2016 # The worker expands $1 inside its own shell.
xargs -P "$jobs" -I{} bash -c 'run_one "$1"' _ {} <"$scratch/queue"
failed=0
while IFS= read -r name; do
  status=$(awk -v n="$name" '$1 == n {print $2}' "$scratch/statuses" | tail -1)
  passes=$(grep -c "^PASS: publication records/$name\$" "$scratch/logs/$name.log" || true)
  if [[ ${status:-missing} == 0 && $passes == 1 ]] && tail -1 "$scratch/logs/$name.log" | grep -q '^Passed 1 publication-journal contracts\.$'; then
    printf 'PASS: publication records/%s\n' "$name"
  else
    failed=$((failed+1))
    printf 'FAIL: publication records/%s (status %s, passes %s)\n' "$name" "${status:-missing}" "$passes"
    tail -20 "$scratch/logs/$name.log" | sed 's/^/    /'
  fi
done <"$scratch/registered"
if (( failed > 0 )); then
  printf 'Failed %s of %s publication-journal contracts across %s workers.\n' "$failed" "$registered" "$jobs" >&2
  exit 1
fi
printf 'Passed %s publication-journal contracts across %s parallel per-case workers.\n' "$registered" "$jobs"
