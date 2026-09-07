PREFIX     ?= /usr
BINDIR      = $(PREFIX)/bin
LIBDIR      = $(PREFIX)/lib/omasecboot
LICENSEDIR  = $(PREFIX)/share/licenses/omasecboot
DOCDIR      = $(PREFIX)/share/doc/omasecboot
# pacman always reads the system hook directory (configured HookDir entries
# take precedence for same-named hooks, so activation refuses shadowed hooks),
# and systemd-tmpfiles reads only its own directories, so these do not follow PREFIX.
HOOKDIR     = /usr/share/libalpm/hooks
TMPFILESDIR = /usr/lib/tmpfiles.d
LIMINEPREHOOKDIR  = /etc/boot/hooks/pre.d
LIMINEPOSTHOOKDIR = /etc/boot/hooks/post.d
PACMAN_HOOKS = 00-omasecboot-removal-guard.hook \
               00-omasecboot-transition-guard.hook \
               zzz-omasecboot.hook

.PHONY: install uninstall test

# Installation is package staging only: DESTDIR must be an absolute path that
# does not resolve to the live root. The Arch package built from PKGBUILD is the
# supported deployment; durable state under /var/lib/omasecboot is declared
# through tmpfiles and is never package content.
install:
	@case "$(DESTDIR)" in /*) test "$$(realpath -m -- "$(DESTDIR)")" != / ;; *) false ;; esac || { echo "Refusing live source install; use a package build with an absolute non-root DESTDIR" >&2; exit 1; }
	install -Dm644 -t "$(DESTDIR)$(LIBDIR)/" lib/*.sh
	install -Dm755 bin/omasecboot "$(DESTDIR)$(BINDIR)/omasecboot"
	install -d "$(DESTDIR)$(HOOKDIR)"
	@for hook in $(PACMAN_HOOKS); do \
	  sed 's|@BINDIR@|$(BINDIR)|g' "pacman-hooks/$$hook" > "$(DESTDIR)$(HOOKDIR)/$$hook" || exit 1; \
	  chmod 644 "$(DESTDIR)$(HOOKDIR)/$$hook" || exit 1; \
	done
	install -d "$(DESTDIR)$(LIMINEPREHOOKDIR)"
	sed 's|@BINDIR@|$(BINDIR)|g' limine-hooks/000-omasecboot-guard > "$(DESTDIR)$(LIMINEPREHOOKDIR)/000-omasecboot-guard"
	chmod 755 "$(DESTDIR)$(LIMINEPREHOOKDIR)/000-omasecboot-guard"
	install -d "$(DESTDIR)$(LIMINEPOSTHOOKDIR)"
	sed 's|@BINDIR@|$(BINDIR)|g' limine-hooks/zzz-omasecboot-sign > "$(DESTDIR)$(LIMINEPOSTHOOKDIR)/zzz-omasecboot-sign"
	chmod 755 "$(DESTDIR)$(LIMINEPOSTHOOKDIR)/zzz-omasecboot-sign"
	install -Dm644 omasecboot.tmpfiles "$(DESTDIR)$(TMPFILESDIR)/omasecboot.conf"
	install -Dm644 LICENSE "$(DESTDIR)$(LICENSEDIR)/LICENSE"
	install -Dm644 README.md "$(DESTDIR)$(DOCDIR)/README.md"

# Package removal through pacman is the supported removal path. Its
# PreTransaction guard allows removal only from verified disabled or pristine
# lifecycle state and preserves durable state, local sbctl keys, and the lock.
uninstall:
	@echo "Refusing source uninstall; remove the omasecboot package with pacman" >&2
	@false

test:
	bash tests/lifecycle.sh
	bash tests/producers.sh
	bash tests/producer-repair.sh
	bash tests/producer-ownership.sh
	bash tests/recovery-publication.sh
	bash tests/software-recovery.sh
	bash tests/artifacts.sh
	bash tests/unconfigure.sh
	bash tests/unconfigure-tools.sh
	bash tests/guards.sh
	bash tests/dispatcher.sh
	bash tests/install.sh
	bash tests/package.sh
	bash tests/windows.sh
	bash tests/windows-preflight.sh
	bash tests/windows-entry.sh
	bash tests/enrollment.sh
