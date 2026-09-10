# Boardsuite-pi.Dockerfile - the suite image with the patched qemu in
# it, for the Raspberry Pi configurations.
#
# Kept apart from Boardsuite.Dockerfile so that the seven configurations
# which need no patched qemu still build their image in seconds.  This
# one is that image plus the binary out of Qemu.Dockerfile's, which
# docker/boardsuite.sh builds first.
ARG SUITE_IMAGE=inferno-boardsuite
ARG QEMU_IMAGE=inferno-qemu
FROM ${QEMU_IMAGE} AS qemu
FROM ${SUITE_IMAGE}
COPY --from=qemu /usr/local/bin/qemu-system-aarch64 /usr/local/bin/qemu-system-aarch64
COPY --from=qemu /usr/local/bin/qemu-system-riscv64 /usr/local/bin/qemu-system-riscv64
COPY --from=qemu /usr/local/bin/qemu-system-riscv32 /usr/local/bin/qemu-system-riscv32
COPY --from=qemu /usr/local/share/qemu /usr/local/share/qemu
RUN apt-get update && apt-get install -y --no-install-recommends \
	libpixman-1-0 \
	&& rm -rf /var/lib/apt/lists/*
# The suite's built-in default is a path on the machine this tree was
# developed on, which will never exist in here.
ENV QEMU=/usr/local/bin/qemu-system-aarch64

# And virtarm64 keeps the packaged one, by name rather than by PATH.
# The patched binary is earlier in PATH and would answer for it, which
# would still pass -- but it would quietly cost the thing this image is
# for: virtarm64 passing on a stock qemu is what says the Pi patches
# are Pi patches, and a run where one binary answers for every board
# cannot say it.
ENV QEMU_AARCH64=/usr/bin/qemu-system-aarch64

# The riscv ones go the other way, and for a reason the aarch64 line
# does not have: bookworm packages qemu 7.2, whose sifive_u does not
# put a -drive if=sd behind its MMC-SPI controller (sifiveu reports
# SD-NONE) and whose firmware ships no riscv32 OpenSBI at all (virt32s
# cannot start).  These are v10.1.3 built out of the pristine clone,
# ahead of the Pi patch series, so they are stock in the sense that
# matters.
ENV QEMU_RISCV64=/usr/local/bin/qemu-system-riscv64
ENV QEMU_RISCV32=/usr/local/bin/qemu-system-riscv32
CMD ["docker/build-and-run"]
