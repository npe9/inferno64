#!/bin/sh
# Make lib/tls/ca-bundle.der from lib/tls/ca-bundle.pem.
#
# The PEM bundle is the readable original and stays the thing a person
# edits or replaces.  The DER beside it is the same certificates with
# the base64 and the BEGIN/END lines taken off and nothing put in their
# place: a DER certificate carries its own length, so a bundle of them
# needs no framing and a reader needs no decoder.
#
# tls12(2) reads the DER when it is there because the PEM is not free.
# Reading 2950 lines through bufio(2) and base64-decoding 182 KB cost
# 1.5 s and 1.7 s of interpreted Dis on a fast machine, inside a
# handshake that a server is timing, and a native kernel has no JIT to
# soften it.
#
# usage: scripts/mkcabundle.sh [pem [der]]
set -e
ROOT=`cd \`dirname "$0"\`/.. && pwd`
PEM=${1:-$ROOT/lib/tls/ca-bundle.pem}
DER=${2:-$ROOT/lib/tls/ca-bundle.der}

[ -f "$PEM" ] || { echo "mkcabundle: no $PEM" >&2; exit 1; }

python3 - "$PEM" "$DER" <<'EOF'
import base64, re, sys
pem, der = sys.argv[1], sys.argv[2]
text = open(pem).read()
blocks = re.findall(
    r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)
if not blocks:
    sys.exit("mkcabundle: no certificates in " + pem)
out = bytearray()
for b in blocks:
    d = base64.b64decode("".join(b.split()))
    # A certificate is SEQUENCE; refuse anything else rather than
    # writing a bundle whose reader will stop at the first surprise.
    if not d or d[0] != 0x30:
        sys.exit("mkcabundle: a block is not a DER SEQUENCE")
    out += d
open(der, "wb").write(out)
print("mkcabundle: %d certificates, %d bytes -> %s" % (len(blocks), len(out), der))
EOF
