#!/bin/sh
# Build the Plan 9 namespace library as a program on the host toolchain.
# The name space (chan/dev/pgrp/devroot) is the kernel's own upper half
# compiled against the shim (nsdat.h/dat.h/mem.h/fns.h + p9shim.c bodies).
# Link note: the disk libc.a has members the host 6l cannot read (built
# by a newer 6c), so link -l (no auto-libc) and supply those members
# from lib9 source; libc.a still provides its readable members.
set -e
cd "$(dirname "$0")/../../../.."          # repo root
P=os/osprey/cmd/p9
INC="-I $P -I os/osprey/port -I os/osprey/pc64 -I Osprey/amd64/include -I Osprey/include -I include"
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
OBJ="os/osprey/pc64/init9.6"
for f in $P/main.c $P/p9shim.c os/osprey/port/chan.c os/osprey/port/dev.c \
         os/osprey/port/pgrp.c os/osprey/port/devroot.c \
         os/osprey/port/devenv.c os/osprey/port/qio.c os/osprey/port/devmnt.c os/osprey/port/devpipe.c \
         $P/dev9ploop.c $P/p9file.c $P/p9srv.c; do
	o=/tmp/p9_$(basename $f .c).6
	6c $INC -o $o $f
	OBJ="$OBJ $o"
done
# libc members the host linker can't read, supplied from lib9 source
SUP=""
for m in utfnlen convM2D convD2M convS2M convM2S fcallfmt vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/p9_$m.6 lib9/$m.c
	SUP="$SUP /tmp/p9_$m.6"
done
# the ring transport is compiled against the user headers (its sleep is
# libc's SLEEP syscall, not the name space's), then linked with the rest
6c $LIBINC -o /tmp/p9_ring9p.6 $P/ring9p.c
OBJ="$OBJ /tmp/p9_ring9p.6"

6l -l -R4096 -o /tmp/p9lib $OBJ $SUP Osprey/amd64/lib/libc.a
echo "built /tmp/p9lib"

# Emit the loader image os/osprey/pc64/p9prog.i from the linked binary,
# truncated to header+text+data (the loader reads no symbol table).  This
# is what ospreyloadp9() parses and eager-maps; regenerating it here keeps
# the embedded image in step with the sources above.
python3 - "$PWD/os/osprey/pc64/p9prog.i" <<'PY'
import sys
data=open('/tmp/p9lib','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar p9prog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
