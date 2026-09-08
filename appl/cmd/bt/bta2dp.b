implement Bta2dp;

#
# bta2dp: an audio stream to a Bluetooth sink.
#
# It finds a device offering the advanced audio sink service, opens
# the AVDTP signalling channel, asks what its stream endpoints can do,
# picks an SBC configuration out of what it says it will take, and
# opens and starts the stream.  Then it reads a file and sends it down
# the media channel, one media packet at a time.
#
# What it does not do is encode.  A2DP is AVDTP plus SBC and there is
# no SBC here: what the file must hold is SBC frames already in the
# configuration that was agreed, and a file of anything else will be
# sent faithfully and make a noise or no sound at all.  That is a real
# limit and this program says it on the way past rather than leaving
# it to be discovered by listening.
#
# Everything Bluetooth is reached through btfs's files, as in bthid
# and btpan: what this opens is the two L2CAP channel files btfs made.
#
# On 9front this is one C program doing the same five requests.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bt.m";
	bt: Bt;
	avdtp: Avdtp;
	Sep, Cap: import avdtp;

Bta2dp: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

# the advanced audio distribution sink, in a service record
Usink:		con "110b";
# the PSM, written the way btfs(4) wants it
Psmtext:	con "0019";

btmnt	:= "/net/bt";
verbose	:= 0;

#
# Our own stream endpoint identifier.  It means nothing to the sink
# beyond being something to name this side by, and 1 is what every
# source uses.
#
Ourseid:	con 1;

# how much of the file goes in one media packet, and how fast
Chunk:		con 256;
Gap:		con 20;		# ms between packets

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	bt = load Bt Bt->PATH;
	avdtp = load Avdtp Avdtp->PATH;
	if(arg == nil || bt == nil || avdtp == nil){
		sys->fprint(sys->fildes(2), "bta2dp: cannot load the stack: %r\n");
		return;
	}
	bt->init();
	if((ie := avdtp->init(bt)) != nil){
		sys->fprint(sys->fildes(2), "bta2dp: avdtp: %s\n", ie);
		return;
	}

	arg->init(argv);
	arg->setusage("bt/bta2dp [-v] [-b btmountpoint] [-d device] [file]");
	dev := "";
	while((c := arg->opt()) != 0)
		case c {
		'v' =>	verbose = 1;
		'b' =>	btmnt = arg->arg();
		'd' =>	dev = arg->arg();
		* =>	arg->usage();
		}
	a := arg->argv();
	file := "";
	if(a != nil)
		file = hd a;

	if(dev == "")
		dev = findsink();
	if(dev == ""){
		sys->fprint(sys->fildes(2),
			"bta2dp: no connected device offers an audio sink\n");
		return;
	}
	sys->print("bta2dp: %s\n", dev);

	#
	# The signalling channel and then the media one, both to the
	# same PSM: AVDTP puts them there and tells them apart by
	# which was opened first, which is why the second is not
	# opened until the stream has been configured.
	#
	if((ce0 := writefile(dev + "/ctl", "l2cap " + Psmtext)) != nil){
		sys->fprint(sys->fildes(2), "bta2dp: the signalling channel: %s\n", ce0);
		return;
	}
	sf := dev + "/l2cap/" + Psmtext;
	sfd := sys->open(sf, Sys->ORDWR);
	if(sfd == nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s: %r\n", sf);
		return;
	}
	s := avdtp->start(sfd);

	(seps, de) := avdtp->discover(s);
	if(de != nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s\n", de);
		return;
	}
	sep := audiosink(seps);
	if(sep == nil){
		sys->fprint(sys->fildes(2),
			"bta2dp: the device has no free audio sink endpoint\n");
		return;
	}
	sys->print("bta2dp: endpoint %d\n", sep.seid);

	(caps, ce) := avdtp->capabilities(s, sep.seid);
	if(ce != nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s\n", ce);
		return;
	}
	codec := codecof(caps);
	if(codec == nil){
		sys->fprint(sys->fildes(2),
			"bta2dp: the endpoint says nothing about a codec\n");
		return;
	}
	(chosen, what, se) := avdtp->sbcchoose(codec);
	if(se != nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s\n", se);
		return;
	}
	sys->print("bta2dp: %s\n", what);

	#
	# Media transport with no bytes in it, and the codec: those two
	# and nothing else.  Reporting and recovery are things this
	# does not do, and asking for them would be asking for
	# something it could not then keep to.
	#
	cl := ref Cap(Avdtp->Cmediatransport, nil) :: chosen :: nil;
	e: string;
	if((e = avdtp->setconfig(s, sep.seid, Ourseid, cl)) != nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s\n", e);
		return;
	}
	if((e = avdtp->open(s, sep.seid)) != nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s\n", e);
		return;
	}
	#
	# and now the media channel, which is the second one to the
	# same PSM.  btfs names a channel by its PSM, so the second is
	# asked for by a name of its own; there is one link and two
	# channels on it.
	#
	if((e = writefile(dev + "/ctl", "l2cap " + Psmtext)) != nil){
		sys->fprint(sys->fildes(2), "bta2dp: the media channel: %s\n", e);
		return;
	}
	mf := dev + "/l2cap/" + Psmtext + ".1";
	mfd := sys->open(mf, Sys->ORDWR);
	if(mfd == nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s: %r\n", mf);
		return;
	}
	if((e = avdtp->startstream(s, sep.seid)) != nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s\n", e);
		return;
	}
	sys->print("bta2dp: the stream is open\n");

	if(file == ""){
		sys->print("bta2dp: no file to send; the stream is up and idle\n");
		return;
	}
	sys->fprint(sys->fildes(2),
		"bta2dp: %s is sent as it is: nothing here encodes, so it must already be SBC\n",
		file);
	stream(mfd, file);
	avdtp->close(s, sep.seid);
	sys->print("bta2dp: the stream is closed\n");
}

