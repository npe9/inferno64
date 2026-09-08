#!/bin/sh
#
# btvirt's server socket, carried to a TCP port.
#
# socat forks per connection and each new Unix connection makes btvirt
# build a fresh btdev, so a bench phase that connects gets a
# controller that has just been reset -- which is what every phase
# assumes and what the model gives it.
#
set -e
PORT=${PORT:-5555}
SOCK=${SOCK:-/tmp/bt-server-bredrle}

btvirt -s &
i=0
while [ ! -S "$SOCK" ] && [ $i -lt 100 ]; do
	sleep 0.1
	i=$((i + 1))
done
if [ ! -S "$SOCK" ]; then
	echo "btvirt did not create $SOCK" >&2
	exit 1
fi
#
# The peer, unless it is not wanted.  It takes a controller of its own
# from the same btvirt -- every controller btvirt makes goes in one
# list, so the two can hear each other -- and advertises on it.
#
if [ "${PEER:-1}" != 0 ]; then
	btpeer "$SOCK" &
	sleep 1
fi

echo "btvirt is on $SOCK, serving H4 on tcp $PORT" >&2
exec socat TCP-LISTEN:$PORT,reuseaddr,fork UNIX-CONNECT:"$SOCK"
