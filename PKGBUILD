# Maintainer: Hesham A. <132817088+peregrinus879@users.noreply.github.com>

pkgname=omasecboot
pkgver=0.1.0
pkgrel=1
pkgdesc='Secure Boot for Omarchy with your own keys, through sbctl and the Limine tools'
arch=('any')
url='https://github.com/peregrinus879/omasecboot'
license=('MIT')
# Version floors only: the tool never blocks a system update, and its status
# report says what an upstream change broke.
# limine 11.0.0 is the first with the efi_boot_entry protocol, which the
# Windows entry uses; sbctl 0.18 and limine-mkinitcpio-hook 1.38.0 are the
# versions the upstream contracts were read at.
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
  'procps-ng'
  'systemd'
  'pacman'
  'jq'
  'gum'
  'sbctl>=0.18'
  'efibootmgr'
  'limine>=11.0.0'
  'limine-mkinitcpio-hook>=1.38.0'
)
# One message before removal from a machine that is still set up; see the file.
install=omasecboot.install
# The documentation directory carries the menu fragment the README points to,
# and a package of scripts has nothing for a debug package, which the field
# guide's install line would match.
options=('docs' '!debug')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
# An in-tree recipe cannot carry the checksum of the archive that contains it,
# so a release recipe in omarchy-pkgs would pin the tagged archive checksum instead.
# "make package" supplies an archive of the working tree in its place.
sha256sums=('SKIP')

package() {
  cd "$srcdir/$pkgname-$pkgver" || return 1
  make DESTDIR="$pkgdir" PREFIX=/usr install
}
