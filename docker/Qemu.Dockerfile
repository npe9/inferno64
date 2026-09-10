# Qemu.Dockerfile - the patched qemu the Pi boards need, built from
# source.
#
# tools/qemu-patches holds device models the Pi 3B and 4B need that
# stock qemu either does not have or models in a way that cannot
# exercise the guest driver.  They are patches against v10.1.3 and
# nothing packages them, so a container that wants to run the Pi
# configurations has to build one.
#
# Separate from Boardsuite.Dockerfile on purpose.  That image is apt
# only and builds in seconds; folding a qemu source build into it would
# make every run of the seven other configurations wait on a layer that
# goes stale whenever a patch changes.  The suite image copies the
# binary out of this one.
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
	git ca-certificates build-essential ninja-build pkg-config \
	python3 python3-venv python3-pip flex bison \
	libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev \
	&& rm -rf /var/lib/apt/lists/*

ARG QEMU_TAG=v10.1.3
RUN git clone --depth 1 --branch $QEMU_TAG \
	https://gitlab.com/qemu-project/qemu.git /qemu

COPY patches /patches

# One at a time, and stop on the first that does not apply.  git am
# over the whole series would leave a half-applied tree on a rejection,
# and a half-patched qemu boots and lies rather than failing.
RUN cd /qemu && \
	git config user.email boardsuite@invalid && \
	git config user.name boardsuite && \
	for p in /patches/*.patch; do \
		echo "applying `basename $p`"; \
		git am "$p" || { echo "REJECTED: `basename $p`" >&2; exit 1; }; \
	done && \
	echo "all `ls /patches/*.patch | wc -l` patches applied"

# Only the target the Pi boards need.  Everything else doubles the
# build for nothing.
#
# libslirp is not optional here even though the README's recipe does
# not name it: qemu 10 takes -netdev user from the system libslirp, and
# without the -dev package configure quietly builds a binary that
# answers "network backend 'user' is not compiled into this binary" the
# first time a board asks for a network.  It is easy to miss because
# the Pi boards that do not use a network boot perfectly on it.
RUN cd /qemu && mkdir build && cd build && \
	../configure --target-list=aarch64-softmmu --disable-docs \
		--disable-fuse --disable-jack >/dev/null && \
	ninja

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
	libglib2.0-0 libpixman-1-0 zlib1g libslirp0 \
	&& rm -rf /var/lib/apt/lists/*
COPY --from=build /qemu/build/qemu-system-aarch64 /usr/local/bin/qemu-system-aarch64
COPY --from=build /qemu/build/pc-bios /usr/local/share/qemu
ENV QEMU=/usr/local/bin/qemu-system-aarch64
CMD ["/usr/local/bin/qemu-system-aarch64", "--version"]
