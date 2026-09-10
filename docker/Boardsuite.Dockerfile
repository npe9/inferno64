# Boardsuite.Dockerfile - a Linux host for tools/boardsuite.
#
# What this is for: the board suite was written on macOS, and three of
# the things it depends on are the host's, not the board's -- hdiutil
# for the FAT image, the system qemu packages, and whatever else the
# machine happens to have installed.  A container fixes all three, and
# it exercises the paths the Mac never takes: mkfs.vfat and mcopy
# instead of hdiutil, and a qemu built by Debian rather than by hand.
#
# It carries no Inferno source.  The tree is bind-mounted read-only at
# run time, and there are two ways to get a kernel to boot.
#
# The quick one boots the kernel binaries that are in the tree.  Those
# should not be in the tree: .gitignore says "kernel binaries:
# os/inferno/<board>/i<board>" and means it, and the eleven that are
# tracked are tracked only because they were added before that rule
# arrived, after which git stopped applying it to them.  The two Pi
# kernels were never added, which is exactly why the quick path cannot
# run those boards.
#
# The other builds the tree -- mk, the libraries, the kenc compilers,
# limbo and the kernels -- from source in here, with docker/build-and-run,
# and needs nothing in the repository that the repository says should
# not be there.  It wants build-essential, which is why that is
# installed below, and it takes minutes rather than seconds.
#
# Nine of the fifteen configurations run in it.  The six Pi ones do
# not:
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
	build-essential \
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
CMD ["tools/boardsuite/run", "virtarm64", "virtarm64-peer", "sifiveu", "virt", "virts", "virt32", "virt32s", "virt-peer", "peer-mixed"]
