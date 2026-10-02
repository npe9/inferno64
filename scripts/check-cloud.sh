#!/bin/sh
# M10 of doc/genesize-plan.ms: Inferno schedules virtual machines across
# several hypervisor hosts.
#
# Two native hosts (os/inferno/pc64/pc64vmserve) boot on the vmhost
# bench, one with 2 GiB and one with 1 GiB, each exporting its #H over
# Styx on a forwarded port.  Hosted Inferno (emu) mounts both and runs
# vmsched(1) (appl/cloud/vmsched.b) to place three 256 MiB Linux guests:
# it reads each host's dev/vm/host and spreads them -- fewest machines
# first, then the most contiguous memory -- so guests 0 and 2 go to the
# larger host and guest 1 to the smaller.  Every guest must boot and
# answer, from the host it was placed on, a line typed at its console.
# SVM backend, QEMU's TCG.
#
# usage: scripts/check-cloud.sh
# needs: os/inferno/pc64/ipc64vmserve, .guest/ (mklinuxguest.sh), emu
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
KERN=$ROOT/os/inferno/pc64/ipc64vmserve
[ -f "$KERN" ] || { echo "check-cloud: no $KERN; mk CONF=pc64vmserve first" >&2; exit 1; }
[ -f "$ROOT/.guest/vmlinuz-virt" ] || { echo "check-cloud: no guest; run scripts/mklinuxguest.sh" >&2; exit 1; }
WORK=`mktemp -d`
port() {
	python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
}
P0=`port`
P1=`port`
trap 'st=$?; pkill -f "hostfwd=tcp:127.0.0.1:$P0-" 2>/dev/null || true; pkill -f "hostfwd=tcp:127.0.0.1:$P1-" 2>/dev/null || true; rm -rf "$WORK" || true; rm -f "$ROOT/tmp/cloud-cli.sh" || true; exit $st' 0

sh "$ROOT/scripts/vmhost.sh" build "$KERN" >/dev/null 2>&1
# a previous run's logs would say "listening" before these hosts have
rm -f "$ROOT/.qemu/vmhost-h0.log" "$ROOT/.qemu/vmhost-h1.log"
VMHOST_TAG=h0 VMHOST_MEM=2048 VMHOST_SMP=2 VMHOST_FWD=$P0 sh "$ROOT/scripts/vmhost.sh" run 1500 >"$WORK/h0.out" 2>&1 &
VMHOST_TAG=h1 VMHOST_MEM=1024 VMHOST_SMP=2 VMHOST_FWD=$P1 sh "$ROOT/scripts/vmhost.sh" run 1500 >"$WORK/h1.out" 2>&1 &
for t in h0 h1; do
	n=0
	while ! grep -q 'VMSERVE: listening' "$ROOT/.qemu/vmhost-$t.log" 2>/dev/null; do
		sleep 3
		n=`expr $n + 1`
		if [ $n -gt 150 ] || grep -q 'VMSERVE: FAIL' "$ROOT/.qemu/vmhost-$t.log" 2>/dev/null; then
			echo "check-cloud: FAIL -- host $t never listened"
			grep 'VMSERVE' "$ROOT/.qemu/vmhost-$t.log" | sed 's/^/	/'
			tail -5 "$WORK/$t.out" | sed 's/^/	/'
			exit 1
		fi
	done
	echo "check-cloud: host $t listening"
done

mkdir -p "$ROOT/tmp"
cat >"$WORK/cli.sh" <<'EOF'
load std
mount {mntgen} /n
for h in h0!P0 h1!P1 {
	(name p) = ${split ! $h}
	x=1
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 {
		if {~ $x 1} {
			if {mount -A 'tcp!127.0.0.1!'^$p /n/$name} {x=0} {sleep 5}
		}
	}
}
echo CLOUD: mounted
ls /n/h0/dev/vm /n/h1/dev/vm
/dis/cloud/vmsched.dis -n 3 -m 256 -i /.guest/initramfs.cpio /.guest/vmlinuz-virt /n/h0 /n/h1
echo CLOUD: done
# mntgen would keep emu running
echo halt >/dev/sysctl
EOF
sed -e "s/P0/$P0/" -e "s/P1/$P1/" "$WORK/cli.sh" >"$ROOT/tmp/cloud-cli.sh"
timeout 1500 emu -r"$ROOT" /dis/sh.dis /tmp/cloud-cli.sh >"$WORK/cli.log" 2>&1 || true
grep -a 'CLOUD\|vmsched:\|LINUXGUEST: guest\|^Linux 6' "$WORK/cli.log" | sed 's/^/emu: /'

ok=1
for g in "0 placed on /n/h0" "1 placed on /n/h1" "2 placed on /n/h0"; do
	grep -q "^LINUXGUEST: guest $g" "$WORK/cli.log" || { echo "check-cloud: guest $g did not answer"; ok=0; }
done
[ `grep -c '^Linux 6' "$WORK/cli.log"` -ge 3 ] || { echo "check-cloud: not every guest ran uname"; ok=0; }
if [ $ok = 1 ]; then
	echo "check-cloud: M10 pass -- three guests placed across two hosts by Limbo, each answering from its host"
	exit 0
fi
echo "check-cloud: M10 FAIL"
tail -30 "$WORK/cli.log" | sed 's/^/	/'
exit 1
