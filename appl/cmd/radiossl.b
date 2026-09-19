implement Radiossl;

#
# ssl(3) over the radio, which is the claim doc/pycubed-plan.ms rests on
# and which nothing had run.
#
# The claim is that an encrypted, integrity-checked link over this radio
# needs no IP stack under it, because ssl(3) is a filter over a file
# descriptor -- "fd m" on its control file, and ssl->connect() taking a
# ref Sys->FD -- rather than something that lives on a network.  So the
# whole of it is: open /dev/radio0/data, hand that descriptor to
# ssl->connect(), and write through what comes back.
#
# What this does NOT do is authenticate.  keyring->auth() wants a signer
# and certificates, and this uses a shared secret written into both ends
# instead, which is a demonstration of the transport and not of the
# authentication.  A constant in a program is exactly what
# doc/pycubed-plan.ms criticises cdh.py for, and it is here for the same
# reason cdh.py has one: to show the shape without the ceremony.  Said
# plainly rather than glossed.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
include "security.m";
	ssl: SSL;

Radiossl: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Data:	con "/dev/radio0/data";

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	ssl = load SSL SSL->PATH;
	if(ssl == nil){
		sys->print("radiossl: load %s: %r\n", SSL->PATH);
		return;
	}

	mode := "recv";
	if(tl argv != nil)
		mode = hd tl argv;
	rest := argv;
	if(rest != nil)
		rest = tl rest;
	if(rest != nil)
		rest = tl rest;

	fd := sys->open(Data, Sys->ORDWR);
	if(fd == nil){
		sys->print("radiossl: %s: %r\n", Data);
		return;
	}

	(err, c) := ssl->connect(fd);
	if(err != nil){
		sys->print("radiossl: connect: %s\n", err);
		return;
	}
	sys->print("ssl attached to %s, dir %s\n", Data, c.dir);

	# The same secret at both ends.  Digesting only: with "alg sha"
	# ssl(3) appends a SHA1 over the secret, the message and a message
	# number, so a packet that did not come from the other end does
	# not read.  That is 22 bytes a message -- devssl.c:648 is
	# diglen+2 -- which is what doc/pycubed-plan.ms counts against the
	# payload budget.
	key := "not-a-real-key-see-the-comment";
	if(mode == "recv" && rest != nil)
		key = hd rest;
	secret := array of byte key;
	sys->print("ssl secret %q\n", key);
	err = ssl->secret(c, secret, secret);
	if(err != nil){
		sys->print("radiossl: secret: %s\n", err);
		return;
	}
	if(sys->fprint(c.cfd, "alg sha") < 0){
		sys->print("radiossl: alg sha: %r\n");
		return;
	}
	sys->print("ssl digesting with sha1\n");

	if(mode == "send"){
		msg := "through-ssl-over-the-radio";
		if(rest != nil){
			msg = hd rest;
			if(tl rest != nil)
				secret = array of byte hd tl rest;
		}
		b := array of byte msg;
		n := sys->write(c.dfd, b, len b);
		sys->print("wrote %d of %d: %r\n", n, len b);
		if(n == len b)
			sys->print("RADIOSSL-SENT %d\n", n);
	}else{
		b := array[251] of byte;
		n := sys->read(c.dfd, b, len b);
		if(n <= 0){
			sys->print("radiossl: read: %r\n");
			return;
		}
		sys->print("RADIOSSL-GOT %q\n", string b[0:n]);
	}
}
