#!/usr/bin/env bash
#
# mkroot9front.sh -- fill in $ROOT/9front so it is a whole 9front
# root and not only what a compiler produces.
#
# The build puts programs and libraries under $ROOT/9front: that is
# what a deployed 9front has at /, and every install path the import
# rewrote points into it.  A root is more than that.  It also holds
# the things no compiler makes -- the fonts, the name database, the
# troff tables, the keyboard maps, the rc scripts -- and those the
# import deliberately leaves out of 9front-src, because they are
# runtime data rather than source and a copy of them in the tree
# would be 88 MB of files nothing compiles.
#
# So they are taken from an upstream checkout, here, at the moment a
# root is wanted.  The checkout is the same commit the import pins;
# give it as an argument or let this clone one.
#
# What comes from where:
#
#	9front-src/rc		the rc scripts and rcmain.  These the
#				import does bring across, because
#				they are text in the tree like any
#				other source; /rc on a 9front machine
#				is where they live and is not built.
#	upstream lib		fonts, dictionaries, the face
#				database, firmware
#	upstream sys/lib	troff and postscript tables, kbmap,
#				plumbing rules, the dist skeleton
#	the build		everything under $objtype, and what
#				the mkfiles installed into sys/lib,
#				rc/bin and acme
#
# Anything the build already installed wins: the copy is
# no-clobber, and runs after the build rather than before it, so a
# generated file is never replaced by upstream's copy of it.
#
# Usage: scripts/mkroot9front.sh [-o objtype] [upstream-checkout]

set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD

objtype=amd64
if [ "${1:-}" = "-o" ]; then objtype=$2; shift 2; fi

UPSTREAM_URL=https://github.com/9front/9front.git
UPSTREAM_BRANCH=front
UPSTREAM_COMMIT=$(/usr/bin/sed -n 's/^commit		//p' "$ROOT/9front-src/MANIFEST")

SRC=${1:-}
if [ -z "$SRC" ]; then
	SRC=$(mktemp -d)/9front
	echo "cloning $UPSTREAM_URL ($UPSTREAM_BRANCH) into $SRC"
	git clone --depth 1 --branch "$UPSTREAM_BRANCH" "$UPSTREAM_URL" "$SRC"
fi
[ -d "$SRC/lib/font" ] || { echo "$SRC is not a 9front tree" >&2; exit 1; }

DEST=$ROOT/9front

#
# The directories a root has whether or not anything has been
# installed into them yet.  /env, /dev, /proc, /net, /srv and /mnt
# are served by the kernel and by programs rather than held on disk,
# but a root that is going to be copied onto a disk wants the mount
# points to exist.
#
echo "directories"
for d in tmp env dev proc net srv mnt n usr adm cfg mail acme lib sys/lib rc/bin rc/lib; do
	mkdir -p "$DEST/$d"
done

#
# lib/firmware is named by the kernel's boot proto and is not in
# upstream's git tree: 9front ships the firmware blobs with the
# installation, not with the sources, and a build machine has them
# because it is a 9front machine.  The directory is made empty.  What
# that costs is nothing for the pc64 kernel this tree builds, whose
# only ethernet driver is etherigbe and which asks for no firmware; a
# kernel configured with etheriwl or ether4330 would want the files
# and would have to be given them.
#
mkdir -p "$DEST/lib/firmware"

echo "rc, from the imported tree"
( cd "$ROOT/9front-src/rc" && find . -type f -print ) | while IFS= read -r f; do
	[ -e "$DEST/rc/${f#./}" ] && continue
	mkdir -p "$(dirname "$DEST/rc/${f#./}")"
	cp "$ROOT/9front-src/rc/${f#./}" "$DEST/rc/${f#./}"
	chmod 775 "$DEST/rc/${f#./}"
done

for d in lib sys/lib; do
	echo "$d, from upstream"
	( cd "$SRC/$d" && find . -type f -print ) | while IFS= read -r f; do
		[ -e "$DEST/$d/${f#./}" ] && continue
		mkdir -p "$(dirname "$DEST/$d/${f#./}")"
		cp "$SRC/$d/${f#./}" "$DEST/$d/${f#./}"
	done
done

#
# The dist skeleton: what a fresh installation has under /adm, /cfg,
# /mail, /usr and /rc/bin, which upstream keeps in sys/lib/dist and
# an installer copies into place.  Same rule -- nothing already there
# is replaced.
#
echo "the dist skeleton"
for d in adm cfg mail usr rc ndb; do
	[ -d "$SRC/sys/lib/dist/$d" ] || continue
	case "$d" in
	ndb)	t=lib/ndb;;
	*)	t=$d;;
	esac
	( cd "$SRC/sys/lib/dist/$d" && find . -type f -print ) | while IFS= read -r f; do
		[ -e "$DEST/$t/${f#./}" ] && continue
		mkdir -p "$(dirname "$DEST/$t/${f#./}")"
		cp "$SRC/sys/lib/dist/$d/${f#./}" "$DEST/$t/${f#./}"
	done
done

#
# The kernel this tree builds, where a boot loader looks for it.
#
kernel=$ROOT/os/9front/pc64/9pc64
if [ -f "$kernel" ]; then
	echo "kernel"
	cp "$kernel" "$DEST/$objtype/9pc64"
else
	echo "no kernel at $kernel; build os/9front/pc64 first" >&2
fi

echo
echo "root: $DEST"
echo "files: $(find "$DEST" -type f | wc -l | tr -d ' ')"
echo "size:  $(du -sh "$DEST" | cut -f1)"
