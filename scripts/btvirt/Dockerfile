#
# A Bluetooth controller this tree did not write.
#
# BlueZ's btvirt emulates a controller: btdev.c answers HCI the way
# its authors read the specification, which is the whole point of
# using it.  Every phase of scripts/btbench.sh otherwise talks to
# scripts/bthci.py, written from the same documents by the same
# reader, so a misreading agrees with itself and passes.
#
# btvirt -s listens on a Unix socket and speaks plain H4 -- a packet
# type byte and then the HCI packet -- which is exactly what btfs's
# tcp! transport already speaks to the model.  socat carries it to a
# TCP port so nothing in the guest has to change.  No kernel module,
# no /dev/vhci and no privilege: -s never touches the vhci driver.
#
FROM debian:bookworm-slim AS build
ARG BLUEZ=5.79
RUN apt-get update && apt-get install -y --no-install-recommends \
	build-essential autoconf automake libtool pkg-config \
	libglib2.0-dev libdbus-1-dev libudev-dev libical-dev \
	libreadline-dev flex bison wget xz-utils ca-certificates \
	&& rm -rf /var/lib/apt/lists/*
RUN wget -q https://mirrors.edge.kernel.org/pub/linux/bluetooth/bluez-${BLUEZ}.tar.xz \
	&& tar xf bluez-${BLUEZ}.tar.xz && mv bluez-${BLUEZ} /src
WORKDIR /src
#
# One patch, and it is declared rather than folded into the build:
# bthost's RFCOMM data frames put the header length into the length
# indicator, which TS 07.10 defines as the information field's length
# alone.  Wireshark calls the frames malformed and the stack under
# test refuses them.  Everything else in BlueZ's RFCOMM -- the
# multiplexer, parameter negotiation, the DLC state machine, modem
# status -- is left exactly as it is, because it is the point.
#
COPY bthost-rfcomm-length.patch /src/
RUN patch -p1 < bthost-rfcomm-length.patch
#
# And a passkey with bits in it.  bthost reads passkey_notify for the
# twenty rounds of Secure Connections passkey entry, but nothing sets
# it and bthost.h exposes no way to, so it is zero: every bit of the
# secret is zero, and a fixture whose secret is zero cannot tell a
# right implementation from one that ignores the secret.
#
# sed and not a patch, deliberately.  A context patch over these two
# lines applied one of them and silently left the other, so bthost
# sent its confirms with the real passkey and checked the other side's
# against zero -- which agrees in every round whose bit is 0 and fails
# at the first round whose bit is 1.  That cost a day and an entirely
# wrong conclusion about whose fault it was.  A global substitution
# cannot half-apply.
#
COPY bthost-passkey.sh /src/
RUN sh bthost-passkey.sh

#
# lib/bluetooth/*.h are symlinks the build makes on the way to its
# default targets.  Naming a target directly skips that rule, so they
# are made here instead.
#
RUN ./configure --disable-systemd --disable-udev --disable-manpages \
		--disable-mesh --disable-cups --disable-obex --enable-testing \
	&& mkdir -p lib/bluetooth \
	&& for h in lib/*.h; do ln -sf ../$(basename $h) lib/bluetooth/; done \
	&& make -j"$(nproc)" emulator/btvirt tools/btproxy

#
# And the peer.  bthost.c is BlueZ's own host stack, the one its test
# suite drives its implementation with; putting it on a second
# controller from the same btvirt gives the Inferno side something to
# talk to whose controller, link layer and host were all written by
# other people.  It is not built by any of BlueZ's own targets, so it
# is compiled here against the sources it needs.
#
COPY btpeer.c /src/btpeer.c
RUN gcc -I. -Ilib $(pkg-config --cflags glib-2.0) -O2 -o emulator/btpeer btpeer.c \
		emulator/bthost.c emulator/smp.c \
		src/shared/util.c src/shared/queue.c src/shared/crypto.c \
		src/shared/ecc.c src/shared/ad.c src/shared/io-mainloop.c \
		src/shared/mainloop.c src/shared/mainloop-notify.c \
		src/shared/timeout-mainloop.c \
		src/shared/att.c src/shared/gatt-db.c src/shared/gatt-server.c \
		lib/bluetooth.c lib/hci.c lib/uuid.c $(pkg-config --libs glib-2.0)

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
	socat procps libglib2.0-0 && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/emulator/btvirt /usr/local/bin/btvirt
COPY --from=build /src/tools/btproxy /usr/local/bin/btproxy
COPY --from=build /src/emulator/btpeer /usr/local/bin/btpeer
COPY serve.sh /usr/local/bin/serve.sh
ENV PEERARGS=""
EXPOSE 5555
ENTRYPOINT ["/usr/local/bin/serve.sh"]
