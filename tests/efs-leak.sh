#!/dis/sh
# efs's heap cost per operation grows with the size of the FILESYSTEM.
#
# The measurement is `cat /dev/memory`, whose heap row is
#	cursize maxsize hw nalloc nfree nbrk poolmax name
# The figure to take is nalloc per operation.  Live blocks (nalloc-nfree)
# are NOT the measure: the same arm gave 94 live per operation in one emu
# and 858 in another, nine times apart, because live counts whatever the
# collector has not got to yet.  nalloc per operation reproduces across
# runs to about two per cent.  cursize is not a measure either -- the
# pool both grows and shrinks.
#
# Four arms, because one cannot tell efs from the plumbing it is mounted
# through.  memfs is a Dis Styx server reached by the same mount, so it
# holds the mount, devmnt and served-program paths fixed and varies only
# the server.
#
# Measured on 2026-09-30 (host emu, -pheap=256M), 240 rewrites of one
# existing file -- no new names, no new inodes, nothing added:
#				this test   measured alone
#	memfs  1 entry		 151.4	     151.5
#	memfs 60 entries	 151.7	     151.5	flat
#	efs    1 entry		 323.6	     323.5
#	efs   60 entries	1439.3	    1442.5	4.5 times
#
# memfs does not care how many files exist; efs does.  Everything but the
# server is identical, so that term is efs's.  At one entry the two are
# within a factor of two, which is why a test on a near-empty image could
# not have found it.
#
# It is the whole filesystem, not the directory written to.  A separate
# run held the written file's parent at two entries and grew a
# SUBDIRECTORY instead:
#	fs 2 entries		 348.7	     328.5
#	fs 62 entries		1386.9	    1370.7
#	fs 242 entries		2000.8	    1988.4
# The parent never changed, so the cost is not the directory's size.  The
# arms cross-check: sixty entries in the parent gave 1439.3, sixty-two
# with a two-entry parent 1386.9.  And every arm reproduces between a run
# of this whole script and a run of that arm alone, within six per cent --
# which is the reason to quote nalloc and not live blocks.
#
# And it is NOT an unreclaimable leak.  In the 242-entry arm live blocks
# FELL during the 240 operations, 952256 to 417297 -- half a million
# reclaimed.  What exhausts the heap is the collector not keeping up with
# an allocation rate that grows with the filesystem, so the ceiling is
# the high-water of uncollected garbage.  That is also why 300 creates
# showed a 132.6MB pool for a 4MB image: backlog, not representation.
# It agrees with tests/efs-stress.sh's reading that a falling census was
# a collector reclaiming rather than a leak.
#
# Where the term is NOT: Fs.cblk/cnode is bounded by Ncache and cleared
# at commit; Fs.groups caps at Maxgroups*4096 = 2MB; Fs.freed is emptied
# by commit.  Reads cost about what writes do, so it is in the path both
# share.  Which allocation it is has NOT been established -- the obvious
# reading of the code said the directory, and measurement said no.
#
# Run as: emu -pheap=256M -r<tree> /dis/sh.dis /tests/efs-leak.sh
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
or {mkdir -p /n/x} {echo -n}
or {mkdir -p /n/client} {echo -n}
or {mkdir -p /n/t} {echo -n}

fn marks {
	echo MARK-$1
	cat /dev/memory
}

fn arm {
	for i in `{seq 1 240} { echo payload > $1/one }
}

echo '=== memfs: the same mount path, a different server'
memfs /n/x
echo payload > /n/x/one
marks memfs-1entry-base
arm /n/x
marks memfs-1entry-240rewrites
for i in `{seq 2 60} { echo payload > /n/x/f^$i }
marks memfs-60entries-base
arm /n/x
marks memfs-60entries-240rewrites

echo '=== efs'
disk/mkefs -n 1024 $T/efsleak.img
disk/efs -f $T/efsleak.img /n/client
echo payload > /n/client/one
marks efs-1entry-base
arm /n/client
marks efs-1entry-240rewrites
for i in `{seq 2 60} { echo payload > /n/client/f^$i }
marks efs-60entries-base
arm /n/client
marks efs-60entries-240rewrites

#
# The parent held fixed while the filesystem grows, which is what shows
# the term is the filesystem's size and not the directory's.  Everything
# written goes to /n/client/one, whose parent -- the root -- holds two
# entries throughout; the files pile up in sub.
#
echo '=== efs with the parent fixed at two entries'
disk/mkefs -n 4096 $T/efstree.img
disk/efs -f $T/efstree.img /n/t
mkdir /n/t/sub
echo payload > /n/t/one
marks efs-fs2-base
arm /n/t
marks efs-fs2-240rewrites
for i in `{seq 1 60} { echo payload > /n/t/sub/f^$i }
marks efs-fs62-base
arm /n/t
marks efs-fs62-240rewrites
for i in `{seq 61 240} { echo payload > /n/t/sub/f^$i }
marks efs-fs242-base
arm /n/t
marks efs-fs242-240rewrites

echo EFS-LEAK-DONE
