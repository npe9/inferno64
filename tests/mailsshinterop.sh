#!/bin/sh
set -eu

# Interoperability test: the Inferno clients (ssh(1), upas/send over smtp2(2),
# upas/fetch over imap4(2)) driven from the host against a SEPARATE Linux host
# - a Docker container (tests/docker) running real OpenSSH sshd, real Postfix
# (SMTPS) and real Dovecot (IMAPS). The point is to prove Inferno speaks the
# actual protocols to mainstream server software, not to a stub.
#
# The headline check is a full mail round trip through the real servers: a
# message COMPOSED and SENT by Inferno's SMTP client is delivered by Postfix,
# stored by Dovecot, and then FETCHED back by Inferno's IMAP client - so both
# ends of the mail path are Inferno talking to independent implementations.
# Plus: ssh publickey login + remote command, and wrong-credential negative
# controls on ssh and on mail.
#
# Uses Docker + OpenSSH/Postfix/Dovecot purely as the interop oracle. The host
# runs the shipped Inferno client unchanged; nothing here is part of it.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
emu=${EMU:-"$root/MacOSX/arm64/bin/emu-g"}

IMG=inferno-interop-host
NAME=inferno-interop-$$
HOSTN=mail.test.local
USER=tester@$HOSTN
PASS=s3cret
SSHPORT=${INTEROP_SSH_PORT:-2222}
IMAPPORT=${INTEROP_IMAP_PORT:-9993}
SMTPPORT=${INTEROP_SMTP_PORT:-9465}
bundle="$root/lib/tls/ca-bundle.pem"

for t in docker openssl ssh-keygen; do
	command -v "$t" >/dev/null 2>&1 || { echo "INTEROP: $t not found" >&2; exit 2; }
done
test -x "$emu" || { echo "INTEROP: emu not built at $emu" >&2; exit 2; }
for d in ssh upas/send upas/fetch; do
	test -f "$root/dis/$d.dis" || { echo "INTEROP: dis/$d.dis not built" >&2; exit 2; }
done
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "INTEROP: image $IMG missing; run: docker build -t $IMG tests/docker" >&2; exit 2; }

