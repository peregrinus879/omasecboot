#!/bin/bash
# shellcheck disable=SC2154 # Activation helpers read constants from the sourced dispatcher.
# Builds the Arch package from the working tree, inspects the built payload, and
# proves a staged pacman install, reinstall, upgrade, and removal preserve
# durable state. The staged root cannot execute chrooted hooks without
# privileges, so this suite disables hook execution; hook semantics are covered
# by the hermetic dispatcher suite and by the privileged container run in CI.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The lifecycle validators reject symlink components, so resolve the build root.
BUILD_DIR=$(readlink -f "$(mktemp -d "${TMPDIR:-/tmp}/omasecboot-package.XXXXXX")")

cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for tool in makepkg fakeroot bsdtar pacman vercmp git tar jq sha256sum make; do
  command -v "$tool" >/dev/null 2>&1 || fail_test "package test requires ${tool}"
done
git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail_test "package test must run from a git checkout; it archives the tree with git ls-files"

pkgname=omasecboot
pkgbuild="${ROOT_DIR}/PKGBUILD"
pkgver=$(sed -n 's/^pkgver=//p' "$pkgbuild")
pkgurl=$(sed -n "s/^url='\(.*\)'$/\1/p" "$pkgbuild")
[[ "$pkgver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || fail_test "PKGBUILD pkgver is not a release version: ${pkgver}"
[[ $(sed -n 's/^pkgrel=//p' "$pkgbuild") == 1 ]] \
  || fail_test "PKGBUILD pkgrel must restart at 1 for a release version"
[[ $(bash "${ROOT_DIR}/bin/omasecboot" version) == "omasecboot ${pkgver}" ]] \
  || fail_test "PKGBUILD pkgver and the command version contract disagree"
[[ -n "$pkgurl" ]] || fail_test "PKGBUILD does not declare the repository url"
grep -Fxq "pkgname=${pkgname}" "$pkgbuild" || fail_test "PKGBUILD names the wrong package"
grep -Fxq "arch=('any')" "$pkgbuild" || fail_test "shell-only package must be architecture any"
grep -Fxq "license=('MIT')" "$pkgbuild" || fail_test "PKGBUILD license drifted"
grep -Eq '^install=' "$pkgbuild" \
  && fail_test "package declares an install scriptlet; tmpfiles and the removal guard own lifecycle"
grep -Eq '^(backup|conflicts|provides|replaces|makedepends|checkdepends|optdepends)=' "$pkgbuild" \
  && fail_test "PKGBUILD declares an unexpected package relation"
grep -Fq 'startdir' "$pkgbuild" && fail_test "PKGBUILD reads outside its source archive"
# An in-tree recipe cannot carry the checksum of the archive that contains it;
# the build below substitutes the working-tree archive checksum.
grep -Eq "^sha256sums=\('(SKIP|[0-9a-f]{64})'\)$" "$pkgbuild" \
  || fail_test "PKGBUILD must declare exactly one sha256sums entry"

# The activation constants and hook validator come from the dispatcher module.
# shellcheck source=/dev/null
source "${ROOT_DIR}/bin/omasecboot"
control_owner_uid() {
  id -u
}
admin_hook_dir="${BUILD_DIR}/admin-hooks"
mkdir -p "$admin_hook_dir"
pacman_configured_hook_dirs() {
  printf '%s/\n' "$admin_hook_dir"
}

# Dependency floors must admit every exact runtime pin.
floor_admits_pin() {
  local floor="$1" pin="$2"
  (( $(vercmp "$pin" "$floor") >= 0 ))
}
expected_depends=$(sort <<'EOF'
bash
coreutils>=9.5
diffutils
efibootmgr>=18
findutils
gawk
grep
gum
jq
limine
limine-mkinitcpio-hook>=1.38.0
limine-snapper-sync>=1.31.0
openssl
pacman
sbctl>=0.18
systemd
util-linux
EOF
)
floor_admits_pin 18 "$WINDOWS_EFIBOOTMGR_MINIMUM_VERSION" \
  || fail_test "efibootmgr floor disagrees with the runtime minimum"
floor_admits_pin 0.18 "$SUPPORTED_SBCTL_VERSION" \
  || fail_test "sbctl floor rejects the pinned recovery version"
floor_admits_pin 1.38.0 "$SUPPORTED_LIMINE_MKINITCPIO_VERSION" \
  || fail_test "limine-mkinitcpio-hook floor rejects the pinned producer version"
floor_admits_pin 1.31.0 "$SUPPORTED_LIMINE_SNAPPER_SYNC_VERSION" \
  || fail_test "limine-snapper-sync floor rejects the pinned producer version"

# Source archive with the release layout (<name>-<version>/ prefix). It carries
# tracked plus unignored untracked files so an uncommitted change is tested; a
# tagged release archive carries tracked files only.
archive="${BUILD_DIR}/${pkgname}-${pkgver}.tar.gz"
src_root="${BUILD_DIR}/${pkgname}-${pkgver}"
mkdir -p "$src_root"
git -C "$ROOT_DIR" ls-files -z --cached --others --exclude-standard \
  | tar -C "$ROOT_DIR" --null -T - -cf - | tar -C "$src_root" -xf -
tar -C "$BUILD_DIR" -czf "$archive" "${pkgname}-${pkgver}"
rm -rf "$src_root"
archive_sha256=$(sha256sum "$archive" | cut -d' ' -f1)
# Keep the host makepkg configuration but force the options this payload needs.
makepkg_conf="${BUILD_DIR}/makepkg.conf"
cat /etc/makepkg.conf > "$makepkg_conf"
printf 'OPTIONS+=(docs !debug)\nPKGEXT=.pkg.tar.zst\n' >> "$makepkg_conf"

build_package() {
  local dir="$1" rel="$2" package
  mkdir -p "$dir"
  sed -e "s/^pkgrel=.*/pkgrel=${rel}/" \
    -e "s/^sha256sums=.*/sha256sums=('${archive_sha256}')/" "$pkgbuild" > "${dir}/PKGBUILD"
  cp "$archive" "${dir}/${pkgname}-${pkgver}.tar.gz"
  package="${dir}/${pkgname}-${pkgver}-${rel}-any.pkg.tar.zst"
  (cd "$dir" && PKGDEST="$dir" SRCDEST="$dir" SRCPKGDEST="$dir" LOGDEST="$dir" \
    BUILDDIR="${dir}/build" \
    makepkg --config "$makepkg_conf" --nodeps --noconfirm --noprogressbar --nosign --force \
    > "${dir}/makepkg.log" 2>&1) || {
    cat "${dir}/makepkg.log" >&2
    fail_test "makepkg failed for pkgrel ${rel}"
  }
  [[ -f "$package" ]] || fail_test "makepkg did not produce ${package##*/}"
  printf '%s\n' "$package"
}

package=$(build_package "${BUILD_DIR}/rel1" 1)
grep -Fq 'Validating source files with sha256sums' "${BUILD_DIR}/rel1/makepkg.log" \
  || fail_test "makepkg did not validate the substituted archive checksum"

# --- Built payload -----------------------------------------------------------

payload=$(bsdtar -tf "$package" | grep -v '^\.' | sort)
expected_payload=$(sort <<'EOF'
etc/
etc/boot/
etc/boot/hooks/
etc/boot/hooks/post.d/
etc/boot/hooks/post.d/zzz-omasecboot-sign
etc/boot/hooks/pre.d/
etc/boot/hooks/pre.d/000-omasecboot-guard
usr/
usr/bin/
usr/bin/omasecboot
usr/lib/
usr/lib/omasecboot/
usr/lib/omasecboot/checks.sh
usr/lib/omasecboot/common.sh
usr/lib/omasecboot/discover.sh
usr/lib/omasecboot/enroll.sh
usr/lib/omasecboot/lifecycle.sh
usr/lib/omasecboot/producers.sh
usr/lib/omasecboot/sign.sh
usr/lib/omasecboot/status.sh
usr/lib/omasecboot/windows.sh
usr/lib/tmpfiles.d/
usr/lib/tmpfiles.d/omasecboot.conf
usr/share/
usr/share/doc/
usr/share/doc/omasecboot/
usr/share/doc/omasecboot/README.md
usr/share/libalpm/
usr/share/libalpm/hooks/
usr/share/libalpm/hooks/00-omasecboot-removal-guard.hook
usr/share/libalpm/hooks/00-omasecboot-transition-guard.hook
usr/share/libalpm/hooks/zzz-omasecboot.hook
usr/share/licenses/
usr/share/licenses/omasecboot/
usr/share/licenses/omasecboot/LICENSE
EOF
)
[[ "$payload" == "$expected_payload" ]] || {
  diff <(printf '%s\n' "$expected_payload") <(printf '%s\n' "$payload") >&2 || true
  fail_test "built package payload drifted"
}
bsdtar -tf "$package" | grep -Fxq 'var/lib/omasecboot/' \
  && fail_test "durable state directory became package content"

pkginfo=$(bsdtar -xOf "$package" .PKGINFO)
grep -Fxq "pkgname = ${pkgname}" <<< "$pkginfo" || fail_test "built package name drifted"
grep -Fxq "pkgver = ${pkgver}-1" <<< "$pkginfo" || fail_test "built package version drifted"
grep -Fxq 'arch = any' <<< "$pkginfo" || fail_test "built package architecture drifted"
grep -Fxq 'license = MIT' <<< "$pkginfo" || fail_test "built package license drifted"
grep -Fxq "url = ${pkgurl}" <<< "$pkginfo" || fail_test "built package url drifted"
grep -Eq '^(makedepend|checkdepend|optdepend|backup|conflict|provides|replaces) = ' \
  <<< "$pkginfo" && fail_test "built package carries an unexpected relation"
[[ $(sed -n 's/^depend = //p' <<< "$pkginfo" | sort) == "$expected_depends" ]] \
  || fail_test "built package dependency registry drifted"

while read -r mode owner group path; do
  [[ "$owner:$group" == 0:0 ]] || fail_test "package entry is not root-owned: ${path}"
  case "$path" in
    */)
      [[ "$mode" == drwxr-xr-x ]] || fail_test "wrong directory mode: ${path} ${mode}" ;;
    usr/bin/omasecboot|etc/boot/hooks/pre.d/000-omasecboot-guard|etc/boot/hooks/post.d/zzz-omasecboot-sign)
      [[ "$mode" == -rwxr-xr-x ]] || fail_test "wrong executable mode: ${path} ${mode}" ;;
    usr/lib/omasecboot/*.sh|usr/share/libalpm/hooks/*.hook|usr/lib/tmpfiles.d/omasecboot.conf|usr/share/licenses/omasecboot/LICENSE|usr/share/doc/omasecboot/README.md)
      [[ "$mode" == -rw-r--r-- ]] || fail_test "wrong file mode: ${path} ${mode}" ;;
    .PKGINFO|.MTREE|.BUILDINFO) ;;
    *) fail_test "unexpected package entry: ${path}" ;;
  esac
done < <(bsdtar --numeric-owner -tvf "$package" | awk '{print $1, $3, $4, $NF}')

extract="${BUILD_DIR}/extract"
mkdir -p "$extract"
bsdtar -xf "$package" -C "$extract"
# The dispatcher normalizes hooks back to the placeholder, so only rendered
# hooks are scanned for it. Package metadata legitimately records the build
# directory; the payload may not.
grep -rFq '@BINDIR@' "${extract}/usr/share/libalpm/hooks" "${extract}/etc/boot/hooks" \
  && fail_test "an installed hook kept the unrendered command placeholder"
grep -rFq "$BUILD_DIR" "${extract}/usr" "${extract}/etc" \
  && fail_test "the build directory leaked into an installed file"
cmp -s "${extract}/usr/bin/omasecboot" "${ROOT_DIR}/bin/omasecboot" \
  || fail_test "packaged command differs from the source command"
for lib in common lifecycle checks discover sign producers enroll windows status; do
  cmp -s "${extract}/usr/lib/omasecboot/${lib}.sh" "${ROOT_DIR}/lib/${lib}.sh" \
    || fail_test "packaged library differs from the source: ${lib}.sh"
done
cmp -s "${extract}/usr/lib/tmpfiles.d/omasecboot.conf" "${ROOT_DIR}/omasecboot.tmpfiles" \
  || fail_test "packaged tmpfiles declaration differs from the source"
cmp -s "${extract}/usr/share/licenses/omasecboot/LICENSE" "${ROOT_DIR}/LICENSE" \
  || fail_test "packaged license differs from the source"

# Every packaged hook must pass activation for the packaged command target.
activation_hook_path() {
  case "$1" in
    removal) printf '%s/usr/share/libalpm/hooks/00-omasecboot-removal-guard.hook\n' "$extract" ;;
    transaction) printf '%s/usr/share/libalpm/hooks/00-omasecboot-transition-guard.hook\n' "$extract" ;;
    package-sign) printf '%s/usr/share/libalpm/hooks/zzz-omasecboot.hook\n' "$extract" ;;
    limine-pre) printf '%s/etc/boot/hooks/pre.d/000-omasecboot-guard\n' "$extract" ;;
    limine-post) printf '%s/etc/boot/hooks/post.d/zzz-omasecboot-sign\n' "$extract" ;;
    *) return 1 ;;
  esac
}
for key in removal transaction package-sign limine-pre limine-post; do
  validate_activation_hook "$key" /usr/bin/omasecboot \
    || fail_test "packaged hook would fail activation: ${key}"
  validate_activation_hook "$key" /usr/local/bin/omasecboot >/dev/null 2>&1 \
    && fail_test "packaged hook accepted a foreign command target: ${key}"
done
# A same-named administrator hook takes precedence in pacman, so it must block.
: > "${admin_hook_dir}/zzz-omasecboot.hook"
validate_activation_hook package-sign /usr/bin/omasecboot >/dev/null 2>&1 \
  && fail_test "a shadowed packaged hook passed activation"
rm -f "${admin_hook_dir}/zzz-omasecboot.hook"

# --- Staged pacman lifecycle --------------------------------------------------

root="${BUILD_DIR}/root"
override_hooks="${BUILD_DIR}/override-hooks"
mkdir -p "${root}/var/lib/pacman" "$override_hooks" "${BUILD_DIR}/cache"
printf '[options]\nSigLevel = Never\n' > "${BUILD_DIR}/pacman.conf"
# Same-named hooks in a later hook directory replace the packaged ones, so the
# staged transactions never try to execute the packaged command inside a chroot.
for hook in 00-omasecboot-removal-guard 00-omasecboot-transition-guard \
  zzz-omasecboot; do
  cat > "${override_hooks}/${hook}.hook" <<'EOF'
[Trigger]
Type = Path
Operation = Install
Target = omasecboot-staged-test/never/*

[Action]
Description = OmaSecBoot staged package test placeholder
When = PreTransaction
Exec = /usr/bin/true
EOF
done

stage_pacman() {
  fakeroot -- pacman --root "$root" --dbpath "${root}/var/lib/pacman" \
    --cachedir "${BUILD_DIR}/cache" --logfile "${BUILD_DIR}/pacman.log" \
    --hookdir "$override_hooks" --config "${BUILD_DIR}/pacman.conf" \
    --noconfirm "$@"
}

state="${root}/var/lib/omasecboot"
sbctl_keys="${root}/var/lib/sbctl/keys/db"
durable_snapshot() {
  find "$state" "${root}/var/lib/sbctl" -type f -exec sha256sum {} + | sort
}
installed_paths=(
  "${root}/usr/bin/omasecboot"
  "${root}/usr/lib/omasecboot/lifecycle.sh"
  "${root}/usr/share/libalpm/hooks/00-omasecboot-removal-guard.hook"
  "${root}/usr/share/libalpm/hooks/00-omasecboot-transition-guard.hook"
  "${root}/usr/share/libalpm/hooks/zzz-omasecboot.hook"
  "${root}/etc/boot/hooks/pre.d/000-omasecboot-guard"
  "${root}/etc/boot/hooks/post.d/zzz-omasecboot-sign"
  "${root}/usr/lib/tmpfiles.d/omasecboot.conf"
  "${root}/usr/share/licenses/omasecboot/LICENSE"
)
assert_installed() {
  local path
  for path in "${installed_paths[@]}"; do
    [[ -f "$path" ]] || fail_test "installed file is missing: ${path#"$root"}"
  done
  [[ -x "${root}/usr/bin/omasecboot" ]] || fail_test "installed command is not executable"
  [[ $(stage_pacman -Q "$pkgname") == "${pkgname} ${pkgver}-$1" ]] \
    || fail_test "installed package version is not ${pkgver}-$1"
  stage_pacman -Ql "$pkgname" | grep -Fq " ${root}/var/lib/omasecboot" \
    && fail_test "installed package claims the durable state directory"
  stage_pacman -Ql "$pkgname" | grep -Fq " ${root}/usr/bin/omasecboot" \
    || fail_test "installed package file listing is not root-prefixed as expected"
  stage_pacman -Qkk "$pkgname" >/dev/null 2>&1 \
    || fail_test "installed package failed its own file integrity check"
}

stage_pacman -Udd "$package" > "${BUILD_DIR}/install.out" 2>&1 \
  || { cat "${BUILD_DIR}/install.out" >&2; fail_test "staged package install failed"; }
assert_installed 1
[[ ! -e "$state" ]] || fail_test "package install created durable state before tmpfiles"

mkdir -p "${state}/transactions/fixture" "${state}/firmware-backup" "$sbctl_keys"
printf '{"schema_version":2,"state":"active"}\n' > "${state}/lifecycle.json"
printf '{}\n' > "${state}/transactions/fixture/manifest.json"
printf 'raw\n' > "${state}/firmware-backup/dbx.bin"
printf '{"schema_version":1,"enabled":true}\n' > "${state}/windows-enabled"
: > "${state}/repair.lock"
printf 'fixture key\n' > "${sbctl_keys}/db.key"
before=$(durable_snapshot)

stage_pacman -Udd "$package" > "${BUILD_DIR}/reinstall.out" 2>&1 \
  || { cat "${BUILD_DIR}/reinstall.out" >&2; fail_test "staged package reinstall failed"; }
assert_installed 1
[[ $(durable_snapshot) == "$before" ]] || fail_test "reinstall changed durable state"

upgrade=$(build_package "${BUILD_DIR}/rel2" 2)
stage_pacman -Udd "$upgrade" > "${BUILD_DIR}/upgrade.out" 2>&1 \
  || { cat "${BUILD_DIR}/upgrade.out" >&2; fail_test "staged package upgrade failed"; }
assert_installed 2
[[ $(durable_snapshot) == "$before" ]] || fail_test "upgrade changed durable state"

# Failure injection: an AbortOnFail removal guard that cannot succeed must leave
# the package, its files, and durable state exactly as they were. Under fakeroot
# the hook child cannot chroot into the stage, so this proves that a failing
# PreTransaction hook aborts the removal, not how its exit status propagates;
# tests/package-root.sh covers the real execution.
cat > "${override_hooks}/00-omasecboot-removal-guard.hook" <<'HOOK'
[Trigger]
Type = Package
Operation = Remove
Target = omasecboot

[Action]
Description = OmaSecBoot staged package test: failing removal guard
When = PreTransaction
Exec = /usr/bin/false
AbortOnFail
HOOK
if stage_pacman -Rdd "$pkgname" > "${BUILD_DIR}/blocked-remove.out" 2>&1; then
  fail_test "removal succeeded although the removal guard failed"
fi
assert_installed 2
[[ $(durable_snapshot) == "$before" ]] || fail_test "blocked removal changed durable state"
cat > "${override_hooks}/00-omasecboot-removal-guard.hook" <<'HOOK'
[Trigger]
Type = Path
Operation = Install
Target = omasecboot-staged-test/never/*

[Action]
Description = OmaSecBoot staged package test placeholder
When = PreTransaction
Exec = /usr/bin/true
HOOK

stage_pacman -Rdd "$pkgname" > "${BUILD_DIR}/remove.out" 2>&1 \
  || { cat "${BUILD_DIR}/remove.out" >&2; fail_test "staged package removal failed"; }
stage_pacman -Q "$pkgname" >/dev/null 2>&1 && fail_test "package remained installed after removal"
for path in "${installed_paths[@]}"; do
  [[ ! -e "$path" ]] || fail_test "removal left package content behind: ${path#"$root"}"
done
[[ ! -d "${root}/usr/lib/omasecboot" ]] || fail_test "removal left the library directory behind"
[[ $(durable_snapshot) == "$before" ]] \
  || fail_test "removal changed durable lifecycle, recovery, Windows, or key state"
[[ -f "${state}/repair.lock" ]] || fail_test "removal deleted the stable repair lock"

# --- make package ------------------------------------------------------------

make_dest="${BUILD_DIR}/make-package"
make_output=$(make -s -C "$ROOT_DIR" package PKGDEST="$make_dest" 2> "${BUILD_DIR}/make-package.log") \
  || { cat "${BUILD_DIR}/make-package.log" >&2; fail_test "make package failed"; }
[[ "$make_output" == "${make_dest}/${pkgname}-${pkgver}-1-any.pkg.tar.zst" && -f "$make_output" ]] \
  || fail_test "make package did not report the built package path"
[[ $(bsdtar -tf "$make_output" | grep -v '^\.' | sort) == "$payload" ]] \
  || fail_test "make package payload differs from the tested build"

printf 'package tests passed\n'
