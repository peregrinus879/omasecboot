#!/bin/bash
# Privileged package lifecycle check for a disposable Arch container.
#
# Installs the built package with real pacman hook execution, then proves the
# tmpfiles state layout, both guards admitting a pristine lifecycle, both
# guards failing closed on a malformed managed record, an upgrade, and removal
# that preserves durable state. It mutates the running system, so it refuses
# to run unless OMASECBOOT_DISPOSABLE_ROOT=1 is set by a throwaway container
# job. Never run it on a real machine.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "${OMASECBOOT_DISPOSABLE_ROOT:-}" == 1 ]] \
  || fail_test "refusing to mutate a system that is not a declared disposable root"
[[ $EUID -eq 0 ]] || fail_test "the privileged package check requires root"
[[ -f /.dockerenv || -f /run/.containerenv || -n "${GITHUB_ACTIONS:-}" ]] \
  || fail_test "refusing to run outside a container or CI job"
[[ ! -e /var/lib/sbctl/keys ]] \
  || fail_test "refusing to run where sbctl keys already exist"

pkgname=omasecboot
pkgver=$(sed -n 's/^pkgver=//p' "${ROOT_DIR}/PKGBUILD")
BUILD_DIR=$(mktemp -d /tmp/omasecboot-package-root.XXXXXX)
builder=omasecboot-build
id "$builder" >/dev/null 2>&1 || useradd --system --create-home "$builder"
chown -R "$builder" "$BUILD_DIR"

# Build the package as an unprivileged user from a working-tree archive.
mkdir -p "${BUILD_DIR}/${pkgname}-${pkgver}"
git -C "$ROOT_DIR" ls-files -z --cached --others --exclude-standard \
  | tar -C "$ROOT_DIR" --null -T - -cf - | tar -C "${BUILD_DIR}/${pkgname}-${pkgver}" -xf -
tar -C "$BUILD_DIR" -czf "${BUILD_DIR}/${pkgname}-${pkgver}.tar.gz" "${pkgname}-${pkgver}"
cp "${ROOT_DIR}/PKGBUILD" "${BUILD_DIR}/PKGBUILD"
chown -R "$builder" "$BUILD_DIR"
build_release() {
  local rel="$1"
  sed -i "s/^pkgrel=.*/pkgrel=${rel}/" "${BUILD_DIR}/PKGBUILD"
  runuser -u "$builder" -- env HOME="/home/${builder}" PKGDEST="$BUILD_DIR" \
    SRCDEST="$BUILD_DIR" SRCPKGDEST="$BUILD_DIR" LOGDEST="$BUILD_DIR" \
    BUILDDIR="${BUILD_DIR}/build" \
    PKGEXT='.pkg.tar.zst' bash -c "cd '$BUILD_DIR' && makepkg --nodeps --noconfirm --noprogressbar --nosign --force" \
    > "${BUILD_DIR}/makepkg-${rel}.log" 2>&1 \
    || { cat "${BUILD_DIR}/makepkg-${rel}.log" >&2; fail_test "makepkg failed for pkgrel ${rel}"; }
  printf '%s\n' "${BUILD_DIR}/${pkgname}-${pkgver}-${rel}-any.pkg.tar.zst"
}
package=$(build_release 1)
upgrade=$(build_release 2)

# Runtime dependencies that Arch provides; the two Omarchy producer packages are
# assumed so the container does not depend on the Omarchy repository.
pacman -S --noconfirm --needed bash coreutils diffutils findutils gawk grep \
  util-linux systemd pacman jq openssl gum efibootmgr sbctl limine \
  > "${BUILD_DIR}/deps.log" 2>&1 || { cat "${BUILD_DIR}/deps.log" >&2; fail_test "dependency install failed"; }
assume=(--assume-installed limine-mkinitcpio-hook=1.38.0-1
        --assume-installed limine-snapper-sync=1.31.0-1)
install -d -m 755 /run/lock

state=/var/lib/omasecboot
hooks=/usr/share/libalpm/hooks
installed_paths=(
  /usr/bin/omasecboot
  /usr/lib/omasecboot/lifecycle.sh
  "${hooks}/00-omasecboot-removal-guard.hook"
  "${hooks}/00-omasecboot-transition-guard.hook"
  "${hooks}/zzz-omasecboot.hook"
  /etc/boot/hooks/pre.d/000-omasecboot-guard
  /etc/boot/hooks/post.d/zzz-omasecboot-sign
  /usr/lib/tmpfiles.d/omasecboot.conf
  /usr/share/licenses/omasecboot/LICENSE
)
assert_installed() {
  local path
  for path in "${installed_paths[@]}"; do
    [[ -f "$path" ]] || fail_test "installed file is missing: ${path}"
  done
  [[ $(pacman -Q "$pkgname") == "${pkgname} ${pkgver}-$1" ]] \
    || fail_test "installed package version is not ${pkgver}-$1"
  pacman -Qkk "$pkgname" >/dev/null || fail_test "installed package failed its integrity check"
  [[ $(/usr/bin/omasecboot version) == "omasecboot ${pkgver}" ]] \
    || fail_test "installed command reports the wrong version"
}

# 1. Install with hooks executing for real. pacman's systemd tmpfiles hook must
#    create the state directory and the stable repair lock with the declared
#    modes; no manual tmpfiles run is allowed to stand in for it.
pacman -U --noconfirm "${assume[@]}" "$package" > "${BUILD_DIR}/install.log" 2>&1 \
  || { cat "${BUILD_DIR}/install.log" >&2; fail_test "package install failed"; }
