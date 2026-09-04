#!/bin/sh
set -eu

# Hermetic end-to-end test for the Inferno ssh(2) client (sshtest(1)
# exec mode). Launches a throwaway OpenSSH sshd on a high port with a
# generated host key and a single authorized client key, then drives
# the Limbo client through it: connect with the host thumbprint pinned
# to ssh-keygen's own fingerprint, authenticate by publickey, exec a
# command, and check its output and exit status against known values.
# A second run with an UNAUTHORISED key must be rejected - the negative
# control that proves auth actually checks the key. Later stages exercise
# ecdsa/ed25519 host keys, the ssh(1) command and interactive shell,
# factotum(4) publickey auth (key never leaves the agent), and finally
# factotum -S fetching that key from a secstored(8) over the network.
#
# Uses the host's sshd/ssh-keygen purely as a test oracle (the
# #C-as-oracle exception in CLAUDE.md); nothing here is part of the
# shipped client.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH

# emu binary: defaults to the macOS build; the Docker/Linux run overrides
# it via $EMU (e.g. Linux/amd64/bin/emu). All invocations go through $emu.
emu=${EMU:-"$root/MacOSX/arm64/bin/emu-g"}

port=${SSH_TEST_PORT:-2222}

for tool in ssh-keygen; do
	command -v "$tool" >/dev/null 2>&1 || { echo "SSHLOCAL: $tool not found" >&2; exit 2; }
done
SSHD=/usr/sbin/sshd
test -x "$SSHD" || SSHD=$(command -v sshd || true)
test -n "$SSHD" && test -x "$SSHD" || { echo 'SSHLOCAL: sshd not found' >&2; exit 2; }
test -x "$emu" || { echo "SSHLOCAL: emu not built at $emu" >&2; exit 2; }

tmp=$(mktemp -d)
# emu's / is the tree root, so the client key must live under $root to
# be visible inside emu; stage it in a temp subdir (never committed).
intree="$root/.sshtesttmp"
sshdpid=
esshdpid=
edpid=
eport=$((port+1))
edport=$((port+2))
ssport=$((port+3))
cleanup() {
	test -n "$sshdpid" && kill "$sshdpid" 2>/dev/null || true
	test -n "$esshdpid" && kill "$esshdpid" 2>/dev/null || true
	test -n "$edpid" && kill "$edpid" 2>/dev/null || true
	rm -rf "$tmp" "$intree"
}
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

# factotum key: generated inside emu with auth/rsagen (the Plan 9 key
# format factotum loads), its ssh public key produced by auth/rsa2ssh.
# Tag it service=ssh so ssh(1)'s factotum keyspec matches it, and add
# its public key to authorized_keys so the same server accepts it.
cat > "$intree/gen.sh" <<'GEN'
auth/rsagen -b 2048 > /.sshtesttmp/keyline
auth/rsa2ssh /.sshtesttmp/keyline > /.sshtesttmp/facpub
GEN
"$emu" -r. sh /.sshtesttmp/gen.sh >/dev/null 2>&1
sed -i.bak 's/^key proto=rsa/key proto=rsa service=ssh/' "$intree/keyline" && rm -f "$intree/keyline.bak"
cat "$intree/facpub" >> "$tmp/authorized_keys"

# an ECDSA-only host key for the ecdsa-sha2-nistp256 host-key test
ssh-keygen -q -t ecdsa -b 256 -f "$tmp/hostkey_ecdsa" -N "" -C ecdsahost
chmod 600 "$tmp/hostkey_ecdsa"
eraw=$(ssh-keygen -l -E sha256 -f "$tmp/hostkey_ecdsa.pub" | awk '{print $2}')
ewantthumb="sha256=${eraw#SHA256:}"

# an ed25519-only host key for the ssh-ed25519 host-key test
ssh-keygen -q -t ed25519 -f "$tmp/hostkey_ed" -N "" -C edhost
chmod 600 "$tmp/hostkey_ed"
edraw=$(ssh-keygen -l -E sha256 -f "$tmp/hostkey_ed.pub" | awk '{print $2}')
edwantthumb="sha256=${edraw#SHA256:}"

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

