#
# The Bluetooth stack.  Everything above the controller is a user
# program: the kernel's only part is carrying HCI packets, which it
# already does -- a byte stream through devuart (os/inferno/port/
# devuart.c) for an H4 UART controller, or endpoints through devusb
# (os/inferno/port/devusb.c) for a USB one.  See btfs(4).
#

#
# Bt: what every layer needs -- the packet indicators an HCI transport
# puts in front of a packet, and the little endian accessors the
# protocol is written in.
#
Bt: module
{
	PATH:	con "/dis/lib/bt/bt.dis";

	init:	fn();

	# HCI packet indicators.  H4 sends them as the first byte on the
	# wire; USB carries each kind on its own endpoint, so there they
	# are only this stack's own name for which endpoint a packet
	# came from or goes to.
	Hcicmd:	con 1;
	Hciacl:	con 2;
	Hcisco:	con 3;
	Hcievt:	con 4;

	Baddrlen:	con 6;

	# LE address types
	Apublic:	con 0;
	Arandom:	con 1;

	# A random address says what kind it is in the top two bits of
	# its most significant byte: 01 is resolvable private -- three
	# bytes of random and three of ah(irk, random), which only the
	# holder of the identity resolving key can undo -- 11 is static
	# and 00 is non-resolvable private.  Neither of the last two is
	# resolvable, and a public address never is.
	Rpatop:		con 16r40;
	Rpamask:	con 16rc0;

	get16:	fn(a: array of byte, o: int): int;
	get24:	fn(a: array of byte, o: int): int;
	get32:	fn(a: array of byte, o: int): int;
	put16:	fn(a: array of byte, o: int, v: int);
	put24:	fn(a: array of byte, o: int, v: int);
	put32:	fn(a: array of byte, o: int, v: int);

	# a Bluetooth address is six bytes, least significant first on
	# the wire and most significant first when written down
	addrstr:	fn(a: array of byte): string;
	straddr:	fn(s: string): array of byte;

	hex:	fn(a: array of byte): string;
	unhex:	fn(s: string): array of byte;

	# one hexadecimal digit, or -1
	digit:	fn(c: int): int;

	# a UUID is written down in lower case, and a client that types
	# one in upper case means the same service
	lower:	fn(s: string): string;

	# a UUID is 2, 4 or 16 bytes, little endian on the wire; it is
	# written big endian, and the 16 bit and 32 bit forms are
	# written as they are rather than expanded into the base UUID
	uuid:	fn(a: array of byte, o, n: int): string;
	uuidbytes:	fn(s: string): array of byte;

	# is this address one a bond's identity resolving key could
	# explain?  Only says the address has the shape; smp->resolve
	# says whether a particular key actually accounts for it.
	resolvable:	fn(atype: int, a: array of byte): int;

	opcode:	fn(ogf, ocf: int): int;
	hcierr:	fn(status: int): string;
	atypestr:	fn(t: int): string;
};

#
# An HCI transport.  Two are built: h4.dis, which frames packets on a
# byte stream (a uart -- the Raspberry Pi's onboard controller and any
# H4 module), and btusb.dis, which carries them on the endpoints of a
# USB Bluetooth controller.  Nothing above this interface knows which
# one it has.
#
Bttransport: module
{
	H4PATH:		con "/dis/lib/bt/h4.dis";
	H5PATH:		con "/dis/lib/bt/h5.dis";
	USBPATH:	con "/dis/lib/bt/btusb.dis";

	# spec names the controller: for h4 the byte stream and its
	# speed, "/dev/eia1!115200"; for btusb the device directory
	# under /dev/usb, "ep3.0", or nil to take the first Bluetooth
	# controller found there
	init:	fn(bt: Bt, spec: string): string;

	# one whole HCI packet: its indicator, its bytes without the
	# indicator or the transport's own framing, and an error
	read:	fn(): (int, array of byte, string);
	write:	fn(ptype: int, p: array of byte): string;
	close:	fn();
};

