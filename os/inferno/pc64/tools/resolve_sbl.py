#!/usr/bin/env python3
"""
Resolve Dis instruction indices to source file:line using a .sbl file
(limbo/sbl.c's own format, mirrored here). ninst entries after the
header, in order; entry K (0-indexed) is Dis PC index K -- INOOP
instructions are skipped by the compiler before final code generation,
so the .sbl file's entries already line up 1:1 with the linked .dis
module's real PC indices.

Format per entry (see limbo/sbl.c:sblsrcconv/sblinst):
    [SF:][SL.]SPOS,[EF:][EL.]EPOS BLOCKID
SF/EF (source/end file index) and SL/EL (source/end line) are only
printed when they differ from running state (SF from the previous
entry's end file; SL from the previous entry's end line; EF from this
entry's own start file; EL from this entry's own start line).

Usage: python3 resolve_sbl.py <path.sbl> <inst-index> [inst-index ...]
"""
import sys, re

ENTRY_RE = re.compile(
    r'^(?:(\d+):)?(?:(\d+)\.)?(\d+),(?:(\d+):)?(?:(\d+)\.)?(\d+) (\d+)$'
)

def load_sbl(path):
    with open(path) as f:
        lines = f.read().split('\n')
    idx = 0
    assert lines[idx].startswith('limbo .sbl'), lines[idx]
    idx += 1
    modname = lines[idx]; idx += 1
    nfiles = int(lines[idx]); idx += 1
    files = []
    for i in range(nfiles):
        files.append(lines[idx]); idx += 1
    ninst = int(lines[idx]); idx += 1

    entries = []
    lastf = 0
    lastline = 0
    for i in range(ninst):
        line = lines[idx]; idx += 1
        m = ENTRY_RE.match(line)
        if not m:
            raise RuntimeError(f"entry {i}: can't parse {line!r}")
        sf, sl, spos, ef, el, epos, blockid = m.groups()
        startf = int(sf) if sf is not None else lastf
        startl = int(sl) if sl is not None else lastline
        stopf = int(ef) if ef is not None else startf
        stopl = int(el) if el is not None else startl
        entries.append((startf, startl, int(spos), stopf, stopl, int(epos), int(blockid)))
        lastf = stopf
        lastline = stopl
    return modname, files, entries

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    modname, files, entries = load_sbl(sys.argv[1])
    print(f"module {modname}, {len(files)} files, {len(entries)} instructions")
    for i, fn in enumerate(files):
        print(f"  file {i}: {fn}")
    for a in sys.argv[2:]:
        k = int(a)
        if k < 0 or k >= len(entries):
            print(f"inst {k} -> out of range (0..{len(entries)-1})")
            continue
        startf, startl, spos, stopf, stopl, epos, blockid = entries[k]
        print(f"inst {k} -> {files[startf]}:{startl} col {spos}"
              f"  (stop {files[stopf]}:{stopl} col {epos})  block {blockid}")
