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
	addr := "tcp!*!6666";
	if(tl argv != nil)
		addr = hd tl argv;
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
	msg := array of byte "INFERNO-ACCEPTED-YOUR-CONNECTION\n";
	sys->write(dfd, msg, len msg);
	sys->print("tcpserve: replied\n");
}
