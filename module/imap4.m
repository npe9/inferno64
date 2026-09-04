#
# IMAP4rev1 client over tls12(2), enough to reach Gmail (imap.gmail.com
# :993): greeting, CAPABILITY, LOGIN (an app password over TLS), LIST,
# SELECT, FETCH and LOGOUT. The transport is this tree's own verifying
# TLS 1.2 client - never a host command. Line/literal parsing per RFC
# 3501. Used by the upas fetch path.
#
Imap4: module
{
	PATH:	con "/dis/lib/imap4.dis";

	Client: adt {
		fd:	ref Sys->FD;		# underlying TCP connection
		sess:	ref TLS12->Session;	# TLS session over fd
		rbuf:	array of byte;		# decrypted-but-unread bytes
		tagn:	int;			# command tag counter
		host:	string;

		# send a command (no CRLF) and read its tagged response;
		# returns (untagged lines, completion line, error).
		docmd:	fn(c: self ref Client, command: string): (list of string, string, string);
		capa:	fn(c: self ref Client): (string, string);
		login:	fn(c: self ref Client, user, pass: string): string;
		mailboxes:	fn(c: self ref Client, reff, pat: string): (list of string, string);
		# SELECT a mailbox; returns the EXISTS message count.
		select:	fn(c: self ref Client, mbox: string): (int, string);
		# EXAMINE (read-only SELECT); returns the EXISTS count.
		examine:	fn(c: self ref Client, mbox: string): (int, string);
		# STATUS: returns the "* STATUS" line for the requested items
		# (e.g. "MESSAGES UNSEEN") without selecting the mailbox.
		status:	fn(c: self ref Client, mbox, items: string): (string, string);
		# FETCH one item (e.g. "BODY.PEEK[]" or "BODY.PEEK[HEADER]")
		# of message msg; returns its literal bytes.
		fetch:	fn(c: self ref Client, msg: int, item: string): (array of byte, string);
		# SEARCH the selected mailbox; returns matching message numbers.
		search:	fn(c: self ref Client, criteria: string): (list of int, string);
		# STORE flags on a message, e.g. item "+FLAGS (\Seen)" to mark
		# read or "+FLAGS (\Deleted)" to mark for expunge.
		store:	fn(c: self ref Client, msg: int, item: string): string;
		# COPY a message to another mailbox.
		copy:	fn(c: self ref Client, msg: int, mbox: string): string;
		# EXPUNGE deleted messages from the selected mailbox.
		expunge:	fn(c: self ref Client): string;
		# mailbox management.
		create:	fn(c: self ref Client, mbox: string): string;
		delete:	fn(c: self ref Client, mbox: string): string;
		rename:	fn(c: self ref Client, old, newmb: string): string;
		logout:	fn(c: self ref Client): string;
	};

	init:		fn(): string;
	# dial dialip (or host if dialip is "") at port, run the TLS
	# handshake naming host for SNI/cert, and read the server greeting.
	# dialip lets a caller resolve the name outside emu, where /net/cs
	# does not resolve, while still verifying the certificate for host.
	connect:	fn(host: string, port: int, dialip: string): (ref Client, string);
};
