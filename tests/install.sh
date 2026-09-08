#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib/harness.sh
source "${ROOT_DIR}/tests/lib/harness.sh"
test_harness_init install
STAGE_DIR="$TEST_DIR"
PREFIX=/opt/omasecboot-test
MAKE_INSTALL_PATHS=(
  "BINDIR=${PREFIX}/bin"
  "LIBDIR=${PREFIX}/lib/omasecboot"
  "LICENSEDIR=${PREFIX}/share/licenses/omasecboot"
  "DOCDIR=${PREFIX}/share/doc/omasecboot"
  "HOOKDIR=/usr/share/libalpm/hooks"
  "TMPFILESDIR=/usr/lib/tmpfiles.d"
  "LIMINEPREHOOKDIR=/etc/boot/hooks/pre.d"
  "LIMINEPOSTHOOKDIR=/etc/boot/hooks/post.d"
)

canonical="${STAGE_DIR}${PREFIX}/bin/omasecboot"
canonical_lib="${STAGE_DIR}${PREFIX}/lib/omasecboot"
canonical_state="${STAGE_DIR}/var/lib/omasecboot"
windows_state_file="${canonical_state}/windows-enabled"
sbctl_hook_name=zz-sbctl.hook
repair_hook_name=zzz-omasecboot.hook
hook_dir="${STAGE_DIR}/usr/share/libalpm/hooks"
removal_guard="${hook_dir}/00-omasecboot-removal-guard.hook"
guard_hook="${hook_dir}/00-omasecboot-transition-guard.hook"
repair_hook="${hook_dir}/${repair_hook_name}"
limine_pre_hook="${STAGE_DIR}/etc/boot/hooks/pre.d/000-omasecboot-guard"
limine_post_hook="${STAGE_DIR}/etc/boot/hooks/post.d/zzz-omasecboot-sign"
tmpfiles_conf="${STAGE_DIR}/usr/lib/tmpfiles.d/omasecboot.conf"
license_file="${STAGE_DIR}${PREFIX}/share/licenses/omasecboot/LICENSE"
readme_file="${STAGE_DIR}${PREFIX}/share/doc/omasecboot/README.md"

root_dest_link="${STAGE_DIR}/root-dest"
ln -s / "$root_dest_link"
for unsafe_destdir in '' ' ' $'\t' relative / // /./ "$root_dest_link"; do
  if make -s -C "$ROOT_DIR" install DESTDIR="$unsafe_destdir" \
    BINDIR="${STAGE_DIR}/live/bin" LIBDIR="${STAGE_DIR}/live/lib" \
    LICENSEDIR="${STAGE_DIR}/live/license" DOCDIR="${STAGE_DIR}/live/doc" \
    HOOKDIR="${STAGE_DIR}/live/hooks" TMPFILESDIR="${STAGE_DIR}/live/tmpfiles" \
    LIMINEPREHOOKDIR="${STAGE_DIR}/live/pre" \
    LIMINEPOSTHOOKDIR="${STAGE_DIR}/live/post" \
    > "${STAGE_DIR}/live-install.out" 2>&1; then
    fail_test "install accepted a root-resolving DESTDIR: ${unsafe_destdir:-empty}"
  fi
  grep -Fq 'Refusing live source install' "${STAGE_DIR}/live-install.out" \
    || fail_test "unstaged install omitted its package-build boundary"
  [[ ! -e "${STAGE_DIR}/live" ]] || fail_test "refused unstaged install wrote files"
done

make -s -C "$ROOT_DIR" install DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" \
  "${MAKE_INSTALL_PATHS[@]}" >/dev/null

[[ -x "$canonical" ]] || fail_test "canonical command was not installed"
for version_arg in version --version -v; do
  [[ $("$canonical" "$version_arg") == 'omasecboot 1.0.0' ]] \
    || fail_test "version form returned the wrong contract: ${version_arg}"
done

grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet guard removal" "$removal_guard" \
  || fail_test "removal guard does not target the canonical command"
grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet guard transaction" "$guard_hook" \
  || fail_test "transition guard does not target the canonical command"
