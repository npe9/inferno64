#!/bin/sh
# Build hosted console emu on Linux/riscv64 (on-target). Restores mkconfig on exit.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SAVE=$(mktemp)
cp mkconfig "$SAVE"
trap 'cp "$SAVE" mkconfig; rm -f "$SAVE"' EXIT

cat > mkconfig <<EOF
ROOT=$ROOT
TKSTYLE=std
CONF=emu
SYSHOST=Linux
SYSTARG=\$SYSHOST
OBJTYPE=riscv64
OBJDIR=\$SYSTARG/\$OBJTYPE
<\$ROOT/mkfiles/mkhost-\$SYSHOST
<\$ROOT/mkfiles/mkfile-\$SYSTARG-\$OBJTYPE
EOF

export MACOSINF=caseinsensitive
export X11LIBS=
sh makemk.sh
BIN=$ROOT/Linux/riscv64/bin
export PATH="$BIN:$PATH"
mk install
(cd emu/Linux && mk CONF=emu-g install)
cp "$BIN/emu-g" "$BIN/emu"

echo "build ok; verifying emu..."
"$BIN/emu" -c0 /dis/sh.dis -c 'echo linux-riscv64-ok'
