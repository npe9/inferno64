#!/usr/bin/env python3
"""
Resolve native PCs against a pc64 ipc64 kernel binary's own symbol table.

ipc64 is a Plan9 "fat header" a.out image (HEADTYPE=2, magic|0x8000, per
utils/6l/asm.c).  inm/acid both report "no symbol information" against it
(header-cracking works for ksize's txt/dat/bss but not for symbols, cause
not tracked down) so this parses the symbol table directly out of the file.

Format (from utils/6l/span.c's putsymb(), HEADTYPE==2 case): each entry is
an 8-byte big-endian value, a 1-byte (type-char | 0x80), then either a
null-terminated ASCII name (most types) or, for 'Z'/'z' (source-file line
tables), a leading byte followed by 2-byte pairs terminated by 0x0000 --
NOT ASCII, must be parsed with the pair-terminator rule or the whole rest
of the table desyncs.

Table start = 9 bytes before the *third* occurrence of b"etext\\x00" in the
file (the first two are false positives inside unrelated embedded debug
strings, e.g. "...Key.safe" paths) -- asmsym() always writes etext first.

IMPORTANT: this must be re-run against whichever ipc64 build produced the
capture being resolved -- addresses shift across rebuilds, even ones that
look unrelated to the crash path.  Do not resolve an old capture's pc
against a newer binary.

Usage: python3 resolve_ipc64_syms.py <path-to-ipc64> <hex-addr> [hex-addr ...]
"""
import struct, bisect, sys

def load_symtab(path):
    data = open(path, "rb").read()
    idx = -1
    seen = 0
    target = None
    while True:
        idx = data.find(b"etext\x00", idx + 1)
        if idx == -1:
            break
        seen += 1
        if seen == 3:
            target = idx
            break
    if target is None:
        raise RuntimeError("could not find etext symbol table anchor")
    pos = target - 9
    syms = []
    while pos < len(data) - 9:
        val = struct.unpack(">Q", data[pos:pos+8])[0]
        tb = data[pos+8]
        if tb < 0x80:
            break
        t = chr(tb - 0x80)
        pos += 9
        if t in ("Z", "z"):
            pos += 1
            while True:
                pair = data[pos:pos+2]
                pos += 2
                if pair == b"\x00\x00":
                    break
            syms.append((val, t, "<lineinfo>"))
        else:
            end = data.find(b"\x00", pos)
            name = data[pos:end]
            pos = end + 1
            syms.append((val, t, name.decode("ascii", "replace")))
    return syms

def resolve_all(syms):
    Tsyms = sorted((v, n) for v, t, n in syms if t == "T")
    addrs = [v for v, n in Tsyms]
    names = [n for v, n in Tsyms]
    def resolve(addr):
        i = bisect.bisect_right(addrs, addr) - 1
        if i < 0:
            return None
        return (names[i], addr - addrs[i], addrs[i])
    return resolve

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    syms = load_symtab(sys.argv[1])
    resolve = resolve_all(syms)
    print(f"parsed {len(syms)} symbol-table entries from {sys.argv[1]}")
    for a in sys.argv[2:]:
        addr = int(a, 16)
        r = resolve(addr)
        if r is None:
            print(f"{a} -> unresolved")
        else:
            name, off, base = r
            print(f"{a} -> {name}+{off} (base {hex(base)})")
