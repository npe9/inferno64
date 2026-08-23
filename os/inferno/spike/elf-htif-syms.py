#!/usr/bin/env python3
"""
jl -H5 emits ELF without section headers; Plan 9 symbols live in phdr[2].
QEMU -M spike HTIF needs ELF symbols tohost/fromhost.  Inject a minimal
.symtab / .strtab and section header table.
"""
import struct
import sys

SHT_NULL = 0
SHT_SYMTAB = 2
SHT_STRTAB = 3
SHN_ABS = 0xFFF1
STB_GLOBAL = 1
STT_OBJECT = 1


def parse_plan9_syms(data):
	"""jl putsymb: BE uvlong value, type byte, NUL-terminated name."""
	pos = 0
	syms = {}
	while pos + 9 < len(data):
		val = struct.unpack_from('>Q', data, pos)[0]
		pos += 8
		t = data[pos]
		pos += 1
		try:
			end = data.index(0, pos)
		except ValueError:
			break
		name = data[pos:end].decode('ascii', 'replace')
		pos = end + 1
		base = name.split('<>', 1)[0]
		syms[base] = val
	return syms


def shdr(name_off, typ, flags, addr, offset, size, link, info, addralign, entsize):
	return (
		struct.pack('<II', name_off, typ) +
		struct.pack('<QQ', flags, addr) +
		struct.pack('<QQ', offset, size) +
		struct.pack('<II', link, info) +
		struct.pack('<QQ', addralign, entsize)
	)


def main():
	if len(sys.argv) != 2:
		print(f'usage: {sys.argv[0]} ispike', file=sys.stderr)
		sys.exit(2)
	path = sys.argv[1]
	with open(path, 'rb') as f:
		b = bytearray(f.read())

	if b[:4] != b'\x7fELF':
		print('not ELF', file=sys.stderr)
		sys.exit(1)

	e_phoff = struct.unpack_from('<Q', b, 32)[0]
	e_phentsize = struct.unpack_from('<H', b, 54)[0]
	e_phnum = struct.unpack_from('<H', b, 56)[0]
	if e_phnum < 3:
		print('expected 3 program headers', file=sys.stderr)
		sys.exit(1)

	off = e_phoff + 2 * e_phentsize
	p_offset, _, _, p_filesz, _, _ = struct.unpack_from('<6Q', b, off + 8)
	syms = parse_plan9_syms(bytes(b[p_offset:p_offset + p_filesz]))
	if 'tohost' not in syms:
		print('tohost not in Plan 9 symtab', file=sys.stderr)
		sys.exit(1)

	# Single 16-byte GLOBL tohost in l.s; fromhost is always tohost+8.
	# (Two separate BSS symbols are not kept adjacent by jl, and QEMU
	# maps the whole [min,max+8) span as HTIF — a gap kills the kernel.)
	tohost = syms['tohost']
	fromhost = tohost + 8
	print(f'HTIF tohost={tohost:#x} fromhost={fromhost:#x}')

	strtab = bytearray(b'\0')
	def addstr(s):
		i = len(strtab)
		strtab.extend(s.encode('ascii') + b'\0')
		return i

	symtab = bytearray(24)  # undef
	for name, val in (('tohost', tohost), ('fromhost', fromhost)):
		st_name = addstr(name)
		st_info = (STB_GLOBAL << 4) | STT_OBJECT
		symtab += struct.pack('<IBBHQQ', st_name, st_info, 0, SHN_ABS, val, 8)

	shstr = bytearray(b'\0.symtab\0.strtab\0.shstrtab\0')
	name_symtab = 1
	name_strtab = 1 + len('.symtab\0')
	name_shstrtab = name_strtab + len('.strtab\0')

	symoff = len(b)
	b += symtab
	stroff = len(b)
	b += strtab
	shstroff = len(b)
	b += shstr
	shoff = len(b)

	b += shdr(0, SHT_NULL, 0, 0, 0, 0, 0, 0, 0, 0)
	b += shdr(name_symtab, SHT_SYMTAB, 0, 0, symoff, len(symtab), 2, 1, 8, 24)
	b += shdr(name_strtab, SHT_STRTAB, 0, 0, stroff, len(strtab), 0, 0, 1, 0)
	b += shdr(name_shstrtab, SHT_STRTAB, 0, 0, shstroff, len(shstr), 0, 0, 1, 0)

	struct.pack_into('<Q', b, 40, shoff)
	struct.pack_into('<H', b, 58, 64)
	struct.pack_into('<H', b, 60, 4)
	struct.pack_into('<H', b, 62, 3)

	with open(path, 'wb') as f:
		f.write(b)
	print(f'patched {path}: shoff={shoff:#x}')


if __name__ == '__main__':
	main()
