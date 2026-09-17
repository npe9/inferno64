#!/bin/sh
# Build the file-server container's program (userprog.c + the 9P server
# srv9p.c) on the host toolchain and emit userprog.i, the image
# ospreyloadprog flat-loads for the server task.  Same shape as
# build.sh: compile against the user headers, supply the libc members the
# host linker cannot read from source, link init9 first for the entry,
# truncate to header+text+data (the loader reads no symbol table).
#
# The one argument is the object type, amd64 when it is absent, and it
# picks the toolchain, the kernel directory the image is for (and which
# holds that type's init9 and userregtorture), and the libc: for amd64
# 9front's, for 386 the archive os/osprey/pc/mkfile builds.
set -e
cd "$(dirname "$0")/../../../.."			# repo root
OBJTYPE=${1:-amd64}
case $OBJTYPE in
amd64)	O=6; K=os/osprey/pc64 ;;
386)	O=8; K=os/osprey/pc ;;
*)	echo "buildserver.sh: no kernel for $OBJTYPE" >&2; exit 1 ;;
esac
P=os/osprey/cmd/p9
LIBINC="-I Osprey/$OBJTYPE/include -I Osprey/include -I include -I $P"
${O}a -o /tmp/srv_userregtorture.$O $K/userregtorture.s
OBJ="$K/init9.$O /tmp/srv_userregtorture.$O"
for f in os/osprey/port/userprog.c $P/srv9p.c; do
	o=/tmp/srv_$(basename $f .c).$O
	${O}c $LIBINC -o $o $f
	OBJ="$OBJ $o"
done
# libc members the host linker can't read, supplied from lib9 source
SUP=""
for m in convM2S convS2M convD2M utfnlen vsnprint dofmt vfprint; do
	${O}c $LIBINC -o /tmp/srv_$m.$O lib9/$m.c
	SUP="$SUP /tmp/srv_$m.$O"
done
${O}l -l -R1 -o /tmp/userprog.$O $OBJ $SUP Osprey/$OBJTYPE/lib/libc.a
python3 - "$PWD/$K/userprog.i" /tmp/userprog.$O <<'PY'
import sys
data=open(sys.argv[2],'rb').read()
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