#
# HCI: the controller.  Commands are serialised (a controller answers
# one at a time), events are parsed and dispatched, ACL data is
# fragmented on the way down and reassembled on the way up, and the
# controller's ACL buffers are accounted so a write blocks rather
# than overruns.
#
Hci: module
{
	PATH:	con "/dis/lib/bt/hci.dis";

	Adv: adt {
		evtype:	int;
		atype:	int;
		addr:	array of byte;
		rssi:	int;
		data:	array of byte;
	};

	#
	# What an inquiry heard.  This is the Classic side of Adv, and
	# the differences are the whole difference between the two
	# radios: a BD_ADDR is always public, so there is no address
	# type; a device answers an inquiry rather than advertising
	# unasked, so there is no advertisement to carry a name and the
	# name has to be asked for; and paging it afterwards needs the
	# page scan repetition mode and the clock offset it answered
	# with, which is why they are kept rather than being a detail of
	# the event.
	#
	Inq: adt {
		addr:	array of byte;
		class:	int;		# class of device
		psrm:	int;		# page scan repetition mode
		clock:	int;		# clock offset
		rssi:	int;		# 127 when the controller did not say
		eir:	array of byte;	# extended inquiry response, or nil
	};

	# the General Inquiry Access Code, the lower address part every
	# discoverable device answers an inquiry on
	Giac:	con 16r9e8b33;

	#
	# What a controller asks while a BR/EDR link is being secured,
	# and what it says came of it.  All of it is per address and
	# none of it is per connection, because a link key belongs to a
	# pair of devices rather than to the link that happens to be up.
	#
	Slinkkey:	con 0;	# have you a key for this device
	Siocap:		con 1;	# what can this side display and type
	Sconfirm:	con 2;	# a number both sides can see, if anyone looks
	Skeynote:	con 3;	# here is the key that came of it
	Spin:		con 4;	# the old kind of pairing, which this refuses
	Sdone:		con 5;	# authentication finished, well or badly

	Sec: adt {
		kind:	int;
		addr:	array of byte;
		key:	array of byte;	# on Skeynote
		ktype:	int;		# what kind of key it is
		value:	int;		# the number on Sconfirm
		err:	string;		# on Sdone
	};

	#
	# What this side can do about a passkey: nothing, which is what
	# makes its pairing Just Works and no protection against a man
	# in the middle.  This is the HCI IO capability and not smp's,
	# which is a different field that happens to be numbered the
	# same way; giving it a name of its own is what stops the two
	# being taken for one.
	#
	Hnoio:	con 3;
	# and what it wants of the pairing: no man in the middle
	# protection, and a bond that lasts
	Hbonding:	con 1;

	# An L2CAP frame being reassembled on one link, and a command's
	# answer.  Both are the reader process's business and nobody
	# else's; they are here rather than private to hci.b only
	# because Ctlr holds them and Ctlr has to be nameable from
	# outside.
	Cstate: adt {
		c:	ref Conn;
		acc:	array of byte;
		want:	int;
	};

	Reply: adt {
		op:	int;
		status:	int;
		p:	array of byte;
		err:	string;
	};

	#
	# One controller.  This used to be the module's own variables,
	# which meant one radio per program however many were plugged
	# in.  Everything a controller has that another controller does
	# not share is here: its transport, its command lock, its ACL
	# credits, its links, and what it said it was.
	#
	# our role on a link, as the controller reports it in LE
	# Connection Complete: central if we opened it, peripheral if a
	# peer opened it to us.
	Rcentral:	con 0;
	Rperipheral:	con 1;

	Ctlr: adt {
		t:		Bttransport;
		cmdlock:	chan of int;
		connlock:	chan of int;
		replyc:		chan of ref Reply;
		advc:		chan of ref Adv;
		connc:		chan of (ref Conn, string);
		credits:	chan of int;
		states:		list of ref Cstate;
		statelock:	chan of int;
		running:	int;
		scodrop:	int;
		laddr:		array of byte;
		lver:		string;
		aclsize:	int;
		aclbufs:	int;
		adv:		int;		# is it advertising
		inc:		chan of ref Conn;	# links a peer opened
		inqc:		chan of ref Inq;	# what an inquiry hears
		inq:		int;		# is an inquiry running
		#
		# A BR/EDR connection, which arrives as an event long
		# after the command was answered, exactly as an LE one
		# does.  It is a second channel and not connc because a
		# Classic connection and an LE one can be in flight at
		# once and neither is the other's answer.
		#
		bconnc:		chan of (ref Conn, string);
		bconnlock:	chan of int;
		#
		# who this side is paging, or nil.  An LE Connection
		# Complete says which side opened the link; a BR/EDR one
		# does not, so the only thing that distinguishes a link
		# this side asked for from one a peer opened is whether
		# the address is the one being paged.  Written under
		# bconnlock and read by the event process; it is one
		# word either way.
		#
		bconnaddr:	array of byte;
		namec:		chan of (string, string);
		namelock:	chan of int;
		#
		# What the controller wants answered while a link is
		# being secured.  It is a channel and not a callback
		# because the answer is policy -- which key, whether to
		# confirm -- and policy lives above this, with the
		# bonds.
		#
		secc:		chan of ref Sec;
	};

	Conn: adt {
		x:	ref Ctlr;	# the controller this link is on
		handle:	int;
		role:	int;
		#
		# A BR/EDR link rather than an LE one.  It matters above
		# here as well as in here: a BD_ADDR has no address type
		# and never rotates, L2CAP's signalling channel is a
		# different CID, and ATT is LE only, so nothing that
		# assumes an LE link may be run over one.
		#
		classic:	int;
		atype:	int;
		addr:	array of byte;
		encrypted:	int;
		# what the link is running at now: the interval in units
		# of 1.25ms, the number of connection events the
		# peripheral may skip, and the supervision timeout in
		# units of 10ms
		interval:	int;
		latency:	int;
		timeout:	int;
		up:	chan of array of byte;	# whole L2CAP frames
		#
		# The controller asking for the key to encrypt this link
		# with, which is what a peripheral gets when the central
		# starts encryption.  Carries the random number and the
		# diversifier that name the key; both are zero when the
		# key being asked for is the short term one pairing has
		# just produced.  Buffered, because the request arrives
		# when the central feels like it.
		#
		ltkreq:	chan of (array of byte, int);
		#
		# Why the link went away, and a broadcast rather than a
		# message: more than one process waits for it -- the
		# L2CAP demultiplexer, and whoever above is watching the
		# device -- and there is one reason to go round.  So
		# whoever takes it puts it back, and every waiter sees
		# it.  Taking it and keeping it leaves the others
		# waiting for ever on a link that has gone.
		#
		closed:	chan of string;
	};

	init:	fn(bt: Bt): string;

	# reset a controller, read what identifies it, and return it.
	# Every call is a different radio; nothing here is shared
	# between them.
	start:	fn(t: Bttransport): (ref Ctlr, string);
	stop:	fn(x: ref Ctlr);

	localaddr:	fn(x: ref Ctlr): array of byte;
	localver:	fn(x: ref Ctlr): string;
	aclmtu:		fn(x: ref Ctlr): (int, int);	# payload size, buffer count

	# SCO packets the transport framed and this dropped.  Nothing
	# above the transport has a use for them until there is audio,
	# and until then a count is the honest thing to publish: they
	# arrived, and they went nowhere.
	scodropped:	fn(x: ref Ctlr): int;

	# ask the controller to run the link at different parameters.
	# The answer is an event, not a reply, so this returns when the
	# controller has accepted the request rather than when the link
	# has changed; the Conn's own fields say what it is running at.
	leconnupdate:	fn(c: ref Conn, min, max, latency, timeout: int): string;

	# are these parameters ones a controller will take?  The ranges
	# are the specification's, and the last is the rule that keeps a
	# link from timing out before the peripheral is obliged to speak
	paramsok:	fn(min, max, latency, timeout: int): string;

	cmd:	fn(x: ref Ctlr, op: int, p: array of byte): (int, array of byte, string);

	lescan:	fn(x: ref Ctlr, on: int): string;
	advs:	fn(x: ref Ctlr): chan of ref Adv;

	#
	# Classic inquiry.  It is not a scan: a scan runs until it is
	# stopped and hears whatever advertises, an inquiry runs for a
	# length the controller is told and then says it is over.  So
	# inquiry(x, 1) starts one and the controller ends it; the
	# results arrive on inqs() meanwhile, and a nil on that channel
	# is the Inquiry Complete.  inquiry(x, 0) cancels one early.
	#
	inquiry:	fn(x: ref Ctlr, on: int): string;
	inquiring:	fn(x: ref Ctlr): int;
	inqs:		fn(x: ref Ctlr): chan of ref Inq;

	#
	# A Classic device's name is not in what it answered an inquiry
	# with unless it sent an extended inquiry response; it is asked
	# for, over a page that does not become a connection.  psrm and
	# clock are what the inquiry said, and are what make the page
	# short rather than a blind search.
	#
	remotename:	fn(x: ref Ctlr, addr: array of byte, psrm, clock: int): (string, string);

	# Advertising, which is how this side is found at all.  The
	# parameters are set once and the data can be changed while it
	# is running, which is what a controller allows and what saves
	# stopping and starting to change a name.
	leadvparams:	fn(x: ref Ctlr, connectable: int): string;
	leadvdata:	fn(x: ref Ctlr, ad: array of byte): string;
	leadvresp:	fn(x: ref Ctlr, ad: array of byte): string;
	leadvertise:	fn(x: ref Ctlr, on: int): string;
	advertising:	fn(x: ref Ctlr): int;

	# Links a peer opened to this side.  They arrive here and not on
	# the channel leconnect waits on: a connection nobody asked for
	# handed to a caller that asked for a different one is that
	# caller's answer, and it would be the wrong device.
	incoming:	fn(x: ref Ctlr): chan of ref Conn;

	leconnect:	fn(x: ref Ctlr, atype: int, addr: array of byte): (ref Conn, string);

	#
	# A BR/EDR connection.  psrm and clock are what the inquiry
	# said: they are what make the page short rather than a blind
	# search, and 0 for both is legal and slow.
	#
	connect:	fn(x: ref Ctlr, addr: array of byte, psrm, clock: int): (ref Conn, string);

	#
	# Secure simple pairing, and the security a BR/EDR link needs
	# before most profiles will do anything.  secs() is where the
	# controller's questions arrive; the replies answer them.
	#
	secs:		fn(x: ref Ctlr): chan of ref Sec;
	linkkeyreply:	fn(x: ref Ctlr, addr, key: array of byte): string;
	linkkeynegreply: fn(x: ref Ctlr, addr: array of byte): string;
	iocapreply:	fn(x: ref Ctlr, addr: array of byte, iocap, auth: int): string;
	confirmreply:	fn(x: ref Ctlr, addr: array of byte, yes: int): string;
	pinnegreply:	fn(x: ref Ctlr, addr: array of byte): string;

	# ask the controller to authenticate the link, and then to
	# encrypt it.  Authentication is what produces a link key; a
	# link that is authenticated and not encrypted is one where the
	# key was agreed and never used.
	authenticate:	fn(c: ref Conn): string;
	encrypt:	fn(c: ref Conn, on: int): string;
	disconnect:	fn(c: ref Conn): string;
	conns:		fn(x: ref Ctlr): list of ref Conn;

	acl:	fn(c: ref Conn, p: array of byte): string;

	lerand:		fn(x: ref Ctlr): (array of byte, string);
	leencrypt:	fn(x: ref Ctlr, key, plain: array of byte): (array of byte, string);
	lestartencrypt:	fn(c: ref Conn, rand: array of byte, ediv: int, ltk: array of byte): string;

	# the peripheral's answer to that request: here is the key, or
	# there is no key for what you named
	leltkreply:	fn(c: ref Conn, ltk: array of byte): string;
	leltknegreply:	fn(c: ref Conn): string;
};