#
# The file, one media packet at a time.  The first byte of an A2DP
# payload says how many SBC frames are in it and whether this is a
# fragment; one whole frame per packet is what a source sends when it
# can, and this cannot count frames it did not encode, so it says one
# and sends what it was given.
#
stream(fd: ref Sys->FD, file: string)
{
	f := sys->open(file, Sys->OREAD);
	if(f == nil){
		sys->fprint(sys->fildes(2), "bta2dp: %s: %r\n", file);
		return;
	}
	buf := array[Chunk] of byte;
	seq := 0;
	stamp := 0;
	n := 0;
	for(;;){
		k := sys->read(f, buf, len buf);
		if(k <= 0)
			break;
		p := array[1 + k] of byte;
		p[0] = byte 1;			# one frame, not a fragment
		p[1:] = buf[0:k];
		m := avdtp->media(seq, stamp, 16r5a5a5a5a, 96, p);
		if(sys->write(fd, m, len m) != len m){
			sys->fprint(sys->fildes(2), "bta2dp: the stream stopped: %r\n");
			return;
		}
		seq = (seq + 1) & 16rffff;
		stamp += k;
		n++;
		if(verbose)
			sys->print("bta2dp: packet %d, %d bytes\n", seq, k);
		sys->sleep(Gap);
	}
	sys->print("bta2dp: %d media packets sent\n", n);
}

#
# the first endpoint that is an audio sink and is not already in use.
# A device with two is offering a choice and this takes the first,
# which is what a source with nothing to choose on does.
#
audiosink(l: list of ref Sep): ref Sep
{
	for(; l != nil; l = tl l){
		p := hd l;
		if(p.media == Avdtp->Maudio && p.sink && !p.inuse)
			return p;
	}
	return nil;
}

codecof(l: list of ref Cap): ref Cap
{
	for(; l != nil; l = tl l)
		if((hd l).cat == Avdtp->Cmediacodec)
			return hd l;
	return nil;
}

#
# the first connected device with an audio sink in its service
# records.  A device offering none has nothing here to play to.
#
findsink(): string
{
	for(cl := lsdir(btmnt); cl != nil; cl = tl cl){
		rd := btmnt + "/" + hd cl + "/remote";
		for(dl := lsdir(rd); dl != nil; dl = tl dl){
			d := rd + "/" + hd dl;
			for(rl := lsdir(d + "/sdp"); rl != nil; rl = tl rl)
				if(hasline(readfile(d + "/sdp/" + hd rl),
						"class " + Usink))
					return d;
		}
	}
	return "";
}

hasline(s, want: string): int
{
	for(i := 0; i < len s; ){
		j := i;
		while(j < len s && s[j] != '\n')
			j++;
		if(len want <= j - i && s[i:i+len want] == want)
			return 1;
		i = j + 1;
	}
	return 0;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[4096] of byte;
	for(;;){
		n := sys->pread(fd, buf, len buf, big len array of byte s);
		if(n <= 0)
			break;
		s += string buf[0:n];
		if(n < len buf)
			break;
	}
	return s;
}

writefile(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

lsdir(path: string): list of string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			l = d[i].name :: l;
	}
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
