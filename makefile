PREFIX?=$(DESTDIR)/usr/local
BINDIR?=$(PREFIX)/bin
SHRDIR?=$(PREFIX)/share

install:
	install -D mkusb.sh $(BINDIR)/mkusb

uninstall:
	-rm -f $(BINDIR)/mkusb

.PHONY: install uninstall