#
# L2CAP.  On an LE link the channels that matter are the fixed ones --
# 4 for ATT, 5 for LE signalling, 6 for security management -- so
# what this does is length/CID framing, demultiplexing to a channel
# per CID, and answering the signalling commands a peripheral sends.
#
L2cap: module
{
	PATH:	con "/dis/lib/bt/l2cap.dis";

	#
	# The signalling channel is CID 1 on a BR/EDR link and CID 5 on
	# an LE one, and the commands that travel on them are different
	# sets with different codes.  Everything else here is CID
	# agnostic, which is why one demultiplexer serves both.
	#
	Cbredr:	con 1;
	Cattr:	con 4;
	Cle:	con 5;
	Csmp:	con 6;

	# channel states
	Sfixed, Swait, Sup, Sdown:	con iota;

	# A whole service data unit, and the number of PDUs it arrived
	# in.  The credits it cost are given back when the reader takes
	# it, so the count has to travel with it.
	Sdu: adt {
		data:	array of byte;
		pdus:	int;
	};

	# One channel on a link.  A fixed channel is nothing but a CID
	# and the queue of frames that arrived for it; the credit-based
	# channels add to this adt rather than to a second one, so that
	# the demultiplexer has a single thing to look up.
	Chan: adt {
		cid:	int;			# the CID the peer sends to
		rq:	chan of array of byte;	# frames up from the link
		state:	int;

		#
		# A basic mode channel, which is what BR/EDR L2CAP opens:
		# no credits, no segmentation, one frame is one SDU, and
		# the size limit comes out of the configuration
		# handshake rather than out of the connection response.
		#
		basic:	int;
		confin:	int;			# the peer has configured us

		# credit-based channels only
		dcid:	int;			# the CID the peer receives on
		psm:	int;
		mtu:	int;			# the largest SDU we will take
		mps:	int;			# the largest PDU we will take
		dmtu:	int;			# the largest SDU the peer will take
		dmps:	int;			# the largest PDU the peer will take
		rxcred:	int;			# credits the peer still holds
		txcred:	int;			# credits the peer has given us
		sq:	chan of ref Sdu;	# whole SDUs up from the link
		wake:	chan of int;		# poked for a sender: credits, or the channel going
		rwake:	chan of int;		# poked for a reader: an SDU, or the channel going
		sdu:	array of byte;		# the SDU being reassembled
		have:	int;			# how much of it has arrived
		pdus:	int;			# in how many PDUs
		err:	string;			# why the channel went down
	};

	Mux: adt {
		c:	ref Hci->Conn;
		sig:	int;			# the signalling CID for this link
		#
		# What this side will answer a connection request for.
		# A PSM nobody is listening on is refused with the
		# reason that is true; one somebody is listening on gets
		# a channel, configured, on that channel.
		#
		psms:	list of (int, chan of ref Chan);
		mtu:	int;
		chans:	list of ref Chan;
		nextid:	int;			# signalling identifier
		# what is waiting for an answer: the identifier, the
		# code the answer must carry, and where to put it.  The
		# code is checked as well as the identifier because
		# identifiers wrap at 255 and the credit packets churn
		# through them, so a reused one must not be able to hand
		# a waiter something that is not its answer.
		pend:	list of (int, int, chan of array of byte);
		reply:	chan of int;
	};

	init:	fn(bt: Bt, hci: Hci): string;
	start:	fn(c: ref Hci->Conn): ref Mux;
	open:	fn(m: ref Mux, cid: int): chan of array of byte;
	send:	fn(m: ref Mux, cid: int, p: array of byte): string;
	stop:	fn(m: ref Mux);

	# LE credit-based channels.  connect asks the peer for one on a
	# PSM and comes back with it open or with the peer's reason for
	# refusing.  csend takes one SDU, segments it and pays a credit
	# per segment, blocking while the peer has given us none.  crecv
	# takes one whole reassembled SDU and gives back the credits it
	# cost.  cclose tears the channel down from this end; the peer
	# tearing it down from its end makes crecv and csend fail.
	connect:	fn(m: ref Mux, psm: int): (ref Chan, string);

	# the BR/EDR equivalent: a basic mode channel, opened with a
	# connection request and then configured in both directions.
	# What comes back is read and written with the same csend and
	# crecv a credit-based channel is.
	bconnect:	fn(m: ref Mux, psm: int): (ref Chan, string);

	#
	# and the other way round: say this side will answer a
	# connection request on that PSM, and take the channels a peer
	# opens off the channel this returns.  A second listen on the
	# same PSM is the first one's channel, so two callers cannot
	# each believe they own it.
	#
	listen:	fn(m: ref Mux, psm: int): chan of ref Chan;
	csend:		fn(m: ref Mux, c: ref Chan, p: array of byte): string;
	crecv:		fn(m: ref Mux, c: ref Chan): (array of byte, string);
	cclose:		fn(m: ref Mux, c: ref Chan): string;
};

