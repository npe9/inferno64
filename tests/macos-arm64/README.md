# macOS arm64 regression

`run.sh` builds both the Cocoa and console emulators, rebuilds the two Draw3d
providers, and runs a command-mode smoke test.  It is intentionally usable on
a developer Mac and by a self-hosted Bitbucket runner; Cocoa rendering checks
can be added to the same entry point without duplicating the build setup.

Run it from the repository root:

    tests/macos-arm64/run.sh

The test requires Apple Silicon, Xcode command-line tools, and the repository's
bootstrap `mk` in `MacOSX/arm64/bin`.
