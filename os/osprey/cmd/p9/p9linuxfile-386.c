/*
 * The boot files that are whole binaries, for 386: there are none yet.
 *
 * p9linuxfile.c beside this embeds os/osprey/pc64/linuxprog.i, which
 * buildlinux.sh makes by compiling linuxlegacy.c with clang for
 * x86_64-linux-gnu.  It is a Linux x86-64 binary and amd64 by its
 * nature; the demonstration it belongs to - an unmodified Linux
 * program answered by a buddy over the ring - is that machine's.
 *
 * So on this object type the file system simply has no /boot/linux.
 * main.c calls this unconditionally, and the honest answer to it is an
 * empty one rather than an empty program pretending to be Linux.
 *
 * p9legacyfile is the same shape and is empty for a different reason.
 * It adds the ordinary Plan 9 binaries - /boot/legacy, /boot/cat and
 * the rest - which are a second family of programs from the ten the
 * personality embeds: linked against libc and trapping, where those ten
 * are linked against p9crt.c and call the personality as a library.
 * They have build scripts of their own (buildlegacy.sh, buildcat.sh and
 * their fellows) and no 386 twins yet, so this object type's file
 * system has the library-OS programs and not the trapping ones.  The
 * point of the exercise - one source, two arrangements - is amd64's
 * until those are built.
 */
#include <u.h>
#include <libc.h>

void
p9linuxfile(void)
{
}

void
p9legacyfile(void)
{
}
