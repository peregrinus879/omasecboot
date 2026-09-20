#!/bin/bash
# Builds the Arch package from the checkout's files and inspects what it would
# put on a machine: metadata, dependencies, the exact payload, owners and modes.
# Installation, the hook and removal run for real in tests/container.sh.
set -euo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")
# shellcheck source=tests/lib/harness.sh
source "$ROOT_DIR/tests/lib/harness.sh"
test_harness_init package
CASE_NAME=built-package

for tool in makepkg fakeroot bsdtar git tar make; do
  command -v "$tool" >/dev/null 2>&1 || fail_test "the package test needs ${tool}"
done
git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail_test "the package is built from git ls-files and needs a checkout"

pkgbuild=$ROOT_DIR/PKGBUILD
pkgver=$(sed -n 's/^pkgver=//p' "$pkgbuild")
[[ $pkgver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail_test "pkgver is not a release version: ${pkgver}"
[[ $(bash "$ROOT_DIR/bin/omasecboot" version) == "omasecboot ${pkgver}" ]] || fail_test "PKGBUILD and the command disagree on the version"
grep -Fxq "arch=('any')" "$pkgbuild" || fail_test "an interpreted package must be architecture any"
grep -Fxq "license=('MIT')" "$pkgbuild" || fail_test "license"
# No scriptlet, no backup files, no relations: everything outside the
# package's own files is the work of the tool's commands.
! grep -Eq '^(install|backup|conflicts|provides|replaces|makedepends|checkdepends|optdepends)=' "$pkgbuild" ||
  fail_test "PKGBUILD declares a scriptlet or an unexpected relation"

expected_depends=$(sort <<'DEPENDS'
bash
coreutils
diffutils
efibootmgr
findutils
gawk
grep
gum
jq
limine-mkinitcpio-hook>=1.38.0
limine>=11.0.0
pacman
procps-ng
sbctl>=0.18
sed
systemd
tar
util-linux
DEPENDS
)

package=$(make -s -C "$ROOT_DIR" package PKGDEST="$TEST_DIR" 2>"$TEST_DIR/build.log") ||
  { cat "$TEST_DIR/build.log" >&2; fail_test "make package failed"; }
[[ -f $package ]] || fail_test "no package at ${package}"

expected_payload=$(sort <<'PAYLOAD'
etc/
etc/boot/
etc/boot/hooks/
etc/boot/hooks/post.d/
etc/boot/hooks/post.d/90-omasecboot-sign
usr/
usr/bin/
usr/bin/omasecboot
usr/lib/
usr/lib/omasecboot/
usr/lib/omasecboot/checks.sh
usr/lib/omasecboot/common.sh
usr/lib/omasecboot/files.sh
usr/lib/omasecboot/firmware.sh
usr/lib/omasecboot/limine.sh
usr/lib/omasecboot/sign.sh
usr/lib/omasecboot/status.sh
usr/lib/omasecboot/windows.sh
usr/lib/systemd/
usr/lib/systemd/system/
usr/lib/systemd/system/omasecboot-watch@.path
usr/lib/systemd/system/omasecboot-watch@.service
usr/share/
usr/share/doc/
usr/share/doc/omasecboot/
usr/share/doc/omasecboot/CHANGELOG.md
usr/share/doc/omasecboot/README.md
usr/share/doc/omasecboot/docs/
usr/share/doc/omasecboot/docs/field-testing.md
usr/share/doc/omasecboot/docs/maintenance.md
usr/share/doc/omasecboot/docs/omarchy-integration.md
usr/share/doc/omasecboot/docs/release-checklist.md
usr/share/doc/omasecboot/docs/spec.md
usr/share/doc/omasecboot/docs/upstream-contracts.md
usr/share/doc/omasecboot/omarchy-menu.jsonc
usr/share/licenses/
usr/share/licenses/omasecboot/
usr/share/licenses/omasecboot/LICENSE
PAYLOAD
)
payload=$(bsdtar -tf "$package" | grep -v '^\.' | sort)
[[ $payload == "$expected_payload" ]] || {
  diff <(printf '%s\n' "$expected_payload") <(printf '%s\n' "$payload") >&2 || true
  fail_test "the built payload drifted"
}

pkginfo=$(bsdtar -xOf "$package" .PKGINFO)
[[ $(sed -n 's/^depend = //p' <<<"$pkginfo" | sort) == "$expected_depends" ]] || fail_test "the built dependencies drifted"
grep -Fxq 'arch = any' <<<"$pkginfo" || fail_test "built architecture"
! bsdtar -tf "$package" | grep -Fxq '.INSTALL' || fail_test "the package carries an install scriptlet"

# Everything is root's; only the command and the hook are executable.
while read -r mode owner group path; do
  [[ $path != .* ]] || continue
  [[ $owner == 0 && $group == 0 ]] || fail_test "${path} is owned by ${owner}:${group}"
  case $path in
    */) [[ $mode == drwxr-xr-x ]] || fail_test "${path} has mode ${mode}" ;;
    usr/bin/omasecboot | etc/boot/hooks/post.d/90-omasecboot-sign) [[ $mode == -rwxr-xr-x ]] || fail_test "${path} has mode ${mode}" ;;
    *) [[ $mode == -rw-r--r-- ]] || fail_test "${path} has mode ${mode}" ;;
  esac
done < <(bsdtar --numeric-owner -tvf "$package" | awk '{print $1, $3, $4, $NF}')

bsdtar -xOf "$package" etc/boot/hooks/post.d/90-omasecboot-sign | grep -qx '/usr/bin/omasecboot sign --quiet || :' ||
  fail_test "the packaged hook does not call /usr/bin/omasecboot"
printf 'PASS: package/built-package\npackage tests passed (1 cases)\n'
