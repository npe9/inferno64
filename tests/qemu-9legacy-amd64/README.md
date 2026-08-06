# 9legacy AMD64 QEMU regression

`run.sh` creates an isolated overlay from the official 9legacy QEMU image,
selects its amd64 kernel in the overlay's 9fat, boots it with local
`qemu-system-x86_64`, and attaches the current Inferno worktree as a read-only
ISO. The guest builds the `Plan9` target with `OBJTYPE=amd64` using the native
Plan 9 toolchain and runs the resulting emu.

Requirements on the host are QEMU, Expect, Git, curl, bzip2, GNU dd, and
either xorriso or hdiutil.

Run it from the repository root:

    tests/qemu-9legacy-amd64/run.sh

Set `QEMU9LEGACY_WORK` to keep downloaded VM assets outside the default
`.qemu-9legacy-amd64` directory.
