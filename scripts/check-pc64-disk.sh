#!/bin/sh
# Write a file to a disk, reboot, and read it back.
#
# Nothing in this tree had ever written a block to a disk under test.
# os/inferno/init/pc64devinit.b reads 512 bytes from each unit it finds
# and stops there, and no script formatted or wrote anything on any
# board -- so "the write path works" rested on sdvirtio10.c having a
# vioblkreq(vd, write != 0, ...) in it, which is a claim about source
# and not about a running kernel.  This is the claim about a running
# kernel, and it is the prerequisite for putting any state on a cloud
# disk.
#
# Two boots over one disk image.  The first reams a kfs onto a raw
# virtio-blk disk, creates a file and syncs; the second is a cold boot
# of the same image that mounts the same disk and reads the file back.
# The nonce differs per run, so a pass cannot come from a stale image.
#
# usage: scripts/check-pc64-disk.sh        (FS=disk/kfs64 for the other one)
# needs: a built os/inferno/pc64/ipc64 and .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/pc64/ipc64
[ -f "$KERN" ] || { echo "check-pc64-disk: no $KERN; mk CONF=pc64 first" >&2; exit 1; }

WORK=`mktemp -d`
# status latched and restored; every cleanup command made to
# succeed, because "set -e" would otherwise abort the trap and
# lose it.  See the fuller note in check-pc64-tcp.sh.
trap 'st=$?; rm -rf "$WORK" || true; exit $st' 0
NONCE=DISKPROOF-$$-`date +%s`

INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/d.iso" >/dev/null 2>&1
qemu-img create -f raw "$WORK/disk.img" 64M >/dev/null

run() {	# run WAIT COMMAND
	cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars.fd"
	timeout 240 python3 "$ROOT/scripts/type-at-console.py" "$WORK/p$3" "$1" "$2" \
		qemu-system-x86_64 -machine q35 -m 1024 -display none -smp 2 \
		-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
		-drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
		-cdrom "$WORK/d.iso" \
		-drive if=none,id=dk,format=raw,file="$WORK/disk.img" \
		-device virtio-blk-pci,drive=dk \
		-chardev pipe,id=c0,path="$WORK/p$3" -serial chardev:c0 2>/dev/null
}

# Both file servers, because they failed differently.  disk/kfs works;
# disk/kfs64 used to die with "illegal dis instruction" the moment it
# reached a byte/big cast, which was a Limbo compiler bug rather than
# anything about kfs (see limbo/ecom.c's precastinit).  A regression in
# that fix would show up here first.
FS=${FS:-disk/kfs}

# -c on the mount: without it kfs refuses the create with "mounted
# directory forbids creation".  The explicit sync matters too --
# unmount alone does not flush, and the first version of this test
# wrote a file, saw it in the session, and left the disk image
# untouched.
run 55 "mount -c {$FS -r -n main /dev/sdF0/data} /n; echo $NONCE > /n/proof; cat /n/proof; disk/kfscmd -n main sync; echo PHASE1-DONE" 1 > "$WORK/one.log"
if ! grep -q PHASE1-DONE "$WORK/one.log"; then
	echo "check-pc64-disk: FAIL -- first boot did not finish" >&2
	tail -20 "$WORK/one.log" >&2
	exit 1
fi
if ! strings "$WORK/disk.img" | grep -q "$NONCE"; then
	echo "check-pc64-disk: FAIL -- nothing reached the disk image on the host" >&2
	exit 1
fi

run 55 "mount {$FS -n main /dev/sdF0/data} /n; echo READBACK-FOLLOWS; cat /n/proof" 2 > "$WORK/two.log"
if grep -q "$NONCE" "$WORK/two.log"; then
	echo "check-pc64-disk: ok ($FS) -- $NONCE written, rebooted, read back"
	exit 0
fi
echo "check-pc64-disk: FAIL -- the file did not survive the reboot" >&2
sed -n '/READBACK-FOLLOWS/,$p' "$WORK/two.log" >&2
exit 1
