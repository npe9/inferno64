#
# The size of an I/O buffer in this tree, for a Dis word of four bytes.
# A Dis word follows the size of a pointer, so DISWORD=8 means a
# machine and DISWORD=4 means a board -- see mkfiles/mkdis and the note
# in mkconfig.  bufio(2) gives every open Iobuf one of these, and cat(1)
# and anything else that reads a file in chunks takes its buffer from
# the same number.
#
# 512, which is what the original Unix used: BSIZE in the V6 and V7
# buffer cache and BUFSIZ in V7 stdio, both one disk sector.  Plan 9's
# 8192 is the right answer for a machine with memory to spare and the
# wrong one for os/inferno/stm32f407, where a buffer this size is the
# largest single thing the Dis heap is ever asked for and the heap has
# to find it in one piece: 192K in three disjoint banks, the largest
# contiguous run 104K after the kernel, and no allocation able to span
# the gaps.
#
# Measured on that board from #c/memory, heap in use at the prompt and
# its peak over cat(1), ls(1) of /dev and cat(1) again:
#
#	8192	could not run the sequence at all
#	4096	50944 at the prompt, peak 67904
#	 512	47360 at the prompt, peak 60800
#
# The cost is a read(2) per 512 bytes of file rather than per 8192, and
# on these boards a read comes from a root filesystem that is already
# in the address space.
#
Bufsize:	con 512;
