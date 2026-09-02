#!/bin/sh
# Build the unmodified Linux x86-64 binary and emit os/osprey/pc64/linuxprog.i.
# It is a static ELF with raw Linux syscalls and no libc; the whole file is
# embedded, and the kernel's ELF loader parses its program headers.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
clang -target x86_64-linux-gnu -nostdlib -static -ffreestanding -fno-stack-protector \
	-Wl,-e,_start -O2 -o /tmp/linuxprog $P/linuxlegacy.c
python3 - "$PWD/os/osprey/pc64/linuxprog.i" <<'PY'
import sys
data=open('/tmp/linuxprog','rb').read()
out=['uchar linuxprog[]={']
for i in range(0,len(data),16):
    out.append(','.join('0x%02x'%b for b in data[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes, whole ELF)'%(sys.argv[1],len(data)))
PY
