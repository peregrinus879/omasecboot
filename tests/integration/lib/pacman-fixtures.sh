#!/usr/bin/env bash
# Caller supplies scratch, repo and die. All package payloads are synthetic.
# shellcheck disable=SC2154
pacman_fixture_read_error() {
  cc -Wall -Wextra -Werror -fPIC -shared -O2 \
    "$repo/tests/integration/fixtures/pacman-read-error.c" -ldl -o "$scratch/fixtures/pacman-read-error.so"
}

pacman_fixture_package() {
  local name=$1 version=$2 module=$3 scriptlet=${4:-none}
  local root=$scratch/package-$name-$version
  mkdir -p "$root/usr/share/omasecboot-contract"
  chmod 755 "$root/usr" "$root/usr/share" "$root/usr/share/omasecboot-contract"
  printf 'fixture %s %s\n' "$name" "$version" >"$root/usr/share/omasecboot-contract/$name"
  chmod 644 "$root/usr/share/omasecboot-contract/$name"
  if [[ $module != none ]]; then
    mkdir -p "$root/usr/lib/modules/$module"
    chmod 755 "$root/usr/lib" "$root/usr/lib/modules" "$root/usr/lib/modules/$module"
    if [[ $module != directory-only ]]; then
      printf 'fixture builtin\n' >"$root/usr/lib/modules/$module/modules.builtin"
      printf 'fixture kernel %s\n' "$version" >"$root/usr/lib/modules/$module/vmlinuz"
      chmod 644 "$root/usr/lib/modules/$module/"*
    fi
  fi
  cat >"$root/.PKGINFO" <<EOF
pkgname = $name
pkgbase = $name
pkgver = $version
pkgdesc = Disposable OmaSecBoot contract fixture
url = https://example.invalid/omasecboot-contract
builddate = 1
packager = OmaSecBoot contract fixture
size = 128
arch = any
license = MIT
EOF
  case $scriptlet in
    remove-hook)
      cat >"$root/.INSTALL" <<'EOF'
post_install() {
  rm /etc/pacman.d/hooks/80-contract-producer.hook
}
EOF
      ;;
    change-hook)
      cat >"$root/.INSTALL" <<'EOF'
post_install() {
  printf '\n# changed after expectation\n' >>/etc/pacman.d/hooks/80-contract-producer.hook
}
EOF
      ;;
    none) ;;
    *) die "unknown fixture scriptlet: $scriptlet" ;;
  esac
  local -a entries=(.PKGINFO usr)
  [[ $scriptlet == none ]] || entries+=(.INSTALL)
  bsdtar --uid 0 --gid 0 --uname root --gname root \
    -cf "$scratch/fixtures/packages/$name-$version-any.pkg.tar" -C "$root" "${entries[@]}"
}