#
# ATT: the attribute protocol.  One request may be outstanding at a
# time, which is what makes this a small layer: a request goes down,
# the matching response or an error response comes back, and
# notifications and indications arrive in between.
#
Att: module
{
	PATH:	con "/dis/lib/bt/att.dis";

	Dmtu:	con 23;

	# opcodes used by a client
	Rerror:		con 16r01;
	Rmtureq:	con 16r02;
	Rmturesp:	con 16r03;
	Rfindinfo:	con 16r04;
	Rfindinforesp:	con 16r05;
	Rfindtype:	con 16r06;
	Rfindtyperesp:	con 16r07;
	Rreadtype:	con 16r08;
	Rreadtyperesp:	con 16r09;
	Rread:		con 16r0a;
	Rreadresp:	con 16r0b;
	Rreadblob:	con 16r0c;
	Rreadblobresp:	con 16r0d;
	Rreadgroup:	con 16r10;
	Rreadgroupresp:	con 16r11;
	Rwrite:		con 16r12;
	Rwriteresp:	con 16r13;
	Rprepare:	con 16r16;
	Rprepareresp:	con 16r17;
	Rexecute:	con 16r18;
	Rexecuteresp:	con 16r19;
	Rwritecmd:	con 16r52;

	# Execute Write flags
	Xcancel:	con 0;
	Xwrite:		con 1;
	Rnotify:	con 16r1b;
	Rindicate:	con 16r1d;
	Rconfirm:	con 16r1e;

	Sess: adt {
		m:	ref L2cap->Mux;
		mtu:	int;
		rq:	chan of array of byte;	# frames up from L2CAP
		resp:	chan of array of byte;	# the answer to the outstanding request
		notify:	chan of array of byte;	# notifications and indications
		lock:	chan of int;		# one request at a time
	};

	init:	fn(bt: Bt, l2: L2cap): string;
	start:	fn(m: ref L2cap->Mux): ref Sess;
	stop:	fn(s: ref Sess);

	exchangemtu:	fn(s: ref Sess, want: int): (int, string);
	request:	fn(s: ref Sess, req: array of byte): (array of byte, string);
	command:	fn(s: ref Sess, req: array of byte): string;
	notifies:	fn(s: ref Sess): chan of array of byte;
	errstr:		fn(e: int): string;
};