work="$root/.mailsshtmp"
shared="$work/shared"
cid=
cleanup() {
	[ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1 || true
	[ -f "$work/bundle.bak" ] && cp "$work/bundle.bak" "$bundle" || true
	rm -rf "$work"
}
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$shared"

# --- crypto material the container consumes from /shared ---
# TLS CA + server cert for the mail hostname
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -out "$work/ca.crt" \
	-days 2 -subj "/CN=Inferno Interop Test CA" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$shared/server.key" -out "$work/srv.csr" \
	-subj "/CN=$HOSTN" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n' "$HOSTN" > "$work/ext.cnf"
openssl x509 -req -in "$work/srv.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
	-CAcreateserial -out "$shared/server.crt" -days 2 -extfile "$work/ext.cnf" >/dev/null 2>&1

# sshd host key (we generate it, so we know its thumbprint to pin)
ssh-keygen -q -t rsa -b 2048 -f "$shared/ssh_host_rsa_key" -N "" -C interophost
raw=$(ssh-keygen -l -E sha256 -f "$shared/ssh_host_rsa_key.pub" | awk '{print $2}')
thumb="sha256=${raw#SHA256:}"

# ssh client key (PEM PKCS#1, what the Inferno client's -i reads) + an
# unauthorised key for the negative control
ssh-keygen -q -t rsa -b 2048 -m PEM -f "$work/id_rsa" -N "" -C interopclient
ssh-keygen -q -t rsa -b 2048 -m PEM -f "$work/id_bad" -N "" -C interopbad
cp "$work/id_rsa.pub" "$shared/authorized_keys"

# passwords, visible inside emu under the tree root
printf '%s' "$PASS" > "$work/pass"
printf 'wrongpassword' > "$work/badpass"
MARKER="interop-body-$$-marker"
printf 'From an Inferno client, over real SMTP.\n%s\n' "$MARKER" > "$work/body.txt"

# --- start the container ---
cid=$(docker run -d --name "$NAME" \
	-v "$shared:/shared:ro" -e MAILPASS="$PASS" -e MAILHOST="$HOSTN" \
	-p 127.0.0.1:$SSHPORT:22 -p 127.0.0.1:$IMAPPORT:993 -p 127.0.0.1:$SMTPPORT:465 \
	"$IMG")
echo "INTEROP: container $NAME up ($cid)"

waitport() {  # host port
	i=0
	while [ "$i" -lt 60 ]; do
		if command -v nc >/dev/null 2>&1 && nc -z 127.0.0.1 "$1" 2>/dev/null; then return 0; fi
		i=$((i+1)); sleep 0.5
	done
	echo "INTEROP: port $1 never came up" >&2
	docker logs "$cid" 2>&1 | tail -30 >&2
	return 1
}
waitport "$SSHPORT"; waitport "$IMAPPORT"; waitport "$SMTPPORT"
# give postfix/dovecot a moment past the TCP accept to finish init
sleep 3

# temporarily trust the test CA so the Inferno TLS client accepts the cert
cp "$bundle" "$work/bundle.bak"
cat "$work/ca.crt" >> "$bundle"

cd "$root"
rc=0
fail() { echo "INTEROP: FAIL - $1" >&2; rc=1; }
runemu() { timeout 60 "$emu" -r. sh "/.mailsshtmp/$1" > "$2" 2>&1 || true; }

# --- 1. ssh: publickey login + remote command against real sshd ---
echo 'INTEROP: === ssh publickey login + remote command ==='
sout=$("$emu" -r. ssh -i /.mailsshtmp/id_rsa -p "$SSHPORT" -t "$thumb" "tester@127.0.0.1" "printf ssh-interop-ok" 2>&1) || true
echo "$sout" | grep -q 'ssh-interop-ok' && echo 'INTEROP: ssh publickey + command: PASS' \
	|| fail "ssh command did not return the marker: [$sout]"

# --- 2. ssh negative control: unauthorised key must be rejected ---
nout=$("$emu" -r. ssh -i /.mailsshtmp/id_bad -p "$SSHPORT" -t "$thumb" "tester@127.0.0.1" "printf nope" 2>&1) || true
echo "$nout" | grep -q 'ssh-interop-ok\|nope' && fail "unauthorised ssh key was ACCEPTED" \
	|| echo 'INTEROP: unauthorised ssh key rejected: PASS'

# --- 3. Inferno SMTP send -> real Postfix (implicit TLS + SASL) ---
echo 'INTEROP: === send mail with Inferno smtp2 to real Postfix ==='
cat > "$work/send.sh" <<EOF
bind -a '#I' /net
/dis/upas/send.dis -s $HOSTN -a 127.0.0.1 -p $SMTPPORT -u $USER -P /.mailsshtmp/pass -f $USER -t $USER -j 'Interop round trip' /.mailsshtmp/body.txt
EOF
runemu send.sh "$work/send.log"
echo "----- send log -----"; cat "$work/send.log"
grep -q 'authenticated as' "$work/send.log" || fail "SMTP AUTH failed against Postfix"
grep -q 'accepted for delivery' "$work/send.log" || fail "Postfix did not accept the message"

# let Postfix deliver to the Maildir before fetching
sleep 3

# --- 4. Inferno IMAP fetch <- real Dovecot: the round trip closes ---
echo 'INTEROP: === fetch mail with Inferno imap4 from real Dovecot ==='
cat > "$work/fetch.sh" <<EOF
bind -a '#I' /net
/dis/upas/fetch.dis -b -s $HOSTN -a 127.0.0.1 -p $IMAPPORT -u $USER -P /.mailsshtmp/pass
EOF
runemu fetch.sh "$work/fetch.log"
echo "----- fetch log -----"; cat "$work/fetch.log"
grep -q 'logged in' "$work/fetch.log" || fail "IMAP login failed against Dovecot"
grep -q 'Interop round trip' "$work/fetch.log" || fail "sent message subject not found via IMAP"
grep -q "$MARKER" "$work/fetch.log" \
	&& echo 'INTEROP: SMTP->Postfix->Dovecot->IMAP round trip: PASS' \
	|| fail "the body sent via Inferno SMTP was not retrieved via Inferno IMAP"

# --- 5. mail negative control: wrong IMAP password must be rejected ---
cat > "$work/badfetch.sh" <<EOF
bind -a '#I' /net
/dis/upas/fetch.dis -b -s $HOSTN -a 127.0.0.1 -p $IMAPPORT -u $USER -P /.mailsshtmp/badpass
EOF
runemu badfetch.sh "$work/badfetch.log"
grep -qi 'AUTHENTICATIONFAILED\|login rejected\|no.*login\|authentication fail' "$work/badfetch.log" \
	&& echo 'INTEROP: wrong IMAP password rejected: PASS' \
	|| fail "wrong IMAP password was ACCEPTED by Dovecot login"

if [ "$rc" -eq 0 ]; then
	echo 'INTEROP: ALL PASS - Inferno ssh/SMTP/IMAP interoperate with OpenSSH/Postfix/Dovecot'
else
	echo 'INTEROP: FAILURE'; echo '--- container logs ---'; docker logs "$cid" 2>&1 | tail -40
fi
exit $rc
