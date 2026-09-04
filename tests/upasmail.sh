#!/bin/sh
set -eu

# Hermetic end-to-end test for the upas Gmail client with NO Google
# account: a local IMAP+SMTP TLS oracle (tests/mailoracle.py) stands in
# for the server. A throwaway CA is generated and TEMPORARILY trusted in
# this tree's TLS root bundle (restored afterward), the oracle serves TLS
# with a cert for testmail.local, and the Inferno client is driven against
# it over real TLS. Verifies: IMAP login + fetch, IMAP-backed upas/fs, and
# SMTP auth + send - each with a wrong-password negative control. This is
# the mail analogue of tests/sshlocal.sh's local-sshd oracle.

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PATH="$root/MacOSX/arm64/bin:$PATH"
export PATH
command -v openssl >/dev/null 2>&1 || { echo 'UPASMAIL: openssl not found' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo 'UPASMAIL: python3 not found' >&2; exit 2; }
test -x "$root/MacOSX/arm64/bin/emu-g" || { echo 'UPASMAIL: emu-g not built' >&2; exit 2; }
test -f "$root/dis/upas/fetch.dis" || { echo 'UPASMAIL: dis/upas/fetch.dis not built' >&2; exit 2; }

HOSTN=testmail.local
IMAPPORT=${UPASMAIL_IMAP:-14993}
SMTPPORT=${UPASMAIL_SMTP:-14465}
USER=tester@test.example
PASS=s3cret
bundle="$root/lib/tls/ca-bundle.pem"

work="$root/.upasmailtmp"
oraclepid=
cleanup() {
	[ -n "$oraclepid" ] && kill "$oraclepid" 2>/dev/null || true
	[ -f "$work/bundle.bak" ] && cp "$work/bundle.bak" "$bundle" || true	# restore trust roots
	rm -rf "$work" "$root/mnt/oraclembox"
}
trap cleanup EXIT INT TERM
rm -rf "$work"; mkdir -p "$work"
printf '%s' "$PASS" > "$work/pass"
printf 'wrongpassword' > "$work/badpass"
printf 'This is the body of the sent message.\n' > "$work/body.txt"

# --- generate a throwaway CA and a server cert for testmail.local ---
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -out "$work/ca.crt" \
	-days 2 -subj "/CN=Upas Oracle Test CA" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$work/srv.key" -out "$work/srv.csr" \
	-subj "/CN=$HOSTN" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n' "$HOSTN" > "$work/ext.cnf"
openssl x509 -req -in "$work/srv.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" \
	-CAcreateserial -out "$work/srv.crt" -days 2 -extfile "$work/ext.cnf" >/dev/null 2>&1

# temporarily trust the test CA (the client verifies against this bundle)
cp "$bundle" "$work/bundle.bak"
cat "$work/ca.crt" >> "$bundle"

# --- start the oracle ---
python3 "$root/tests/mailoracle.py" "$work/srv.crt" "$work/srv.key" \
	"$IMAPPORT" "$SMTPPORT" "$USER" "$PASS" "$work/captured.eml" >"$work/oracle.log" 2>&1 &
oraclepid=$!
python3 - "$IMAPPORT" "$SMTPPORT" <<'PYWAIT' || { echo 'UPASMAIL: oracle did not come up' >&2; cat "$work/oracle.log" >&2; exit 1; }
import socket, sys, time
ip, sp = int(sys.argv[1]), int(sys.argv[2])
for _ in range(50):
    try:
        socket.create_connection(("127.0.0.1", ip), 0.2).close()
        socket.create_connection(("127.0.0.1", sp), 0.2).close()
        sys.exit(0)
    except OSError:
        time.sleep(0.1)
sys.exit(1)
PYWAIT

fail() { echo "UPASMAIL: FAIL - $1" >&2; exit 1; }
runemu() {  # $1 = script name under work, $2 = logfile
	timeout 45 "$root/MacOSX/arm64/bin/emu-g" -r"$root" sh "/.upasmailtmp/$1" > "$2" 2>&1 || true
}

