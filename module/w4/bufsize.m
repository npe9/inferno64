#
# The buffer every open Iobuf carries, for a Dis word of four bytes:
# in this tree that means a board, and the boards are small.  A Dis
# word follows the size of a pointer, so DISWORD=4 and "not much RAM"
# are the same set here -- see mkfiles/mkdis and the note in mkconfig.
#
# 512, which is what the original Unix used: BSIZE in the V6 and V7
# buffer cache and BUFSIZ in V7 stdio, both one disk sector.  Plan 9's
# 8192 is the right answer for a machine with memory to spare and the
# wrong one for os/inferno/stm32f407, where this array is the largest
# single thing the Dis heap is ever asked for and the heap has to find
# it in one piece: 192K in three disjoint banks, the largest contiguous
# run 104K after the kernel, and no allocation able to span the gaps.
#
# Measured on that board, from #c/memory, over cat(1) then ls(1) of
# /dev and cat(1) again:
#
#	8192   the heap could not do it at all
#	4096   heap 50944 at the prompt, peak 67904
#	 512   heap 47360 at the prompt, peak 60800
#
# The cost is one read(2) per 512 bytes of file rather than per 8192,
# and on these boards a read is from a root filesystem that is already
# in the address space.
#
Bufsize:	con 512;
