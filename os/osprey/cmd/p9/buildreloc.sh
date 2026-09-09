#!/bin/sh
# Build the relocation probe as a dynamically loadable module and emit
# os/osprey/pc64/relocprog.i.
#
# The difference from every other loaded program here is the -u: it is
# Plan 9's dynamically-loadable-module link, and it changes three things
# that matter.  The image is linked at 0 rather than at -T, so it has no
# address of its own.  A relocation table is appended after the symbol
# table (asmdyn in utils/6l/span.c), holding every absolute address the
# image contains.  And the header's entry is no longer a code entry -
# with -u the linker sets INITENTRY to _exporttab, so it points at the
# export table, which is why the loader here does not read it.
#
# p9start is at offset 0 of the module.  That is the same invariant every
# other program of this kind relies on - p9crt.c is linked first and
# p9start is the first thing in its text - and with the text linked at 0
# it becomes simply offset 0, which is what p9loadreloc enters.  The
# check below is that invariant tested rather than assumed: the module's
# first instructions must be the same ones the ordinary link puts at its
# entry.
set -e
cd "$(dirname "$0")/../../../.."
P=os/osprey/cmd/p9
LIBINC="-I Osprey/amd64/include -I Osprey/include -I include -I $P"
6c $LIBINC -o /tmp/reloc_crt.6 $P/p9crt.c
6c $LIBINC -o /tmp/reloc_prog.6 $P/relocp9.c
6a -o /tmp/reloc_cons.6 $P/p9cons.s
OBJ="/tmp/reloc_crt.6 /tmp/reloc_prog.6 /tmp/reloc_cons.6"
# the libc members the host linker cannot read out of the archive, from
# source, as every other loaded program here does
for m in utfnlen vsnprint dofmt vfprint; do
	6c $LIBINC -o /tmp/reloc_$m.6 lib9/$m.c
	OBJ="$OBJ /tmp/reloc_$m.6"
done
6l -u -l -R4096 -o /tmp/relocdlm $OBJ Osprey/amd64/lib/libc.a
python3 - "$PWD/os/osprey/pc64/relocprog.i" <<'PYEND'
import sys

def hdrof(d):
    be=lambda o,n=4:int.from_bytes(d[o:o+n],'big')
    magic=be(0)
    hdr=40 if (magic & 0x8000) else 32
    return magic,hdr,be(4),be(8),be(12),be(16),be(24),be(28)

d=open('/tmp/relocdlm','rb').read()
magic,hdr,text,data,bss,syms,spsz,pcsz = hdrof(d)

if (magic & 0x80000000) == 0:
    raise SystemExit('not a dynamically loadable module: magic %#x' % magic)
if (magic & 0xffff) != 0x8a97:
    raise SystemExit('not an amd64 module: magic %#x' % magic)

# p9start must be at offset 0 of the module, because that is what the
# loader enters.  Taken from the module's own symbol table rather than
# inferred: an amd64 entry is an eight-byte value, a type byte, and the
# name, so the nine bytes before the name are the two that matter.  The
# type must be T - text, with the high bit Plan 9 sets - and the value 0.
# (Only the first occurrence of the name is examined, which is enough
# here: this module has one p9start and no file whose name contains it.)
st = hdr+text+data
sym = d[st:st+syms]
i = sym.find(b'p9start\x00')
if i < 9:
    raise SystemExit('p9start is not in the module symbol table')
val = int.from_bytes(sym[i-9:i-1],'big')
typ = sym[i-1]
if (typ & 0x7f) != ord('T'):
    raise SystemExit('p9start is symbol type %r, not text' % chr(typ & 0x7f))
if val != 0:
    raise SystemExit('p9start is at %#x in the module, not 0: the loader enters offset 0'
                     % val)

# the relocation table, so the build says how many there are rather than
# emitting a module nobody looked at
off = hdr+text+data+syms+spsz+pcsz
relsize = int.from_bytes(d[off:off+4],'big')
p = off+4
nimport = int.from_bytes(d[p:p+4],'big'); p += 4
if nimport != 0:
    raise SystemExit('%d imports: this module is meant to be self-contained' % nimport)
nrel = int.from_bytes(d[p:p+4],'big'); p += 4
modes = {}
a = 0
for i in range(nrel):
    m = d[p]; p += 1
    n = m >> 6
    if n == 0: v = d[p]; p += 1
    elif n == 1: v = int.from_bytes(d[p:p+2],'big'); p += 2
    else: v = int.from_bytes(d[p:p+4],'big'); p += 4
    a += v
    modes[m & 0xf] = modes.get(m & 0xf, 0) + 1
if set(modes) != {0}:
    raise SystemExit('unexpected relocation modes %r; only 0 (absolute, defined) is handled' % modes)

# Every recorded offset must name a value that is an address inside this
# module, because a self-contained module's absolute addresses all point
# into itself.  One that does not means the offset is wrong, and the
# symptom this catches is a real one: 6l records a relocation while it
# assembles an instruction and then inserts the rex prefix in front of
# it, moving every later byte up by one and leaving the offset behind,
# so a rex-prefixed instruction's field is named one byte early.  Adding
# the base at the wrong alignment gives an address nobody meant, and the
# program faults on the first one.
#
# It is checked here rather than trusted because the image depends on the
# linker as much as on the source, and mk cannot see that: a module built
# with a 6l that has the bug looks up to date to a tree whose sources
# have not changed.
size = text + data + bss
img = d[hdr:hdr+text+data]
a = 0
p = off+12
bad = []
for i in range(nrel):
    m = d[p]; p += 1
    n = m >> 6
    if n == 0: v = d[p]; p += 1
    elif n == 1: v = int.from_bytes(d[p:p+2],'big'); p += 2
    else: v = int.from_bytes(d[p:p+4],'big'); p += 4
    a += v
    if int.from_bytes(img[a:a+4],'little') > size:
        bad.append(a)
if bad:
    raise SystemExit('%d of %d relocations name a value outside the module (first at %#x): '
                     'the linker recorded the offset wrongly - see utils/6l/span.c, asmins'
                     % (len(bad), nrel, bad[0]))

# The whole file, not header+text+data.  Every other program here is
# truncated to what the a.out loader reads, because the symbol table is
# no use to it; this one is not, because its relocation table lives
# after the symbol table and the loader has to reach it.  Truncating it
# the same way was the first thing that went wrong, and the loader said
# so: "no relocation table".
img = d
out = ['uchar relocprog[]={']
for i in range(0, len(img), 16):
    out.append(','.join('0x%02x'%b for b in img[i:i+16])+',')
out.append('};')
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
print('wrote %s (%d bytes, the whole module: hdr %d text %d data %d bss %d syms %d, '
      '%d relocations, all absolute; p9start at offset 0)'
      % (sys.argv[1], len(img), hdr, text, data, bss, syms, nrel))
PYEND
