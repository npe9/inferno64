#!/bin/sh
# Build a Bochs that emulates VMX and SVM, for the hypervisor bench.
#
# QEMU's TCG does not implement VMX ("TCG doesn't support requested
# feature: CPUID[eax=01h].ECX.vmx"); it does implement SVM with nested
# paging.  Bochs implements both in software: --enable-vmx=2 gives VMX
# with EPT, unrestricted guest and VMCS shadowing, --enable-svm gives
# SVM with nested paging.  That lets the portable VM layer be run
# against both backends on one emulator on this (arm64) host.
#
# Bochs' platform is i440FX-class: no q35, no PCIe ECAM, no VT-d.  The
# PCIe/IOMMU/SR-IOV bench stays QEMU q35 (scripts/vmhost.sh).
#
# usage: scripts/mkbochs-vmx.sh        installs into $ROOT/.bochs
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
VER=${BOCHS_VERSION:-3.0}
DEST=$ROOT/.bochs
SRC=$DEST/src
mkdir -p "$SRC"
cd "$SRC"
if [ ! -d bochs-$VER ]; then
	curl -fL -o bochs-$VER.tar.gz \
		"https://downloads.sourceforge.net/project/bochs/bochs/$VER/bochs-$VER.tar.gz"
	tar xzf bochs-$VER.tar.gz
fi
cd bochs-$VER
# gui/keymap.cc calls basename() without <libgen.h>; glibc declares it
# in <string.h>, macOS does not, and clang makes that an error.
grep -q '<libgen.h>' gui/keymap.cc ||
	sed -i.orig 's/^#include "param_names.h"/#include "param_names.h"\
#include <libgen.h>/' gui/keymap.cc
# Bochs' slirp uses res_ninit and friends, which on macOS are in
# libresolv and not libc; its configure does not add it.
case `uname` in Darwin) LIBS="$LIBS -lresolv"; export LIBS;; esac
# --enable-usb: the i440FX's PIIX3 carries a UHCI controller and Bochs
# refuses to start ("Plugin 'usb_uhci' not found") without it.
./configure --prefix="$DEST" \
	--enable-x86-64 --enable-smp --enable-cpu-level=6 \
	--enable-vmx=2 --enable-svm \
	--enable-avx --enable-evex \
	--enable-pci --enable-pcidev=no --enable-e1000 --enable-usb --enable-usb-xhci \
	--enable-gdb-stub=no --enable-debugger \
	--with-nogui --with-term \
	--disable-docbook >"$DEST/configure.log" 2>&1
make -j`sysctl -n hw.ncpu 2>/dev/null || nproc` >"$DEST/make.log" 2>&1
make install >>"$DEST/make.log" 2>&1
"$DEST/bin/bochs" --help cpu 2>&1 | head -40
