#!/usr/bin/env python3
#
# p9sym.py -- resolve kernel PCs to symbols in a Plan 9 a.out.
#
# Written because inm(1) prints nothing for this tree's kernels: nm's
# execsyms() ignores a syminit() failure silently, so a kernel whose
# symbol table it cannot read looks identical to one with no symbols.
# Every capture this branch's corruption hunt has taken carries pcs that
# nobody could read; this reads them.
#
# The two things a hand-written reader gets wrong, both taken from
# libmach's own syminit()/decodename() (utils/libmach/sym.c):
#
#   * symbol values are 8 bytes when the magic has HDR_MAGIC, which
#     amd64's S_MAGIC (0x8a97) does.  Reading them as 4 loses most of
#     the table and leaves plausible-looking wrong answers.
#   * a type byte without 0x80 means an old-style fixed-length name
#     (NNAME bytes then skip 3), and type 'z'/'Z' names are a byte then
#     16-bit pairs ending 00 00, not NUL-terminated strings.  Assuming
#     NUL-terminated desyncs the whole table.
#
# The header is 40 bytes for amd64 (libmach's sizeof(Exec)+8), which is
# confirmable: with 40 the symbol table is consumed exactly, with 32
# there are 3 bytes left over.
#
# usage: p9sym.py kernel pc...        (pcs in hex, with or without 0x)
#        p9sym.py kernel < capture    (reads pcs from stdin text)
#
import sys, struct, bisect, re

NNAME = 8

def symbols(path):
	d = open(path, 'rb').read()
	text, data = struct.unpack('>I', d[4:8])[0], struct.unpack('>I', d[8:12])[0]
	syms, entry = struct.unpack('>I', d[16:20])[0], struct.unpack('>I', d[20:24])[0]
	st = d[40+text+data:][:syms]
	out, i = [], 0
	while i + 9 <= len(st):
		val = int.from_bytes(st[i:i+8], 'big'); i += 8
		t = st[i]; i += 1
		if (t & 0x80) == 0:			# old style, fixed-length name
			name = st[i:i+NNAME].split(b'\0')[0].decode('latin1', 'replace')
			i += NNAME + 3
			typ = chr(t)
		else:
			typ = chr(t & ~0x80)
			if typ in 'zZ':			# file name: 16-bit pairs to 00 00
				i += 1
				while i + 2 <= len(st) and st[i:i+2] != b'\0\0':
					i += 2
				i += 2
				continue
			j = st.find(b'\0', i)
			if j < 0:
				break
			name = st[i:j].decode('latin1', 'replace'); i = j + 1
		if typ in 'Tt' and entry <= val < entry + text:
			out.append((val, name))
	out.sort()
	return out

def main():
	if len(sys.argv) < 2:
		sys.exit("usage: p9sym.py kernel [pc...]")
	fns = symbols(sys.argv[1])
	if not fns:
		sys.exit("p9sym: no text symbols -- is %s stripped?" % sys.argv[1])
	addrs = [a for a, _ in fns]
	print("# %d text symbols, %#x..%#x" % (len(fns), fns[0][0], fns[-1][0]), file=sys.stderr)
	pcs = sys.argv[2:]
	if not pcs:
		pcs = re.findall(r'(?:pc=)?0x([0-9a-f]{5,16})', sys.stdin.read())
	for s in pcs:
		a = int(s, 16)
		k = bisect.bisect_right(addrs, a) - 1
		if k < 0:
			print("%#x -> ?" % a)
		else:
			print("%#x -> %s+%#x" % (a, fns[k][1], a - fns[k][0]))

if __name__ == '__main__':
	main()
