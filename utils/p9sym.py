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
# The root cause underneath that silence was found by the cloud-port
# session: utils/include/a.out.h declares struct Exec's eight fields
# `long`, and they are 32-bit big-endian words in the file.  `long` is
# 64 bits on the hosts these tools build on, so the struct is twice the
# width of the record it describes and every field after magic reads
# the wrong four bytes -- symsz in particular comes out 0 for any
# kernel below 4GB, so libmach concludes there are no symbols.
#
# This file's own measurements corroborate that from the other side.
# libmach's amd64 ExecTable row gives the header size as
# sizeof(Exec)+8; with the broken 64-bit Exec that is 72, and with the
# 32-bit one it is 40.  40 is exactly what this reader determined
# empirically before the cause was known -- at 40 the symbol table is
# consumed with zero bytes left, at 32 there are 3 -- which is why the
# constant below is 40 and not computed.
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

def readelf(path, want='Tt'):
	"""Plan 9 symbols out of an ELF-wrapped kernel (7l -H7, riscv likewise).

	These boards are not Plan 9 a.out: the file starts \x7fELF and the
	reader below sees no magic it knows.  But the ELF is only a loader
	wrapper -- there is no SHT_SYMTAB, just two PROGBITS and a tiny
	string table -- and the Plan 9 symbol table sits immediately after
	the data section, in the ordinary format.  libmach cannot read
	these at all (no Elf64 support), so without this the arm64 and
	riscv64 boards have no way to resolve a pc.

	Two things differ from the amd64 case.  The table starts at the end
	of the data section rather than at a header-derived offset, and the
	values are narrower.  The first was read off the bytes: the first
	entry decodes as "40 0e 84 c8 | d4 | etext\\0", value 0x400e84c8,
	which is exactly the text section's addr plus its size.

	The width is not guessed and not assumed from the ELF class.
	Symbol width is a property of the LOADER, not the file format: 6l
	and 7l write eight-byte values for the Plan 9 a.out header type and
	four for ELF, while jl writes eight either way.  Rather than encode
	which linker made which board, both widths are decoded and the one
	that decodes cleanly is taken.

	"Cleanly" is the type byte, not the byte count.  An earlier version
	of this took whichever width consumed the table with zero bytes
	left over, and that test is NOT decisive -- the cloud-port session
	controlled it in both directions and found that too-small overshoots
	and is caught, while too-large can land on the size exactly and
	return a table of rubbish.  On this tree's aarch64 kernel the wrong
	width happens to leave 4 bytes, so this reader would have caught it
	here; that is the binary's luck and not the test working.

	Every symbol record these loaders write has 0x80 set in the type
	byte -- the length-prefixed name -- and a type from TtLlDdBbapmzZf.
	Measured, not assumed: across ipc64 and ivirtarm64 that is 53828
	records with no exception, matching the same survey done over ten
	boards on the cloud-port branch.  A wrong width lands on a type
	byte that fails one of those within the first records, which is
	decisive where the arithmetic is not.
	"""
	d = open(path, 'rb').read()
	if d[:4] != b'\x7fELF':
		return None			# not ELF; the a.out reader gets it
	if d[4] != 2:
		# ELF32: the riscv virt32/virt32s boards.  Refusing is fine;
		# refusing WITHOUT saying why is not -- libmach's elfdotout
		# returned 0 here without setting errstr, so ksize said
		# "Undefined error: 0" and no reader could tell a corrupt file
		# from a format nobody had taught it.  Say which it is.
		raise ValueError("%s is ELF32; this reader handles ELF64 and "
			"Plan 9 a.out only" % path)
	e = '<' if d[5] == 1 else '>'
	shoff, = struct.unpack_from(e+'Q', d, 0x28)
	shentsize, shnum, shstrndx = struct.unpack_from(e+'HHH', d, 0x3a)
	secs = [struct.unpack_from(e+'IIQQQQIIQQ', d, shoff + i*shentsize)
		for i in range(shnum)]
	prog = [x for x in secs if x[1] == 1]		# SHT_PROGBITS
	if len(prog) < 2:
		raise ValueError("%s has %d PROGBITS sections, expected text "
			"and data" % (path, len(prog)))
	text, data = prog[0], prog[1]
	tbase, tsize = text[3], text[5]
	st = d[data[4] + data[5]:shoff]
	out = None
	for width in (4, 8):
		syms, left, ok = _decode(st, width, want)
		if ok and left == 0:
			out = syms
			break
	if out is None:
		raise ValueError("%s: no symbol-value width decodes the table "
			"cleanly at either 4 or 8 bytes -- stripped, or a "
			"loader this reader does not know" % path)
	out.sort()
	return out, d, tbase, tsize

TYPES = 'TtLlDdBbapmzZf'

