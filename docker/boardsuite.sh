#!/bin/sh
# boardsuite.sh - run tools/boardsuite inside the Linux container.
#
#	docker/boardsuite.sh			the five it runs by default
#	docker/boardsuite.sh virt		one of them
#	docker/boardsuite.sh -v virt		the suite's own flags pass through
#	docker/boardsuite.sh sh			a shell in the image
#	docker/boardsuite.sh build		build the tree in the
#						container first, and run
#						what was built
#
# The tree is bind-mounted read-only.  By default the suite boots the
# kernel binaries that happen to be in it; "build" instead builds them
# from source inside the container, which is the honest way round --
# the tree's own .gitignore says kernel binaries do not belong in it.
# See docker/build-and-run.
set -e

here=`dirname "$0"`
root=`cd "$here/.." && pwd`
image=${BOARDSUITE_IMAGE:-inferno-boardsuite}

# The Mac is arm64 and Docker Desktop will quietly serve an amd64 image
# under emulation if asked for one.  Several of these checks time
# themselves against the guest clock and would fail for a reason that
# has nothing to do with the boards, so the platform is named rather
# than left to the daemon.  Override for a machine that is not arm64.
platform=${BOARDSUITE_PLATFORM:-linux/arm64}

docker build --platform "$platform" \
	-f "$root/docker/Boardsuite.Dockerfile" \
	-t "$image" "$root/docker" >&2

# Read-only: the suite writes only to its work directory, and a run that
# tried to write into the tree should say so rather than do it.  In
# particular -b cannot record a container run over the checked-in
# baselines, which would be a host's marker set written down as the
# tree's truth.
run='docker run --rm --platform '"$platform"' -v '"$root"':/src:ro -e BOARDSUITE_WORK=/work'

if [ $# -eq 0 ]; then
	exec $run "$image"
fi
if [ "$1" = build ]; then
	shift
	exec $run --entrypoint /src/docker/build-and-run "$image" "$@"
fi
if [ "$1" = sh ]; then
	shift
	tty=
	[ -t 0 ] && tty="-i -t"
	# shellcheck disable=SC2086
	exec $run $tty --entrypoint /bin/sh "$image" "$@"
fi
exec $run "$image" tools/boardsuite/run "$@"
