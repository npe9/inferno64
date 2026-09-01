implement Command;

# dialtest(1) - DISPOSABLE probe, not a real command: checks whether
# this emu instance can dial a real TCP connection at all (module/
# dial.m has been read this session, never run) before any TLS work
# is built on top of it. See doc/ssl-modernization-plan.md.
#
# Checks, in order: dial by hostname (needs /net/cs, the connection
# server, reachable), dial by literal IP (works even if name
# resolution doesn't), and - if a connection was made - a plaintext
# HTTP/1.0 GET to prove data actually flows both ways, independent of
# anything TLS-shaped.

include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
	dial: Dial;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	dial = load Dial Dial->PATH;
	if(sys == nil || dial == nil){
		sys->print("dialtest: cannot load support modules\n");
		raise "fail:load";
	}

	sys->print("=== by hostname: tcp!bsky.social!80 ===\n");
	c := dial->dial("tcp!bsky.social!80", nil);
	if(c == nil)
		sys->print("FAILED: %r\n");
	else{
		sys->print("OK: dfd=%d dir=%s\n", c.dfd.fd, c.dir);
		probehttp(c.dfd);
	}

	sys->print("=== by literal IP (looked up once via host tools) ===\n");
	# bsky.social's own A record, resolved once outside emu - this
	# isolates DNS/cs from the dial+TCP path itself.
	c2 := dial->dial("tcp!104.20.28.66!80", nil);
	if(c2 == nil)
		sys->print("FAILED: %r\n");
	else{
		sys->print("OK: dfd=%d dir=%s\n", c2.dfd.fd, c2.dir);
		probehttp(c2.dfd);
	}
}

probehttp(fd: ref Sys->FD)
{
	req := array of byte "GET / HTTP/1.0\r\nHost: bsky.social\r\n\r\n";
	n := sys->write(fd, req, len req);
	sys->print("wrote %d/%d bytes\n", n, len req);
	buf := array[200] of byte;
	rn := sys->read(fd, buf, len buf);
	if(rn <= 0){
		sys->print("read failed/eof: %r\n");
		return;
	}
	sys->print("read %d bytes: %q\n", rn, string buf[0:rn]);
}
