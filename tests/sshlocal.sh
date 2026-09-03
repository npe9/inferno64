#!/bin/sh
set -eu

# Hermetic end-to-end test for the Inferno ssh(2) client (sshtest(1)
# exec mode). Launches a throwaway OpenSSH sshd on a high port with a
# generated host key and a single authorized client key, then drives
# the Limbo client through it: connect with the host thumbprint pinned
# to ssh-keygen's own fingerprint, authenticate by publickey, exec a
# command, and check its output and exit status against known values.
# A second run with an UNAUTHORISED key must be rejected - the negative
# control that proves auth actually checks the key.
#
# Uses the host's sshd/ssh-keygen purely as a test oracle (the
# #C-as-oracle exception in CLAUDE.md); nothing here is part of the
# shipped client.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH

port=${SSH_TEST_PORT:-2222}

for tool in ssh-keygen; do
	command -v "$tool" >/dev/null 2>&1 || { echo "SSHLOCAL: $tool not found" >&2; exit 2; }
done
SSHD=/usr/sbin/sshd
test -x "$SSHD" || SSHD=$(command -v sshd || true)
test -n "$SSHD" && test -x "$SSHD" || { echo 'SSHLOCAL: sshd not found' >&2; exit 2; }
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'SSHLOCAL: emu-g not built' >&2; exit 2; }

tmp=$(mktemp -d)
# emu's / is the tree root, so the client key must live under $root to
# be visible inside emu; stage it in a temp subdir (never committed).
intree="$root/.sshtesttmp"
sshdpid=
cleanup() { test -n "$sshdpid" && kill "$sshdpid" 2>/dev/null || true; rm -rf "$tmp" "$intree"; }
trap cleanup EXIT
rm -rf "$intree"; mkdir -p "$intree"

# keys: client (PEM PKCS#1, what rsakey_pem parses), host, and an
# unauthorised key for the negative control
ssh-keygen -q -t rsa -b 2048 -m PEM -f "$tmp/id_rsa" -N "" -C test
ssh-keygen -q -t rsa -b 2048 -f "$tmp/hostkey" -N "" -C host
ssh-keygen -q -t rsa -b 2048 -m PEM -f "$tmp/id_bad" -N "" -C bad
cp "$tmp/id_rsa.pub" "$tmp/authorized_keys"
chmod 600 "$tmp/authorized_keys" "$tmp/id_rsa" "$tmp/id_bad" "$tmp/hostkey"
cp "$tmp/id_rsa" "$intree/id_rsa"
cp "$tmp/id_bad" "$intree/id_bad"

# host thumbprint oracle: ssh-keygen prints "<bits> SHA256:xxx comment"
raw=$(ssh-keygen -l -E sha256 -f "$tmp/hostkey.pub" | awk '{print $2}')
wantthumb="sha256=${raw#SHA256:}"
echo "SSHLOCAL: host thumbprint oracle $wantthumb"

"$SSHD" -D -e \
	-p "$port" \
	-h "$tmp/hostkey" \
	-o "AuthorizedKeysFile=$tmp/authorized_keys" \
	-o StrictModes=no \
	-o UsePAM=no \
	-o PasswordAuthentication=no \
	-o KbdInteractiveAuthentication=no \
	-o PidFile=none \
	-o "HostKeyAlgorithms=+ssh-rsa" \
	-o "PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-256" \
	>"$tmp/sshd.log" 2>&1 &
sshdpid=$!

# wait for the port to accept
i=0
while [ "$i" -lt 40 ]; do
	if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$port" 2>/dev/null; then break; fi
	kill -0 "$sshdpid" 2>/dev/null || { echo 'SSHLOCAL: sshd exited early'; cat "$tmp/sshd.log"; exit 1; }
	i=$((i+1)); sleep 0.25
done
echo "SSHLOCAL: sshd up (pid $sshdpid) on port $port"

user=$(id -un)
cd "$root"
rc=0
marker="all tests passed"

echo 'SSHLOCAL: === positive: authorised key ==='
pout=$(./MacOSX/arm64/bin/emu-g -r. sshtest exec "tcp!127.0.0.1!$port" "$user" "/.sshtesttmp/id_rsa" "$wantthumb" "printf hello" "hello" 2>&1) || true
echo "$pout"
echo "$pout" | grep -q "$marker" || { echo 'SSHLOCAL: POSITIVE TEST FAILED'; rc=1; }

echo 'SSHLOCAL: === negative control: unauthorised key must be REJECTED ==='
nout=$(./MacOSX/arm64/bin/emu-g -r. sshtest exec "tcp!127.0.0.1!$port" "$user" "/.sshtesttmp/id_bad" "$wantthumb" "printf hello" "hello" 2>&1) || true
echo "$nout"
if echo "$nout" | grep -q "$marker"; then
	echo 'SSHLOCAL: NEGATIVE CONTROL FAILED: unauthorised key accepted!'; rc=1
else
	echo 'SSHLOCAL: unauthorised key rejected, as expected: PASS'
fi

echo 'SSHLOCAL: === ssh(1) command: run a remote command ==='
# -p is the port; the host thumbprint is pinned with -t. The client
# separates stdout and stderr internally (proven by the exec test's
# clean res.stdout comparison above), but emu-g ties the Dis fd 2 to
# the host process's stdout, so a host-side 2>/dev/null cannot drop the
# remote login shell's rc-file chatter here - assert the command output
# is PRESENT rather than exclusive.
cout=$(./MacOSX/arm64/bin/emu-g -r. ssh -i /.sshtesttmp/id_rsa -p "$port" -t "$wantthumb" "$user@127.0.0.1" "printf" "cmd-ok" 2>&1) || true
if echo "$cout" | grep -q "cmd-ok"; then
	echo 'SSHLOCAL: ssh(1) command run: PASS'
else
	echo "SSHLOCAL: ssh(1) command run FAILED: [$cout]"; rc=1
fi

echo 'SSHLOCAL: === ssh(1) interactive shell: piped script ==='
# No command -> ssh(1) requests a shell and pumps stdin<->channel (the
# Plan 9 telnet/vt model). $TERM is unset in emu, so no pty is asked
# for and the remote runs a non-interactive shell reading our script.
# It must run both commands and then exit on our EOF.
sout=$(printf 'echo line-one\necho line-two\nexit\n' | ./MacOSX/arm64/bin/emu-g -r. ssh -i /.sshtesttmp/id_rsa -p "$port" -t "$wantthumb" "$user@127.0.0.1" 2>/dev/null) || true
if echo "$sout" | grep -q "line-one" && echo "$sout" | grep -q "line-two"; then
	echo 'SSHLOCAL: ssh(1) interactive shell: PASS'
else
	echo "SSHLOCAL: ssh(1) interactive shell FAILED: [$sout]"; rc=1
fi

if [ "$rc" -eq 0 ]; then echo 'SSHLOCAL: ALL PASS'; else echo 'SSHLOCAL: FAILURE'; cat "$tmp/sshd.log"; fi
exit $rc
