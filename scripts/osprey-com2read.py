#!/usr/bin/env python3
"""Read what the guest's uart task sends out of the second serial port.

Run beside osprey-console.py, which offers the port with
-2 unix:PATH,server,nowait.  Whatever arrives is written to stdout as it
comes, so a test can see that the bytes a driver task was given went out
of the device.
"""
import socket, sys, time

path = sys.argv[1]
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 90.0
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for i in range(60):
    try:
        s.connect(path)
        break
    except OSError:
        time.sleep(0.5)
else:
    sys.exit('cannot reach %s' % path)
s.settimeout(1.0)
end = time.time() + seconds
while time.time() < end:
    try:
        b = s.recv(4096)
    except socket.timeout:
        continue
    except OSError:
        break
    if b == b'':
        break
    sys.stdout.write(b.decode('utf-8', 'replace'))
    sys.stdout.flush()
s.close()
