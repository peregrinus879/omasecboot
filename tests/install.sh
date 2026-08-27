#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-install.XXXXXX")
PREFIX=/opt/omasecboot-test

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

canonical="${STAGE_DIR}${PREFIX}/bin/omasecboot"
canonical_lib="${STAGE_DIR}${PREFIX}/lib/omasecboot"
canonical_state="${STAGE_DIR}/var/lib/omasecboot"
cleanup_hook_name=zz-omasecboot-cleanup.hook
sbctl_hook_name=zz-sbctl.hook
repair_hook_name=zzz-omasecboot.hook
guard_hook="${STAGE_DIR}/etc/pacman.d/hooks/00-omasecboot-transition-guard.hook"
cleanup_hook="${STAGE_DIR}/etc/pacman.d/hooks/${cleanup_hook_name}"
repair_hook="${STAGE_DIR}/etc/pacman.d/hooks/${repair_hook_name}"
limine_pre_hook="${STAGE_DIR}/etc/boot/hooks/pre.d/000-omasecboot-guard"
limine_post_hook="${STAGE_DIR}/etc/boot/hooks/post.d/zzz-omasecboot-sign"

make -s -C "$ROOT_DIR" install DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" >/dev/null

[[ -x "$canonical" ]] || fail "canonical command was not installed"
for version_arg in version --version -v; do
  [[ $("$canonical" "$version_arg") == 'omasecboot 1.0.0' ]] \
    || fail "version form returned the wrong contract: ${version_arg}"
done

grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet guard transaction" "$guard_hook" \
  || fail "transition guard does not target the canonical command"
grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet cleanup" "$cleanup_hook" \
  && fail "cleanup hook retained the public mutation path"
grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet hook package-cleanup" "$cleanup_hook" \
  || fail "cleanup hook does not target lifecycle-aware automation"
grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet hook package-sign" "$repair_hook" \
  || fail "repair hook does not target lifecycle-aware automation"
grep -Fxq "exec ${PREFIX}/bin/omasecboot --quiet hook pre" "$limine_pre_hook" \
  || fail "Limine pre-hook does not target the ownership guard"
grep -Fxq "exec ${PREFIX}/bin/omasecboot --quiet hook post" "$limine_post_hook" \
  || fail "Limine post-hook does not target validated repair"
if grep -Fq 'OMASECBOOT_IN_LIMINE_HOOK' "$limine_post_hook"; then
  fail "Limine post-hook retained the environment-only bypass"
fi

[[ -x "${STAGE_DIR}${PREFIX}/bin/omasecboot" ]] \
  || fail "rendered hook target is not executable in the stage"
grep -Fq "$STAGE_DIR" "$guard_hook" "$cleanup_hook" "$repair_hook" \
  "$limine_pre_hook" "$limine_post_hook" \
  && fail "DESTDIR leaked into a runtime hook target"

[[ -d "$canonical_lib" ]] || fail "canonical library path is missing"
[[ -d "$canonical_state" ]] || fail "canonical state path is missing"
[[ $(stat -Lc '%a' "$canonical_state") == 755 ]] \
  || fail "canonical state path is not safely traversable"
[[ ! -e "${canonical_state}/repair.lock" ]] \
  || fail "install created an ephemeral repair lock"
[[ "$cleanup_hook_name" < "$sbctl_hook_name" ]] \
  || fail "cleanup hook no longer sorts before sbctl"
[[ "$sbctl_hook_name" < "$repair_hook_name" ]] \
  || fail "repair hook no longer sorts after sbctl"

printf 'canonical\n' > "${canonical_state}/windows-enabled"
mkdir -p "${canonical_state}/transactions/fixture" "${canonical_state}/firmware-backup"
printf '{}\n' > "${canonical_state}/lifecycle.json"
printf '{}\n' > "${canonical_state}/transactions/fixture/manifest.json"
printf 'raw\n' > "${canonical_state}/firmware-backup/dbx.bin"
make -s -C "$ROOT_DIR" install DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" >/dev/null
grep -Fxq 'canonical' "${canonical_state}/windows-enabled" \
  || fail "idempotent install replaced canonical Windows opt-in state"

if make -s -C "$ROOT_DIR" uninstall DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" \
  > "${STAGE_DIR}/uninstall.out" 2>&1; then
  fail "uninstall succeeded without lifecycle removal verification"
fi
grep -Fq 'Refusing uninstall until lifecycle removal verification is available' \
  "${STAGE_DIR}/uninstall.out" || fail "blocked uninstall omitted its safety reason"

[[ -x "$canonical" && -d "$canonical_lib" ]] \
  || fail "blocked uninstall removed the command or recovery library"
[[ -f "$guard_hook" && -f "$cleanup_hook" && -f "$repair_hook" \
  && -x "$limine_pre_hook" && -x "$limine_post_hook" ]] \
  || fail "blocked uninstall removed a lifecycle guard or repair hook"
grep -Fxq canonical "${canonical_state}/windows-enabled" \
  || fail "uninstall removed durable Windows opt-in state"
[[ -f "${canonical_state}/lifecycle.json" \
  && -f "${canonical_state}/transactions/fixture/manifest.json" \
  && -f "${canonical_state}/firmware-backup/dbx.bin" ]] \
  || fail "uninstall removed durable lifecycle or recovery state"

printf 'install tests passed\n'
