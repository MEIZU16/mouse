CC = gcc
CFLAGS = -Wall -Wextra -g -O2 -I..
LDFLAGS = $(shell pkg-config --libs gtk+-3.0 wayland-client) -lm
CPPFLAGS = $(shell pkg-config --cflags gtk+-3.0 wayland-client)

OBJS = mouse_sender.o ../common/network.o

all: mouse-sender

mouse-sender: $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

mouse_sender.o: mouse_sender.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -c -o $@ $<

../common/network.o: ../common/network.c ../common/network.h ../common/protocol.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f mouse-sender $(OBJS)

.PHONY: all clean 