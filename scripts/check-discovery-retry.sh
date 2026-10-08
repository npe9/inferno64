#!/bin/sh
# Does a mounted namespace need the layers it claims to remove?
#
# doc/inferno-cloud-modern.ms lists three results that would sink the
# design.  The third: "if a namespace mounted across two machines turns
# out to need a supervisor, a retry policy and a naming service to be
# usable in practice, then the four layers have been reinvented rather
# than removed, and the honest conclusion is that they were load-bearing
# all along."
#
# Two of those three are tested here, because both are answerable and
# the answers are not the same.
#
# NAMING.  The client is told nothing but where a registry is.  It finds
# the file server by attribute -- "proto styx" -- and mounts whatever
# address comes back.  registry(4) is itself a file server: a service
# registers by writing a line to /mnt/registry/new and a client searches
# by writing a filter to find and reading the matches.  So discovery is
# not a fifth layer bolted on; it is the same mechanism pointed at the
# problem of locating things.  That is the design's own answer and this
# demonstrates it rather than asserting it.
#
# RETRY.  A mount does NOT survive its server.  Measured: with the
# server killed the read fails "mount rpc error", and when the server
# comes back on the same port the mount does not recover on its own.
# Something has to notice and mount again.  That is a retry policy, and
# the criterion is right that one is needed.
#
# What the criterion gets wrong is the weight.  The whole policy is
# "if the read fails, mount again and read again", because in this
# design re-establishing is the same operation as establishing -- there
# is no session to rebuild, no connection pool to drain, no client
# object to reconstruct.  It is four lines of shell and they are in this
# script.  A supervisor is not needed for the namespace at all; it is
# needed for services, which is true of every system, and supervise(1)
# is that.
#
# usage: scripts/check-discovery-retry.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PATH=$ROOT/MacOSX/arm64/bin:$PATH
export PATH ROOT

sh "$ROOT/scripts/mkemptydirs.sh" >/dev/null

WORK=`mktemp -d`
trap 'st=$?; kill $SP $SP2 2>/dev/null || true; sleep 1; rm -rf "$WORK" || true; rm -rf "$ROOT/tmp" 2>/dev/null || true; exit $st' 0
mkdir -p "$WORK/share" "$ROOT/tmp"
echo 'SERVED-CONTENT' >"$WORK/share/file"

port() {
	python3 -c "
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
}
REGPORT=`port`
SVCPORT=`port`

# The server: a registry, a service registered in it, and both exported.
cat >"$ROOT/tmp/dr-srv.sh" <<EOF
load std
bind -c '#U*$WORK/share' /n/local
mount {ndb/registry} /mnt/registry
echo 'fileserver persist 1 proto styx addr tcp!127.0.0.1!$SVCPORT' > /mnt/registry/new
styxlisten -A 'tcp!*!$REGPORT' export /mnt/registry &
styxlisten -A 'tcp!*!$SVCPORT' export /n/local
EOF

# The client knows the registry and nothing else.  get() is the entire
# retry policy.
cat >"$ROOT/tmp/dr-cli.sh" <<EOF
load std
mount -A tcp!127.0.0.1!$REGPORT /n/registry
found := ''
<> /n/registry/find {
	echo 'proto styx' > /fd/1
	found = \`{read}
}
(nil k addr rest) := \$found
echo DISCOVERED \$addr
fn get {
	if { ! cat /n/client/file >[2]/dev/null } {
		mount -A \$addr /n/client >[2]/dev/null
		cat /n/client/file >[2]/dev/null
	}
}
mount -A \$addr /n/client
echo READ1 \`{get}
sleep 12
echo READ2 \`{get}
sleep 16
echo READ3 \`{get}
echo DRDONE
EOF

emu -r"$ROOT" /dis/sh.dis /tmp/dr-srv.sh >"$WORK/s1.log" 2>&1 &
SP=$!
sleep 5
emu -r"$ROOT" /dis/sh.dis /tmp/dr-cli.sh >"$WORK/c.log" 2>&1 &
CP=$!
sleep 9
kill $SP 2>/dev/null || true		# the server dies mid-session
sleep 9
emu -r"$ROOT" /dis/sh.dis /tmp/dr-srv.sh >"$WORK/s2.log" 2>&1 &	# and comes back
SP2=$!
wait $CP 2>/dev/null || true
kill $SP2 2>/dev/null || true

ok=1
# Unanchored: see the note in scripts/check-arm64-smp.sh.  A marker whose
# absence means FAIL must not be anchored against a console log.
grep -q 'DISCOVERED tcp!' "$WORK/c.log" || {
	echo "check-discovery-retry: FAIL -- the client did not find the service" >&2; ok=0; }
grep -qx 'READ1 SERVED-CONTENT' "$WORK/c.log" || {
	echo "check-discovery-retry: FAIL -- could not read what it discovered" >&2; ok=0; }
# READ2 must be empty: with the server gone the read has to fail.  A
# pass here would mean the test never took the server away.
grep -qx 'READ2' "$WORK/c.log" || {
	echo "check-discovery-retry: FAIL -- the read succeeded while the server was down;" >&2
	echo "  nothing below is evidence that the retry did anything." >&2; ok=0; }
grep -qx 'READ3 SERVED-CONTENT' "$WORK/c.log" || {
	echo "check-discovery-retry: FAIL -- did not recover after the server returned" >&2; ok=0; }
[ $ok = 1 ] || { sed -n '/DISCOVERED/,$p' "$WORK/c.log" >&2; exit 1; }

echo "check-discovery-retry: ok"
echo "  naming: the client was told a registry and found the server by attribute"
echo "  retry:  the mount did not survive the server; four lines of shell restored it"
grep -E '^(DISCOVERED|READ[123])' "$WORK/c.log" | sed 's/^/    /'
