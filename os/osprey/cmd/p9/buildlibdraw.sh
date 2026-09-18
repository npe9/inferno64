#!/bin/sh
# Build the drawing program for the library-OS personality and emit
# os/osprey/pc64/libdrawprog.i.
#
# It is an ordinary Plan 9 graphics program - initdraw, allocimage,
# draw - linked against the real libdraw built from source in
# 9front/src, and against p9crt.c, which is the personality standing in
# for libc's system calls.  So libdraw's open of /dev/draw and its
# writes of the draw protocol go to the personality in this program's
# own address space, and /dev/draw there is the kernel's devdraw.c
# compiled into it.  A draw is a call.
#
# libc9.a is the source-built 9front libc: libdraw asks it for the
# things p9crt.c does not define - the formatted print, the string and
# rune functions, malloc over p9crt's own sbrk.  The disk libc.a comes
# last and answers only its readable members.
#
# p9crt.c comes first so that p9start is the first thing in the text -
# the loader recovers the link address from the entry that way - and the
# link address is above the personality's image, below the stack, and
# clear of the other loaded programs.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
DRAWINC="-I $PWD/9front/src/include -I $PWD/9front/amd64/include"
TEXT=0x2400028		# P9progbase6 in p9lib.h, plus the header
6c $LIBINC -o /tmp/libdraw_crt.6 $P/p9crt.c
6c $DRAWINC -o /tmp/libdraw_prog.6 $P/drawlibp9.c
6a -o /tmp/libdraw_cons.6 $P/p9cons-amd64.s
OBJ="/tmp/libdraw_crt.6 /tmp/libdraw_prog.6 /tmp/libdraw_cons.6"
6l -l -R4096 -T $TEXT -E p9start -o /tmp/libdrawp9 $OBJ \
	9front/amd64/lib-src/libdraw.a 9front/amd64/lib-src/libc9.a \
	Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/libdrawprog.i" "$TEXT" <<'PYEND'
import sys
data=open('/tmp/libdrawp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat,bss=be(0),be(4),be(8),be(12)
hdr=40 if (magic & 0x8000) else 32
entry=int.from_bytes(data[32:40],'big') if hdr==40 else be(20)
textaddr=int(sys.argv[2],0)
if entry != textaddr:
    raise SystemExit('entry %#x is not the start of the text %#x: p9start must be linked first' % (entry, textaddr))
img=data[:hdr+text+dat]
out=['uchar libdrawprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d bss %d entry %#x)'%(sys.argv[1],len(img),hdr,text,dat,bss,entry))
PYEND
