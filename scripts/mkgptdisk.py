#!/usr/bin/env python3
"""Write a GPT-partitioned raw disk holding one EFI system partition.

This is the shape every cloud provider that takes a custom image wants:
AWS imports a raw disk as an EBS snapshot, Compute Engine takes a raw
disk in a tar.gz, OCI's BYOI takes the same disk, and a rented metal
box boots it after dd.  None of them take the ISO
scripts/mkinferno-efi-iso.sh builds.

There is no sgdisk, gdisk or parted on a Mac, and the layout is small
enough to write directly rather than take a dependency for it.

usage: mkgptdisk.py disk.raw esp.fat [size-in-MiB]
"""
import binascii, os, struct, sys, uuid

SECTOR = 512
ESP_TYPE = uuid.UUID('C12A7328-F81F-11D2-BA4B-00A0C93EC93B')
FIRST_LBA = 2048            # 1 MiB in, the alignment every tool uses
ENTRIES = 128
ENTSIZE = 128


def guid_le(u):
    """GPT stores the first three fields little-endian, the rest as-is."""
    return u.bytes_le


def crc(b):
    return binascii.crc32(b) & 0xffffffff


def gpt_header(cur, other, first, last, entries_lba, entries_crc, disk_guid):
    h = bytearray(92)
    struct.pack_into('<8sIIIIQQQQ16sQIII', h, 0,
                     b'EFI PART', 0x00010000, 92, 0, 0,
                     cur, other, first, last,
                     guid_le(disk_guid), entries_lba,
                     ENTRIES, ENTSIZE, entries_crc)
    struct.pack_into('<I', h, 16, crc(bytes(h)))
    return bytes(h) + b'\0' * (SECTOR - 92)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out, esp = sys.argv[1], sys.argv[2]
    mib = int(sys.argv[3]) if len(sys.argv) > 3 else 128

    total = mib * 1024 * 1024 // SECTOR
    last_usable = total - 34
    esp_size = os.path.getsize(esp)
    if FIRST_LBA + esp_size // SECTOR > last_usable + 1:
        sys.exit('esp %d bytes does not fit in %d MiB' % (esp_size, mib))
    esp_last = FIRST_LBA + (esp_size + SECTOR - 1) // SECTOR - 1

    disk_guid = uuid.uuid4()
    part_guid = uuid.uuid4()

    ent = bytearray(ENTSIZE)
    struct.pack_into('<16s16sQQQ', ent, 0,
                     guid_le(ESP_TYPE), guid_le(part_guid),
                     FIRST_LBA, esp_last, 0)
    ent[56:56 + 2 * len('EFI System')] = 'EFI System'.encode('utf-16-le')
    table = bytes(ent) + b'\0' * (ENTSIZE * (ENTRIES - 1))
    tcrc = crc(table)

    # protective MBR: one 0xEE partition covering the disk (or 0xffffffff)
    mbr = bytearray(SECTOR)
    struct.pack_into('<BBBBBBBBII', mbr, 446,
                     0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF,
                     1, min(total - 1, 0xffffffff))
    mbr[510:512] = b'\x55\xaa'

    tsec = ENTRIES * ENTSIZE // SECTOR
    with open(out, 'wb') as f:
        f.truncate(total * SECTOR)
        f.write(bytes(mbr))
        f.write(gpt_header(1, total - 1, FIRST_LBA, last_usable,
                           2, tcrc, disk_guid))
        f.write(table)
        f.seek(FIRST_LBA * SECTOR)
        with open(esp, 'rb') as g:
            f.write(g.read())
        f.seek((total - 1 - tsec) * SECTOR)
        f.write(table)
        f.seek((total - 1) * SECTOR)
        f.write(gpt_header(total - 1, 1, FIRST_LBA, last_usable,
                           total - 1 - tsec, tcrc, disk_guid))
    print('%s: %d MiB, esp at lba %d..%d' % (out, mib, FIRST_LBA, esp_last))


main()
