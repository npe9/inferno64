implement Bcmfw;

#
# Load a Broadcom controller's patch firmware over HCI.
#
# A BCM43438 -- the radio on a Raspberry Pi 3B -- comes up able to
# answer HCI Reset and the vendor commands that download a patch, and
# very little else: it has no address of its own until it has one.  The
# board says so plainly.  btfs(4) reads
#
#	addr AAAAAAAAAAAA ... aclsize 251 aclbufs 8
#
# on a cold controller: the buffer sizes are real, read out of the
# chip, and the address is not there at all.
#
# The patch is a file, BCM4345C0.hcd for this part, and its format is
# the commands themselves: a stream of records, each a little endian
# HCI opcode, a length byte, and that many bytes of parameters.
# Loading it is sending each record as an HCI command and waiting for
# its Command Complete, with two vendor commands around the outside --
# Download Minidriver first, which puts the controller in the state
# that accepts RAM writes, and Launch RAM last, which starts what was
# written.  Nothing here is Raspberry Pi specific except the default
# file name; any Broadcom part with an .hcd loads the same way.
#
# usage: bt/bcmfw [-a addr] [-v] uartspec [hcdfile]
#
# where uartspec is what btfs(4) takes, "/dev/eia0!115200!fc", and addr
# is a Bluetooth address to give the controller afterwards, six bytes
# as twelve hex digits.  Without -a the controller keeps whatever the
# patch left it, which for this part is a Broadcom default that every
# such board would share.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bt.m";
	bt: Bt;
	tport: Bttransport;

Bcmfw: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;
verbose := 0;
identify := 0;		# -n: say what the controller is and write nothing

Hcdpath:	con "/n/dos/BCM4345C0.hcd";

Cmdreset:	con 16r0c03;	# HCI Reset
Cmddownload:	con 16rfc2e;	# vendor: Download Minidriver
Cmdlaunch:	con 16rfc4e;	# vendor: Launch RAM
Cmdbdaddr:	con 16rfc01;	# vendor: Write BD_ADDR
Cmdreadbdaddr:	con 16r1009;	# HCI Read BD_ADDR
Cmdreadver:	con 16r1001;	# HCI Read Local Version Information

Replyms:	con 5000;	# how long a command may go unanswered
Launchms:	con 500;	# settle after Launch RAM restarts the controller
Resettries:	con 6;	# HCI Resets to try once it is back

fail(s: string)
{
	sys->fprint(stderr, "bcmfw: %s\n", s);
	raise "fail:error";
}

#
# One command, and the Command Complete that answers it.
#
# Every record in the file is a command and every command is answered,
# so this is the whole protocol.  An event that is not the Command
# Complete for the command just sent is not an error: a controller may
# have something else to say first, and the one being waited for comes
# after it.  A status byte that is not zero is an error, and says which
# command and what it answered, because "the firmware would not load"
# is not something anyone can act on.
#
#
# A read with a deadline, because a controller that says nothing is a
# thing that happens.  Loading a patch onto a part that had already
# taken one left this program blocked in a read for as long as the
# board was up, holding the only shell on the board with it -- the
# console still echoed and nothing consumed a line.  A transport read
# cannot be interrupted, so it runs in its own process and this waits
# on a channel with a timer beside it; the reader is abandoned rather
# than killed, which costs one blocked process in a program that is
# about to exit either way.
#
Reply: adt {
	ptype:	int;
	ev:	array of byte;
	err:	string;
};

readproc(c: chan of ref Reply, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	(ptype, ev, err) := tport->read();
	c <-= ref Reply(ptype, ev, err);
}

timeout(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}

#
# Both channels are buffered and the reader is killed rather than left.
#
# Abandoning it looked tidy and was not: a process blocked in a read
# keeps emu from exiting, so the test that drives this against the
# controller model never finished -- the load succeeded, the program
# printed its line, and nothing came back to the shell.  An unbuffered
# channel does the same thing from the other side: a timer that fires
# with nobody listening blocks the timer process for ever.
#
kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