def _decode(st, width, want):
	"""Decode a Plan 9 symbol table at a given value width.

	Returns (symbols, bytes left unconsumed, ok).  ok is false as soon
	as a type byte is not one this tree's loaders write -- 0x80 set and
	a letter from TYPES -- which is what actually rules a width out.
	"""
	out, i = [], 0
	while i + width + 1 <= len(st):
		val = int.from_bytes(st[i:i+width], 'big'); i += width
		t = st[i]; i += 1
		if (t & 0x80) == 0 or chr(t & ~0x80) not in TYPES:
			return out, len(st) - i, False
		if (t & 0x80) == 0:
			name = st[i:i+NNAME].split(b'\0')[0].decode('latin1', 'replace')
			i += NNAME + 3
			typ = chr(t)
		else:
			typ = chr(t & ~0x80)
			if typ in 'zZ':
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
	return out, len(st) - i, True

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
		self.path = path
		self._kd = 0
		self.elf = False
		r = readelf(path)
		if r is not None:
			fns, self.d, self.entry, self.text = r
			self.elf = True
		else:
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
		"""'ret', 'boundary', 'interior', or None if unavailable.

		On a fixed-width instruction set the check is arithmetic and
		needs no disassembler: arm64 and riscv64 instructions are 4
		bytes and 4-byte aligned, so an odd or 2-mod-4 value cannot
		be a pc at all.  Worth having because it is the same mistake
		the x86 boundary check exists to stop -- a ktrace word that
		resolves to a tidy name+offset and is simply stack litter.
		0x4005000a resolved to vmachine+0x56 and had two of us
		reading it as a frame.
		"""
		if self.elf and (pc & 3):
			return 'interior'
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

	def etext(self):
		"""End of text -- a fingerprint of the layout itself.

		pc64's main.c already prints "etext 0x%p edata 0x%p end 0x%p"
		in its Important Addresses banner, so a console log carries
		this too.  It is a better build check than kerndate: KERNDATE
		only changes when $CONF.c is recompiled, so a kernel relinked
		against a changed library can carry the previous build's
		stamp, while etext moves whenever the text does -- which is
		exactly when captured pcs stop meaning what they said.
		"""
		syms, _, _, _ = readsyms(self.path, 'Tt')
		for v, n in syms:
			if n == 'etext':
				return v
		return None

	def kerndate(self):
		"""The kernel's own build stamp, read out of its data segment.

		os/inferno/*/mkfile compiles $CONF.c with -DKERNDATE=`{$NDATE}
		and main.c prints "Inferno release built at %ud" in the boot
		banner, so every console log already names the build that
		produced it.  Reading the same u32 back out of the binary
		turns that into a check: if the numbers differ, the pcs in
		that log belong to a different kernel and any name this tool
		prints for them is fiction.  Data addresses map to the file
		at the page-rounded end of text (4096 on amd64).
		"""
		if getattr(self, '_kd', 0) is not None and getattr(self, '_kd', 0) != 0:
			return self._kd
		syms, _, _, _ = readsyms(self.path, 'DdBb')
		dbase = (self.entry + self.text + 4095) & ~4095
		for v, n in syms:
			if n == 'kerndate':
				off = 40 + self.text + (v - dbase)
				if 0 <= off <= len(self.d) - 4:
					self._kd = struct.unpack('<I', self.d[off:off+4])[0]
					return self._kd
		self._kd = None
		return None

	def rets(self):
		"""Every call-return address in text -> (symbol, offset, callee).

		A pc captured by getcallerpc() must be one of these.  Built
		once and cached; it is also the denominator for judging a
		coincidence -- on this kernel only 1.87% of text bytes are
		call-return addresses.
		"""
		if self.md is None:
			return None
		if getattr(self, '_rets', None) is not None:
			return self._rets
		r = {}
		for i, (a, n) in enumerate(self.fns):
			e = self.addrs[i+1] if i+1 < len(self.addrs) else self.entry + self.text
			if not (0 < e - a <= 0x4000):
				continue
			for ins in self.md.disasm(self.d[40 + (a - self.entry):][:e-a], a):
				if ins.mnemonic.startswith('call'):
					t = ins.op_str
					try:
						ti = int(t, 16)
						k = bisect.bisect_right(self.addrs, ti) - 1
						t = self.fns[k][1]
					except ValueError:
						t = '*' + t
					r[ins.address + ins.size] = (n, ins.address + ins.size - a, t)
		self._rets = r
		return r

	def scan(self, pcs, span=0x2000):
		"""Find a build offset that makes these pcs valid return addresses.

		A capture is only meaningful against the exact binary that
		produced it.  This tree rebuilds constantly and its panics
		carry no build stamp, so pcs written down during one boot get
		resolved months later against a kernel whose functions have
		moved -- yielding a name that is confidently wrong.  If every
		pc in a capture becomes a call-return address under one common
		delta, that delta is the shift between the two builds and the
		names under it are the real ones.  Coincidence is easy to rule
		out: hitting by chance runs at the call-return density, so k
		pcs agreeing on one delta is ~0.019**k per delta tried.
		"""
		r = self.rets()
		if r is None:
			return []
		# a shifted pc is still a text address; anything else scraped
		# off a log (heap pointers, block addresses) can never be
		# placed and would only dilute the agreement count.
		lo, hi = self.entry - span, self.entry + self.text + span
		pcs = [p for p in pcs if lo <= p <= hi]
		out = []
		for D in range(-span, span+1):
			hit = [p for p in pcs if (p + D) in r]
			if hit:
				out.append((len(hit), D, hit))
		out.sort(key=lambda x: (-x[0], abs(x[1])))
		return out, len(pcs)

	def describe(self, pc):
		nm, off, _ = self.name(pc)
		if nm is None:
			return "%#x -> ?\t[outside text]" % pc
		s = "%#x -> %s+%#x" % (pc, nm, off)
		st = self.check(pc)
		if st == 'ret':
			s += "\t[return address]"
		elif st == 'boundary':
			s += "\t[boundary but not after a call; try -s]"
		elif st == 'interior':
			s += "\t[not an instruction boundary in this build; try -s]"
		return s