#
# GATT: a database convention over ATT.  Services, the characteristics
# inside them and their descriptors -- which is exactly a directory of
# directories of files, so btfs(4) serves it as one.
#
Gatt: module
{
	PATH:	con "/dis/lib/bt/gatt.dis";

	Uprimary:	con 16r2800;
	Uinclude:	con 16r2802;
	Uchar:		con 16r2803;
	Ucccd:		con 16r2902;

	# the Generic Attribute service and its Service Changed
	# characteristic, which a device indicates on when the database
	# under it has moved
	Ugattsvc:	con 16r1801;
	Uchanged:	con 16r2a05;

	Pbroadcast:	con 16r01;
	Pread:		con 16r02;
	Pwritenoresp:	con 16r04;
	Pwrite:		con 16r08;
	Pnotify:	con 16r10;
	Pindicate:	con 16r20;

	Service: adt {
		start:	int;
		end:	int;
		uuid:	string;
	};

	Char: adt {
		dhandle:	int;	# the declaration
		vhandle:	int;	# the value
		ehandle:	int;	# last handle of this characteristic
		props:		int;
		uuid:		string;
		cccd:		int;	# 0 if it has none
		#
		# every descriptor between the value and the end of the
		# characteristic, as (handle, uuid), in handle order.
		# The client configuration is in here too, and cccd
		# above is the same handle: it is called out because
		# subscribing is what every client does and reading a
		# descriptor is what almost none do.
		#
		descs:		list of (int, string);
	};

	init:	fn(bt: Bt, att: Att): string;

	services:	fn(s: ref Att->Sess): (list of ref Service, string);
	chars:		fn(s: ref Att->Sess, svc: ref Service): (list of ref Char, string);

	# the services this one includes.  An include declaration names
	# a handle range and, for a 16 bit UUID, the UUID itself; for a
	# 128 bit one it does not, and the included service's own
	# declaration has to be read to find out what it is.  An
	# included service need not be a primary one, so it need not
	# appear in services() at all -- which is why ignoring these
	# loses attributes rather than only losing a relationship.
	includes:	fn(s: ref Att->Sess, svc: ref Service): (list of ref Service, string);
	descriptors:	fn(s: ref Att->Sess, c: ref Char): string;
	read:		fn(s: ref Att->Sess, h: int): (array of byte, string);
	write:		fn(s: ref Att->Sess, h: int, v: array of byte): string;

	#
	# A write with no response, which is a different opcode and not
	# an option on the same one.  A characteristic says which of
	# the two it takes, and the properties are not advice: Protocol
	# Mode in the HID service is write without response and not
	# write, and a Write Request to it is answered by a real device
	# with Write Not Permitted.
	#
	writecmd:	fn(s: ref Att->Sess, h: int, v: array of byte): string;
	subscribe:	fn(s: ref Att->Sess, c: ref Char, on: int): string;
	propstr:	fn(p: int): string;
};

#
# SMP: pairing.  LE legacy pairing, which needs nothing but AES-128 --
# the key generation functions c1 and s1 are built out of it -- and
# so can be done with the crypt(2) the kernel already links.  LE
# Secure Connections needs P-256, which this does not do.
#
#
# The GATT server: the same database as Gatt, read the other way.
# Gatt discovers a peer's attributes into the name space; this serves
# attributes out of it to a peer that has connected to us.
#
Gattsrv: module
{
	PATH:	con "/dis/lib/bt/gattsrv.dis";

	# One attribute.  A UUID here is on the wire the way it goes out
	# -- least significant byte first, two bytes or sixteen -- so
	# nothing has to reverse it in the middle of answering.
	Attr: adt {
		handle:	int;
		uuid:	array of byte;
		val:	array of byte;
		rd:	int;		# may a peer read it
		wr:	int;		# may a peer write it
	};

	# One link this database is being served on.  A subscription
	# belongs to the link and not to the database: two peers may
	# want notifications from the same characteristic and only one
	# of them may have asked.
	Sess: adt {
		m:	ref L2cap->Mux;
		mtu:	int;
		cccd:	list of (int, int);	# handle, what this peer wrote
		confirm: chan of int;		# an indication was answered
		up:	int;
	};

	Db: adt {
		attrs:	list of ref Attr;	# in handle order
		n:	int;			# the last handle given out
		sess:	list of ref Sess;	# links it is being served on
		changed:	int;		# the Service Changed value's handle
		lock:	chan of int;
	};

	init:	fn(bt: Bt, l2: L2cap): string;
	newdb:	fn(): ref Db;

	# Build the database.  A service, then its characteristics.
	# Handles are given out in the order attributes are added and
	# never given out again, so this happens before a peer is
	# connected; btfs(4) says so.
	addsvc:		fn(d: ref Db, uuid: array of byte): (int, string);
	# the declaration's handle, the value's, and the client
	# characteristic configuration descriptor's -- 0 when the
	# properties do not ask for one.
	addchar:	fn(d: ref Db, uuid: array of byte, props: int,
				val: array of byte): (int, int, int, string);

	# the value a peer reads, and the value a peer last wrote
	setval:	fn(d: ref Db, h: int, v: array of byte): string;
	getval:	fn(d: ref Db, h: int): array of byte;

	# serve this database to the peer on the far end of that link
	serve:	fn(d: ref Db, m: ref L2cap->Mux);

	# The value changed here.  Every peer that asked for
	# notifications on it is told, and every peer that asked for
	# indications is told and waited for.  A peer that asked for
	# neither is not written to at all.
	notify:	fn(d: ref Db, vh: int, v: array of byte): string;

	# is anyone subscribed to it
	subscribed:	fn(d: ref Db, vh: int): int;

	# The Generic Attribute service every database carries, and the
	# handle of the Service Changed value in it.  A peer that
	# subscribes to it is told when the database grows, which is the
	# only thing that makes growing it under a connected peer safe:
	# handles are never given out twice, so what the peer holds is
	# still right, but what it has not seen it has to be told about.
	Ugattsvc:	con 16r1801;
	Uchanged:	con 16r2a05;
	changedh:	fn(d: ref Db): int;
};