grep -Fxq "Exec = ${PREFIX}/bin/omasecboot --quiet hook package-sign" "$repair_hook" \
  || fail_test "repair hook does not target lifecycle-aware automation"
grep -Fxq "exec ${PREFIX}/bin/omasecboot --quiet hook pre" "$limine_pre_hook" \
  || fail_test "Limine pre-hook does not target the ownership guard"
grep -Fxq "exec ${PREFIX}/bin/omasecboot --quiet hook post" "$limine_post_hook" \
  || fail_test "Limine post-hook does not target validated repair"
for hook in "$removal_guard" "$guard_hook" "$repair_hook" \
  "$limine_pre_hook" "$limine_post_hook"; do
  grep -Fxq '# OmaSecBoot hook schema: 1' "$hook" \
    || fail_test "installed hook omitted its deployment schema: ${hook##*/}"
done
if grep -Fq 'OMASECBOOT_IN_LIMINE_HOOK' "$limine_post_hook"; then
  fail_test "Limine post-hook retained the environment-only bypass"
fi
[[ ! -e "${STAGE_DIR}/etc/pacman.d/hooks" ]] \
  || fail_test "install wrote hooks into the administrator hook directory"
status_hooks=0
while IFS= read -r status_hook; do
  status_hooks=$((status_hooks + 1))
  [[ "$status_hook" == */zz-sbctl.hook || -f "${STAGE_DIR}${status_hook}" ]] \
    || fail_test "status expects a hook the package does not install: ${status_hook}"
done < <(grep -oh "printf '/\(usr/share/libalpm/hooks\|etc/boot/hooks\)/[^'\\\\]*" \
  "${ROOT_DIR}/lib/checks.sh" "${ROOT_DIR}/lib/status.sh" | sed "s/^printf '//")
[[ $status_hooks -eq 6 ]] \
  || fail_test "hook paths could not be read from lib/checks.sh and lib/status.sh (${status_hooks})"
shadow_hooks=0
while IFS= read -r status_hook; do
  shadow_hooks=$((shadow_hooks + 1))
  [[ -f "${hook_dir}/${status_hook}" ]] \
    || fail_test "status shadow check names a hook the package does not install: ${status_hook}"
done < <(sed -n '/for hook_name in/,/; do/p' "${ROOT_DIR}/lib/status.sh" \
  | grep -o '[0-9a-z-]*omasecboot[0-9a-z-]*\.hook')
[[ $shadow_hooks -eq 3 ]] || fail_test "status shadow list could not be read from lib/status.sh (${shadow_hooks})"

[[ -x "${STAGE_DIR}${PREFIX}/bin/omasecboot" ]] \
  || fail_test "rendered hook target is not executable in the stage"
grep -Fq "$STAGE_DIR" "$removal_guard" "$guard_hook" "$repair_hook" \
  "$limine_pre_hook" "$limine_post_hook" "$tmpfiles_conf" \
  && fail_test "DESTDIR leaked into a runtime hook target"
for hook in "$removal_guard" "$guard_hook" "$repair_hook"; do
  [[ $(stat -Lc '%a' "$hook") == 644 ]] \
    || fail_test "pacman hook has the wrong installed mode: ${hook##*/}"
done
for hook in "$limine_pre_hook" "$limine_post_hook"; do
  [[ $(stat -Lc '%a' "$hook") == 755 ]] \
    || fail_test "Limine hook has the wrong installed mode: ${hook##*/}"
done

[[ -d "$canonical_lib" ]] || fail_test "canonical library path is missing"
for lib in common lifecycle records software checks discover sign producers enroll windows status; do
  [[ -f "${canonical_lib}/${lib}.sh" \
    && $(stat -Lc '%a' "${canonical_lib}/${lib}.sh") == 644 ]] \
    || fail_test "library module missing or wrong mode: ${lib}.sh"
done
[[ ! -e "$canonical_state" ]] \
  || fail_test "install created the durable state directory as package content"
[[ -f "$tmpfiles_conf" && $(stat -Lc '%a' "$tmpfiles_conf") == 644 ]] \
  || fail_test "tmpfiles declaration is missing or has the wrong mode"