def main():
	av = sys.argv[1:]
	docheck = doscan = False
	while av and av[0] in ('-c', '-s'):
		if av[0] == '-c': docheck = True
		else: doscan = True
		av = av[1:]
	if not av:
		sys.exit("usage: p9sym.py [-c] kernel [pc...]")
	try:
		r = Resolver(av[0])
	except ValueError as e:
		sys.exit("p9sym: %s" % e)
	if not r.fns:
		sys.exit("p9sym: %s decoded, but it has no text symbols" % av[0])
	kd, et = r.kerndate(), r.etext()
	print("# %d text symbols, %#x..%#x, built at %s, etext %s"
		% (len(r.fns), r.fns[0][0], r.fns[-1][0], kd if kd else "?",
		   ("%#x" % et) if et else "?"), file=sys.stderr)
	if docheck and r.md is None:
		print("# -c given but capstone is not installed; names only", file=sys.stderr)
	pcs = av[1:]
	if not pcs:
		txt = sys.stdin.read()
		pcs = re.findall(r'(?:pc=)?0x([0-9a-f]{5,16})', txt)
		# dumpstack()/ktrace prints raw stack words as "addr=value",
		# every word that might be a return address.  Feeding them
		# through -c is what turns that dump into a backtrace: the
		# ones that really follow a call are the frames, the rest is
		# stack litter.
		pcs += re.findall(r'=([0-9a-f]{8,16})\b', txt)
		# the boot banner names the build the capture came from, two
		# ways; etext is the one that tracks the text layout itself.
		bad = None
		for e in set(re.findall(r'etext 0x([0-9a-f]+)', txt)):
			if et and int(e, 16) != et:
				bad = "etext %#x, this binary %#x" % (int(e, 16), et)
		for b in set(re.findall(r'built at (\d+)', txt)):
			if kd and int(b) != kd and bad is None:
				bad = "built at %s, this binary %d" % (b, kd)
		if bad is not None:
			print("# WARNING: capture is from a different kernel (%s)."
				"\n#          Names below are meaningless as printed; use -s."
				% bad, file=sys.stderr)
	vals = [int(s, 16) for s in pcs]
	for v in vals:
		print(r.describe(v))
	if doscan:
		if r.md is None:
			sys.exit("p9sym: -s needs capstone")
		res, ntext = r.scan(vals)
		if not res:
			print("\n# no build offset makes any of these a call return")
			return
		n = res[0][0]
		dens = 100.0 * len(r.rets()) / r.text
		print("\n# %.2f%% of text bytes are call-return addresses; %d of %d text pcs agree at best"
			% (dens, n, ntext))
		if n < 2:
			print("# one pc alone agrees with many offsets by chance -- not conclusive."
				"\n# Give every pc from a single boot; they share one offset.")
		shown = 0
		for cnt, D, hit in res:
			if cnt < n:
				break
			shown += 1
			if shown > 8:
				print("# ... and %d more offsets with the same count"
					% (sum(1 for c, _, _ in res if c == n) - 8))
				break
			print("# build offset %+#x -- %d/%d pcs are call returns:" % (D, cnt, ntext))
			for v in vals:
				if v + D in r.rets():
					sym, off, callee = r.rets()[v+D]
					print("    %#x -> %s+%#x\t(call %s)" % (v, sym, off, callee))
				elif r.name(v)[0] is not None:
					print("    %#x -> unplaced" % v)

if __name__ == '__main__':
	main()
