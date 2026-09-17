implement Hfp;

#
# Hands free: the control half.
#
# What a hands free unit and an audio gateway say to each other is AT
# commands over an RFCOMM serial port -- the same AT commands a modem
# took, with a set of extensions that are all HFP is.  So this sits on
# the file btfs serves for an RFCOMM channel and is a line protocol,
# and there is no Bluetooth in it at all.
#
# The service level connection is the handshake that has to happen
# before anything else: what features each side has, what indicators
# the gateway keeps and what they are now, and a request to be told
# when they change.  A gateway will answer nothing else until it has
# happened, so it is not optional and it is not split up.
#
# What is not here is the audio.  A call's sound goes over a
# synchronous connection -- SCO or eSCO -- which needs the controller
# to carry it and, over USB, isochronous endpoints; none of that is
# verified in this tree.  So this can see a call, place one, answer
# one and hang up, and cannot hear or be heard, and says so.
#
# On 9front this is one C file: the same line reader.
#

include "sys.m";
	sys: Sys;
include "bt.m";
	bt: Bt;

#
# What this side can do.  Every bit of it is something the code below
# actually does: there is no three way calling here, no codec
# negotiation, and no voice recognition, so none of those bits are
# set.  A unit that claims a feature and then ignores what the gateway
# sends for it is worse than one that claims nothing.
#
Fhfindicators:	con 0;		# nothing claimed
Slctimeout:	con 10000;	# ms for one command's answer

init(b: Bt): string
{
	sys = load Sys Sys->PATH;
	bt = b;
	return nil;
}

#
# The reader is started here and is the only thing that ever reads the
# port.  It has to be running before the first command: a gateway may
# say something before it is asked anything, and a line read by two
# processes is a line that arrives in halves.
#
start(fd: ref Sys->FD): ref Sess
{
	s := ref Sess;
	s.fd = fd;
	s.buf = "";
	s.names = nil;
	s.values = nil;
	s.agfeatures = 0;
	s.events = chan[8] of string;
	s.replies = chan of string;
	spawn reader(s);
	return s;
}

#
# Every line the gateway sends.  What is unsolicited goes to whoever
# is watching; everything else is an answer and goes to whoever asked.
#
reader(s: ref Sess)
{
	for(;;){
		(r, e) := line(s);
		if(e != nil){
			post(s, "gone " + e);
			#
			# and let go of anyone waiting for an answer that
			# is not coming
			#
			alt {
			s.replies <-= "ERROR" =>	;
			* =>	;
			}
			return;
		}
		if(unsolicited(s, r))
			continue;
		s.replies <-= r;
	}
}

