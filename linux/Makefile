CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
PKG_CONFIG ?= pkg-config

LIBUSB_CFLAGS := $(shell $(PKG_CONFIG) --cflags libusb-1.0)
LIBUSB_LIBS := $(shell $(PKG_CONFIG) --libs libusb-1.0)

all: ezp2023

ezp2023: ezp2023.c
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) ezp2023.c -o ezp2023 $(LIBUSB_LIBS)

clean:
	rm -f ezp2023

install-rules:
	sudo cp 99-ezp2023.rules /etc/udev/rules.d/
	sudo udevadm control --reload-rules
	sudo udevadm trigger

.PHONY: all clean install-rules
