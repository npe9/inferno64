#!/usr/bin/env python3
#
# Resolve kernel addresses to function names, for a kernel that has no
# symbol table.
#
# WHY THIS EXISTS.  The armv7m kernels link with -H4, and utils/tl's
# asm.c forces debug['s'] for that header type, so the image carries no
# symbols at all.  Every fault this board reports is therefore a bare
# address -- "usage fault pc 0806db5a", "bus fault pc 0804e5a6" -- and
# three separate hunts in one session stalled on not being able to name
# one.  inm cannot read the image either.
#
# HOW.  Relink the same objects with -H2, which keeps the symbol table,
# and parse it.  The two links place text at the same addresses: the
# code is byte-identical and only 56 bytes differ in the first 64K,
# all of them two-byte literal-pool entries holding data addresses that
# moved.  So a symbol from the -H2 link names the right function in the
# -H4 image.  Verified by comparing the text of both.
#
# The format is a plain Plan 9 a.out (utils/libmach/sym.c): a 32-byte
# big-endian header of magic, text, data, bss, syms, entry, spsz, pcsz,
# then text, then data, then the symbol table.  Each symbol is a 4-byte
# big-endian value, a type byte, and a name -- NUL-terminated when 0x80
# is set in the type, otherwise 8 bytes plus 3 of padding.  Types 'z'
# and 'Z' are source-history entries whose "name" is a run of 2-byte
# pairs ending in two zeros, and they are skipped.
#
#	ksym.py <conf> <addr> ...
#
# e.g.  ksym.py stm32f407auth 0x08033561 0x08022091
#
# It does the relink itself, into a temporary file, so the kernel that
# was flashed is not touched -- relinking in place would change the
# build stamp and disarm every tool that checks it.
#
# AND THE BUILD HAS TO MATCH.  This relinks whatever objects are in the
# tree NOW, so an address from yesterday's console resolved against
# today's objects names the wrong function -- quietly, and plausibly.
# Two runs minutes apart here moved every address by 0xc8 because one
# file had grown.  Resolve against the build that produced the address,
# or not at all.
#
# A WARNING THE HARD WAY.  A name is not a call chain.  The first use of
# this resolved a register holding "poolaudit+0xad" and it looked like a
# diagnosis; poolaudit has NO callers in the kernel -- only emu's
# devmem calls it -- so the register held a stale value from earlier
# code.  Resolve addresses, then check that the function can actually be
# reached from where you think it was.
#
import bisect, os, re, struct, subprocess, sys, tempfile

def relink(conf):
    root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True).stdout.strip()
    bd = os.path.join(root, "os/inferno/stm32f407")
    n = subprocess.run(["mk", "-n", "CONF=" + conf,
                        "INIT=armv7mstyx", "i" + conf],
                       cwd=bd, capture_output=True, text=True).stdout
    line = next((l for l in n.splitlines() if l.startswith("tl ")), None)
    if line is None:
        sys.exit("ksym: mk -n printed no tl line for conf %s; build it first"
                 % conf)
    out = tempfile.NamedTemporaryFile(suffix=".sym", delete=False).name
    line = line.replace("-o i" + conf, "-o " + out).replace("-H4", "-H2")
    r = subprocess.run(["sh", "-c", line], cwd=bd,
                       capture_output=True, text=True)
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        sys.exit("ksym: relink produced nothing: " + (r.stderr or r.stdout))
    return out

def symbols(path):
    d = open(path, "rb").read()
    magic, text, data, bss, syms = struct.unpack(">5I", d[:20])
    blob = d[32 + text + data: 32 + text + data + syms]
    out, i = [], 0
    while i + 5 <= len(blob):
        val = struct.unpack(">I", blob[i:i+4])[0]
        t = blob[i+4]
        i += 5
        if not (t & 0x80):                      # fixed-length name
            out.append((val, chr(t), blob[i:i+8].split(b"\0")[0]
                        .decode("latin1")))
            i += 11
            continue
        t &= 0x7f
        if chr(t) in "zZ":                      # source history, skipped
            j = i + 1
            while j + 1 < len(blob) and not (blob[j] == 0 and blob[j+1] == 0):
                j += 2
            i = j + 2
            continue
        j = blob.index(b"\0", i)
        out.append((val, chr(t), blob[i:j].decode("latin1")))
        i = j + 1
    return out

def main():
    if len(sys.argv) < 3:
        sys.exit("usage: ksym.py <conf> <addr> ...")
    conf = sys.argv[1]
    syms = symbols(relink(conf))
    # T and t are text, L and l are leaf functions; data symbols would
    # make a nearest-preceding lookup answer with a table for a code
    # address, which is worse than refusing.
    txt = sorted((v, n) for v, c, n in syms if c in "TtLl")
    addrs = [v for v, _ in txt]
    data = sorted((v, n) for v, c, n in syms if c in "DdBb")
    daddrs = [v for v, _ in data]
    print("%d text symbols, %d data" % (len(txt), len(data)))
    for a in sys.argv[2:]:
        x = int(a, 0)
        k = bisect.bisect_right(addrs, x) - 1
        if k < 0:
            print("%#010x  before the first text symbol" % x)
            continue
        v, n = txt[k]
        nxt = addrs[k+1] if k+1 < len(addrs) else None
        if nxt is not None and x >= nxt:
            print("%#010x  past %s, not in any function" % (x, n))
            continue
        print("%#010x  %s+%#x" % (x, n, x - v))

main()
