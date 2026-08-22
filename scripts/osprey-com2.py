#!/usr/bin/env python3
"""Write to the guest's second serial port a moment after the boot.

The guest's uart driver task is what receives it, so this is how the
interrupt that wakes that task is produced.  Run beside osprey-console.py,
which offers the port with -2 unix:PATH,server,nowait.
"""
import socket, sys, time

path = sys.argv[1]
delay = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
text = (sys.argv[3] if len(sys.argv) > 3 else 'osprey').encode()
time.sleep(delay)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for i in range(40):
    try:
        s.connect(path)
        break
    except OSError:
        time.sleep(0.5)
else:
    sys.exit('cannot reach %s' % path)
# keep sending for a long window, so the guest need not be ready at any
# particular moment for the test to see characters arrive
end = time.time() + 90
while time.time() < end:
    try:
        s.send(text)
    except OSError:
        break
    time.sleep(0.5)
s.close()
