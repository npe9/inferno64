#!/usr/bin/env python3
#
# p9sym.py -- resolve kernel pcs to symbols in a Plan 9 a.out, and say
# whether each pc could actually be a pc at all.
#
# Written because inm(1) prints nothing for this tree's kernels: nm's
# execsyms() ignores a syminit() failure silently, so a kernel whose
# symbol table it cannot read looks identical to a stripped one.  Every
# pc this branch's corruption hunt captured was written down unresolved
# because of that, and the two hand-rolled readers that were tried
# instead each produced confident, wrong names.
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
# confirmable: at 40 the symbol table is consumed exactly, at 32 there
# are 3 bytes left over.
#
# The -c check is the part that matters more than the name.  A pc
# recorded by getcallerpc() is a return address, so it must be an
# instruction boundary, and the instruction ending there must be a
# call.  Neither holds for a getcallerpc() anchored on the wrong stack
# slot -- and this tree has four such sites (see os/inferno/port/alloc.c
# on D2B/D2BPC).  Such a value still resolves to a tidy name+offset,
# which is exactly how it fools a reader.  Decoding forward from the
# containing symbol's first byte answers it: interior pcs are junk.
# The check needs capstone (pip install capstone); without it the names
# still print, unchecked.
#
# usage: p9sym.py [-c] kernel pc...     (pcs in hex, with or without 0x)
#        p9sym.py [-c] kernel < capture (reads pcs from stdin text)
#
import sys, struct, bisect, re

NNAME = 8

def readsyms(path, want='Tt'):
	"""Decode the symbol table.  want is the set of type letters kept."""
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
		if typ in want:
			out.append((val, name))
	out.sort()
	return out, d, entry, text

def symbols(path):
	"""Text symbols only, sorted.  Kept for callers that just want names."""
	fns, d, entry, text = readsyms(path)
	return [(a, n) for a, n in fns if entry <= a < entry + text]

class Resolver:
	def __init__(self, path):
		fns, self.d, self.entry, self.text = readsyms(path)
		self.fns = [(a, n) for a, n in fns if self.entry <= a < self.entry + self.text]
		self.addrs = [a for a, _ in self.fns]
		self.md = None
		try:
			from capstone import Cs, CS_ARCH_X86, CS_MODE_64
			self.md = Cs(CS_ARCH_X86, CS_MODE_64)
		except ImportError:
			pass

	def name(self, pc):
		if not (self.entry <= pc < self.entry + self.text):
			return None, None, None	# not a text address at all
		k = bisect.bisect_right(self.addrs, pc) - 1
		if k < 0:
			return None, None, None
		nxt = self.addrs[k+1] if k+1 < len(self.addrs) else self.entry + self.text
		return self.fns[k][1], pc - self.fns[k][0], (self.fns[k][0], nxt)

	def check(self, pc):
		"""'ret', 'boundary', 'interior', or None if unavailable."""
		if self.md is None:
			return None
		nm, off, rng = self.name(pc)
		if nm is None:
			return None
		base, end = rng
		code = self.d[40 + (base - self.entry):][:end - base]
		prev = None
		for ins in self.md.disasm(code, base):
			if ins.address == pc:
				if prev is not None and prev.mnemonic.startswith('call'):
					return 'ret'
				return 'boundary'
			if ins.address > pc:
				return 'interior'
			prev = ins
		return None

	def describe(self, pc):
		nm, off, _ = self.name(pc)
		if nm is None:
			return "%#x -> ?\t[outside text]" % pc
		s = "%#x -> %s+%#x" % (pc, nm, off)
		st = self.check(pc)
		if st == 'ret':
			s += "\t[return address]"
		elif st == 'boundary':
			s += "\t[instruction boundary, but not after a call]"
		elif st == 'interior':
			s += "\t[NOT an instruction boundary -- cannot be a pc]"
		return s

def main():
	av = sys.argv[1:]
	docheck = False
	if av and av[0] == '-c':
		docheck = True; av = av[1:]
	if not av:
		sys.exit("usage: p9sym.py [-c] kernel [pc...]")
	r = Resolver(av[0])
	if not r.fns:
		sys.exit("p9sym: no text symbols -- is %s stripped?" % av[0])
	print("# %d text symbols, %#x..%#x" % (len(r.fns), r.fns[0][0], r.fns[-1][0]), file=sys.stderr)
	if docheck and r.md is None:
		print("# -c given but capstone is not installed; names only", file=sys.stderr)
	pcs = av[1:]
	if not pcs:
		pcs = re.findall(r'(?:pc=)?0x([0-9a-f]{5,16})', sys.stdin.read())
	for s in pcs:
		print(r.describe(int(s, 16)))

if __name__ == '__main__':
	main()