assert_installed 1
[[ -d "$state" && $(stat -c '%u:%a' "$state") == 0:755 ]] \
  || fail_test "tmpfiles did not create the state directory as root 0755"
[[ -f "${state}/repair.lock" && $(stat -c '%u:%a' "${state}/repair.lock") == 0:644 ]] \
  || fail_test "tmpfiles did not create the stable repair lock as root 0644"
pacman -Ql "$pkgname" | grep -Fq ' /var/lib/omasecboot' \
  && fail_test "package claims the durable state directory"

# 2. Pristine lifecycle: a producer package transaction and package removal are
#    both allowed, and the guards actually executed.
pacman -S --noconfirm sbctl > "${BUILD_DIR}/pristine-producer.log" 2>&1 \
  || { cat "${BUILD_DIR}/pristine-producer.log" >&2; fail_test "pristine lifecycle blocked a producer package transaction"; }
grep -Fq 'Secure Boot: validate lifecycle before boot mutation' "${BUILD_DIR}/pristine-producer.log" \
  || fail_test "the transition guard did not run for a pinned producer package"
pacman -R --noconfirm "$pkgname" > "${BUILD_DIR}/pristine-remove.log" 2>&1 \
  || { cat "${BUILD_DIR}/pristine-remove.log" >&2; fail_test "pristine lifecycle blocked package removal"; }
grep -Fq 'Secure Boot: validate lifecycle before dependency removal' "${BUILD_DIR}/pristine-remove.log" \
  || fail_test "the removal guard did not run"
for path in "${installed_paths[@]}"; do
  [[ ! -e "$path" ]] || fail_test "removal left package content behind: ${path}"
done
[[ -d "$state" && -f "${state}/repair.lock" ]] \
  || fail_test "removal from pristine state deleted the state directory or lock"

# 3. Reinstall and seed a malformed managed record. The strict reader rejects
#    it, so both guards must fail closed without reading any further.
pacman -U --noconfirm "${assume[@]}" "$package" > "${BUILD_DIR}/reinstall.log" 2>&1 \
  || { cat "${BUILD_DIR}/reinstall.log" >&2; fail_test "package reinstall failed"; }
assert_installed 1
mkdir -p "${state}/transactions/fixture" "${state}/firmware-backup" /var/lib/sbctl/keys/db
printf '{"schema_version":2,"state":"active"}\n' > "${state}/lifecycle.json"
chmod 644 "${state}/lifecycle.json"
printf '{}\n' > "${state}/transactions/fixture/manifest.json"
printf 'raw\n' > "${state}/firmware-backup/dbx.bin"
printf '{"schema_version":1,"enabled":true}\n' > "${state}/windows-enabled"
printf 'fixture key\n' > /var/lib/sbctl/keys/db/db.key
before=$(find "$state" /var/lib/sbctl -type f -exec sha256sum {} + | sort)

if pacman -R --noconfirm "$pkgname" > "${BUILD_DIR}/blocked-remove.log" 2>&1; then
  fail_test "package removal succeeded with a managed lifecycle record"
fi
grep -Fq 'Package removal requires verified disabled or pristine lifecycle state' \
  "${BUILD_DIR}/blocked-remove.log" || fail_test "blocked removal omitted the guard reason"
assert_installed 1
if pacman -S --noconfirm sbctl > "${BUILD_DIR}/blocked-producer.log" 2>&1; then
  fail_test "a pinned producer package transaction succeeded with a managed lifecycle record"
fi
grep -Fq 'Boot-mutating package transaction blocked' "${BUILD_DIR}/blocked-producer.log" \
  || fail_test "blocked producer transaction omitted the guard reason"

# 4. Upgrading omasecboot itself is not a producer transaction and stays allowed.
pacman -U --noconfirm "${assume[@]}" "$upgrade" > "${BUILD_DIR}/upgrade.log" 2>&1 \
  || { cat "${BUILD_DIR}/upgrade.log" >&2; fail_test "package upgrade failed with a managed lifecycle record"; }
assert_installed 2
[[ $(find "$state" /var/lib/sbctl -type f -exec sha256sum {} + | sort) == "$before" ]] \
  || fail_test "upgrade changed durable state"

# 5. Removal is allowed again once the lifecycle record is gone, and durable
#    state survives it.
rm -f "${state}/lifecycle.json"
before=$(find "$state" /var/lib/sbctl -type f -exec sha256sum {} + | sort)
pacman -R --noconfirm "$pkgname" > "${BUILD_DIR}/final-remove.log" 2>&1 \
  || { cat "${BUILD_DIR}/final-remove.log" >&2; fail_test "package removal failed from pristine state"; }
pacman -Q "$pkgname" >/dev/null 2>&1 && fail_test "package remained installed after removal"
for path in "${installed_paths[@]}"; do
  [[ ! -e "$path" ]] || fail_test "removal left package content behind: ${path}"
done
[[ $(find "$state" /var/lib/sbctl -type f -exec sha256sum {} + | sort) == "$before" ]] \
  || fail_test "removal changed durable lifecycle, recovery, Windows, or key state"

rm -rf "$BUILD_DIR"
printf 'privileged package tests passed\n'