#
# The Service Discovery Protocol.  It is what makes Bluetooth Classic
# findable at all: LE has GATT, whose database is a name space of
# handles a client walks; Classic has this, which is a set of records
# a client asks for by UUID and gets back as a tree of typed data
# elements.  There is no walking and no handles to hold on to.
#
# One record is a set of (attribute id, value) pairs.  What matters to
# anything above is a handful of them: 0x0001 the service classes,
# 0x0004 the protocol stack the service is reached over -- which is
# where an RFCOMM channel number lives -- and 0x0100 its name.
#
Sdp: module
{
	PATH:	con "/dis/lib/bt/sdp.dis";

	# SDP is always on this PSM, and only on it
	Psm:	con 16r0001;

	# data element types, which are the top five bits of the
	# descriptor byte
	Enil:	con 0;
	Euint:	con 1;
	Esint:	con 2;
	Euuid:	con 3;
	Etext:	con 4;
	Ebool:	con 5;
	Eseq:	con 6;
	Ealt:	con 7;
	Eurl:	con 8;

	# the attributes anything here looks at
	Ahandle:	con 16r0000;
	Aclasses:	con 16r0001;
	Aprotos:	con 16r0004;
	Abrowse:	con 16r0005;
	Aprofiles:	con 16r0009;
	Aname:		con 16r0100;

	# the browse group every service that wants to be found is in
	Upublic:	con "1002";

	#
	# One data element.  A leaf carries one of n, s or uuid
	# depending on its type; a sequence or an alternative carries
	# its children, in order.
	#
	Elem: adt {
		ty:	int;
		n:	big;			# an integer or a boolean
		s:	string;			# text or a URL
		#
		# and the same bytes unconverted.  A text element is not
		# always text: the HID descriptor list carries a report
		# descriptor in one, and its bytes are not UTF-8 and do
		# not survive being made into a string.
		#
		data:	array of byte;
		uuid:	string;			# a UUID as hexadecimal
		l:	list of ref Elem;	# a sequence or an alternative

		# the nth child, or nil
		at:	fn(e: self ref Elem, i: int): ref Elem;
		text:	fn(e: self ref Elem): string;
	};

	#
	# One service record: what the server answered with, in the
	# order it answered.
	#
	Rec: adt {
		handle:	int;
		attrs:	list of (int, ref Elem);

		attr:	fn(r: self ref Rec, id: int): ref Elem;
	};

	init:	fn(bt: Bt, l2: L2cap): string;

	#
	# Every record whose service class list holds that UUID, with
	# every attribute the server will give.  ch is an open L2CAP
	# channel to Psm.
	#
	search:	fn(m: ref L2cap->Mux, ch: ref L2cap->Chan, uuid: string): (list of ref Rec, string);

	# One data element out of a buffer: the element, how many bytes
	# it took, and an error.  It is exposed because it is the part
	# worth testing on its own.
	parse:	fn(a: array of byte, o: int): (ref Elem, int, string);

	#
	# What a protocol descriptor list says, one line per protocol,
	# lowest first: "l2cap 0x0003", "rfcomm 1", and so on.  A
	# protocol with no parameters is just its name.
	#
	protos:	fn(r: ref Rec): list of string;

	# the well known name of a 16 bit UUID, or the UUID itself
	uuidname:	fn(u: string): string;

	#
	# The server half.  A device that wants to be found by a
	# Classic host has to answer these, and what it answers with is
	# a set of records built the same way a client reads them.
	#
	# The building blocks: an element of each kind, and a sequence
	# of them.  A record is a list of (attribute, value), and a
	# database is a list of records -- the same Rec a client gets
	# back, so what this side serves and what it reads are the same
	# thing in the same shape.
	#
	uint:	fn(v: int, width: int): ref Elem;
	uuidof:	fn(u: string): ref Elem;
	text:	fn(s: string): ref Elem;
	seq:	fn(l: list of ref Elem): ref Elem;

	# a record's bytes, and a whole answer's
	packrec:	fn(r: ref Rec): array of byte;

	#
	# Answer one request.  What goes in is a whole SDP protocol data
	# unit and what comes out is the answer to it, or nil for a
	# request this does not serve -- which is answered with an error
	# rather than with silence.
	#
	answer:	fn(db: list of ref Rec, p: array of byte): array of byte;

	#
	# The HID report descriptor a record carries, or nil.  It lives
	# in the HID descriptor list, attribute 0x0206, as a sequence of
	# (descriptor type, bytes) pairs; type 0x22 is the report
	# descriptor, which is the same thing hidreport(2) parses off an
	# LE device's 2a4b characteristic.
	#
	Ahiddesc:	con 16r0206;
	Dreport:	con 16r22;
	hiddesc:	fn(r: ref Rec): array of byte;
};

#
# RFCOMM: serial ports over L2CAP, which is TS 07.10 with a Bluetooth
# adaptation layer.  It is a multiplexer inside a multiplexer: one
# L2CAP channel to PSM 3 carries a session, and the session carries up
# to thirty data link connections, each named by a server channel
# number -- which is what an SDP record's protocol descriptor list
# gives, so a device is found with SDP and reached with this.
#
Rfcomm: module
{
	PATH:	con "/dis/lib/bt/rfcomm.dis";

	# RFCOMM is always on this PSM
	Psm:	con 16r0003;

	#
	# One session: the multiplexer on one L2CAP channel, and every
	# data link connection open on it.
	#
	Sess: adt {
		m:	ref L2cap->Mux;
		ch:	ref L2cap->Chan;
		up:	int;
		dead:	string;			# why it went, or nil
		dlcs:	list of ref Dlc;
		#
		# Server channels this side will answer a SABM on, and
		# where the connections a peer opens arrive.  A session
		# started by a peer carries both directions: it may open
		# a port on us while we open one on it.
		#
		chans:	list of (int, chan of ref Dlc);
		lock:	chan of int;
		# answers the reader hands to whoever is waiting: the
		# DLCI, the frame or control type, and the value
		reply:	chan of (int, int, array of byte);
	};

	#
	# One data link connection, which is a serial port.  credits is
	# what the peer has given us to send with; given is what we
	# have given the peer.  They go opposite ways and conflating
	# them is the easy mistake here.
	#
	Dlc: adt {
		s:	ref Sess;
		dlci:	int;
		state:	int;			# 0 opening, 1 up, 2 down
		mtu:	int;			# the frame size agreed
		credits: int;			# ours to spend
		given:	int;			# the peer's to spend
		err:	string;
		rq:	chan of array of byte;
		wake:	chan of int;

		# the server channel behind the DLCI
		chanof:	fn(d: self ref Dlc): int;
	};

	init:	fn(bt: Bt, l2: L2cap): string;

	# start the multiplexer on an open L2CAP channel to Psm
	start:	fn(m: ref L2cap->Mux, ch: ref L2cap->Chan): (ref Sess, string);
	stop:	fn(s: ref Sess);

	# one serial port, by the server channel number SDP gave
	open:	fn(s: ref Sess, ch: int): (ref Dlc, string);
	close:	fn(d: ref Dlc): string;

	#
	# Take a session a peer opened, and say this side will answer
	# on a server channel.  accept() is start()'s other half: the
	# multiplexer is already up because the peer put it up, so
	# there is nothing to ask for.
	#
	accept:	fn(m: ref L2cap->Mux, ch: ref L2cap->Chan): ref Sess;
	serve:	fn(s: ref Sess, ch: int): chan of ref Dlc;

	# a stream, not records: a write longer than the frame the peer
	# agreed to is cut into frames, and a read is whatever arrived
	write:	fn(d: ref Dlc, p: array of byte): string;
	read:	fn(d: ref Dlc): (array of byte, string);

	#
	# The frame check sequence over as many header bytes as the
	# frame type says.  It is here because it is the one part of
	# this that can be checked against numbers written down
	# elsewhere: SABM on DLCI 0 is 03 3F 01 1C and UA is
	# 03 73 01 D7 in every description of RFCOMM there is.
	#
	fcs:	fn(p: array of byte): int;
};

