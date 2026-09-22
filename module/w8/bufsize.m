#
# The size of an I/O buffer in this tree, for a Dis word of eight bytes.
# A Dis word follows the size of a pointer, so DISWORD=8 means a
# machine and DISWORD=4 means a board -- see mkfiles/mkdis and the note
# in mkconfig.  bufio(2) gives every open Iobuf one of these, and cat(1)
# and anything else that reads a file in chunks takes its buffer from
# the same number.
#
# 8192 is Sys->ATOMICIO, which is also the kernel's iounit, so a full
# buffer is exactly one read(2).  It is what Plan 9's libbio uses and
# what every target in this tree used before there was anywhere for it
# to differ.
#
Bufsize:	con 8192;
