# Maintainer: OmaSecBoot maintainers (https://github.com/peregrinus879/omasecboot)

pkgname=omasecboot
pkgver=1.0.0
pkgrel=1
pkgdesc='Secure Boot for Omarchy with your own keys: sbctl signing and Limine config enrollment'
arch=('any')
url='https://github.com/peregrinus879/omasecboot'
license=('MIT')
# Version floors only: the tool never blocks a system update, and its status
# report says what an upstream change broke.
depends=(
  'bash'
  'coreutils'
  'diffutils'
  'findutils'
  'gawk'
  'grep'
  'sed'
  'tar'
  'util-linux'
  'systemd'
  'pacman'
  'jq'
  'gum'
  'sbctl>=0.18'
  'limine'
  'limine-mkinitcpio-hook>=1.38.0'
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
