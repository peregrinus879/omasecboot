#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-install.XXXXXX")
PREFIX=/opt/omasecboot-test
MAKE_INSTALL_PATHS=(
  "BINDIR=${PREFIX}/bin"
  "LIBDIR=${PREFIX}/lib/omasecboot"
  "HOOKDIR=/etc/pacman.d/hooks"
  "LIMINEPREHOOKDIR=/etc/boot/hooks/pre.d"
  "LIMINEPOSTHOOKDIR=/etc/boot/hooks/post.d"
  "STATEDIR=/var/lib/omasecboot"
)

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
windows_state_file="${canonical_state}/windows-enabled"
cleanup_hook_name=zz-omasecboot-cleanup.hook
sbctl_hook_name=zz-sbctl.hook
repair_hook_name=zzz-omasecboot.hook
removal_guard="${STAGE_DIR}/etc/pacman.d/hooks/00-omasecboot-removal-guard.hook"
guard_hook="${STAGE_DIR}/etc/pacman.d/hooks/00-omasecboot-transition-guard.hook"
cleanup_hook="${STAGE_DIR}/etc/pacman.d/hooks/${cleanup_hook_name}"
repair_hook="${STAGE_DIR}/etc/pacman.d/hooks/${repair_hook_name}"
limine_pre_hook="${STAGE_DIR}/etc/boot/hooks/pre.d/000-omasecboot-guard"
limine_post_hook="${STAGE_DIR}/etc/boot/hooks/post.d/zzz-omasecboot-sign"

root_dest_link="${STAGE_DIR}/root-dest"
ln -s / "$root_dest_link"
for unsafe_destdir in '' ' ' $'\t' relative / // /./ "$root_dest_link"; do
  if make -s -C "$ROOT_DIR" install DESTDIR="$unsafe_destdir" \
    BINDIR="${STAGE_DIR}/live/bin" LIBDIR="${STAGE_DIR}/live/lib" \
    HOOKDIR="${STAGE_DIR}/live/hooks" LIMINEPREHOOKDIR="${STAGE_DIR}/live/pre" \
    LIMINEPOSTHOOKDIR="${STAGE_DIR}/live/post" STATEDIR="${STAGE_DIR}/live/state" \
    > "${STAGE_DIR}/live-install.out" 2>&1; then
    fail "install accepted a root-resolving DESTDIR: ${unsafe_destdir:-empty}"
  fi
  grep -Fq 'Refusing live source install' "${STAGE_DIR}/live-install.out" \
    || fail "unstaged install omitted its package-build boundary"
  [[ ! -e "${STAGE_DIR}/live" ]] || fail "refused unstaged install wrote files"
done

make -s -C "$ROOT_DIR" install DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" \
  "${MAKE_INSTALL_PATHS[@]}" >/dev/null

[[ -x "$canonical" ]] || fail "canonical command was not installed"
for version_arg in version --version -v; do
  [[ $("$canonical" "$version_arg") == 'omasecboot 1.0.0' ]] \
    || fail "version form returned the wrong contract: ${version_arg}"
done

grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet guard removal" "$removal_guard" \
  || fail "removal guard does not target the canonical command"
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
for hook in "$removal_guard" "$guard_hook" "$cleanup_hook" "$repair_hook" \
  "$limine_pre_hook" "$limine_post_hook"; do
  grep -Fxq '# OmaSecBoot hook schema: 1' "$hook" \
    || fail "installed hook omitted its deployment schema: ${hook##*/}"
done
if grep -Fq 'OMASECBOOT_IN_LIMINE_HOOK' "$limine_post_hook"; then
  fail "Limine post-hook retained the environment-only bypass"
fi

[[ -x "${STAGE_DIR}${PREFIX}/bin/omasecboot" ]] \
  || fail "rendered hook target is not executable in the stage"
grep -Fq "$STAGE_DIR" "$removal_guard" "$guard_hook" "$cleanup_hook" "$repair_hook" \
  "$limine_pre_hook" "$limine_post_hook" \
  && fail "DESTDIR leaked into a runtime hook target"
[[ $(stat -Lc '%a' "$removal_guard") == 644 ]] \
  || fail "removal guard has the wrong installed mode"

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
printf '%s\n' "${removal_guard##*/}" "${guard_hook##*/}" | LC_ALL=C sort -C \
  || fail "removal guard no longer sorts before the producer guard"

jq -n '{
  schema_version: 1,
  writer_version: "1.0.0",
  enabled: true,
  boot_number: "0007",
  label: "Windows Boot Manager",
  partuuid: "11111111-2222-3333-4444-555555555555",
  loader_path: "\\EFI\\Microsoft\\Boot\\bootmgfw.efi"
}' > "$windows_state_file"
windows_state_checksum=$(sha256sum "$windows_state_file")
windows_state_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' "$windows_state_file")
mkdir -p "${canonical_state}/transactions/fixture" "${canonical_state}/firmware-backup"
printf '{}\n' > "${canonical_state}/lifecycle.json"
printf '{}\n' > "${canonical_state}/transactions/fixture/manifest.json"
printf 'raw\n' > "${canonical_state}/firmware-backup/dbx.bin"
make -s -C "$ROOT_DIR" install DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" \
  "${MAKE_INSTALL_PATHS[@]}" >/dev/null
[[ -f "$windows_state_file" && ! -L "$windows_state_file" \
  && "$(sha256sum "$windows_state_file")" == "$windows_state_checksum" \
  && "$(stat -Lc '%d:%i:%u:%g:%a:%h' "$windows_state_file")" == \
    "$windows_state_identity" ]] \
  || fail "idempotent reinstall replaced canonical Windows opt-in state"

if make -s -C "$ROOT_DIR" uninstall DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" \
  "${MAKE_INSTALL_PATHS[@]}" > "${STAGE_DIR}/uninstall.out" 2>&1; then
  fail "uninstall succeeded without lifecycle removal verification"
fi
grep -Fq 'Refusing uninstall until concurrency-safe package removal is available' \
  "${STAGE_DIR}/uninstall.out" || fail "blocked uninstall omitted its safety reason"

[[ -x "$canonical" && -d "$canonical_lib" ]] \
  || fail "blocked uninstall removed the command or recovery library"
[[ -f "$removal_guard" && -f "$guard_hook" && -f "$cleanup_hook" && -f "$repair_hook" \
  && -x "$limine_pre_hook" && -x "$limine_post_hook" ]] \
  || fail "blocked uninstall removed a lifecycle guard or repair hook"
[[ -f "$windows_state_file" && ! -L "$windows_state_file" \
  && "$(sha256sum "$windows_state_file")" == "$windows_state_checksum" \
  && "$(stat -Lc '%d:%i:%u:%g:%a:%h' "$windows_state_file")" == \
    "$windows_state_identity" ]] \
  || fail "uninstall removed durable Windows opt-in state"
[[ -f "${canonical_state}/lifecycle.json" \
  && -f "${canonical_state}/transactions/fixture/manifest.json" \
  && -f "${canonical_state}/firmware-backup/dbx.bin" ]] \
  || fail "uninstall removed durable lifecycle or recovery state"

printf 'install tests passed\n'
