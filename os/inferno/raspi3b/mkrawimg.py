#!/usr/bin/env python3
# elf-to-raw: lay each PT_LOAD segment at (p_vaddr - base) in a flat image,
# padding gaps with zero, exactly as `objcopy -O binary` would.  The Pi
# firmware loads this flat image at `base` (0x80000) and jumps to it.
import os, struct, sys
elf_path, out_path = sys.argv[1], sys.argv[2]
base = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x80000
b = open(elf_path, 'rb').read()
assert b[:4] == b'\x7fELF', 'not an ELF'
e_phoff = struct.unpack('<Q', b[0x20:0x28])[0]
e_phnum = struct.unpack('<H', b[0x38:0x3a])[0]
segs = []
for i in range(e_phnum):
    o = e_phoff + i*56
    p_type, = struct.unpack('<I', b[o:o+4])
    p_off, p_vaddr, p_paddr, p_filesz, p_memsz = struct.unpack('<5Q', b[o+8:o+8+40])
    if p_type == 1 and p_filesz:      # PT_LOAD with file data
        segs.append((p_vaddr, p_off, p_filesz))
segs.sort()
end = max(v - base + fsz for v, _, fsz in segs)
img = bytearray(end)
for v, off, fsz in segs:
    img[v-base:v-base+fsz] = b[off:off+fsz]
#
# Write a temporary file and rename it, never truncate the real one.
#
# The board's own kupdate copies this file off the host over styx on
# every boot, and a rebuild here takes a while.  Writing in place means
# there is a window where kernel8.img is short or half-written, and a
# kupdate landing in that window puts a truncated kernel on the card --
# which boots to nothing and costs a card swap.  os.replace is atomic
# within a directory, so a reader sees either the old image or the new
# one and never a partial.
#
tmp_path = out_path + '.new'
open(tmp_path, 'wb').write(img)
os.replace(tmp_path, out_path)
print('wrote %s: %d bytes, %d PT_LOAD segments, base %#x' % (out_path, len(img), len(segs), base))
