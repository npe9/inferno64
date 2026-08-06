# 9front AMD64 QEMU regression

`run.sh` creates an isolated QEMU overlay from the current official 9front
AMD64 image, attaches the current Inferno worktree as a read-only ISO, and
runs `guest.rc` in the guest. The guest builds the 9front AMD64 emulator with
the native Plan 9 toolchain and runs a command-mode smoke test.

Requirements on the host are QEMU, Expect, Git, curl, gzip, and either xorriso
or hdiutil.

Run it from the repository root:

    tests/qemu-9front-amd64/run.sh

Set `QEMU9FRONT_WORK` to keep downloaded VM assets outside the default
`.qemu-9front-amd64` directory.
