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

	Conn: adt {
		handle:	int;
		role:	int;
		atype:	int;
		addr:	array of byte;
		encrypted:	int;
		up:	chan of array of byte;	# whole L2CAP frames
		closed:	chan of string;
	};

	init:	fn(bt: Bt, t: Bttransport): string;

	# reset the controller and read what identifies it
	start:	fn(): string;
	stop:	fn();

	localaddr:	fn(): array of byte;
	localver:	fn(): string;
	aclmtu:		fn(): (int, int);	# payload size, buffer count

	cmd:	fn(op: int, p: array of byte): (int, array of byte, string);

	lescan:	fn(on: int): string;
	advs:	fn(): chan of ref Adv;

	leconnect:	fn(atype: int, addr: array of byte): (ref Conn, string);
	disconnect:	fn(c: ref Conn): string;
	conns:		fn(): list of ref Conn;

	acl:	fn(c: ref Conn, p: array of byte): string;

	lerand:		fn(): (array of byte, string);
	leencrypt:	fn(key, plain: array of byte): (array of byte, string);
	lestartencrypt:	fn(c: ref Conn, rand: array of byte, ediv: int, ltk: array of byte): string;
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

	Mux: adt {
		c:	ref Hci->Conn;
		mtu:	int;
		chans:	list of (int, chan of array of byte);
		reply:	chan of int;
	};

	init:	fn(bt: Bt, hci: Hci): string;
	start:	fn(c: ref Hci->Conn): ref Mux;
	open:	fn(m: ref Mux, cid: int): chan of array of byte;
	send:	fn(m: ref Mux, cid: int, p: array of byte): string;
	stop:	fn(m: ref Mux);
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
	};

	init:	fn(bt: Bt, att: Att): string;

	services:	fn(s: ref Att->Sess): (list of ref Service, string);
	chars:		fn(s: ref Att->Sess, svc: ref Service): (list of ref Char, string);
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
};
