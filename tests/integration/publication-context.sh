#!/usr/bin/env bash
# Read-only context contracts with hardware seams replaced only by the fixture.
set -euo pipefail
umask 077

ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/../..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init publication-context
[[ -d "$TEST_DIR" && ! -L "$TEST_DIR" && -O "$TEST_DIR" \
  && $(stat -c '%a' "$TEST_DIR") == 700 ]] \
  || fail_test "context fixture scratch must be private and caller-owned"
for tool in /usr/bin/python /usr/bin/openssl /usr/bin/timeout; do
  [[ -x "$tool" ]] || fail_test "context fixture requires ${tool}"
done
mkdir "$TEST_DIR/home" "$TEST_DIR/tmp"

# -I -S supplies actual interpreter isolation; -B covers imports before the
# fixture also disables bytecode. timeout bounds the suite and its process group.
status=0
/usr/bin/timeout --signal=TERM --kill-after=5s 120s env -i \
  PATH=/usr/bin LC_ALL=C HOME="$TEST_DIR/home" \
  XDG_CONFIG_HOME="$TEST_DIR/home" XDG_CACHE_HOME="$TEST_DIR/home" \
  XDG_DATA_HOME="$TEST_DIR/home" TMPDIR="$TEST_DIR/tmp" HISTFILE=/dev/null \
  /usr/bin/python -I -S -B \
  "$ROOT_DIR/tests/integration/fixtures/PublicationContextContract.py" \
  "$ROOT_DIR/lib/publication-context.py" "$TEST_DIR/tmp" </dev/null || status=$?
[[ $status == 0 ]] || fail_test "publication context contracts failed (status ${status})"
printf 'publication context tests passed\n'
