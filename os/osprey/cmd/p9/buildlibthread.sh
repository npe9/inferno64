#!/bin/sh
# Build the threaded program for the library-OS personality and emit
# os/osprey/pc64/libthreadprog.i.
#
# It is an ordinary Plan 9 libthread program - threadmain, threadcreate,
# chancreate, send, recv - linked against the real libthread built from
# source in 9front/src, and against p9crt.c and threadmain9.c.
# threadmain9.c is the four functions 9front keeps in libthread/main.c
# for exactly this purpose: main, _schedexec, _schedfork and _schedexit
# are the system a port has to supply, and the rest of libthread is
# linked with no line changed.
#
# Nothing in this program traps.  The link below leaves out the prebuilt
# libc.a - the archive of generated system-call stubs - entirely, and it
# resolves: every call libthread and its libc make is either the
# personality's, through the table, or code in the program's own image.
# The one exception is the console, which is p9cons.s, and which the
# personality does not hold.
#
# p9crt.c comes first so that p9start is the first thing in the text -
# the loader recovers the link address from the entry that way.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
THRINC="-I $PWD/9front/src/include -I $PWD/9front/amd64/include -I $PWD/9front/src/libthread"
TEXT=0x2800028		# P9progbase7 in p9lib.h, plus the header
6c $LIBINC -o /tmp/libthread_crt.6 $P/p9crt.c
6c $THRINC -o /tmp/libthread_main.6 $P/threadmain9.c
6c $THRINC -o /tmp/libthread_prog.6 $P/libthreadp9.c
6a -o /tmp/libthread_cons.6 $P/p9cons.s
OBJ="/tmp/libthread_crt.6 /tmp/libthread_main.6 /tmp/libthread_prog.6 /tmp/libthread_cons.6"
6l -l -R4096 -T $TEXT -E p9start -o /tmp/libthreadp9 $OBJ \
	9front/amd64/lib-src/libthread.a 9front/amd64/lib-src/libc9.a
python3 - "$PWD/os/osprey/pc64/libthreadprog.i" "$TEXT" <<'PYEND'
import sys
data=open('/tmp/libthreadp9','rb').read()
be=lambda o:int.from_bytes(data[o:o+4],'big')
magic,text,dat,bss=be(0),be(4),be(8),be(12)
hdr=40 if (magic & 0x8000) else 32
entry=int.from_bytes(data[32:40],'big') if hdr==40 else be(20)
textaddr=int(sys.argv[2],0)
if entry != textaddr:
    raise SystemExit('entry %#x is not the start of the text %#x: p9start must be linked first' % (entry, textaddr))
img=data[:hdr+text+dat]
out=['uchar libthreadprog[]={']
for i in range(0,len(img),16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes: hdr %d text %d data %d bss %d entry %#x)'%(sys.argv[1],len(img),hdr,text,dat,bss,entry))
PYEND
