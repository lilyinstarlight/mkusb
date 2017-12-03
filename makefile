PREFIX?=$(DESTDIR)/usr/local
BINDIR?=$(PREFIX)/bin
SHRDIR?=$(PREFIX)/share

install:
	install -D mkusb.sh $(BINDIR)/mkusb
	install -D mkusb.1 $(SHRDIR)/man/man1/mkusb.1

uninstall:
	-rm -f $(SHRDIR)/man/man1/mkusb.1
	-rm -f $(BINDIR)/mkusb

.PHONY: install uninstall
