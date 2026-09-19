#!/bin/sh
# Build the Plan 9 personality for 386 and emit os/osprey/pc/p9prog.i.
#
# build.sh does this for amd64 and says at length what the personality
# is and why each piece of it is compiled the way it is; that reasoning
# is there and is not repeated.  What differs for this object type:
#
#	the toolchain	8c, 8a, 8l.
#	the libc	9front/386/lib-src/libc9.a, built from source by
#			build9front386.sh, where amd64 links the prebuilt
#			Osprey/amd64/lib/libc.a.
#	the machine	xcall-386.s rather than xcall-amd64.s.
#	the address	P9selfbase plus this machine's header, 32 bytes
#			where amd64's is 40.  p9setup checks at boot that
#			the number here and p9lib.h's agree.
#	two files	p9linuxfile-386.c stands in for p9linuxfile.c: the
#			Linux binary it embeds is x86-64 and the ordinary
#			Plan 9 binaries beside it have no 386 twins yet, so
#			this object type's file system has the library-OS
#			programs and not the trapping ones.  The file says
#			so itself.
#
# The ten programs the personality embeds are built by buildprogs386.sh,
# which must have run: p9exec.c includes their images.
#
# usage: sh os/osprey/cmd/p9/build386.sh
set -e
cd "$(dirname "$0")/../../../.."
ROOT="$PWD"
P=os/osprey/cmd/p9
K=os/osprey/pc
LIBSRC="$ROOT/9front/386/lib-src"
INC="-Dsleep=ksleep -Dfastticks=kfastticks -I $P -I os/osprey/port -I $K -I os/osprey/ip -I Osprey/386/include -I Osprey/include -I include"
LIBINC="-I Osprey/386/include -I Osprey/include -I include -I $P -I os/osprey/port"
TMP="$LIBSRC/p9"
mkdir -p "$TMP"
rm -f "$TMP"/*.8
OBJ=""

# the personality, the name space it is made of, and the IP stack
for f in $P/main.c $P/p9shim.c os/osprey/port/chan.c os/osprey/port/dev.c \
	os/osprey/port/pgrp.c os/osprey/port/devroot.c os/osprey/port/devenv.c \
	os/osprey/port/qio.c os/osprey/port/devmnt.c os/osprey/port/devpipe.c \
	os/osprey/port/devsrv.c $P/dev9ploop.c $P/p9file.c $P/p9srv.c \
	$P/p9buddy.c $P/devlfs.c $P/pipfsrv.c $P/p9ip.c $P/p9sched.c \
	$P/p9kbd.c $P/p9input.c $P/p9cursor.c $P/devcache.c $P/devtime.c \
	$P/devnote.c $P/devinput.c $P/devdup.c $P/p9proc.c $P/p9syscall.c \
	$P/drawpool.c os/osprey/port/netif.c os/osprey/port/parse.c \
	os/osprey/ip/ip.c os/osprey/ip/ipaux.c os/osprey/ip/iproute.c \
	os/osprey/ip/ipifc.c os/osprey/ip/netlog.c os/osprey/ip/ipmux.c \
	os/osprey/ip/arp.c os/osprey/ip/icmp.c os/osprey/ip/icmp6.c \
	os/osprey/ip/igmp.c os/osprey/ip/ipv6.c os/osprey/ip/tcp.c \
	os/osprey/ip/udp.c os/osprey/ip/rudp.c os/osprey/ip/il.c \
	os/osprey/ip/gre.c os/osprey/ip/devip.c os/osprey/ip/inferno.c \
	os/osprey/ip/loopbackmedium.c os/osprey/ip/ospreymedium.c \
	os/osprey/ip/ospreyvnetmedium.c os/osprey/ip/netdevmedium.c \
	os/osprey/ip/nullmedium.c os/osprey/ip/pktmedium.c \
	os/osprey/ip/chandial.c; do
	o="$TMP/$(echo $f | tr / _ | sed 's/\.c$/.8/')"
	8c $INC -o "$o" "$f"
	OBJ="$OBJ $o"
done

# this object type's Linux and legacy answer, which is that it has none
8c $INC -o "$TMP/p9linuxfile.8" $P/p9linuxfile-386.c
OBJ="$OBJ $TMP/p9linuxfile.8"

# the draw device's two libraries, prefixed because libmemdraw/draw.c
# and libmemlayer/draw.c share a basename, as do line.c, load.c,
# unload.c and warp.c
for f in 9front/src/libmemdraw/*.c; do
	case $f in *mkcmap.c) continue ;; esac
	8c $INC -o "$TMP/md_$(basename $f .c).8" "$f"
	OBJ="$OBJ $TMP/md_$(basename $f .c).8"
done
for f in 9front/src/libmemlayer/*.c; do
	8c $INC -o "$TMP/ml_$(basename $f .c).8" "$f"
	OBJ="$OBJ $TMP/ml_$(basename $f .c).8"
done
8c -I os/osprey/cmd/draw $INC -o "$TMP/devdrawp9.8" $P/devdrawp9.c
OBJ="$OBJ $TMP/devdrawp9.8"
for f in bytesperline chan badrect icossin icossin2 arith computil defont rectclip drawrepl fmt; do
	8c $INC -o "$TMP/ld_$f.8" 9front/src/libdraw/$f.c
	OBJ="$OBJ $TMP/ld_$f.8"
done

# the pool the image memory is carved with, and the ip helpers
8c $INC -o "$TMP/pool.8" os/osprey/kernlib/pool.c
OBJ="$OBJ $TMP/pool.8"
for f in parseip ptclbsum ipaux classmask eipfmt; do
	8c $LIBINC -o "$TMP/k_$f.8" os/osprey/kernlib/$f.c
	OBJ="$OBJ $TMP/k_$f.8"
done

# the pieces compiled against the user headers rather than the name
# space's, as build.sh explains for each
for f in ring9p p9pairsrv drawscreen blkvirtio netvirtio; do
	8c $LIBINC -o "$TMP/u_$f.8" $P/$f.c
	OBJ="$OBJ $TMP/u_$f.8"
done
8c $LIBINC -I $K -o "$TMP/p9exec.8" $P/p9exec.c	# the images are generated there
OBJ="$OBJ $TMP/p9exec.8"
8a -o "$TMP/xcall.8" $P/xcall-386.s
OBJ="$OBJ $TMP/xcall.8"

# libc members the linker cannot read out of an archive, from lib9
SUP=""
for m in utfnlen convM2D convD2M convS2M convM2S fcallfmt vsnprint dofmt vfprint fmtquote runestrlen; do
	8c $LIBINC -o "$TMP/sup_$m.8" lib9/$m.c
	SUP="$SUP $TMP/sup_$m.8"
done

8l -l -R4096 -T 0x40000020 -o "$TMP/p9lib" $OBJ $SUP "$LIBSRC/libc9.a"
echo "built $TMP/p9lib"

python3 - "$ROOT/$K/p9prog.i" "$TMP/p9lib" <<'PY'
import sys
data=open(sys.argv[2],'rb').read()
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
