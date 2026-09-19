SHELL      := /bin/bash
PREFIX     ?= /usr
PKGDEST    ?= $(CURDIR)
BINDIR      = $(PREFIX)/bin
LIBDIR      = $(PREFIX)/lib/omasecboot
LICENSEDIR  = $(PREFIX)/share/licenses/omasecboot
DOCDIR      = $(PREFIX)/share/doc/omasecboot
# systemd and the Limine tools read fixed directories, so these do not follow
# PREFIX.
UNITDIR     = /usr/lib/systemd/system
HOOKDIR     = /etc/boot/hooks/post.d
SCRIPTS = bin/omasecboot $(wildcard lib/*.sh) limine-hooks/90-omasecboot-sign \
          $(wildcard tests/*.sh) $(wildcard tests/lib/*.sh)
TEST_SUITES = common limine sign status firmware windows commands install package
CONTRACT_SUITES = sbctl limine
TEST_TARGETS = $(addprefix test-,$(TEST_SUITES))
CONTRACT_TARGETS = $(addprefix test-contract-,$(CONTRACT_SUITES))

.PHONY: install package lint test test-contract $(TEST_TARGETS) $(CONTRACT_TARGETS)

# Installation is package staging only: DESTDIR must be an absolute path that
# does not resolve to the live root. The Arch package built from PKGBUILD is
# the supported deployment.
install:
	@case "$(DESTDIR)" in /*) test "$$(realpath -m -- "$(DESTDIR)")" != / ;; *) false ;; esac || { echo "Refusing live source install; use a package build with an absolute non-root DESTDIR" >&2; exit 1; }
	install -Dm644 -t "$(DESTDIR)$(LIBDIR)/" lib/*.sh
	install -Dm755 bin/omasecboot "$(DESTDIR)$(BINDIR)/omasecboot"
	install -d "$(DESTDIR)$(HOOKDIR)" "$(DESTDIR)$(UNITDIR)"
	sed 's|@BINDIR@|$(BINDIR)|g' limine-hooks/90-omasecboot-sign > "$(DESTDIR)$(HOOKDIR)/90-omasecboot-sign"
	chmod 755 "$(DESTDIR)$(HOOKDIR)/90-omasecboot-sign"
	@for unit in omasecboot-watch@.path omasecboot-watch@.service; do \
	  sed 's|@BINDIR@|$(BINDIR)|g' "systemd/$$unit" > "$(DESTDIR)$(UNITDIR)/$$unit" || exit 1; \
	  chmod 644 "$(DESTDIR)$(UNITDIR)/$$unit" || exit 1; \
	done
	install -Dm644 LICENSE "$(DESTDIR)$(LICENSEDIR)/LICENSE"
	install -Dm644 README.md "$(DESTDIR)$(DOCDIR)/README.md"
	install -Dm644 -t "$(DESTDIR)$(DOCDIR)/docs/" docs/*.md
	install -Dm644 omarchy/omarchy-menu.jsonc "$(DESTDIR)$(DOCDIR)/omarchy-menu.jsonc"

# Build the Arch package from the files of this checkout that git does not
# ignore, as they are on disk, so the result does not depend on what is staged.
# PKGBUILD names the tagged GitHub archive, which does not exist before the
# release tag, so the same layout (<name>-<version>/ prefix) is produced here
# and makepkg uses it in place of a download. Dependencies are checked by
# pacman at install time.
package:
	@set -euo pipefail; \
	pkgname=$$(sed -n 's/^pkgname=//p' PKGBUILD); \
	pkgver=$$(sed -n 's/^pkgver=//p' PKGBUILD); \
	pkgrel=$$(sed -n 's/^pkgrel=//p' PKGBUILD); \
	dest=$$(realpath -m -- "$(PKGDEST)"); \
	build=$$(mktemp -d "$${TMPDIR:-/tmp}/omasecboot-package.XXXXXX"); \
	trap 'rm -rf "$$build"' EXIT; \
	mkdir -p "$$build/$$pkgname-$$pkgver" "$$dest"; \
	git ls-files -z --cached --others --exclude-standard | \
	  while IFS= read -r -d '' file; do [ ! -e "$$file" ] || printf '%s\0' "$$file"; done > "$$build/files"; \
	tar --null -T "$$build/files" -cf "$$build/files.tar"; \
	tar -C "$$build/$$pkgname-$$pkgver" -xf "$$build/files.tar"; \
	tar -C "$$build" -czf "$$build/$$pkgname-$$pkgver.tar.gz" "$$pkgname-$$pkgver"; \
	cp PKGBUILD "$$build/"; \
	cat /etc/makepkg.conf > "$$build/makepkg.conf"; \
	printf 'OPTIONS+=(docs !debug)\nPKGEXT=.pkg.tar.zst\n' >> "$$build/makepkg.conf"; \
	cd "$$build" && PKGDEST="$$dest" SRCDEST="$$build" SRCPKGDEST="$$build" \
	  LOGDEST="$$build" BUILDDIR="$$build/build" \
	  makepkg --config "$$build/makepkg.conf" --force --nodeps --noconfirm --noprogressbar --nosign 1>&2; \
	  echo "$$dest/$$pkgname-$$pkgver-$$pkgrel-any.pkg.tar.zst"

# bash -n parses only its first operand, so every script gets its own call.
lint:
	@for script in $(SCRIPTS) PKGBUILD; do bash -n "$$script" || exit 1; done
	shellcheck -x $(SCRIPTS)
	# JSONC is JSON with whole-line comments.
	grep -v '^[[:space:]]*//' omarchy/omarchy-menu.jsonc | jq -e . >/dev/null
	# makepkg consumes package metadata and supplies srcdir/pkgdir at execution.
	shellcheck --shell=bash --exclude=SC2034,SC2154 PKGBUILD

test: $(TEST_TARGETS)

$(TEST_TARGETS): test-%:
	bash tests/$*.sh

# The contract suites run the installed sbctl and Limine tools in a sandbox.
# Their result depends on those packages' versions, so "test" leaves them out.
test-contract: $(CONTRACT_TARGETS)

$(CONTRACT_TARGETS): test-contract-%:
	bash tests/contract-$*.sh
