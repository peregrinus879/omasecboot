#!/bin/bash
# Staged installation: what "make install" refuses, what it writes, and that
# the installed pieces point at the installed command.
set -euo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init install
CASE_NAME=staged-install
STAGE=$TEST_DIR/stage
PREFIX=/opt/omasecboot-test

# A source install onto the live root is never supported.
ln -s / "$TEST_DIR/root-link"
for unsafe in '' ' ' relative / // /./ "$TEST_DIR/root-link"; do
  if make -s -C "$ROOT_DIR" install DESTDIR="$unsafe" >"$TEST_DIR/refused.out" 2>&1; then
    fail_test "install accepted DESTDIR '${unsafe}'"
  fi
  grep -Fq 'Refusing live source install' "$TEST_DIR/refused.out" || fail_test "no refusal message for '${unsafe}'"
done

make -s -C "$ROOT_DIR" install DESTDIR="$STAGE" PREFIX="$PREFIX" >/dev/null
command_path=$STAGE$PREFIX/bin/omasecboot
hook=$STAGE/etc/boot/hooks/post.d/90-omasecboot-sign
[[ $("$command_path" version) == "omasecboot $(sed -n 's/^pkgver=//p' "$ROOT_DIR/PKGBUILD")" ]] || fail_test "the installed command does not run"
"$command_path" help | grep -q 'sudo omasecboot setup' || fail_test "help"
"$command_path" nonsense >/dev/null 2>&1 && fail_test "an unknown command succeeded"
for module in common checks files firmware limine windows sign status; do
  [[ -f $STAGE$PREFIX/lib/omasecboot/${module}.sh ]] || fail_test "missing module ${module}"
done
{ [[ -x $hook ]] && grep -qx "${PREFIX}/bin/omasecboot sign --quiet || :" "$hook"; } || fail_test "the hook does not call the installed command"
[[ $(tail -n 1 "$hook") == 'exit 0' ]] || fail_test "the hook's last line is not exit 0"
# Upstream runs hooks in glob order (C2): after its enroll hook, whose work
# ours checks, and before its optional hook that remounts the ESP read-only.
order=$(cd "$TEST_DIR" && mkdir order && cd order && : >90-limine-enroll-config && : >91-esp-set-ro && : >"${hook##*/}" && printf '%s ' *)
[[ $order == "90-limine-enroll-config ${hook##*/} 91-esp-set-ro " ]] || fail_test "hook order: ${order}"
! grep -qE '^(set -e|exec )' "$hook" || fail_test "the hook could fail its caller"
for unit in omasecboot-watch@.path omasecboot-watch@.service; do
  [[ -f $STAGE/usr/lib/systemd/system/$unit ]] || fail_test "missing unit ${unit}"
  ! grep -q '@BINDIR@' "$STAGE/usr/lib/systemd/system/$unit" || fail_test "unsubstituted path in ${unit}"
done
grep -qx 'KillMode=mixed' "$STAGE/usr/lib/systemd/system/omasecboot-watch@.service" || fail_test "a stop would signal the tools the watchers' pass runs, not the pass alone"
for hardening in NoNewPrivileges=yes PrivateNetwork=yes ProtectHome=yes; do
  grep -qx "$hardening" "$STAGE/usr/lib/systemd/system/omasecboot-watch@.service" || fail_test "the watchers' service lost ${hardening}"
done
grep -qx "ExecStart=${PREFIX}/bin/omasecboot sign --quiet --seal-only" "$STAGE/usr/lib/systemd/system/omasecboot-watch@.service" || fail_test "watcher command"
grep -qx 'StartLimitIntervalSec=0' "$STAGE/usr/lib/systemd/system/omasecboot-watch@.service" || fail_test "the watcher's start limit is on"
grep -qx 'PathChanged=%f' "$STAGE/usr/lib/systemd/system/omasecboot-watch@.path" || fail_test "watch path"
[[ ! -e $STAGE/usr/lib/tmpfiles.d ]] || fail_test "a tmpfiles declaration was installed"
[[ ! -e $STAGE/usr/share/libalpm/hooks ]] || fail_test "a pacman hook was installed"
[[ ! -e $STAGE/var ]] || fail_test "state was installed as package content"

# Every relative link in the README resolves from the installed documentation.
doc_dir=$STAGE$PREFIX/share/doc/omasecboot
while IFS= read -r link; do
  [[ -f $doc_dir/$link ]] || fail_test "README links to ${link}, which is not installed"
done < <(grep -oE '\]\((docs/[^)#]+)' "$ROOT_DIR/README.md" | sed 's/^](//' | sort -u)
cmp -s "$STAGE$PREFIX/share/licenses/omasecboot/LICENSE" "$ROOT_DIR/LICENSE" || fail_test "license"
printf 'PASS: install/staged-install\ninstall tests passed (1 cases)\n'