# --- 1. IMAP fetch with the right password ---
cat > "$work/fetch.sh" <<EOF
bind -a '#I' /net
/dis/upas/fetch.dis -b -s $HOSTN -a 127.0.0.1 -p $IMAPPORT -u $USER -P /.upasmailtmp/pass
EOF
runemu fetch.sh "$work/fetch.log"
echo "===== IMAP fetch ====="; cat "$work/fetch.log"
grep -q 'logged in' "$work/fetch.log" || fail "IMAP login failed over TLS"
grep -q 'Oracle test message' "$work/fetch.log" || fail "fetched message subject missing"
grep -q 'Hello from the IMAP oracle' "$work/fetch.log" || fail "fetched message body missing"

# --- 2. IMAP fetch with a WRONG password (negative control) ---
cat > "$work/badfetch.sh" <<EOF
bind -a '#I' /net
/dis/upas/fetch.dis -b -s $HOSTN -a 127.0.0.1 -p $IMAPPORT -u $USER -P /.upasmailtmp/badpass
EOF
runemu badfetch.sh "$work/badfetch.log"
grep -qi 'AUTHENTICATIONFAILED\|login rejected' "$work/badfetch.log" || fail "wrong IMAP password was ACCEPTED (negative control)"

# --- 3. IMAP-backed upas/fs serves the fetched message as a file system ---
cat > "$work/fs.sh" <<EOF
bind -a '#I' /net
/dis/upas/fs.dis -i -s $HOSTN -a 127.0.0.1 -p $IMAPPORT -u $USER -P /.upasmailtmp/pass -m /mnt/oraclembox
echo MARK subject
cat /mnt/oraclembox/1/subject
echo ''
echo MARK body
cat /mnt/oraclembox/1/body
echo ''
echo MARK done
EOF
runemu fs.sh "$work/fs.log"
echo "===== upas/fs -i ====="; cat "$work/fs.log"
awk '/MARK subject/{f=1;next}/MARK /{f=0}f' "$work/fs.log" | grep -q 'Oracle test message' || fail "upas/fs -i did not serve the subject"
awk '/MARK body/{f=1;next}/MARK /{f=0}f' "$work/fs.log" | grep -q 'Hello from the IMAP oracle' || fail "upas/fs -i did not serve the body"

# --- 4. SMTP send with the right password ---
cat > "$work/send.sh" <<EOF
bind -a '#I' /net
/dis/upas/send.dis -s $HOSTN -a 127.0.0.1 -p $SMTPPORT -u $USER -P /.upasmailtmp/pass -f $USER -t rcpt@dest.example -j 'Sent by oracle test' /.upasmailtmp/body.txt
EOF
runemu send.sh "$work/send.log"
echo "===== SMTP send ====="; cat "$work/send.log"
grep -q 'authenticated as' "$work/send.log" || fail "SMTP auth failed over TLS"
grep -q 'accepted for delivery' "$work/send.log" || fail "SMTP send not accepted"
test -f "$work/captured.eml" || fail "oracle captured no message"
grep -q 'Subject: Sent by oracle test' "$work/captured.eml" || fail "captured message subject wrong"
grep -q 'This is the body of the sent message' "$work/captured.eml" || fail "captured message body wrong"

# --- 5. SMTP send with a WRONG password (negative control) ---
rm -f "$work/captured.eml"
cat > "$work/badsend.sh" <<EOF
bind -a '#I' /net
/dis/upas/send.dis -s $HOSTN -a 127.0.0.1 -p $SMTPPORT -u $USER -P /.upasmailtmp/badpass -f $USER -t rcpt@dest.example -j 'should not send' /.upasmailtmp/body.txt
EOF
runemu badsend.sh "$work/badsend.log"
grep -qi 'auth failed\|xoauth2\|535' "$work/badsend.log" || fail "wrong SMTP password was ACCEPTED (negative control)"
test ! -f "$work/captured.eml" || fail "message was delivered despite wrong password"

echo 'UPASMAIL: PASS - IMAP login+fetch, upas/fs -i, and SMTP auth+send verified over real TLS against a local oracle, with wrong-password controls on both'