#
# One line out.  AT commands are terminated by a carriage return and
# nothing else: a line feed after it is what a terminal would add and
# a gateway reading strictly will not take one.
#
send(s: ref Sess, cmd: string): string
{
	b := array of byte (cmd + "\r");
	if(sys->write(s.fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

#
# One line in, out of whatever arrived.  A read of the port is bytes,
# not lines: a gateway may put several responses in one frame and cut
# one across two, so the lines are cut here and the remainder kept.
#
line(s: ref Sess): (string, string)
{
	for(;;){
		for(i := 0; i < len s.buf; i++)
			if(s.buf[i] == '\r' || s.buf[i] == '\n'){
				l := s.buf[0:i];
				s.buf = s.buf[i+1:];
				if(l != "")
					return (l, nil);
				i = -1;		# an empty line is a separator
			}
		b := array[512] of byte;
		n := sys->read(s.fd, b, len b);
		if(n < 0)
			return (nil, sys->sprint("%r"));
		if(n == 0)
			return (nil, "the gateway went away");
		s.buf += string b[0:n];
	}
}

#
# One command and its final answer.  What comes back before OK is the
# answer proper and is handed back a line at a time; an unsolicited
# indication that arrives in the middle is put on the event channel
# rather than being taken for part of the answer, because a gateway is
# entitled to send one at any moment and a caller waiting for a reply
# must not be given a phone ringing instead.
#
command(s: ref Sess, cmd: string): (list of string, string)
{
	if((e := send(s, cmd)) != nil)
		return (nil, e);
	l: list of string;
	tick := chan[1] of int;
	spawn timer(Slctimeout, tick);
	for(;;){
		r: string;
		alt {
		r = <-s.replies =>	;
		<-tick =>
			return (nil, "the gateway never answered " + cmd);
		}
		if(r == "OK"){
			rl: list of string;
			for(; l != nil; l = tl l)
				rl = hd l :: rl;
			return (rl, nil);
		}
		if(r == "ERROR"){
			return (nil, "the gateway refused " + cmd);
		}
		if(len r > 6 && r[0:6] == "+CME E")
			return (nil, "the gateway refused " + cmd + ": " + r);
		l = r :: l;
	}
}

#
# An unsolicited line: an indicator changed, the phone is ringing, the
# caller's number.  It goes to whoever is watching rather than to
# whoever asked, and true is returned so the caller knows it was not
# their answer.
#
unsolicited(s: ref Sess, r: string): int
{
	if(len r >= 6 && r[0:6] == "+CIEV:"){
		indicate(s, r[6:]);
		return 1;
	}
	if(r == "RING" || (len r >= 5 && r[0:5] == "+CLIP")){
		post(s, r);
		return 1;
	}
	return 0;
}

post(s: ref Sess, r: string)
{
	alt {
	s.events <-= r =>	;
	* =>	;	# nobody is watching, and an event is not worth waiting on
	}
}

#
# "+CIEV: n,v" -- the nth indicator, counting from one, is now v.  The
# names came from the test above; the values are kept so that
# something can read what the state is rather than only what changed.
#
indicate(s: ref Sess, rest: string)
{
	(n, f) := sys->tokenize(rest, " ,");
	if(n < 2)
		return;
	i := int hd f;
	v := int hd tl f;
	j := 1;
	nl: list of (string, int);
	name := "";
	for(l := s.values; l != nil; l = tl l){
		(nm, ov) := hd l;
		if(j == i){
			ov = v;
			name = nm;
		}
		nl = (nm, ov) :: nl;
		j++;
	}
	vl: list of (string, int);
	for(; nl != nil; nl = tl nl)
		vl = hd nl :: vl;
	s.values = vl;
	if(name != "")
		post(s, name + " " + string v);
}

#
# The service level connection.  Four commands in a fixed order, and
# the order is the specification's: a gateway will not answer the
# later ones until the earlier ones have been asked.
#
slc(s: ref Sess): string
{
	#
	# what each side can do.  This side claims nothing, which is
	# true: there is no three way calling here and no codec
	# negotiation, and claiming either would be promising to
	# handle what the gateway then sent.
	#
	(r, e) := command(s, "AT+BRSF=" + string Fhfindicators);
	if(e != nil)
		return e;
	for(; r != nil; r = tl r){
		l := hd r;
		if(len l > 7 && l[0:7] == "+BRSF: ")
			s.agfeatures = int l[7:];
	}

	# which indicators the gateway keeps, and in what order
	(r, e) = command(s, "AT+CIND=?");
	if(e != nil)
		return e;
	for(; r != nil; r = tl r){
		l := hd r;
		if(len l > 7 && l[0:7] == "+CIND: ")
			s.names = indnames(l[7:]);
	}
	if(s.names == nil)
		return "the gateway named no indicators";

	# and what they are now
	(r, e) = command(s, "AT+CIND?");
	if(e != nil)
		return e;
	for(; r != nil; r = tl r){
		l := hd r;
		if(len l > 7 && l[0:7] == "+CIND: ")
			s.values = indvalues(s.names, l[7:]);
	}

	# and tell me when they change
	(nil, e) = command(s, "AT+CMER=3,0,0,1");
	return e;
}

#
# The names out of a CIND test response, which is a list of
# ("name",(range)) in the order the gateway will report them.  The
# order is the whole point: an indication says which one by number.
#
indnames(s: string): list of string
{
	l: list of string;
	for(i := 0; i < len s; i++){
		if(s[i] != '"')
			continue;
		j := i + 1;
		while(j < len s && s[j] != '"')
			j++;
		if(j >= len s)
			break;
		l = s[i+1:j] :: l;
		#
		# step over the range that follows, so that a range
		# holding a quoted thing cannot be read as a name
		#
		i = j;
		while(i < len s && s[i] != ')')
			i++;
	}
	rl: list of string;
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return rl;
}

indvalues(names: list of string, s: string): list of (string, int)
{
	(nil, f) := sys->tokenize(s, " ,");
	l: list of (string, int);
	for(; names != nil && f != nil; names = tl names){
		l = (hd names, int hd f) :: l;
		f = tl f;
	}
	rl: list of (string, int);
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return rl;
}

value(s: ref Sess, name: string): int
{
	for(l := s.values; l != nil; l = tl l){
		(nm, v) := hd l;
		if(nm == name)
			return v;
	}
	return -1;
}

#
# The three things a hands free unit does.  Each is one AT command and
# what comes of it is an indicator changing, which is why none of them
# returns anything but an error: what happened is read from the
# indicators, not from the answer.
#
dial(s: ref Sess, number: string): string
{
	(nil, e) := command(s, "ATD" + number + ";");
	return e;
}

answer(s: ref Sess): string
{
	(nil, e) := command(s, "ATA");
	return e;
}

hangup(s: ref Sess): string
{
	(nil, e) := command(s, "AT+CHUP");
	return e;
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	c <-= 1;
}