# second sshd with ONLY an ECDSA host key, to exercise
# ecdsa-sha2-nistp256 host-key verification (the client offers
# rsa-sha2-256,ecdsa-sha2-nistp256 and must fall to ecdsa here)
"$SSHD" -D -e \
	-p "$eport" \
	-h "$tmp/hostkey_ecdsa" \
	-o "AuthorizedKeysFile=$tmp/authorized_keys" \
	-o StrictModes=no -o UsePAM=no -o PasswordAuthentication=no \
	-o KbdInteractiveAuthentication=no -o PidFile=none \
	-o HostKeyAlgorithms=ecdsa-sha2-nistp256 \
	-o "PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-256" \
	>"$tmp/sshd_ecdsa.log" 2>&1 &
esshdpid=$!

# third sshd with ONLY an ed25519 host key, for ssh-ed25519 verification
"$SSHD" -D -e \
	-p "$edport" \
	-h "$tmp/hostkey_ed" \
	-o "AuthorizedKeysFile=$tmp/authorized_keys" \
	-o StrictModes=no -o UsePAM=no -o PasswordAuthentication=no \
	-o KbdInteractiveAuthentication=no -o PidFile=none \
	-o HostKeyAlgorithms=ssh-ed25519 \
	-o "PubkeyAcceptedAlgorithms=+ssh-rsa,rsa-sha2-256" \
	>"$tmp/sshd_ed.log" 2>&1 &
edpid=$!

i=0
while [ "$i" -lt 40 ]; do
	if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$edport" 2>/dev/null; then break; fi
	i=$((i+1)); sleep 0.25
done

user=$(id -un)
cd "$root"
rc=0
marker="all tests passed"

echo 'SSHLOCAL: === positive: authorised key ==='
pout=$("$emu" -r. sshtest exec "tcp!127.0.0.1!$port" "$user" "/.sshtesttmp/id_rsa" "$wantthumb" "printf hello" "hello" 2>&1) || true
echo "$pout"
echo "$pout" | grep -q "$marker" || { echo 'SSHLOCAL: POSITIVE TEST FAILED'; rc=1; }

echo 'SSHLOCAL: === ECDSA host key: verify ecdsa-sha2-nistp256 ==='
# the ecdsa-only server forces the client onto ecdsa host-key
# verification; connect() succeeds only if that signature checks out,
# with the thumbprint pinned to ssh-keygen's oracle for the ecdsa key
eout=$("$emu" -r. sshtest exec "tcp!127.0.0.1!$eport" "$user" "/.sshtesttmp/id_rsa" "$ewantthumb" "printf hi" "hi" 2>&1) || true
echo "$eout" | grep -q "$marker" && echo 'SSHLOCAL: ecdsa host-key verification: PASS' || { echo "SSHLOCAL: ecdsa host-key verification FAILED: [$eout]"; rc=1; }

echo 'SSHLOCAL: === ed25519 host key: verify ssh-ed25519 ==='
edout=$("$emu" -r. sshtest exec "tcp!127.0.0.1!$edport" "$user" "/.sshtesttmp/id_rsa" "$edwantthumb" "printf hi" "hi" 2>&1) || true
echo "$edout" | grep -q "$marker" && echo 'SSHLOCAL: ed25519 host-key verification: PASS' || { echo "SSHLOCAL: ed25519 host-key verification FAILED: [$edout]"; rc=1; }

