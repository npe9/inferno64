implement Tcpserve;
include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
	dial: Dial;
#
# Announce on an address, accept one connection, answer it, exit.
#
# Nothing in the pc64 root had ever listened on TCP -- every command
# written for the cloud dials out -- so the server half of the stack
# was untested.  It works; scripts/check-pc64-tcp.sh is this command
# with a client on the host and a forwarded port.
#
Tcpserve: module { init: fn(nil: ref Draw->Context, argv: list of string); };
init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	if(dial == nil){ sys->print("tcpserve: no Dial: %r\n"); return; }
	#
	# -e: keep the connection and echo whatever arrives, so that a
	# client can time a round trip on a bare TCP connection and
	# compare it with the same round trip carried over Styx.  That
	# comparison is the point of section "measure the claim" in
	# doc/inferno-cloud-modern.ms: the file abstraction is worth
	# having only if it does not cost several times the thing it
	# replaces, and nobody has the number.
	#
	echo := 0;
	argv = tl argv;
	if(argv != nil && hd argv == "-e"){
		echo = 1;
		argv = tl argv;
	}
	addr := "tcp!*!6666";
	if(argv != nil)
		addr = hd argv;
	sys->print("tcpserve: announce %s\n", addr);
	c := dial->announce(addr);
	if(c == nil){
		sys->print("tcpserve: announce failed: %r\n");
		return;
	}
	sys->print("tcpserve: announced, dir %s\n", c.dir);
	sys->print("tcpserve: waiting for a connection\n");
	nc := dial->listen(c);
	if(nc == nil){
		sys->print("tcpserve: listen failed: %r\n");
		return;
	}
	sys->print("tcpserve: CONNECTION from %s\n", c.dir);
	dfd := dial->accept(nc);
	if(dfd == nil){
		sys->print("tcpserve: accept failed: %r\n");
		return;
	}
	if(echo){
		#
		# Keep accepting.  One connection was enough for the
		# announce/accept test this command started as, and wrong
		# for a benchmark server: a probe that merely checked the
		# port was open consumed the only connection, and the
		# measurement that followed failed with a broken pipe.
		#
		sys->print("tcpserve: echoing\n");
		buf := array[8192] of byte;
		for(;;){
			for(;;){
				n := sys->read(dfd, buf, len buf);
				if(n <= 0)
					break;
				if(sys->write(dfd, buf[0:n], n) != n)
					break;
			}
			nc = dial->listen(c);
			if(nc == nil)
				return;
			dfd = dial->accept(nc);
			if(dfd == nil)
				return;
		}
	}
	msg := array of byte "INFERNO-ACCEPTED-YOUR-CONNECTION\n";
	sys->write(dfd, msg, len msg);
	sys->print("tcpserve: replied\n");
}
