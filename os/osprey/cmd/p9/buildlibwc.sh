#!/bin/sh
# Build wc, the far end of a pipeline, for the library-OS personality and emit
# os/osprey/pc64/libwcprog.i.
#
# Linked against p9crt.c, which is the personality standing in for libc's
# system calls, and at an address of its own: a program is at the address
# it was linked for and nothing here relocates it, so every program that
# may run beside another - the two ends of a pipeline, the shell that
# started them - has a base to itself (p9lib.h).
#
# p9crt.c comes first so that p9start is the first thing in the text: the
# loader recovers the link address from the entry that way.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
TEXT=0x1800028		# P9progbase3 in p9lib.h, plus the header
6c $LIBINC -o /tmp/libwc_crt.6 $P/p9crt.c
6c $LIBINC -o /tmp/libwc_prog.6 $P/wcp9.c
6a -o /tmp/libwc_cons.6 $P/p9cons.s
OBJ="/tmp/libwc_crt.6 /tmp/libwc_prog.6 /tmp/libwc_cons.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/libwc_$m.6 lib9/$m.c
	SUP="$SUP /tmp/libwc_$m.6"
done
6l -l -R4096 -T $TEXT -E p9start -o /tmp/libwcp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/libwcprog.i" "$TEXT" <<'PYEND'
import sys
data=open('/tmp/libwcp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat,bss=be(0),be(4),be(8),be(12)
hdr=40 if (magic & 0x8000) else 32
entry=int.from_bytes(data[32:40],'big') if hdr==40 else be(20)
textaddr=int(sys.argv[2],0)
if entry != textaddr:
    raise SystemExit('entry %#x is not the start of the text %#x: p9start must be linked first' % (entry, textaddr))
img=data[:hdr+text+dat]
out=['uchar libwcprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d bss %d entry %#x)'%(sys.argv[1],len(img),hdr,text,dat,bss,entry))
PYEND
