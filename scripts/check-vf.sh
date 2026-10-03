#!/bin/sh
# M7 of doc/genesize-plan.ms: two Linux guests talk through SR-IOV VFs
# at once.
#
# The native host (os/inferno/pc64/pc64vf, vftestinit.b) boots on the
# vmhost bench with *igbvfs=2 in plan9.ini: ether82563, as the 82576's
# PF, makes two VFs when the interface is attached, puts itself in the
# pool after theirs, switches between pools, and answers the VFs'
# mailbox.  Each VF is assigned to a Linux guest (linux-lts, whose
# igbvf drives it), the two boot at once, and each, given an address,
# pings the other through the 82576's switch.
#
# usage: scripts/check-vf.sh
# needs: os/inferno/pc64/ipc64vf, .guest/lts (mklinuxguest.sh)
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
KERN=$ROOT/os/inferno/pc64/ipc64vf
[ -f "$KERN" ] || { echo "check-vf: no $KERN; mk CONF=pc64vf first" >&2; exit 1; }
WORK=`mktemp -d`
trap 'st=$?; pkill -f "qemu-system-x86_6[4].*vmhost-vf" 2>/dev/null || true; rm -rf "$WORK" || true; exit $st' 0

export VMHOST_TAG=vf VMHOST_ISO=$ROOT/.qemu/vmhost-vf.iso
INFERNO_INI='*igbvfs=2' sh "$ROOT/scripts/vmhost.sh" build "$KERN" >"$WORK/build.out" 2>&1 \
|| { echo "check-vf: FAIL -- building the bench image"; tail -5 "$WORK/build.out"; exit 1; }
L=$ROOT/.qemu/vmhost-vf.log
rm -f "$L"	# the last run's would say done before this one starts
sh "$ROOT/scripts/vmhost.sh" run 1800 >/dev/null 2>&1 &
n=0
until grep -a -q 'VFTEST: done\|VFTEST: FAIL\|panic' "$L" 2>/dev/null; do
	sleep 5
	n=`expr $n + 1`
	[ $n -gt 350 ] && break
done
tr -d '\r' <"$L" >"$WORK/log"
grep -a 'VFTEST\|igbvf 0000\|LINUXGUEST: ping .*packets\|LINUXGUEST: ping 64' "$WORK/log" | sed 's/^/host: /'

ok=1
[ `grep -a -c 'igbvf 0000:00:01.0: Link is Up' "$WORK/log"` -ge 2 ] || { echo "check-vf: not both VFs' links came up"; ok=0; }
grep -a -q '^LINUXGUEST: ping 3 packets transmitted, 3 packets received' "$WORK/log" || { echo "check-vf: no complete ping"; ok=0; }
[ `grep -a -c '^LINUXGUEST: ping 3 packets transmitted, 3 packets received' "$WORK/log"` -ge 2 ] || { echo "check-vf: not both guests' pings answered"; ok=0; }
grep -a -q '^VFTEST: pf sriov: vfs 2 pf pool 2' "$WORK/log" || { echo "check-vf: the PF did not report two VFs"; ok=0; }
if [ $ok = 1 ]; then
	echo "check-vf: M7 pass -- two Linux guests on two VFs of the 82576 ping each other at once, the PF being Inferno's"
	exit 0
fi
echo "check-vf: M7 FAIL"
grep -a 'VFTEST\|LINUXGUEST\|igbvf\|vmlinux:' "$WORK/log" | tail -30 | sed 's/^/	/'
exit 1