readwait(ms: int): ref Reply
{
	c := chan[1] of ref Reply;
	t := chan[1] of int;
	pidc := chan[1] of int;
	spawn readproc(c, pidc);
	pid := <-pidc;
	spawn timeout(ms, t);
	alt {
	r := <-c =>
		return r;
	<-t =>
		kill(pid);
		return nil;
	}
}

command(op: int, p: array of byte): string
{
	a := array[3 + len p] of byte;
	a[0] = byte op;
	a[1] = byte (op >> 8);
	a[2] = byte len p;
	a[3:] = p;
	if((e := tport->write(Bt->Hcicmd, a)) != nil)
		return sys->sprint("write %#4.4ux: %s", op, e);
	#
	# A framing error is not always a lost stream here.  Launch RAM
	# restarts the controller, and a restarting controller puts zero
	# bytes and line noise on the wire before it says anything: the
	# reset after the launch read an indicator of 0x00 and gave up on
	# a controller that was merely still coming back.  h4's read
	# consumes exactly one byte when the indicator is wrong, so
	# reading again walks forward a byte at a time until the stream
	# makes sense.  Bounded, because a line that never makes sense is
	# a different fault and should say so.
	#
	junk := 0;
	for(;;){
		r := readwait(Replyms);
		if(r == nil)
			return sys->sprint("%#4.4ux: no answer in %d ms", op, Replyms);
		if(r.err != nil){
			if(len r.err >= 7 && r.err[0:7] == "bad H4 " && junk++ < 256)
				continue;
			return sys->sprint("read after %#4.4ux: %s", op, r.err);
		}
		ev := r.ev;
		if(r.ptype != Bt->Hcievt || len ev < 2)
			continue;
		# 0x0e Command Complete: packets, opcode, status
		if(int ev[0] != 16r0e || len ev < 6)
			continue;
		got := int ev[3] | (int ev[4] << 8);
		if(got != op)
			continue;
		if(int ev[5] != 0)
			return sys->sprint("%#4.4ux: status %#2.2ux", op, int ev[5]);
		return nil;
	}
}

