#!/bin/sh
# Two machines that have never met agree on who they are.
#
# doc/inferno-cloud-modern.ms item 7.  Inferno's authentication is
# mutual and certificate-based: each side holds an Authinfo signed by a
# common signer and verifies the other against the signer's public key
# that its own certificate carries.  Neither side has to have met the
# other and neither has to reach an authentication server while they
# talk, which matters on a provider where the instance that just booted
# may be the only one running.
#
# So the only problem is how each machine got its certificate, and the
# provider already solves that: metadata only that instance can read.
# Here the "provider" is an HTTP server holding the two certificates,
# and each side fetches its own with cloudauth(1) before doing anything.
#
# With a negative control, because "the mount worked" is also what it
# looks like when authentication is not happening at all: a third party
# holding a certificate from a DIFFERENT signer must be refused.
#
# usage: scripts/check-cloudauth.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

WORK=`mktemp -d`
trap 'st=$?; kill $HP $SP 2>/dev/null || true; sleep 1; rm -rf "$WORK" || true; rm -rf "$ROOT/tmp" 2>/dev/null || true; exit $st' 0
mkdir -p "$WORK/certs" "$WORK/signer" "$WORK/othersigner" \
	"$WORK/share" "$WORK/a" "$WORK/b" "$WORK/c" "$ROOT/tmp"
echo "THE-SHARED-FILE" >"$WORK/share/file"

# One signer, two certificates.  auth/createsignerkey writes a
# self-signed Authinfo; auth/mkauthinfo signs a new key with it.
cat >"$ROOT/tmp/gen.sh" <<EOF
bind -c '#U*$WORK/signer' /usr/inferno/keyring
auth/createsignerkey -b 512 -f /usr/inferno/keyring/default cloudsigner
bind -c '#U*$WORK/certs' /n/local
auth/mkauthinfo alice /n/local/alice
auth/mkauthinfo bob /n/local/bob
EOF
emu -r"$ROOT" /dis/sh.dis /tmp/gen.sh >"$WORK/gen.log" 2>&1

# A second signer, for the control.
cat >"$ROOT/tmp/gen2.sh" <<EOF
bind -c '#U*$WORK/othersigner' /usr/inferno/keyring
auth/createsignerkey -b 512 -f /usr/inferno/keyring/default othersigner
bind -c '#U*$WORK/certs' /n/local
auth/mkauthinfo mallory /n/local/mallory
EOF
emu -r"$ROOT" /dis/sh.dis /tmp/gen2.sh >"$WORK/gen2.log" 2>&1

for f in alice bob mallory; do
	[ -s "$WORK/certs/$f" ] || {
		echo "check-cloudauth: no certificate for $f" >&2
		tail -5 "$WORK/gen.log" "$WORK/gen2.log" >&2; exit 1; }
done

# The provider: an HTTP server holding the certificates.
MDPORT=`python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"`
(cd "$WORK/certs" && python3 -m http.server $MDPORT --bind 127.0.0.1 >/dev/null 2>&1) &
HP=$!
sleep 2

PORT=`python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"`

# Party A fetches its identity, then serves.
cat >"$ROOT/tmp/srv.sh" <<EOF
bind -c '#U*$WORK/a' /usr/inferno/keyring
bind -c '#U*$WORK/share' /n/local
cloudauth -u http://127.0.0.1:$MDPORT/alice
styxlisten 'tcp!*!$PORT' export /n/local
EOF
emu -r"$ROOT" /dis/sh.dis /tmp/srv.sh >"$WORK/srv.log" 2>&1 &
SP=$!
sleep 6

# Party B fetches its identity, then mounts.  No -A on either side.
cat >"$ROOT/tmp/cli.sh" <<EOF
bind -c '#U*$WORK/b' /usr/inferno/keyring
cloudauth -u http://127.0.0.1:$MDPORT/bob
mount tcp!127.0.0.1!$PORT /n/client
cat /n/client/file
EOF
emu -r"$ROOT" /dis/sh.dis /tmp/cli.sh >"$WORK/cli.log" 2>&1 || true

# Party C: same fetch, a certificate from the other signer.
cat >"$ROOT/tmp/bad.sh" <<EOF
bind -c '#U*$WORK/c' /usr/inferno/keyring
cloudauth -u http://127.0.0.1:$MDPORT/mallory
mount tcp!127.0.0.1!$PORT /n/client
cat /n/client/file
EOF
emu -r"$ROOT" /dis/sh.dis /tmp/bad.sh >"$WORK/bad.log" 2>&1 || true

ok=1
if ! grep -qx 'THE-SHARED-FILE' "$WORK/cli.log"; then
	echo "check-cloudauth: FAIL -- the authorised party could not read the file" >&2
	tail -5 "$WORK/cli.log" >&2
	ok=0
fi
if grep -qx 'THE-SHARED-FILE' "$WORK/bad.log"; then
	echo "check-cloudauth: FAIL -- a certificate from another signer was accepted;" >&2
	echo "  nothing here is evidence that authentication happened." >&2
	ok=0
fi
[ $ok = 1 ] || exit 1
echo "check-cloudauth: ok -- both sides took their identity from the provider"
echo "  and authenticated; a certificate from a different signer was refused:"
sed -n 's/^\(mount: authentication failed.*\)$/    \1/p' "$WORK/bad.log" | sed 1q
