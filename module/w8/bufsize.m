#
# The buffer every open Iobuf carries, for a Dis word of eight bytes:
# a machine with megabytes at least, and usually with gigabytes.
#
# 8192 is Sys->ATOMICIO, which is also the kernel's iounit, so a full
# buffer is exactly one read(2).  It is what Plan 9's libbio uses and
# what this was before there was anywhere for it to differ.
#
Bufsize:	con 8192;
