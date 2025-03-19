CC = clang
CFLAGS = -Wall -Wextra -g -O2 -I..
OBJC_FLAGS = -framework Foundation -framework AppKit -framework ApplicationServices
OBJC_CFLAGS = -fobjc-arc

OBJS = mouse_receiver_new.o ../common/network_mac.o

all: mouse-receiver

mouse-receiver: $(OBJS)
	$(CC) -o $@ $^ $(OBJC_FLAGS)

mouse_receiver_new.o: mouse_receiver_new.m
	$(CC) $(CFLAGS) $(OBJC_CFLAGS) -c -o $@ $<

../common/network_mac.o: ../common/network_mac.c ../common/network.h ../common/protocol.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f mouse-receiver $(OBJS)

.PHONY: all clean 