hex(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

#
# An address is written to the controller least significant byte
# first, and read back the same way, so the twelve digits given on the
# command line are reversed here.  Getting this backwards gives a
# controller whose address is the mirror of the one asked for, which
# works perfectly and is wrong.
#
addrbytes(s: string): array of byte
{
	if(len s != 12)
		return nil;
	a := array[6] of byte;
	for(i := 0; i < 6; i++){
		hi := hex(s[2*i]);
		lo := hex(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[5-i] = byte ((hi << 4) | lo);
	}
	return a;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil){
		sys->fprint(stderr, "bcmfw: cannot load %s: %r\n", Arg->PATH);
		raise "fail:load";
	}
	newaddr: array of byte;
	arg->init(argv);
	arg->setusage("bt/bcmfw [-a addr] [-nv] uartspec [hcdfile]");
	while((c := arg->opt()) != 0)
		case c {
		'a' =>
			s := arg->earg();
			newaddr = addrbytes(s);
			if(newaddr == nil){
				sys->fprint(stderr, "bcmfw: %q is not twelve hex digits\n", s);
				raise "fail:usage";
			}
		'v' =>	verbose = 1;
		'n' =>	identify = 1;
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	spec := hd argv;
	path := Hcdpath;
	if(tl argv != nil)
		path = hd tl argv;

	bt = load Bt Bt->PATH;
	if(bt == nil){
		sys->fprint(stderr, "bcmfw: cannot load %s: %r\n", Bt->PATH);
		raise "fail:load";
	}
	bt->init();
	tport = load Bttransport Bttransport->H4PATH;
	if(tport == nil){
		sys->fprint(stderr, "bcmfw: cannot load %s: %r\n", Bttransport->H4PATH);
		raise "fail:load";
	}
	if((e := tport->init(bt, spec)) != nil)
		fail(sys->sprint("%s: %s", spec, e));

	# the whole file, because it is read once and it is 64K.  Under -n
	# nothing is written to the controller, so nothing is read here.
	hcd := array[0] of byte;
	if(!identify)
		hcd = readhcd(path);

	if((e = command(Cmdreset, nil)) != nil)
		fail("reset: " + e);
	#
	# Ask the controller what it is, before writing a patch into it.
	#
	# A .hcd is a list of RAM writes and a Launch RAM at the end.  The
	# controller acknowledges every one of those writes whether or not
	# the patch was built for it -- there is nothing in the format that
	# identifies the part -- and then launches whatever was written.
	# Loading a BCM4345C0 patch (a Pi 3B+ / Zero W part) into this
	# board's BCM43430A1 did exactly that: all 220-odd records
	# accepted, launch accepted, and then a controller that answered
	# nothing and could not be recovered by a reboot, because BT_ON
	# survives one.  It took a power cycle.
	#
	# So the part identifies itself first, and the LMP subversion is
	# printed whether or not anything is wrong with it.  It costs one
	# command and it is the only evidence available that the file
	# about to be written belongs here.
	#
	(sub, ve) := localversion();
	if(ve != nil)
		sys->fprint(stderr, "bcmfw: cannot read local version: %s\n", ve);
	else
		sys->print("bcmfw: controller lmp subversion %#4.4ux (%s)\n",
			sub, partname(sub));
	if(identify){
		tport->close();
		return;
	}
	if((e = command(Cmddownload, nil)) != nil)
		fail("download minidriver: " + e);
	# the controller wants a moment after the minidriver before it
	# will take the first write; Broadcom's own loaders wait 50ms
	sys->sleep(50);

	nrec := 0;
	launched := 0;
	for(o := 0; o + 3 <= len hcd; ){
		op := int hcd[o] | (int hcd[o+1] << 8);
		plen := int hcd[o+2];
		if(o + 3 + plen > len hcd)
			fail(sys->sprint("%s: record %d runs past the end of the file",
				path, nrec));
		if(verbose)
			sys->print("bcmfw: record %d op %#4.4ux len %d\n",
				nrec, op, plen);
		if((e = command(op, hcd[o+3:o+3+plen])) != nil)
			fail(sys->sprint("record %d: %s", nrec, e));
		if(op == Cmdlaunch)
			launched = 1;
		o += 3 + plen;
		nrec++;
	}
	if(!launched)
		fail(sys->sprint("%s: no Launch RAM record; nothing was started", path));
	#
	# It restarts on the patched firmware, and restarting means the
	# link as well as the controller.
	#
	# A quarter of a second and a bare HCI Reset was not enough on a
	# Pi 3B: every one of the patch records was acknowledged, the
	# launch went in, and then the controller said nothing at all for
	# five seconds -- not framing errors, which this already walks
	# past, but silence.  Broadcom's own loader closes the tty and
	# opens it again at this point rather than carrying on over the
	# same descriptor, and that is the difference: the controller
	# brings its UART back up, and anything the host had buffered
	# from before the restart belongs to the firmware that is gone.
	#
	# So: drop the transport, give it time, take it again, and ask
	# more than once.  Each attempt is reported under -v, because
	# "no answer" after a successful download is the one failure here
	# that says nothing about which half is wrong.
	#
	if(verbose)
		sys->print("bcmfw: %d records in, launched; reopening %s\n",
			nrec, spec);
	tport->close();
	sys->sleep(Launchms);
	if((e = tport->init(bt, spec)) != nil)
		fail(sys->sprint("reopen %s after launch: %s", spec, e));
	e = "not attempted";
	for(try := 0; try < Resettries; try++){
		if(try > 0)
			sys->sleep(Launchms);
		e = command(Cmdreset, nil);
		if(verbose){
			why := e;
			if(why == nil)
				why = "ok";
			sys->print("bcmfw: reset after launch, try %d: %s\n",
				try + 1, why);
		}
		if(e == nil)
			break;
	}
	if(e != nil)
		fail("reset after launch: " + e);

	if(newaddr != nil){
		if((e = command(Cmdbdaddr, newaddr)) != nil)
			fail("write address: " + e);
		if((e = command(Cmdreset, nil)) != nil)
			fail("reset after address: " + e);
	}

	# and say what it is now, read back from the controller rather
	# than from what was asked for
	a := array[6] of byte;
	got := readaddr(a);
	if(got != nil)
		sys->print("BCMFW-OK %d records from %s, controller address unread (%s)\n",
			nrec, path, got);
	else
		sys->print("BCMFW-OK %d records from %s, controller address %2.2ux%2.2ux%2.2ux%2.2ux%2.2ux%2.2ux\n",
			nrec, path, int a[5], int a[4], int a[3], int a[2], int a[1], int a[0]);
	tport->close();
}

#
# The LMP subversion, which is how a Broadcom part names itself.  The
# names below are the ones whose patch files exist in RPi-Distro's
# bluez-firmware; an unknown one is reported as unknown rather than
# guessed at, because guessing is what this whole function exists to
# prevent.
#
readhcd(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		fail(sys->sprint("stat %s: %r", path));
	hcd := array[int d.length] of byte;
	n := 0;
	while(n < len hcd){
		m := sys->read(fd, hcd[n:], len hcd - n);
		if(m <= 0)
			fail(sys->sprint("read %s: %r", path));
		n += m;
	}
	return hcd;
}

partname(sub: int): string
{
	case sub {
	16r4406 =>	return "BCM4330B1";
	16r610c =>	return "BCM4354";
	16r2209 =>	return "BCM43430A1, the Pi 3B and Zero W radio";
	16r6119 =>	return "BCM4345C0, the Pi 3B+ radio";
	16r6606 =>	return "BCM4345C5, the Pi 4 radio";
	16r230f =>	return "BCM4356A2";
	* =>		return "unknown";
	}
}

localversion(): (int, string)
{
	b := array[3] of byte;
	b[0] = byte Cmdreadver;
	b[1] = byte (Cmdreadver >> 8);
	b[2] = byte 0;
	if((e := tport->write(Bt->Hcicmd, b)) != nil)
		return (0, e);
	for(;;){
		r := readwait(Replyms);
		if(r == nil)
			return (0, sys->sprint("no answer in %d ms", Replyms));
		if(r.err != nil)
			return (0, r.err);
		ev := r.ev;
		if(r.ptype != Bt->Hcievt || len ev < 14)
			continue;
		if(int ev[0] != 16r0e)
			continue;
		if((int ev[3] | (int ev[4] << 8)) != Cmdreadver)
			continue;
		if(int ev[5] != 0)
			return (0, sys->sprint("status %#2.2ux", int ev[5]));
		# status, hci_ver, hci_rev[2], lmp_ver, manuf[2], lmp_subver[2]
		return (int ev[12] | (int ev[13] << 8), nil);
	}
}

readaddr(a: array of byte): string
{
	b := array[3] of byte;
	b[0] = byte Cmdreadbdaddr;
	b[1] = byte (Cmdreadbdaddr >> 8);
	b[2] = byte 0;
	if((e := tport->write(Bt->Hcicmd, b)) != nil)
		return e;
	for(;;){
		r := readwait(Replyms);
		if(r == nil)
			return sys->sprint("no answer in %d ms", Replyms);
		if(r.err != nil)
			return r.err;
		ev := r.ev;
		if(r.ptype != Bt->Hcievt || len ev < 12)
			continue;
		if(int ev[0] != 16r0e)
			continue;
		if((int ev[3] | (int ev[4] << 8)) != Cmdreadbdaddr)
			continue;
		if(int ev[5] != 0)
			return sys->sprint("status %#2.2ux", int ev[5]);
		a[0:] = ev[6:12];
		return nil;
	}
}
