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

# Each boot gets a generous window after the command is typed.
# type-at-console.py defaults to 14 seconds, which is right for a
# command that prints and exits and wrong for this one: kfs's ream
# of a 64M file system runs well over a minute on a loaded machine,
# and the guest was being killed in the middle of it -- which this
# script then reported as "nothing reached the disk image", a
# harness timeout dressed up as a broken write path.
INFERNO_CONSOLE_HOLD=${INFERNO_CONSOLE_HOLD:-150}
export INFERNO_CONSOLE_HOLD

run() {	# run WAIT COMMAND
	cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars.fd"
	timeout 420 python3 "$ROOT/scripts/type-at-console.py" "$WORK/p$3" "$1" "$2" \
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
# -x, an exact line.  The console echoes the command it is given, and
# that command ends with "echo PHASE1-DONE", so a substring match finds
# the token whether or not the shell ever ran it.  Only execution
# produces a line that is the token alone.  The check below -- the
# nonce found in the host's copy of the disk image -- is what actually
# proves the write path, and it is independent of anything the console
# said; this gate only has to fail honestly when the boot did not get
# that far.
if ! grep -qx PHASE1-DONE "$WORK/one.log"; then
	echo "check-pc64-disk: FAIL -- first boot did not finish" >&2
	tail -20 "$WORK/one.log" >&2
	exit 1
fi
if ! strings "$WORK/disk.img" | grep -q "$NONCE"; then
	echo "check-pc64-disk: FAIL -- nothing reached the disk image on the host" >&2
	exit 1
fi

run 55 "mount {$FS -n main /dev/sdF0/data} /n; echo READBACK-FOLLOWS; cat /n/proof" 2 > "$WORK/two.log"
# Sound either way -- the second boot's command does not contain the
# nonce, so finding it means it came off the disk -- but exact, to match
# the rest of this file.
if grep -qx "$NONCE" "$WORK/two.log"; then
	echo "check-pc64-disk: ok ($FS) -- $NONCE written, rebooted, read back"
	exit 0
fi
echo "check-pc64-disk: FAIL -- the file did not survive the reboot" >&2
sed -n '/READBACK-FOLLOWS/,$p' "$WORK/two.log" >&2
exit 1
