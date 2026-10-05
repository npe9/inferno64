#!/bin/sh
# Boot an Inferno pc64 kernel on Bochs: the processor bench for the
# hypervisor (doc/genesize-plan.ms, section 4).  QEMU's TCG has no VMX;
# Bochs, built by scripts/mkbochs-vmx.sh, emulates VMX with EPT and
# unrestricted guest, and SVM with nested paging.
#
# Bochs boots a legacy BIOS, not UEFI, so the kernel comes in through
# 9front's El Torito loader, os/inferno/boot/pc's 9bootiso, from a CD
# image: 9bootiso reads cfg/plan9.ini and loads the a.out kernel its
# bootfile= names, entering it in protected mode as a multiboot loader
# would.  It prints to the VGA screen and to COM1 only once plan9.ini
# names console=0.
#
# usage: scripts/bochs-vm.sh [-c cpu] kernel [seconds]
#
# BOCHS_INFO is the bochsrc info: setting (e.g. "action=ignore, cpu0=report").
# BOCHS_TAG runs another instance beside the first, with its own work
# directory and logs (.bochs/serial-TAG.log).  BOCHS_MEGS sets the
# machine's memory (512 MiB by default), BOCHS_CPUS
# its processors (1).  BOCHS_NICS=n gives it n (up to 4) e1000s
# (82540EM, etherigbe's), each on a user network of its own (Bochs's
# slirp: 10.0.2.x, DHCP from 10.0.2.2), so that #l1/ether1 is there for
# a guest's virtio-net to bridge to, as on the QEMU bench.
#
#	-c cpu	a Bochs CPU model; default corei7_skylake_x (VMX, EPT,
#		unrestricted guest).  ryzen gives SVM with nested paging.
#
# The serial console is written to .bochs/serial.log and printed at
# the end.  Bochs is slow: a minimal configuration boots in minutes.
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH

CPU=corei7_skylake_x
if [ "$1" = -c ]; then
	CPU=$2
	shift 2
fi
KERN=${1:?usage: bochs-vm.sh [-c cpu] kernel [seconds]}
SECS=${2:-300}
B=$ROOT/.bochs
BOCHS=$B/bin/bochs
[ -x "$BOCHS" ] || { echo "bochs-vm: no $BOCHS; run scripts/mkbochs-vmx.sh" >&2; exit 1; }

LOADER=$ROOT/os/inferno/boot/pc/9bootiso
if [ ! -f "$LOADER" ]; then
	(cd "$ROOT/os/inferno/boot/pc" && mk 9bootiso) >/dev/null
fi

T=${BOCHS_TAG:+-$BOCHS_TAG}
WORK=$B/work$T
rm -rf "$WORK"
mkdir -p "$WORK/iso/386" "$WORK/iso/amd64" "$WORK/iso/cfg"
cp "$LOADER" "$WORK/iso/386/9bootiso"
cp "$KERN" "$WORK/iso/amd64/ipc64"
# console=0 as for every other boot path here: pc64 links a VGA and a
# serial console and picks one silently without it.
cat >"$WORK/iso/cfg/plan9.ini" <<INI
bootfile=/amd64/ipc64
console=0
INI
[ -n "$INFERNO_INI" ] && printf '%s\n' "$INFERNO_INI" >>"$WORK/iso/cfg/plan9.ini"
# 9bootiso reads plan9.ini from the root of the CD (os/inferno/boot/pc/iso.c)
cp "$WORK/iso/cfg/plan9.ini" "$WORK/iso/plan9.ini"

# no-emulation El Torito, four 512-byte sectors loaded: the 2 KiB of
# 9bootiso that the BIOS reads, which then reads the rest itself.  It
# finds the rest, and then cfg/plan9.ini and the kernel, by walking
# the plain ISO 9660 directories for the names as written -- so they
# are stored untranslated and without ";1", as Plan 9's mk9660 does,
# not as 9BOOTISO.;1.
xorriso -as mkisofs -quiet -R -untranslated-filenames -omit-version-number \
	-o "$WORK/boot.iso" \
	-b 386/9bootiso -no-emul-boot -boot-load-size 4 \
	"$WORK/iso"

cat >"$WORK/bochsrc" <<RC
megs: ${BOCHS_MEGS:-512}
cpu: model=$CPU, count=${BOCHS_CPUS:-1}, ips=200000000
romimage: file=$B/share/bochs/BIOS-bochs-latest
vgaromimage: file=$B/share/bochs/VGABIOS-lgpl-latest.bin
ata0: enabled=1, ioaddr1=0x1f0, ioaddr2=0x3f0, irq=14
ata0-master: type=cdrom, path="$WORK/boot.iso", status=inserted
boot: cdrom
com1: enabled=1, mode=file, dev=$B/serial$T.log
display_library: nogui
log: $B/bochs$T.log
panic: action=fatal
error: action=report
info: ${BOCHS_INFO:-action=ignore}
debug: action=ignore
clock: sync=none, time0=local
RC
n=0
while [ $n -lt "${BOCHS_NICS:-0}" ]; do
	echo "e1000: card=$n, enabled=1, mac=52:54:00:12:34:5$n, ethmod=slirp" >>"$WORK/bochsrc"
	n=`expr $n + 1`
done

# Bochs is built with its debugger, which starts at its prompt; the
# command file tells it to run.  BOCHS_STOPAT=n stops it after n
# instructions instead and dumps the processor state to bochs.out,
# which is how a boot that stops making progress is located.
if [ -n "$BOCHS_RC" ]; then
	# a debugger script of one's own, e.g. 'sb N\nc\ntrace on\ns 20000\nr\nq'
	printf "$BOCHS_RC" >"$WORK/debugrc"
elif [ -n "$BOCHS_STOPAT" ]; then
	printf 'sb %s\nc\nr\nsreg\ncreg\nu /12\nbt\nprint-stack 24\ninfo idt\nq\n' "$BOCHS_STOPAT" >"$WORK/debugrc"
else
	echo c >"$WORK/debugrc"
fi
rm -f "$B/serial$T.log"
# BOCHS_CMDS=1: the debugger also reads $WORK/cmds as it grows, and
# -dbg makes SIGINT stop the machine into it rather than end Bochs:
#	kill -INT <bochs pid>; echo r >>.bochs/work/cmds
# An empty line repeats the last command, which may be "c".  Its output
# goes to .bochs/bochs.out through a pty (script(1)), so that it is
# line-buffered rather than held until a buffer fills.
if [ -n "$BOCHS_CMDS" ]; then
	: >"$WORK/cmds"
	tail -f "$WORK/cmds" | timeout "$SECS" script -q -F "$B/bochs$T.out" "$BOCHS" -q -dbg -f "$WORK/bochsrc" -rc "$WORK/debugrc" >/dev/null 2>&1 || true
else
	timeout "$SECS" "$BOCHS" -q -f "$WORK/bochsrc" -rc "$WORK/debugrc" >"$B/bochs$T.out" 2>&1 </dev/null || true
fi
sed -e 's/\x1b\[[0-9;=]*[a-zA-Z]//g' -e 's/\r$//' "$B/serial$T.log" 2>/dev/null || true