#
# BNEP: ethernet frames over L2CAP, which is what the personal area
# network profiles are made of.  A BNEP link carries whole ethernet
# frames with their addresses left out where they can be inferred --
# the two ends of the link are the two ends of the wire, so a frame
# between them needs neither address written down.
#
# The addresses themselves are the two BD_ADDRs.  That is the neat
# part of PAN: a Bluetooth link already has two six byte addresses on
# it, so it can be an ethernet without inventing any.
#
Bnep: module
{
	PATH:	con "/dis/lib/bt/bnep.dis";

	# BNEP is always on this PSM
	Psm:	con 16r000f;

	# the PAN service classes: a user, a network access point, and
	# an ad hoc group
	Upanu:	con "1115";
	Unap:	con "1116";
	Ugn:	con "1117";

	# packet types, without the extension bit
	Tgeneral:	con 16r00;
	Tcontrol:	con 16r01;
	Tcompressed:	con 16r02;
	Tsrconly:	con 16r03;
	Tdstonly:	con 16r04;
	Text:		con 16r80;	# an extension header follows

	# control message types
	Cnotunderstood:	con 16r00;
	Csetup:		con 16r01;
	Csetupresp:	con 16r02;

	#
	# One BNEP link.  What is under it is a file: btfs serves an
	# open L2CAP channel as one where a write is an SDU and a read
	# is the next SDU whole, which is exactly what BNEP wants, and
	# taking it that way is what lets the program above be an
	# ordinary file client with no Bluetooth in it.
	#
	Link: adt {
		fd:	ref Sys->FD;
		local:	array of byte;	# our BD_ADDR, which is our MAC
		remote:	array of byte;	# theirs
	};

	init:	fn(bt: Bt): string;

	#
	# Set up a link on an open channel to Psm: a setup request
	# naming what this side is and what it wants the other to be,
	# and the answer to it.  dst and src are service class UUIDs.
	#
	start:	fn(fd: ref Sys->FD, local, remote: array of byte,
			dst, src: string): (ref Link, string);

	# one whole ethernet frame in, and one out.  What crosses this
	# is what crosses a wire: destination, source, type, payload.
	send:	fn(l: ref Link, f: array of byte): string;
	recv:	fn(l: ref Link): (array of byte, string);
};

#
# AVDTP: the signalling under A2DP.  A small request-response protocol
# on an L2CAP channel to PSM 25, and a second channel to the same PSM
# that is the media itself.
#
# What is not here is a codec.  A2DP is AVDTP plus SBC, and SBC is not
# implemented: this finds a sink, asks what it can do, configures it,
# and opens and starts a stream, and what goes down the media channel
# is whatever the caller hands it.  Nothing here turns sound into SBC
# or back.
#
Avdtp: module
{
	PATH:	con "/dis/lib/bt/avdtp.dis";

	# AVDTP is always on this PSM, signalling and media both
	Psm:	con 16r0019;

	# signal identifiers
	Sdiscover:	con 16r01;
	Sgetcaps:	con 16r02;
	Ssetconfig:	con 16r03;
	Sgetconfig:	con 16r04;
	Sreconfigure:	con 16r05;
	Sopen:		con 16r06;
	Sstart:		con 16r07;
	Sclose:		con 16r08;
	Ssuspend:	con 16r09;
	Sabort:		con 16r0a;
	Sgetallcaps:	con 16r0c;

	# service capability categories
	Cmediatransport:	con 16r01;
	Creporting:		con 16r02;
	Crecovery:		con 16r03;
	Ccontent:		con 16r04;
	Cheader:		con 16r05;
	Cmultiplexing:		con 16r06;
	Cmediacodec:		con 16r07;
	Cdelayreport:		con 16r08;

	# media types, and which end of a stream an endpoint is
	Maudio:		con 0;
	Mvideo:		con 1;

	#
	# One stream endpoint the far side has.  sink says which end of
	# a stream it is: a headset's endpoint is a sink, and something
	# that plays into this side would be a source.
	#
	Sep: adt {
		seid:	int;
		inuse:	int;
		media:	int;
		sink:	int;
		caps:	list of ref Cap;
	};

	#
	# One service capability.  The codec one's bytes are the
	# codec's own business and are handed back rather than
	# interpreted, because there is no codec here to interpret
	# them with.
	#
	Cap: adt {
		cat:	int;
		info:	array of byte;
	};

	#
	# The signalling channel.  What is under it is a file, for the
	# same reason bnep's is: the program above is an ordinary file
	# client and btfs owns the link.
	#
	Sess: adt {
		fd:	ref Sys->FD;
		label:	int;		# the next transaction label
	};

	init:	fn(bt: Bt): string;
	start:	fn(fd: ref Sys->FD): ref Sess;

	discover:	fn(s: ref Sess): (list of ref Sep, string);
	capabilities:	fn(s: ref Sess, seid: int): (list of ref Cap, string);
	setconfig:	fn(s: ref Sess, acp, int0: int, caps: list of ref Cap): string;
	open:		fn(s: ref Sess, seid: int): string;
	startstream:	fn(s: ref Sess, seid: int): string;
	suspend:	fn(s: ref Sess, seid: int): string;
	close:		fn(s: ref Sess, seid: int): string;

	# an RTP header and whatever the caller is carrying under it
	media:	fn(seq, stamp, ssrc, pt: int, payload: array of byte): array of byte;

	#
	# Choosing an SBC configuration out of what a sink says it can
	# do.  This is A2DP's and not AVDTP's -- AVDTP does not know
	# what a codec is -- but it is here rather than in a module of
	# its own because it is one function and it belongs with the
	# capability it reads.
	#
	# What comes back is the codec capability to configure with,
	# and a line saying what was chosen, so that what was agreed
	# can be read rather than guessed at.
	#
	Vsbc:	con 16r00;	# the codec identifier for SBC
	sbcchoose:	fn(c: ref Cap): (ref Cap, string, string);

	#
	# One SBC frame of silence in the configuration that was
	# agreed.  This is not an encoder and it is not audio: it is
	# the frame an encoder would emit for a block of nothing, with
	# the header, the length and the CRC that the agreed
	# configuration calls for and every sample bit zero.
	#
	# It exists because a stream that carries something other than
	# SBC while its configuration says SBC is a lie on the wire.
	# The bench used to send counted-up bytes down a channel that
	# had just agreed to SBC; both ends of the bench were content
	# and Wireshark, which had not agreed to anything, read the
	# capture and called the frames malformed.
	#
	sbcsilence:	fn(c: ref Cap): (array of byte, string);

	#
	# How many samples per channel one such frame carries, which is
	# the blocks times the subbands.  A media packet's timestamp
	# counts samples, so a sender needs this and cannot get it from
	# the frame's length.
	#
	sbcsamples:	fn(c: ref Cap): int;
};

