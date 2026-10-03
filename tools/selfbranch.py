#
# Find AArch64 B.cond instructions with imm19 == 0 -- a branch to itself --
# in a kernel, and say which function each is in.
#
# The executable-PT_LOAD filter is NOT enough on an Inferno kernel.  This
# one embeds instruction-template tables in its text segment: a pointer
# table followed by 8-byte entries whose first word is an encoding like
# 0x5400000c (B.GT) or 0xd63f0080 (BLR).  Those match the pattern and are
# data, and they produced six false positives before this filter existed.
#
# The discriminator is the symbol table: a hit must sit within Maxfn bytes
# after a text symbol.  Code lives inside functions; these tables sit in a
# 29KB unsymbolised gap, so "which function is it in" separates them
# exactly.  A hit reported with a symbol and a small offset is worth
# chasing; one that cannot be placed in a function is data.
#
import struct, subprocess, sys

Maxfn = 8192		# no function in this kernel is bigger

def textsyms(path):
    nm = '/Users/npe/src/inferno64-branches/raspi3b-port/MacOSX/arm64/bin/inm'
    out = subprocess.run([nm, '-n', path], capture_output=True, text=True).stdout
    s = []
    for L in out.split('\n'):
        p = L.split()
        if len(p) >= 3 and p[1] in 'Tt':
            try: s.append((int(p[0], 16), p[2]))
            except ValueError: pass
    s.sort()
    return s

def place(syms, a):
    lo, hi = 0, len(syms)
    while lo < hi:
        m = (lo + hi) // 2
        if syms[m][0] <= a: lo = m + 1
        else: hi = m
    if lo == 0: return None
    v, n = syms[lo-1]
    if a - v > Maxfn: return None
    nxt = syms[lo][0] if lo < len(syms) else None
    if nxt is not None and a >= nxt: return None
    return (n, a - v)

def scan(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2:
        return None, None
    #
    # AArch64 ONLY.  0x54000000 is B.cond on this architecture and
    # nothing in particular on any other, so scanning a riscv kernel for
    # it finds nothing and reports "clean" -- a false reassurance, which
    # is worse than skipping it.  EM_AARCH64 is 183.
    #
    machine, = struct.unpack_from('<H', d, 0x12)
    if machine != 183:
        return None, None
    phoff, = struct.unpack_from('<Q', d, 0x20)
    phentsize, phnum = struct.unpack_from('<HH', d, 0x36)
    segs = []
    for i in range(phnum):
        o = phoff + i*phentsize
        t, fl = struct.unpack_from('<II', d, o)
        off, va = struct.unpack_from('<QQ', d, o+0x08)
        fsz, = struct.unpack_from('<Q', d, o+0x20)
        if t == 1 and (fl & 1):
            segs.append((off, va, fsz))
    raw, placed = [], []
    syms = textsyms(path)
    for off, va, fsz in segs:
        for p in range(off, off+fsz-3, 4):
            w, = struct.unpack_from('<I', d, p)
            if (w & 0xff000010) == 0x54000000 and ((w >> 5) & 0x7ffff) == 0:
                a = va + (p - off)
                raw.append((a, w))
                q = place(syms, a)
                if q: placed.append((a, w, q[0], q[1]))
    return raw, placed

for f in sys.argv[1:]:
    raw, placed = scan(f)
    if raw is None:
        print("%s: not a 64-bit ELF" % f); continue
    print("%s:" % f)
    print("   %d pattern matches in executable segments" % len(raw))
    print("   %d of them inside a function:" % len(placed))
    for a, w, n, o in placed:
        print("      %#x  %#010x  %s+%d" % (a, w, n, o))
