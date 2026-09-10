#!/bin/sh
# Build the second library-OS program and emit os/osprey/pc64/prog2.i.
#
# It is linked at P9progbase (p9lib.h) rather than at UTZERO, because the
# personality is already at UTZERO and this program is loaded beside it,
# into the same address space, not over it.  It is entered at p9start and
# not at _main: init9.c is not linked, since nothing here starts it as a
# process - the personality calls it as a function, handing it the table
# of its own entry points.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
BASE=0x1c00000		# P9progbase in p9lib.h; the two must agree
# -T is the address of the first instruction, not of the header: 6l puts
# the forty-byte header below it, which is where the loader lays the file
# down, so the text address is the base plus the header.
TEXT=0x1c00028
6c $LIBINC -o /tmp/prog2p9.6 $P/prog2p9.c
OBJ="/tmp/prog2p9.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/prog2_$m.6 lib9/$m.c
	SUP="$SUP /tmp/prog2_$m.6"
done
6l -l -R4096 -T $TEXT -E p9start -o /tmp/prog2p9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/prog2.i" "$BASE" <<'PY'
import sys
data=open('/tmp/prog2p9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat,bss=be(0),be(4),be(8),be(12)
hdr=40 if (magic & 0x8000) else 32
entry=int.from_bytes(data[32:40],'big') if hdr==40 else be(20)
base=int(sys.argv[2],0)
if not (base+hdr <= entry < base+hdr+text):
    raise SystemExit('entry %#x is not in the text at %#x' % (entry, base))
img=data[:hdr+text+dat]
out=['uchar prog2[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d bss %d entry %#x)'%(sys.argv[1],len(img),hdr,text,dat,bss,entry))
PY
