# Cross build (WSL): make CC=powerpc-linux-gnu-gcc
CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra
CFLAGS += -fPIC -D_FILE_OFFSET_BITS=64 -D_TIME_BITS=64

samba-splice.so: samba-splice.c samba-splice.map
	$(CC) $(CFLAGS) -shared -Wl,--version-script=samba-splice.map -o $@ $<

clean:
	rm -f samba-splice.so
