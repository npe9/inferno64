# ls.sh's TCP client: frame every JSON-RPC line of the session onto a
# connection to the language server and write its replies out, so the
# transport an editor would use is checked against the same golden
import socket, sys, time

port, session, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
msgs = [l for l in open(session).read().split("\n") if l.strip()]
sock = None
for i in range(40):			# the emulator takes a moment to announce
	try:
		sock = socket.create_connection(("127.0.0.1", port), timeout=5)
		break
	except OSError:
		time.sleep(0.5)
if sock is None:
	sys.exit("no connection to port %d" % port)
for m in msgs:
	sock.sendall(("Content-Length: %d\r\n\r\n%s" % (len(m), m)).encode())
sock.settimeout(60)
buf = b""
try:
	while True:
		d = sock.recv(65536)
		if not d:
			break
		buf += d
except OSError:
	pass
open(out, "wb").write(buf)
