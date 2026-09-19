PREFIX     ?= /usr
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
TEST_SUITES = common limine sign status commands install
TEST_TARGETS = $(addprefix test-,$(TEST_SUITES))

.PHONY: install lint test $(TEST_TARGETS)

# Installation is staging only: DESTDIR must be an absolute path that does not
# resolve to the live root. A copy installed by hand is what setup later
# refuses as a leftover.
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

# bash -n parses only its first operand, so every script gets its own call.
lint:
	@for script in $(SCRIPTS); do bash -n "$$script" || exit 1; done
	shellcheck -x $(SCRIPTS)

test: $(TEST_TARGETS)

$(TEST_TARGETS): test-%:
	bash tests/$*.sh
