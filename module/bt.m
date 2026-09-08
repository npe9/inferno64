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
	};

	Conn: adt {
		x:	ref Ctlr;	# the controller this link is on
		handle:	int;
		role:	int;
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
