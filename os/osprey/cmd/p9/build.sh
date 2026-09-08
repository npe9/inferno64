#!/bin/sh
# Build the Plan 9 namespace library as a program on the host toolchain.
# The name space (chan/dev/pgrp/devroot) is the kernel's own upper half
# compiled against the shim (nsdat.h/dat.h/mem.h/fns.h + p9shim.c bodies).
# Kernel-side sources are compiled -Dsleep=ksleep (the host libc owns
# sleep(int)) and -Dfastticks=kfastticks: libc's fastticks calls nsec(),
# which opens /dev/bintime - an OPEN trap the microkernel does not answer
# ("unimplemented syscall 14", once per stack attached, from il.c's
# inittimescale).  The personality's kfastticks (p9sched.c) is the
# cooperative clock's tick count at 100 Hz.
# Link note: the disk libc.a has members the host 6l cannot read (built
# by a newer 6c), so link -l (no auto-libc) and supply those members
# from lib9 source; libc.a still provides its readable members.
set -e
cd "$(dirname "$0")/../../../.."          # repo root
P=os/osprey/cmd/p9
INC="-Dsleep=ksleep -Dfastticks=kfastticks -I $P -I os/osprey/port -I os/osprey/pc64 -I os/osprey/ip -I Osprey/amd64/include -I Osprey/include -I include"
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P -I os/osprey/port"
OBJ="os/osprey/pc64/init9.6"
for f in $P/main.c $P/p9shim.c os/osprey/port/chan.c os/osprey/port/dev.c \
         os/osprey/port/pgrp.c os/osprey/port/devroot.c \
         os/osprey/port/devenv.c os/osprey/port/qio.c os/osprey/port/devmnt.c os/osprey/port/devpipe.c os/osprey/port/devsrv.c \
         $P/dev9ploop.c $P/p9file.c $P/p9srv.c $P/p9buddy.c $P/p9linuxfile.c $P/devlfs.c $P/pipfsrv.c $P/p9ip.c $P/p9sched.c $P/p9kbd.c $P/devcache.c $P/devtime.c $P/devnote.c $P/devinput.c $P/devdup.c $P/p9proc.c $P/drawpool.c \
         os/osprey/port/netif.c os/osprey/port/parse.c \
         os/osprey/ip/ip.c os/osprey/ip/ipaux.c os/osprey/ip/iproute.c os/osprey/ip/ipifc.c \
         os/osprey/ip/netlog.c os/osprey/ip/ipmux.c os/osprey/ip/arp.c os/osprey/ip/icmp.c \
         os/osprey/ip/icmp6.c os/osprey/ip/igmp.c os/osprey/ip/ipv6.c os/osprey/ip/tcp.c \
         os/osprey/ip/udp.c os/osprey/ip/rudp.c os/osprey/ip/il.c os/osprey/ip/gre.c \
         os/osprey/ip/devip.c os/osprey/ip/inferno.c os/osprey/ip/loopbackmedium.c os/osprey/ip/ospreymedium.c os/osprey/ip/ospreyvnetmedium.c os/osprey/ip/netdevmedium.c \
         os/osprey/ip/nullmedium.c os/osprey/ip/pktmedium.c os/osprey/ip/chandial.c; do
	o=/tmp/p9_$(basename $f .c).6
	6c $INC -o $o $f
	OBJ="$OBJ $o"