grep -Fxq 'd /var/lib/omasecboot 0755 root root -' "$tmpfiles_conf" \
  || fail_test "tmpfiles declaration does not declare the durable state directory"
grep -Fxq 'f /var/lib/omasecboot/repair.lock 0644 root root -' "$tmpfiles_conf" \
  || fail_test "tmpfiles declaration does not declare the stable repair lock"
[[ $(grep -c -v -E '^(#|$)' "$tmpfiles_conf") -eq 2 ]] \
  || fail_test "tmpfiles declaration carries an unexpected entry"
[[ -f "$license_file" ]] || fail_test "license file was not installed"
cmp -s "$license_file" "${ROOT_DIR}/LICENSE" || fail_test "installed license drifted"
[[ -f "$readme_file" ]] || fail_test "documentation was not installed"
# The README's relative links resolve from the installed documentation root.
for doc in AGENTS.md docs/maintenance.md docs/omarchy-integration.md docs/release-checklist.md; do
  [[ -f "${STAGE_DIR}${PREFIX}/share/doc/omasecboot/${doc}" ]] \
    || fail_test "linked documentation was not installed: ${doc}"
done
[[ "$sbctl_hook_name" < "$repair_hook_name" ]] \
  || fail_test "repair hook no longer sorts after sbctl"
printf '%s\n' "${removal_guard##*/}" "${guard_hook##*/}" | LC_ALL=C sort -C \
  || fail_test "removal guard no longer sorts before the producer guard"

mkdir -p "${canonical_state}/transactions/fixture" "${canonical_state}/firmware-backup"
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
printf '{}\n' > "${canonical_state}/lifecycle.json"
printf '{}\n' > "${canonical_state}/transactions/fixture/manifest.json"
printf 'raw\n' > "${canonical_state}/firmware-backup/dbx.bin"
: > "${canonical_state}/repair.lock"
make -s -C "$ROOT_DIR" install DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" \
  "${MAKE_INSTALL_PATHS[@]}" >/dev/null
[[ -f "$windows_state_file" && ! -L "$windows_state_file" \
  && "$(sha256sum "$windows_state_file")" == "$windows_state_checksum" \
  && "$(stat -Lc '%d:%i:%u:%g:%a:%h' "$windows_state_file")" == \
    "$windows_state_identity" ]] \
  || fail_test "idempotent reinstall replaced canonical Windows opt-in state"
[[ -f "${canonical_state}/repair.lock" ]] \
  || fail_test "idempotent reinstall removed the stable repair lock"

if make -s -C "$ROOT_DIR" uninstall DESTDIR="$STAGE_DIR" PREFIX="$PREFIX" \
  "${MAKE_INSTALL_PATHS[@]}" > "${STAGE_DIR}/uninstall.out" 2>&1; then
  fail_test "source uninstall succeeded outside the package removal contract"
fi
grep -Fq 'Refusing source uninstall; remove the omasecboot package with pacman' \
  "${STAGE_DIR}/uninstall.out" || fail_test "blocked uninstall omitted its package boundary"

[[ -x "$canonical" && -d "$canonical_lib" ]] \
  || fail_test "blocked uninstall removed the command or recovery library"
[[ -f "$removal_guard" && -f "$guard_hook" && -f "$repair_hook" \
  && -x "$limine_pre_hook" && -x "$limine_post_hook" && -f "$tmpfiles_conf" ]] \
  || fail_test "blocked uninstall removed a lifecycle guard, repair hook, or declaration"
[[ -f "$windows_state_file" && ! -L "$windows_state_file" \
  && "$(sha256sum "$windows_state_file")" == "$windows_state_checksum" \
  && "$(stat -Lc '%d:%i:%u:%g:%a:%h' "$windows_state_file")" == \
    "$windows_state_identity" ]] \
  || fail_test "uninstall removed durable Windows opt-in state"
[[ -f "${canonical_state}/lifecycle.json" \
  && -f "${canonical_state}/transactions/fixture/manifest.json" \
  && -f "${canonical_state}/firmware-backup/dbx.bin" \
  && -f "${canonical_state}/repair.lock" ]] \
  || fail_test "uninstall removed durable lifecycle or recovery state"

printf 'install tests passed\n'