echo 'SSHLOCAL: === negative control: unauthorised key must be REJECTED ==='
nout=$("$emu" -r. sshtest exec "tcp!127.0.0.1!$port" "$user" "/.sshtesttmp/id_bad" "$wantthumb" "printf hello" "hello" 2>&1) || true
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
cout=$("$emu" -r. ssh -i /.sshtesttmp/id_rsa -p "$port" -t "$wantthumb" "$user@127.0.0.1" "printf" "cmd-ok" 2>&1) || true
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
sout=$(printf 'echo line-one\necho line-two\nexit\n' | "$emu" -r. ssh -i /.sshtesttmp/id_rsa -p "$port" -t "$wantthumb" "$user@127.0.0.1" 2>/dev/null) || true
if echo "$sout" | grep -q "line-one" && echo "$sout" | grep -q "line-two"; then
	echo 'SSHLOCAL: ssh(1) interactive shell: PASS'
else
	echo "SSHLOCAL: ssh(1) interactive shell FAILED: [$sout]"; rc=1
fi

echo 'SSHLOCAL: === factotum(4) auth: the private key never leaves the agent ==='
# The Plan 9 model: no -i, so ssh(1) uses factotum. Start factotum
# inside emu, load the rsagen key, and let it sign. The thumbprint must
# be single-quoted for Inferno sh (a bare sha256=... reads as an
# assignment). sshd must log "Accepted publickey" for this key.
cat > "$intree/facssh.sh" <<FAC
auth/factotum
cp /.sshtesttmp/keyline /mnt/factotum/ctl
ssh -p $port -t '$wantthumb' $user@127.0.0.1 printf fac-ok
quitall
FAC
# factotum is a daemon, so quitall(1) ends the emu session once ssh has
# returned; a timeout backstops it in case that ever fails to fire.
fout=$(timeout 60 "$emu" -r. sh /.sshtesttmp/facssh.sh 2>/dev/null) || true
if echo "$fout" | grep -q "fac-ok"; then
	echo 'SSHLOCAL: factotum publickey auth: PASS'
else
	echo "SSHLOCAL: factotum publickey auth FAILED: [$fout]"; rc=1
fi

echo 'SSHLOCAL: === factotum -S from secstore: key fetched over the network ==='
# The full chain: the same rsagen key, stored in a secstored(8) we stand
# up on the loopback, is fetched by factotum -S over a PAK-authenticated
# secstore(2) channel, loaded into factotum, and used to authenticate to
# the real sshd - so this exercises the secstore network round-trip end to
# end against a genuine OpenSSH server. auth/secstore -i takes the store
# password from fd0 (< pwline); the account-create and factotum -S prompts
# read /dev/cons, which is emu's own stdin, so three password lines are
# piped there. secstored and factotum are daemons, so quitall(1) ends the
# session once ssh has returned.
sspw=secretpw
cat > "$intree/secssh.sh" <<SEC
bind -a '#I' /net
rm -rf /tmp/ss; mkdir /tmp/ss
auth/secstored -d /tmp/ss -c alice
auth/secstored -d /tmp/ss -a 'tcp!*!$ssport' &
sleep 2
echo $sspw > /tmp/pwline
rm -rf /tmp/w; mkdir /tmp/w; cd /tmp/w
cp /.sshtesttmp/keyline factotum
auth/secstore -i -s 'tcp!127.0.0.1!$ssport' -u alice r factotum < /tmp/pwline
mkdir /mnt/factotum
auth/factotum -S 'alice@tcp!127.0.0.1!$ssport'
ssh -p $port -t '$wantthumb' $user@127.0.0.1 printf secstore-fac-ok
quitall
SEC
secout=$(printf '%s\n%s\n%s\n' "$sspw" "$sspw" "$sspw" | timeout 90 "$emu" -r. sh /.sshtesttmp/secssh.sh 2>/dev/null) || true
if echo "$secout" | grep -q "secstore-fac-ok"; then
	echo 'SSHLOCAL: factotum -S secstore-seeded publickey auth: PASS'
else
	echo "SSHLOCAL: factotum -S secstore auth FAILED: [$secout]"; rc=1
fi

if [ "$rc" -eq 0 ]; then echo 'SSHLOCAL: ALL PASS'; else echo 'SSHLOCAL: FAILURE'; cat "$tmp/sshd.log"; fi
exit $rc
