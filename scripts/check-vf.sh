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
# CHECKVF_NIC=ixgbe does the same on the X520: the bench's NIC is the
# 82599 of scripts/qemu-patches/0007, *ixgbevfs=2 makes ether82598 its
# PF (named ether0 in plan9.ini, since ethervirtio would otherwise
# find the bench's virtio-net first), and the guests' ixgbevf drives
# the VFs.
#
# CHECKVF_NIC=ixgbe-pf gives the 82599 itself, whole, to one Linux
# guest instead (vftest=pf): the guest's ixgbe brings the link up
# through the assigned function, gets a DHCP lease from QEMU's user
# network and pings the gateway.
#
# usage: [CHECKVF_NIC=igb|ixgbe|ixgbe-pf] scripts/check-vf.sh
# needs: os/inferno/pc64/ipc64vf, .guest/lts (mklinuxguest.sh)
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT
KERN=$ROOT/os/inferno/pc64/ipc64vf
[ -f "$KERN" ] || { echo "check-vf: no $KERN; mk CONF=pc64vf first" >&2; exit 1; }
WORK=`mktemp -d`
trap 'st=$?; pkill -f "qemu-system-x86_6[4].*vmhost-$TAG[-.]" 2>/dev/null || true; rm -rf "$WORK" || true; exit $st' 0

NIC=${CHECKVF_NIC:-igb}
case $NIC in
igb)	INI='*igbvfs=2' PART=82576 VFDRV=igbvf LINKUP='igbvf 0000:00:01.0: Link is Up' TAG=vf ;;
ixgbe)	INI='*ixgbevfs=2
ether0=type=i82598' PART=82599 VFDRV=ixgbevf LINKUP='ixgbevf 0000:00:01.0: NIC Link is Up' TAG=x520vf ;;
ixgbe-pf)	INI='vftest=pf' PART=82599 VFDRV=ixgbe TAG=x520pf ;;
*)	echo "check-vf: CHECKVF_NIC is igb, ixgbe or ixgbe-pf" >&2; exit 2 ;;
esac
export VMHOST_TAG=$TAG VMHOST_ISO=$ROOT/.qemu/vmhost-$TAG.iso VMHOST_NIC1=${NIC%-pf}
INFERNO_INI=$INI sh "$ROOT/scripts/vmhost.sh" build "$KERN" >"$WORK/build.out" 2>&1 \
|| { echo "check-vf: FAIL -- building the bench image"; tail -5 "$WORK/build.out"; exit 1; }
L=$ROOT/.qemu/vmhost-$TAG.log
rm -f "$L"	# the last run's would say done before this one starts
sh "$ROOT/scripts/vmhost.sh" run 1800 >/dev/null 2>&1 &
n=0
until grep -a -q 'VFTEST: done\|VFTEST: FAIL\|panic' "$L" 2>/dev/null; do
	sleep 5
	n=`expr $n + 1`
	[ $n -gt 350 ] && break
done
tr -d '\r' <"$L" >"$WORK/log"
grep -a "VFTEST\\|$VFDRV 0000\\|LINUXGUEST: ping .*packets\\|LINUXGUEST: ping 64\\|LINUXGUEST: \\(link\\|dhcp\\|irq\\)" "$WORK/log" | sed 's/^/host: /'

if [ $NIC = ixgbe-pf ]; then
	ok=1
	grep -a -q 'ixgbe 0000:00:01.0 eth0: NIC Link is Up 10 Gbps' "$WORK/log" || { echo "check-vf: the guest's ixgbe saw no link"; ok=0; }
	grep -a -q '^LINUXGUEST: dhcp .*lease of' "$WORK/log" || { echo "check-vf: no DHCP lease"; ok=0; }
	grep -a -q '^LINUXGUEST: ping 3 packets transmitted, 3 packets received' "$WORK/log" || { echo "check-vf: the gateway did not answer"; ok=0; }
	if [ $ok = 1 ]; then
		echo "check-vf: pass -- the whole 82599 assigned to a Linux guest, whose ixgbe gets a lease and pings through it"
		exit 0
	fi
	echo "check-vf: whole PF FAIL"
	grep -a "VFTEST\\|LINUXGUEST\\|ixgbe\\|vmlinux:" "$WORK/log" | tail -30 | sed 's/^/	/'
	exit 1
fi

ok=1
[ `grep -a -c "$LINKUP" "$WORK/log"` -ge 2 ] || { echo "check-vf: not both VFs' links came up"; ok=0; }
grep -a -q '^LINUXGUEST: ping 3 packets transmitted, 3 packets received' "$WORK/log" || { echo "check-vf: no complete ping"; ok=0; }
[ `grep -a -c '^LINUXGUEST: ping 3 packets transmitted, 3 packets received' "$WORK/log"` -ge 2 ] || { echo "check-vf: not both guests' pings answered"; ok=0; }
grep -a -q '^VFTEST: pf sriov: vfs 2 pf pool 2' "$WORK/log" || { echo "check-vf: the PF did not report two VFs"; ok=0; }
if [ $ok = 1 ]; then
	echo "check-vf: M7 pass -- two Linux guests on two VFs of the $PART ping each other at once, the PF being Inferno's"
	exit 0
fi
echo "check-vf: M7 FAIL"
grep -a "VFTEST\\|LINUXGUEST\\|$VFDRV\\|vmlinux:" "$WORK/log" | tail -30 | sed 's/^/	/'
exit 1
