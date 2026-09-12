# Maintainer: OmaSecBoot maintainers (https://github.com/peregrinus879/omasecboot)

pkgname=omasecboot
pkgver=1.0.0
pkgrel=1
pkgdesc='Secure Boot lifecycle for Omarchy: signing, Limine enrollment, Windows handoff'
arch=('any')
url='https://github.com/peregrinus879/omasecboot'
license=('MIT')
# These are resolver floors so that ordinary system updates keep resolving.
# Runtime admission enforces the audited producer versions documented in
# README.md. The package guard blocks changes to those three producer packages
# while the lifecycle is active. efibootmgr only needs release 18 or newer.
depends=(
  'bash'
  'coreutils>=9.5'
  'diffutils'
  'findutils'
  'gawk'
  'grep'
  'util-linux'
  'systemd'
  'pacman'
  'jq'
  'openssl'
  'gum'
  'efibootmgr>=18'
  'sbctl>=0.18'
  'limine'
  'limine-mkinitcpio-hook>=1.38.0'
  'limine-snapper-sync>=1.31.0'
)
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
# An in-tree recipe cannot carry the checksum of the archive that contains it,
# so the omarchy-pkgs release recipe pins the tagged archive checksum instead.
# tests/package.sh substitutes the working-tree archive checksum for its build.
sha256sums=('SKIP')

package() {
  cd "$srcdir/$pkgname-$pkgver" || return 1
  make DESTDIR="$pkgdir" install
}
