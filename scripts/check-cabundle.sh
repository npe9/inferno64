#!/bin/sh
# The DER trust bundle holds exactly the certificates the PEM holds.
#
# tls12(2) reads lib/tls/ca-bundle.der in preference to the PEM, so the
# two have to agree: a DER that quietly dropped a root would narrow
# what this system trusts, and a DER that kept one the PEM no longer
# has would widen it.  Neither shows up as a failure anywhere else --
# a chain either verifies or does not, and both mistakes look like a
# verdict rather than a bug -- so it is checked here directly, by
# decoding the PEM again and comparing certificate by certificate.
#
# usage: scripts/check-cabundle.sh
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PEM=$ROOT/lib/tls/ca-bundle.pem
DER=$ROOT/lib/tls/ca-bundle.der

[ -f "$PEM" ] || { echo "check-cabundle: no $PEM" >&2; exit 1; }
[ -f "$DER" ] || { echo "check-cabundle: no $DER; run scripts/mkcabundle.sh" >&2; exit 1; }

python3 - "$PEM" "$DER" <<'EOF'
import base64, hashlib, re, sys
pem, der = sys.argv[1], sys.argv[2]
blocks = re.findall(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----",
                    open(pem).read(), re.S)
want = [base64.b64decode("".join(b.split())) for b in blocks]

raw = open(der, "rb").read()
got = []
i = 0
while i < len(raw):
    if raw[i] != 0x30:
        sys.exit("check-cabundle: FAIL -- byte %d is not a DER SEQUENCE" % i)
    j = i + 1
    n = raw[j]; j += 1
    if n == 0x80:
        sys.exit("check-cabundle: FAIL -- indefinite length at %d" % i)
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(raw[j:j+k], "big"); j += k
    if j + n > len(raw):
        sys.exit("check-cabundle: FAIL -- length at %d runs past the end" % i)
    got.append(raw[i:j+n])
    i = j + n

if len(want) != len(got):
    sys.exit("check-cabundle: FAIL -- %d certificates in the PEM, %d in the DER"
             % (len(want), len(got)))
for n, (w, g) in enumerate(zip(want, got)):
    if w != g:
        sys.exit("check-cabundle: FAIL -- certificate %d differs (%s vs %s)"
                 % (n, hashlib.sha256(w).hexdigest()[:16],
                    hashlib.sha256(g).hexdigest()[:16]))
print("check-cabundle: ok -- %d certificates, identical in both" % len(got))
EOF
