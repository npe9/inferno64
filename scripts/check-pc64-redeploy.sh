#!/bin/sh
# Deployment with no image build: run code that was never in the image.
#
# doc/inferno-cloud-modern.ms item 14 offers two ways to update a
# machine -- republish the image and recreate the instance, or mount a
# new /dis and restart -- and says the second is the interesting one.
# This is the second, in its sharpest form: the program run here is not
# in the kernel, not in its compiled-in root, and never touches the
# machine's disk.  It is fetched over Styx from another machine at the
# moment it is run -- and then run again by supervise(1), which is the
# "and restart" half of the same item.
#
# The deployment side is a directory and styxlisten.  There is no
# package format, no image registry and no agent on the target: the
# target mounts a namespace and binds it into /dis, and the next
# command resolves there.  That is the claim being tested.
#
# usage: scripts/check-pc64-redeploy.sh
# needs: a built os/inferno/pc64/ipc64 and .qemu/edk2-*.fd
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

KERN=$ROOT/os/inferno/pc64/ipc64
[ -f "$KERN" ] || { echo "check-pc64-redeploy: no $KERN; mk CONF=pc64 first" >&2; exit 1; }

WORK=`mktemp -d`
trap 'st=$?; kill $SP 2>/dev/null || true; kill $QP 2>/dev/null || true; sleep 1; rm -rf "$WORK" || true; exit $st' 0
mkdir -p "$WORK/newdis"

# The program exists only here.  Its name is deliberately not one the
# kernel root carries, so that finding it proves the mount rather than
# the image.
cat >"$WORK/hello.b" <<'LIMBO'
implement Hello;
include "sys.m";
	sys: Sys;
include "draw.m";
Hello: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("HELLO-FROM-REMOTE-DIS\n");
}
LIMBO
(cd "$WORK" && limbo -I"$ROOT/module" -o "$WORK/newdis/hello.dis" hello.b)

if grep -q 'hello\.dis' "$ROOT/os/inferno/pc64/pc64"; then
	echo "check-pc64-redeploy: hello.dis is in the kernel root; the test" >&2
	echo "  would pass without proving anything." >&2
	exit 1
fi

PORT=`python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"`

# The deployment server: a directory, exported.  Running under emu on
# this host, which the guest reaches at 10.0.2.2 through QEMU's user
# networking.
mkdir -p "$ROOT/tmp"
cat >"$ROOT/tmp/redeploy-serve.sh" <<EOF
bind -c '#U*$WORK/newdis' /n/local
styxlisten -A 'tcp!*!$PORT' export /n/local
EOF
emu -r"$ROOT" /dis/sh.dis /tmp/redeploy-serve.sh >"$WORK/serve.log" 2>&1 &
SP=$!
sleep 6

INFERNO_KERNEL=$KERN sh "$ROOT/scripts/mkinferno-efi-iso.sh" "$WORK/r.iso" >/dev/null 2>&1
cp "$ROOT/.qemu/edk2-vars.fd" "$WORK/vars.fd"

# Waits for the shell's prompt, not for a fixed delay or for a line the
# kernel prints before the shell is reading; see check-pc64-memfloor.sh
# for what that mistake looks like.
INFERNO_CONSOLE_WAITFOR='
; ' INFERNO_CONSOLE_HOLD=45 \
timeout 320 python3 "$ROOT/scripts/type-at-console.py" "$WORK/p" 200 \
	"cloudinit; mount -A tcp!10.0.2.2!$PORT /n/remote; bind -a /n/remote /dis; hello; supervise -n 2 hello" \
	qemu-system-x86_64 -machine q35 -m 1024 -display none -no-reboot \
	-drive if=pflash,format=raw,unit=0,readonly=on,file="$ROOT/.qemu/edk2-code.fd" \
	-drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
	-cdrom "$WORK/r.iso" \
	-netdev user,id=net0 -device virtio-net,netdev=net0 \
	-chardev pipe,id=c0,path="$WORK/p" -serial chardev:c0 \
	>"$WORK/guest.log" 2>"$WORK/guest.err" || true
rm -f "$ROOT/tmp/redeploy-serve.sh"; rmdir "$ROOT/tmp" 2>/dev/null || true

# Three times: once run directly, twice more by supervise(1), which is
# item 14's other half -- "mount a new /dis and restart".  Requiring all
# three means the remote program runs both when invoked and when
# restarted by a supervisor that never saw it either.
#
# A substring match, not -x, and deliberately.  The usual hazard is that
# a console echoes the command, so a token that appears in the command
# is found whether or not anything ran -- but this token does not appear
# in the command, which says "hello".  Only the program prints it.  And
# -x cannot be used here: the kernel prints mount diagnostics without a
# trailing newline, so the program's output can share a line with them.
ran=`grep -c 'HELLO-FROM-REMOTE-DIS' "$WORK/guest.log"`
if [ "$ran" -ge 3 ]; then
	echo "check-pc64-redeploy: ok -- ran a program that is not in the image"
	echo "  $ran times: once directly, then restarted by supervise(1)"
	exit 0
fi
if [ "$ran" -ge 1 ]; then
	echo "check-pc64-redeploy: PARTIAL -- ran $ran of 3; the mount works" >&2
	echo "  but the supervised restarts did not all complete" >&2
	exit 1
fi
echo "check-pc64-redeploy: FAIL -- the remote program did not run" >&2
sed -n '/cloudinit/,$p' "$WORK/guest.log" | tail -20 >&2
exit 1
