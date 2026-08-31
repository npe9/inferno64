#!/bin/sh
# Build the file-server container's program (userprog.c + the 9P server
# srv9p.c) on the host toolchain and emit os/osprey/pc64/userprog.i, the
# image ospreyloadprog flat-loads for the server task.  Same shape as
# build.sh: compile against the user headers, supply the libc members the
# host linker cannot read from source, link init9 first for the entry,
# truncate to header+text+data (the loader reads no symbol table).
set -e
cd "$(dirname "$0")/../../../.."			# repo root
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
OBJ="os/osprey/pc64/init9.6"
for f in os/osprey/port/userprog.c $P/srv9p.c; do
	o=/tmp/srv_$(basename $f .c).6
	6c $LIBINC -o $o $f
	OBJ="$OBJ $o"
done
# libc members the host linker can't read, supplied from lib9 source
SUP=""
for m in convM2S convS2M convD2M utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/srv_$m.6 lib9/$m.c
	SUP="$SUP /tmp/srv_$m.6"
done
6l -l -R1 -o /tmp/userprog $OBJ $SUP Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/userprog.i" <<'PY'
import sys
data=open('/tmp/userprog','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat=be(0),be(4),be(8)
hdr=40 if (magic & 0x8000) else 32
img=data[:hdr+text+dat]
out=['uchar userprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d)'%(sys.argv[1],len(img),hdr,text,dat))
PY
