#!/dis/sh
# A full efs cannot be emptied.
#
# efs is copy on write, and Fs.free gives a block back to the NEXT
# commit, not to this one -- deliberately, because clearing it now would
# let the transaction hand out a block the tree it falls back to still
# points at.  The consequence is that a delete must ALLOCATE in order to
# commit.  On a filesystem with no free blocks it cannot, so rm fails
# with "filesystem is full" and there is no way back: nothing can be
# deleted, so nothing can ever be created again.
#
# Measured on 2026-09-30, host emu, a 64-block (256KiB) image holding
# 41-byte files, of which 44 fit:
#
#	fill to 40 files   rm OK
#	fill to 41 files   rm OK
#	fill to 42 files   rm OK
#	fill to 43 files   rm OK
#	fill to 44 files   rm FAILS
#	fill to 45 (full)  rm FAILS twice, and a create after also fails
#
# So deletes stop working about one file before the filesystem is
# genuinely full, and past that point the image is wedged for good.
#
# The near-full arm is the control: at 39 files rm works twice (39 -> 37)
# and a create afterwards works, so it is the full state that breaks
# delete and not delete itself.
#
# Deleting a LARGER file does not help, which is the arm that matters,
# because a filesystem is usually full on account of large files.  A
# 20480-byte file is five blocks and five extents, and removing it costs a
# copy-on-write path rewrite per extent inside one transaction; at full it
# fails exactly as the small ones do.  Three arms, as run:
#
#	45 small files (full)	rm FAILS, rm FAILS, create FAILS, 45 left
#	39 small files (control)	rm OK, rm OK, 37 left, create OK
#	5-block file + 41 small	rm of the big file FAILS, 42 left
#
# A reserve of free blocks that only deletes may use would stop a
# filesystem reaching this state.  It would not cure an image already in
# it: at zero free blocks rm still cannot allocate, so such an image has
# to be remade, not repaired by new code.
#
# Run as: emu -pheap=256M -r<tree> /dis/sh.dis /tests/efs-wedge.sh
load std

T=/tmp
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
