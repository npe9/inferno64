#!/bin/sh
# M9 of doc/genesize-plan.ms: another Inferno controls the hypervisor
# entirely over Styx.
#
# The native kernel (os/inferno/pc64/pc64vmserve) boots on the vmhost
# bench and exports its namespace -- #H, #Q and #$ in /dev -- on
# tcp!*!5640, forwarded to a host port.  Hosted Inferno (emu, on this
# machine) mounts it and runs vmlinux(1) with the remote /dev/vm and
# /dev/pci bound into its own /dev: it makes a machine there, gives it
# memory, assigns it the bench's virtio-serial function, loads a Linux
# kernel and initramfs read from this machine's own files, starts it,
# types at its console and reads it back -- every step a file
# operation over the mount.  The guest is the one of
# scripts/mklinuxguest.sh, on the SVM backend (QEMU's TCG).
#
# usage: scripts/check-styxvm.sh
# needs: os/inferno/pc64/ipc64vmserve, .guest/ (mklinuxguest.sh), emu
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
KERN=$ROOT/os/inferno/pc64/ipc64vmserve
[ -f "$KERN" ] || { echo "check-styxvm: no $KERN; mk CONF=pc64vmserve first" >&2; exit 1; }
[ -f "$ROOT/.guest/vmlinuz-virt" ] || { echo "check-styxvm: no guest; run scripts/mklinuxguest.sh" >&2; exit 1; }
WORK=`mktemp -d`
# QEMU itself is killed by its forwarded port, which is this run's own;
# killing only vmhost.sh's shell left it running, holding the firmware
# variables file, and the next run's QEMU could not start.
trap 'st=$?; kill $QPID 2>/dev/null || true; pkill -f "hostfwd=tcp:127.0.0.1:$PORT-" 2>/dev/null || true; rm -rf "$WORK" || true; rm -f "$ROOT/tmp/styxvm-cli.sh" || true; exit $st' 0
PORT=`python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"`

sh "$ROOT/scripts/vmhost.sh" build "$KERN" >/dev/null 2>&1
VMHOST_FWD=$PORT sh "$ROOT/scripts/vmhost.sh" run 900 >"$WORK/host.log" 2>&1 &
QPID=$!
n=0
while ! grep -q 'VMSERVE: listening' "$ROOT/.qemu/vmhost.log" 2>/dev/null; do
	sleep 3
	n=`expr $n + 1`
	if [ $n -gt 100 ] || grep -q 'VMSERVE: FAIL' "$ROOT/.qemu/vmhost.log" 2>/dev/null; then
		echo "check-styxvm: FAIL -- the host never listened"
		grep 'VMSERVE' "$ROOT/.qemu/vmhost.log" | sed 's/^/	/'
		exit 1
	fi
done
grep 'VMSERVE' "$ROOT/.qemu/vmhost.log" | sed 's/^/host: /'

# emu's /tmp is this tree's tmp directory
mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/styxvm-cli.sh" <<EOF
load std
# retried: the listener comes up a little after it says so, and slirp
# refuses until it has
x=1
for i in 1 2 3 4 5 6 7 8 9 10 11 12 {
	if {~ \$x 1} {
		if {mount -A 'tcp!127.0.0.1!$PORT' /n/remote} {x=0} {sleep 5}
	}
}
echo STYXVM: mounted
# more connections, each its own flow, for the host's RSS to spread
# over its receive queues (an 82599 host's: the check after M9's)
for i in 1 2 3 4 5 6 7 8 {
	mount -A 'tcp!127.0.0.1!$PORT' /n/remote && ls /n/remote/dev >/dev/null
}
ls /n/remote/dev/vm /n/remote/dev/iommu
cat /n/remote/dev/vm/backend
bind -a /n/remote/dev /dev
vmlinux -s 1200 -m 256 -p 0000:05:00.0 -q 'LINUXGUEST: ran' -i /.guest/initramfs.cpio -t 'echo LINUXGUEST: typed over styx; uname -sr; echo hello-over-styx > /dev/hvc0; echo LINUXGUEST: "r"an' /.guest/vmlinuz-virt
echo STYXVM: done
EOF
timeout 1200 emu -r"$ROOT" /dis/sh.dis /tmp/styxvm-cli.sh >"$WORK/cli.log" 2>&1 || true
grep -a 'STYXVM\|vmlinux:\|LINUXGUEST\|^Linux 6\|backend\|^vcpu0\|^platform handled\|^pci 00' "$WORK/cli.log" | sed 's/^/emu: /' | head -40

if ! grep -q 'LINUXGUEST: typed over styx' "$WORK/cli.log" || ! grep -q '^LINUXGUEST: ran' "$WORK/cli.log" \
|| ! grep -q 'hello-over-styx' "$ROOT/.qemu/vmhost-hvc.log" 2>/dev/null; then
	echo "check-styxvm: M9 FAIL"
	tail -20 "$WORK/cli.log" | sed 's/^/	/'
	exit 1
fi
echo "check-styxvm: M9 pass -- a Linux guest made, assigned a device, run and talked to from hosted Inferno over Styx"

# A host interface with receive queues (the 82599, VMHOST_NIC1=ixgbe,
# RSS on with the bench's processors): the latest report of them must
# show the connections' packets on more than one.
grep -a 'VMSERVE: ether0 rxq' "$ROOT/.qemu/vmhost.log" >"$WORK/rxq" || exit 0
nq=`awk '{print $3}' "$WORK/rxq" | sort -u | wc -l | tr -d ' '`
tail -$nq "$WORK/rxq" | sed 's/^/host: /'
busy=`tail -$nq "$WORK/rxq" | awk '{for(i=1;i<NF;i++) if($i=="pkts" && $(i+1)>0) n++} END{print n+0}'`
if [ "$nq" -gt 1 ] && [ "$busy" -gt 1 ]; then
	echo "check-styxvm: rss pass -- $busy of the host's $nq receive queues took packets"
	exit 0
fi
echo "check-styxvm: rss FAIL -- $busy of $nq receive queues took packets"
exit 1
