PREFIX   ?= /usr/local
BINDIR    = $(PREFIX)/bin
LIBDIR    = $(PREFIX)/lib/omasecboot
HOOKDIR   = /etc/pacman.d/hooks
LIMINEPREHOOKDIR = /etc/boot/hooks/pre.d
LIMINEPOSTHOOKDIR = /etc/boot/hooks/post.d
STATEDIR  = /var/lib/omasecboot

.PHONY: install uninstall test

install:
	install -Dm644 -t $(DESTDIR)$(LIBDIR)/ lib/*.sh
	install -d -m 755 $(DESTDIR)$(STATEDIR)
	install -Dm755 bin/omasecboot $(DESTDIR)$(BINDIR)/omasecboot
	install -d $(DESTDIR)$(HOOKDIR)
	sed 's|@BINDIR@|$(BINDIR)|g' pacman-hooks/00-omasecboot-removal-guard.hook > $(DESTDIR)$(HOOKDIR)/00-omasecboot-removal-guard.hook
	chmod 644 $(DESTDIR)$(HOOKDIR)/00-omasecboot-removal-guard.hook
	sed 's|@BINDIR@|$(BINDIR)|g' pacman-hooks/00-omasecboot-transition-guard.hook > $(DESTDIR)$(HOOKDIR)/00-omasecboot-transition-guard.hook
	chmod 644 $(DESTDIR)$(HOOKDIR)/00-omasecboot-transition-guard.hook
	sed 's|@BINDIR@|$(BINDIR)|g' pacman-hooks/zz-omasecboot-cleanup.hook > $(DESTDIR)$(HOOKDIR)/zz-omasecboot-cleanup.hook
	chmod 644 $(DESTDIR)$(HOOKDIR)/zz-omasecboot-cleanup.hook
	sed 's|@BINDIR@|$(BINDIR)|g' pacman-hooks/zzz-omasecboot.hook > $(DESTDIR)$(HOOKDIR)/zzz-omasecboot.hook
	chmod 644 $(DESTDIR)$(HOOKDIR)/zzz-omasecboot.hook
	install -d $(DESTDIR)$(LIMINEPREHOOKDIR)
	sed 's|@BINDIR@|$(BINDIR)|g' limine-hooks/000-omasecboot-guard > $(DESTDIR)$(LIMINEPREHOOKDIR)/000-omasecboot-guard
	chmod 755 $(DESTDIR)$(LIMINEPREHOOKDIR)/000-omasecboot-guard
	install -d $(DESTDIR)$(LIMINEPOSTHOOKDIR)
	sed 's|@BINDIR@|$(BINDIR)|g' limine-hooks/zzz-omasecboot-sign > $(DESTDIR)$(LIMINEPOSTHOOKDIR)/zzz-omasecboot-sign
	chmod 755 $(DESTDIR)$(LIMINEPOSTHOOKDIR)/zzz-omasecboot-sign
	@echo
	@echo "Installed omasecboot to $(BINDIR)"
	@echo "Run: sudo omasecboot help"

uninstall:
	@echo "Refusing uninstall until concurrency-safe package removal is available" >&2
	@false

test:
	bash tests/lifecycle.sh
	bash tests/producers.sh
	bash tests/producer-ownership.sh
	bash tests/recovery-publication.sh
	bash tests/software-recovery.sh
	bash tests/artifacts.sh
	bash tests/unconfigure.sh
	bash tests/unconfigure-tools.sh
	bash tests/hooks.sh
	bash tests/guards.sh
	bash tests/dispatcher.sh
	bash tests/install.sh
	bash tests/windows.sh
	bash tests/windows-preflight.sh
	bash tests/windows-entry.sh
	bash tests/enrollment.sh
