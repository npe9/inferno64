#!/bin/sh
#
# Hammer a styx server with abrupt disconnects and, the moment it stops
# answering, decide whether it has STOPPED or is merely SLOW -- and say
# which, rather than leaving it to be inferred.
#
# The first version declared a wedge on one five-second handshake.  That
# is not a verdict: a server busy serving a board does not answer a new
# connection in five seconds, and a run declared wedged answered
# normally a minute later.  Whole hypotheses were built on samples taken
# after such a declaration, and at least one of them -- a blocked write
# in exreply -- turned out to be a server that was working.
#
# So when the short probe fails, this asks three more questions:
#	is it burning CPU?	(slow, or spinning)
#	does the CPU time move?	(alive, or stopped dead)
#	does a patient probe get an answer?  (60s, not 5s)
# and reports all three.
#
P=$1
probe() {	# $1 = timeout seconds
	python3 - "$1" <<'PY'
import socket,struct,sys,time
to=float(sys.argv[1]); t0=time.time()
try:
    s=socket.create_connection(('127.0.0.1',6666),timeout=to)
    b=struct.pack('<IH',8192,6)+b'9P2000'
    s.sendall(struct.pack('<IBH',4+1+2+len(b),100,0xffff)+b)
    s.settimeout(to); d=s.recv(64); s.close()
    if d and d[4]==101:
        print("%.2f"%(time.time()-t0)); sys.exit(0)
except Exception: pass
sys.exit(1)
PY
}
cpuof() { ps -o time= -p $P | tr -d ' '; }

n=0
while [ $n -lt 400 ]; do
	python3 tools/jtag/styxabrupt.py >/dev/null 2>&1
	n=`expr $n + 1`
	if probe 5 >/dev/null 2>&1; then
		continue
	fi
	echo "=== short probe (5s) failed after $n abrupt disconnects"
	if ! kill -0 $P 2>/dev/null; then
		echo "VERDICT: the server process is GONE"
		exit 1
	fi
	#
	# Sample NOW, while it is stalled.
	#
	# The stall lasts tens of seconds and costs no CPU at all, so the
	# question is which kernel call every process is parked in -- and
	# that is only answerable while it is still parked.  Samples taken
	# after the fact have twice produced confident wrong answers here.
	#
	sample $P 3 -f /tmp/wedge-stall.sample >/dev/null 2>&1 &
	c0=`cpuof`
	pc=`ps -o %cpu= -p $P | tr -d ' '`
	sleep 5
	c1=`cpuof`
	echo "cpu $c0 -> $c1 over 5s, %cpu $pc"
	if [ "$c0" != "$c1" ]; then
		echo "  it is RUNNING (cpu time moved)"
	else
		echo "  it is IDLE (no cpu time at all in 5s)"
	fi
	echo "--- patient probe (60s):"
	if t=`probe 60`; then
		echo "VERDICT: SLOW, not stopped -- answered in ${t}s"
	else
		echo "VERDICT: STOPPED -- no answer in 60s either"
	fi
	echo "--- sockets:"
	netstat -an | grep '\.6666 ' | grep -v TIME_WAIT | head -6
	exit 0
done
echo "survived $n abrupt disconnects, still answering"
