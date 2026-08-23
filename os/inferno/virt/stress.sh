#!/bin/sh
# Stress-test rooted Dis utilities on Inferno/riscv64 virt.
# Runs the full smoke path including CMD-STRESS + WM-STRESS (every
# menu app except the already-running colours window) and CLI tools.
#
#	./os/virt/stress.sh
set -e
ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
export ROOT
exec "$ROOT/os/virt/smoke.sh"