done
# the draw device's two libraries, compiled against the name space's
# headers the way the device itself is: memdraw does the drawing and
# memlayer the windows, and both are the same sources the user-level
# draw server links against.  Object names are prefixed because
# libmemdraw/draw.c and libmemlayer/draw.c share a basename, as do
# line.c, load.c, unload.c and warp.c.
for f in 9front/src/libmemdraw/*.c; do
	case $f in *mkcmap.c) continue ;; esac	# a host tool, not part of the library
	6c $INC -o /tmp/p9_md_$(basename $f .c).6 $f
	OBJ="$OBJ /tmp/p9_md_$(basename $f .c).6"
done
for f in 9front/src/libmemlayer/*.c; do
	6c $INC -o /tmp/p9_ml_$(basename $f .c).6 $f
	OBJ="$OBJ /tmp/p9_ml_$(basename $f .c).6"
done

# ip address helpers from kernlib (distinct object names: kernlib/ipaux.c
# would collide with ip/ipaux.c on basename)
# the draw device itself, compiled with os/osprey/cmd/draw ahead of
# os/osprey/pc64 on the include path: devdraw.c includes "screen.h", and
# the pc64 kernel has one of its own whose ishwimage is a macro over the
# VGA driver's vgascreen[], which this personality has no VGA driver for.
# The screen.h that belongs to it is the draw server's.
6c -I os/osprey/cmd/draw $INC -o /tmp/p9_devdrawp9.6 $P/devdrawp9.c
OBJ="$OBJ /tmp/p9_devdrawp9.6"

# and the pieces of libdraw the draw device and memdraw call: the
# arithmetic on Points and Rectangles, the channel descriptors, the
# scan-line arithmetic, the compressed-image helpers and the built-in
# font's unpacker.  A kernel links exactly these out of libdraw too.
for f in bytesperline chan badrect icossin icossin2 arith computil defont rectclip drawrepl fmt; do
	6c $INC -o /tmp/p9_ld_$f.6 9front/src/libdraw/$f.c
	OBJ="$OBJ /tmp/p9_ld_$f.6"
done

# the pool allocator image memory is carved with
6c $INC -o /tmp/p9_pool.6 os/osprey/kernlib/pool.c
OBJ="$OBJ /tmp/p9_pool.6"
for f in parseip ptclbsum ipaux classmask eipfmt; do
	6c $LIBINC -o /tmp/p9_k_$f.6 os/osprey/kernlib/$f.c
	OBJ="$OBJ /tmp/p9_k_$f.6"
done
# libc members the host linker can't read, supplied from lib9 source
SUP=""
# fmtquote is here for %q, which namelenerror() uses to name the file an
# error is about: without it every "... does not exist" and "permission
# denied" from the name space came out with a literal %q in it, and the
# draw server's postsrv failure said "Eperm: %q" instead of naming /srv.
# runestrlen comes with it: fmtquote calls it, and it is one of the 34
# members of the prebuilt archive this linker cannot read.
for m in utfnlen convM2D convD2M convS2M convM2S fcallfmt vsnprint dofmt vfprint fmtquote runestrlen; do
	6c $LIBINC -o /tmp/p9_$m.6 lib9/$m.c
	SUP="$SUP /tmp/p9_$m.6"
done
# the ring transport is compiled against the user headers (its sleep is
# libc's SLEEP syscall, not the name space's), then linked with the rest
6c $LIBINC -o /tmp/p9_ring9p.6 $P/ring9p.c
OBJ="$OBJ /tmp/p9_ring9p.6"
6c $LIBINC -o /tmp/p9_p9pairsrv.6 $P/p9pairsrv.c
OBJ="$OBJ /tmp/p9_p9pairsrv.6"
# the library operating system's own loader: it reads a program through
# the name space and calls it, so it needs libc's segattach, not the
# name space's segattach - the user headers, as above
6c $LIBINC -I os/osprey/pc64 -o /tmp/p9_p9exec.6 $P/p9exec.c	# prog2.i is generated there
OBJ="$OBJ /tmp/p9_p9exec.6"
# the screen the draw device draws onto: libc's segattach, so the user
# headers, as ring9p.c is
6c $LIBINC -o /tmp/p9_drawscreen.6 $P/drawscreen.c
OBJ="$OBJ /tmp/p9_drawscreen.6"
6c $LIBINC -o /tmp/p9_blkvirtio.6 $P/blkvirtio.c
OBJ="$OBJ /tmp/p9_blkvirtio.6"
6c $LIBINC -o /tmp/p9_netvirtio.6 $P/netvirtio.c
OBJ="$OBJ /tmp/p9_netvirtio.6"
6a -o /tmp/p9_xcall.6 $P/xcall.s
OBJ="$OBJ /tmp/p9_xcall.6"

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
