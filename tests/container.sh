#!/bin/bash
# The package under real pacman, in a disposable Arch container: what a machine
# that never runs "setup" gets. The files, no state, a dormant hook that costs
# nothing, no pacman hooks, an upgrade, and a removal that leaves the state
# directory alone. It installs and removes packages on the running system, so
# it refuses to run unless a throwaway container job declares itself with
# OMASECBOOT_DISPOSABLE_ROOT=1. Never run it on a real machine.
set -euo pipefail
ROOT_DIR=$(realpath "${BASH_SOURCE[0]%/*}/..")

fail_test() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Runs a command with its output in LOG, shown only when the command fails.
logged() {
  local log=$1 what=$2
  shift 2
  "$@" >"$log" 2>&1 || {
    cat "$log" >&2
    fail_test "$what"
  }
}

[[ ${OMASECBOOT_DISPOSABLE_ROOT:-} == 1 ]] || fail_test "refusing to change a system that is not a declared disposable root"
(( EUID == 0 )) || fail_test "this check installs packages and needs root"
[[ -f /.dockerenv || -f /run/.containerenv ]] || fail_test "refusing to run outside a container"
[[ ! -e /var/lib/sbctl/keys ]] || fail_test "refusing to run where sbctl keys exist"
[[ $(stat -f -c %T /sys/firmware/efi/efivars 2>/dev/null) != efivarfs ]] || fail_test "refusing to run where the firmware's variables are reachable"

pkgname=omasecboot
pkgver=$(sed -n 's/^pkgver=//p' "$ROOT_DIR/PKGBUILD")
state=/var/lib/omasecboot
hook=/etc/boot/hooks/post.d/90-omasecboot-sign
build=$(mktemp -d /tmp/omasecboot-container.XXXXXX)
trap 'rm -rf "$build"' EXIT

# makepkg refuses root, so an unprivileged user builds from an archive of the
# working tree. The checkout belongs to the CI user; root trusts it explicitly.
builder=omasecboot-build
id "$builder" >/dev/null 2>&1 || useradd --system --create-home "$builder"
mkdir -p "$build/$pkgname-$pkgver"
git -C "$ROOT_DIR" -c safe.directory="$ROOT_DIR" ls-files -z --cached --others --exclude-standard |
  tar -C "$ROOT_DIR" --null -T - -cf - | tar -C "$build/$pkgname-$pkgver" -xf -
tar -C "$build" -czf "$build/$pkgname-$pkgver.tar.gz" "$pkgname-$pkgver"
cp "$ROOT_DIR/PKGBUILD" "$ROOT_DIR/omasecboot.install" "$build/"

# build_release PKGREL: prints the path of the built package.
build_release() {
  local release=$1
  sed -i "s/^pkgrel=.*/pkgrel=${release}/" "$build/PKGBUILD"
  chown -R "$builder" "$build"
  logged "$build/makepkg-${release}.log" "makepkg failed for pkgrel ${release}" \
    runuser -u "$builder" -- env HOME="/home/$builder" PKGDEST="$build" SRCDEST="$build" \
    SRCPKGDEST="$build" LOGDEST="$build" BUILDDIR="$build/build" PKGEXT=.pkg.tar.zst \
    bash -c "cd '$build' && makepkg --nodeps --noconfirm --noprogressbar --nosign --force"
  printf '%s\n' "$build/$pkgname-$pkgver-$release-any.pkg.tar.zst"
}
package=$(build_release 1)
upgrade=$(build_release 2)

# The Arch container image skips documentation through NoExtract, which would
# fail the integrity check on the packaged README.
sed -i '/^NoExtract/d' /etc/pacman.conf

# Arch provides every dependency except limine-mkinitcpio-hook, which comes
# from the Omarchy repository and is assumed here.
logged "$build/dependencies.log" "dependency install failed" \
  pacman -S --noconfirm --needed bash coreutils diffutils findutils gawk grep sed tar util-linux procps-ng systemd pacman jq gum sbctl efibootmgr limine
assume=(--assume-installed limine-mkinitcpio-hook=1.38.0-1.1)

logged "$build/install.log" "package install failed" pacman -U --noconfirm "${assume[@]}" "$package"
logged "$build/integrity.log" "installed files differ from the package" pacman -Qkk "$pkgname"
[[ $(omasecboot version) == "omasecboot ${pkgver}" ]] || fail_test "the installed command does not run"
[[ ! -e $state ]] || fail_test "a fresh install wrote state"
[[ -z $(find /usr/share/libalpm/hooks /etc/pacman.d/hooks -name '*omasecboot*' 2>/dev/null) ]] ||
  fail_test "the package installed a pacman hook"
[[ -f /usr/lib/systemd/system/omasecboot-watch@.path ]] || fail_test "watcher template missing"
[[ -z $(find /etc/systemd/system -name 'omasecboot-watch@*') ]] || fail_test "installation enabled a watcher"

# Dormant: the hook exits 0 at once, sign refuses, and remove says that it has
# nothing to take back and leaves no state.
"$hook" || fail_test "the dormant hook failed"
! omasecboot sign >/dev/null 2>&1 || fail_test "sign ran on a machine that was never set up"
output=$(omasecboot remove 2>&1) || fail_test "remove failed on a machine that was never set up: ${output}"
[[ $output == *'Nothing to remove'* ]] || fail_test "remove did not say that there is nothing to remove: ${output}"
[[ ! -e $state ]] || fail_test "remove wrote state on a machine that was never set up"

# Another package's transaction never involves this one.
logged "$build/unrelated.log" "an unrelated transaction failed" pacman -S --noconfirm --needed which
! grep -qi omasecboot "$build/unrelated.log" || fail_test "this package took part in an unrelated transaction"

logged "$build/upgrade.log" "package upgrade failed" pacman -U --noconfirm "${assume[@]}" "$upgrade"

# Removal leaves the state directory: it would hold the firmware backups. From
# a machine that is still set up it says what that means, and goes through.
install -d "$state"
: >"$state/keep-me"
: >"$state/enabled"
logged "$build/remove.log" "package removal failed" pacman -R --noconfirm "$pkgname"
grep -q 'OmaSecBoot is still set up on this machine' "$build/remove.log" || fail_test "removal from a set-up machine said nothing"
[[ -e $state/keep-me ]] || fail_test "removal deleted the state directory's content"
[[ ! -e /usr/bin/omasecboot && ! -e $hook ]] || fail_test "removal left package files behind"
printf 'container tests passed\n'
