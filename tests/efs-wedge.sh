#!/dis/sh
# A full efs could not be emptied.  Fixed; this is the test that holds it.
#
# efs is copy on write, and Fs.free gives a block back to the NEXT
# commit, not to this one -- deliberately, because clearing it now would
# let the transaction hand out a block the tree it falls back to still
# points at.  The consequence is that a delete must ALLOCATE in order to
# commit.  On a filesystem with no free blocks it cannot, so rm fails
# with "filesystem is full" and there is no way back: nothing can be
# deleted, so nothing can ever be created again.
#
# BEFORE the reserve landed, measured on 2026-09-30 on host emu with a
# 64-block (256KiB) image holding 41-byte files, of which 44 fit:
#
#	fill to 40 files	rm OK
#	fill to 41 files	rm OK
#	fill to 42 files	rm OK
#	fill to 43 files	rm OK
#	fill to 44 files	rm FAILS
#	fill to 45 (full)	rm FAILS twice, create after also FAILS
#
#	45 small files (full)	 rm FAILS, rm FAILS, create FAILS, 45 left
#	39 small files (control) rm OK, rm OK, 37 left, create OK
#	5-block file + 41 small	 rm of the big file FAILS, 42 left
#
# Deletes stopped working about one file before the filesystem was
# genuinely full, and past that point the image was wedged for good.  The
# near-full arm is the control, and it is what makes that the full state
# breaking delete rather than delete being broken.  Nor did deleting a
# LARGER file help, which is the arm that matters, since a filesystem is
# usually full on account of large files: removing a 20480-byte file is
# five extents and so five copy-on-write path rewrites inside one
# transaction, and at full it failed exactly as the small ones did.
#
# AFTER the reserve and the part-way commit, the same script:
#
#	fills to 39 files	 rm OK, rm OK, 37 left, create after OK
#	near-full control	 unchanged
#	5-block file + 41 small	 rm of the big file OK, 35 left
#
# Fewer files fit, which is the price: Fs.reserve holds an eighth of the
# filesystem back, capped at Nreserve and floored at four, so that a
# delete always has room to commit.  disk/efsck calls such an image clean
# both before and after a tight delete, with the same count of
# pendingfree blocks unreached, so nothing is corrupted and nothing
# leaks; and tests/efs-crash.sh still mounts clean and whole at all 40 of
# its crash points.
#
# Verified on silicon too, on a Pi 3B booted from the card, against a
# 64-block image made on /n/efs and mounted at /n/efscrash: the fill
# stopped at f40, so 39 files fit exactly as on the host, 21 creates were
# refused with "filesystem is full", and then two rm's and a create all
# succeeded.
#
# What this does NOT do is cure an image already wedged.  At zero free
# blocks rm still cannot allocate, so such an image has to be remade.
#
# Run as: emu -pheap=256M -r<tree> /dis/sh.dis /tests/efs-wedge.sh
load std

T=/tmp

#
# The mountpoints are created here, not assumed.
#
# Everything under n/ in this tree is UNTRACKED -- git holds no empty
# directories and nothing generates them -- so a fresh clone has no
# /n/x, /n/client or /n/t at all, and a test that binds onto one fails
# with "'/n/x' does not exist" for a reason that has nothing to do with
# what it is testing.  Three other test scripts in this directory fail
# exactly that way today.
#
or {mkdir -p /n/client} {echo -n}
or {mkdir -p /n/t} {echo -n}
or {mkdir -p /n/x} {echo -n}
echo seed > $T/seed
# a file of many extents, for the arm that matters most: a filesystem is
# usually full because of large files, and deleting one of those costs a
# path rewrite per extent, all within one transaction.
cat $T/seed $T/seed $T/seed $T/seed > $T/big1
cat $T/big1 $T/big1 $T/big1 $T/big1 > $T/big2
cat $T/big2 $T/big2 $T/big2 $T/big2 > $T/big3
cat $T/big3 $T/big3 $T/big3 $T/big3 > $T/big4
cat $T/big4 $T/big4 $T/big4 $T/big4 > $T/big5
cat $T/big5 $T/big5 $T/big5 $T/big5 > $T/big

# $1/$2 are copied into d/n first: a nested {} block in this sh does not
# see the enclosing fn's positional arguments, and the loop silently does
# nothing if it reads $1 directly.
fn fill {
	d=$1
	n=$2
	for i in `{seq 1 $n} { or {cp $T/seed $d/f^$i} {echo -n} }
}

echo '=== full: 45 small files into an image that holds 44'
disk/mkefs -n 64 $T/efswedge.img
disk/efs -f $T/efswedge.img /n/client
fill /n/client 45
echo '   entries' `{ls /n/client | wc -l}
or {and {rm /n/client/f3} {echo '   rm-on-full OK'}} {echo '   rm-on-full FAILS'}
or {and {rm /n/client/f4} {echo '   rm-again OK'}} {echo '   rm-again FAILS'}
echo '   entries left' `{ls /n/client | wc -l}
or {and {cp $T/seed /n/client/afterrm} {echo '   create-after-rm OK'}} {echo '   create-after-rm FAILS'}

echo '=== near-full control: 39 of the 44'
disk/mkefs -n 64 $T/efsnear.img
disk/efs -f $T/efsnear.img /n/t
fill /n/t 39
echo '   entries' `{ls /n/t | wc -l}
or {and {rm /n/t/f3} {echo '   rm-on-nearfull OK'}} {echo '   rm-on-nearfull FAILS'}
or {and {rm /n/t/f4} {echo '   rm-again OK'}} {echo '   rm-again FAILS'}
echo '   entries left' `{ls /n/t | wc -l}
or {and {cp $T/seed /n/t/afterrm} {echo '   create-after-rm OK'}} {echo '   create-after-rm FAILS'}

echo '=== a many-extent file, deleted at full'
disk/mkefs -n 64 $T/efsbig.img
disk/efs -f $T/efsbig.img /n/x
or {cp $T/big /n/x/big} {echo '   the big file did not fit whole'}
echo '   big is' `{ls -l /n/x/big} 
fill /n/x 45
echo '   entries' `{ls /n/x | wc -l}
or {and {rm /n/x/big} {echo '   rm-big-on-full OK'}} {echo '   rm-big-on-full FAILS'}
echo '   entries left' `{ls /n/x | wc -l}

echo EFS-WEDGE-DONE
