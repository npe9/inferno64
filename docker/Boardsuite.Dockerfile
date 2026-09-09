# Boardsuite.Dockerfile - a Linux host for tools/boardsuite.
#
# What this is for: the board suite was written on macOS, and three of
# the things it depends on are the host's, not the board's -- hdiutil
# for the FAT image, the system qemu packages, and whatever else the
# machine happens to have installed.  A container fixes all three, and
# it exercises the paths the Mac never takes: mkfs.vfat and mcopy
# instead of hdiutil, and a qemu built by Debian rather than by hand.
#
# It carries no Inferno source and builds nothing from this tree.  The
# kernels are committed binaries and the tree is bind-mounted at run
# time, so this image does not go stale when a kernel is relinked, and
# mkconfig's absolute ROOT never has to agree with anything in here.
#
# Six of the eight configurations run in it.  The two Pi ones do not:
# they need the patched qemu of tools/qemu-patches, which is a source
# build, and nothing about the Pi boards is what this image is for.
#
# Build and run it with docker/boardsuite.sh.
FROM debian:bookworm-slim

# qemu-system-arm carries qemu-system-aarch64; qemu-system-misc carries
# the two riscv ones.  dosfstools and mtools are makefat()'s non-macOS
# path -- mkfs.vfat to make the filesystem, mcopy to plant the
# marker.txt that virtinit.b's fsmount() reads back.  python3 is the
# host end of the network checks: two echo servers, a web server, and
# the two clients that knock until the guest has announced.
RUN apt-get update && apt-get install -y --no-install-recommends \
	qemu-system-arm \
	qemu-system-misc \
	dosfstools \
	mtools \
	python3 \
	procps \
	&& rm -rf /var/lib/apt/lists/*

# mtools refuses a raw image with no partition table unless told the
# disk geometry is not its business.  makefat() writes a filesystem
# straight onto the file, exactly as hdiutil -layout NONE does.
ENV MTOOLS_SKIP_CHECK=1

# Its own work directory, so a run in here cannot collide with a run on
# the host: separate images, separate logs, and the host end's ports
# (54322, 54325, 8765 and the two hostfwds) are the container's own.
ENV BOARDSUITE_WORK=/work

# Everything in a container is TCG with no KVM underneath, and several
# of these checks time themselves against the guest's own clock.  They
# lose events under load and gain none, so the boot gets longer to
# report before the harness calls it dead.
ENV BOARDSUITE_TIMEOUT=480

WORKDIR /src
ENTRYPOINT ["/bin/sh"]
CMD ["tools/boardsuite/run", "virtarm64", "sifiveu", "virt", "virt32", "virt-peer"]
