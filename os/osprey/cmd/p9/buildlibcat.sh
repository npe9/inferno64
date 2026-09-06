#!/bin/sh
# Build cat for the library-OS personality and emit
# os/osprey/pc64/libcatprog.i.
#
# It is the same source as the cat that runs under the buddy on the
# server personality (catp9.c), unchanged.  What differs is the link: it
# is linked against p9crt.c, which defines open, read, write, close,
# seek, dup, fd2path, sbrk and exits itself and so keeps libc's
# system-call stubs for them off the link line entirely.  Those calls go
# to the personality in the program's own address space instead.  One
# program, two arrangements: a process boundary on the server
# personality, none here.
#
# p9crt.c comes first so that p9start is the first thing in the text -
# the loader recovers the link address from the entry that way - and the
# link address is above the personality's image, below the stack, and
# clear of the other loaded program.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
TEXT=0x1400028		# P9progbase2 in p9lib.h, plus the header
6c $LIBINC -o /tmp/libcat_crt.6 $P/p9crt.c
6c $LIBINC -o /tmp/libcat_cat.6 $P/catp9.c
OBJ="/tmp/libcat_crt.6 /tmp/libcat_cat.6"
SUP=""
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/libcat_$m.6 lib9/$m.c
	SUP="$SUP /tmp/libcat_$m.6"
done
6l -l -R4096 -T $TEXT -E p9start -o /tmp/libcatp9 $OBJ $SUP Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/libcatprog.i" "$TEXT" <<'PY'
import sys
data=open('/tmp/libcatp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat,bss=be(0),be(4),be(8),be(12)
hdr=40 if (magic & 0x8000) else 32
entry=int.from_bytes(data[32:40],'big') if hdr==40 else be(20)
textaddr=int(sys.argv[2],0)
if entry != textaddr:
    raise SystemExit('entry %#x is not the start of the text %#x: p9start must be linked first' % (entry, textaddr))
img=data[:hdr+text+dat]
out=['uchar libcatprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d bss %d entry %#x)'%(sys.argv[1],len(img),hdr,text,dat,bss,entry))
PY