#
# Hands free: the control half of HFP, which is AT commands over an
# RFCOMM serial port.  It sits on the file btfs serves for an RFCOMM
# channel and is a line protocol; there is no Bluetooth in it.
#
# What is not here is the audio.  A call's sound goes over a
# synchronous connection -- SCO or eSCO -- which needs the controller
# to carry it and, over USB, isochronous endpoints, and none of that
# is verified in this tree.  So this can see a call, place one, answer
# one and hang up, and cannot hear or be heard.
#
Hfp: module
{
	PATH:	con "/dis/lib/bt/hfp.dis";

	# the service classes: a gateway is what a phone offers, and a
	# hands free unit is what this side is
	Uag:	con "111f";
	Uhf:	con "111e";
	# and the headset profile's, which is the older and smaller one
	Uhsag:	con "1112";

	Sess: adt {
		fd:	ref Sys->FD;
		buf:	string;			# what has arrived and is not a line yet
		agfeatures:	int;
		names:	list of string;		# the indicators, in the gateway's order
		values:	list of (string, int);
		events:	chan of string;		# what changed, for whoever watches
		#
		# Everything that is not an unsolicited line, on its way
		# to whoever asked.  One process reads the port and this
		# is how what it read gets to the asker: two readers of
		# one buffer is two halves of one line in two places,
		# which is what happened when there were two.
		#
		replies:	chan of string;
	};

	init:	fn(bt: Bt): string;
	start:	fn(fd: ref Sys->FD): ref Sess;

	# the handshake that has to happen before anything else
	slc:	fn(s: ref Sess): string;

	# one command and the lines that came back before the OK
	command:	fn(s: ref Sess, cmd: string): (list of string, string);

	# what an indicator is now, or -1 if the gateway has no such one
	value:	fn(s: ref Sess, name: string): int;

	dial:	fn(s: ref Sess, number: string): string;
	answer:	fn(s: ref Sess): string;
	hangup:	fn(s: ref Sess): string;

	# and nothing to start: the reader is spawned by start(),
	# because a gateway sends when it feels like it and something
	# has to be reading from the moment the port is open.
};

Smp: module
{
	PATH:	con "/dis/lib/bt/smp.dis";

	# IO capabilities
	Iodisplayonly:	con 0;
	Iodisplayyesno:	con 1;
	Iokeyboardonly:	con 2;
	Ionoio:		con 3;
	Iokeyboarddisplay:	con 4;

	Bond: adt {
		addr:	string;		# the peer, written down
		atype:	int;
		# the controller it was made on, written down.  Empty for
		# a bond read from a key file written before there was
		# more than one controller to make it on.
		local:	string;
		ltk:	array of byte;
		ediv:	int;
		rand:	array of byte;
		irk:	array of byte;
		csrk:	array of byte;
		#
		# The BR/EDR link key, which is the Classic half of the
		# same idea: sixteen bytes agreed once and used to
		# authenticate every link afterwards.  A device may have
		# both -- one bond, two radios' worth of keys -- so this
		# is another field rather than another kind of bond.
		#
		lk:	array of byte;
		lktype:	int;

		text:	fn(b: self ref Bond): string;
	};

	init:	fn(bt: Bt, hci: Hci, l2: L2cap): string;
	parse:	fn(s: string): ref Bond;

	# ah(k, r), the random address hash: e(k, r padded to a block)
	# taken modulo 2^24, which is to say its low three bytes.  It is
	# what a peripheral used to build the resolvable private address
	# it is advertising from, and running it again is the only way
	# to recognise the peripheral behind one.
	ah:	fn(k, r: array of byte): array of byte;

	# does this bond's identity resolving key account for this
	# address?  False for an address that is not resolvable, and for
	# a bond that distributed no key.
	resolve:	fn(b: ref Bond, atype: int, addr: array of byte): int;

	# pair as the initiator over an already open connection
	pair:	fn(c: ref Hci->Conn, m: ref L2cap->Mux, iocap: int): (ref Bond, string);

	# and as the responder: wait for a peer to ask, answer it,
	# hand the controller the key it then asks for, and distribute
	# a long term key so the peer can come back
	# known is the bond already held for this peer, or nil.  A
	# controller asking for a key by its diversifier is asking for
	# that one, and answering it is what lets a bonded peer come
	# back without pairing again.
	respond:	fn(c: ref Hci->Conn, m: ref L2cap->Mux,
				known: ref Bond): (ref Bond, string);
};
