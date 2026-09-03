# ssh(2) - an SSH-2 transport + connection client, in Limbo, ported
# from 9front's /sys/src/cmd/ssh.c. curve25519-sha256 key exchange, a
# host key that is either ssh-rsa (signed rsa-sha2-256) or
# ecdsa-sha2-nistp256 (verified with p256(2)), and the
# chacha20-poly1305@openssh.com authenticated cipher (keyring's raw
# ChaCha20 + one-shot Poly1305, see chachatest(1)). One cipher, one
# KEX, no GSSAPI, no compression - a deliberately small surface. Client
# authentication is RSA only (from a file or factotum(4)).
#
# connect() runs the version and key exchange and returns an
# established, verified, encrypted transport. login() then authenticates
# by publickey (RSA, signed rsa-sha2-256) and/or password, and run()
# opens a session channel and execs one command, collecting its output.
# writepkt/readpkt remain exposed for callers that need to drive the
# connection message by message (e.g. an interactive shell with a pty,
# which this module does not yet package).

Ssh: module
{
	PATH:	con "/dis/lib/ssh.dis";

	# SSH-2 message numbers (RFC 4253/4252/4254), as in ssh.c
	MSG_DISCONNECT:		con 1;
	MSG_IGNORE:		con 2;
	MSG_UNIMPLEMENTED:	con 3;
	MSG_DEBUG:		con 4;
	MSG_SERVICE_REQUEST:	con 5;
	MSG_SERVICE_ACCEPT:	con 6;
	MSG_KEXINIT:		con 20;
	MSG_NEWKEYS:		con 21;
	MSG_ECDH_INIT:		con 30;
	MSG_ECDH_REPLY:		con 31;
	MSG_USERAUTH_REQUEST:	con 50;
	MSG_USERAUTH_FAILURE:	con 51;
	MSG_USERAUTH_SUCCESS:	con 52;
	MSG_USERAUTH_BANNER:	con 53;
	MSG_USERAUTH_PK_OK:	con 60;
	MSG_GLOBAL_REQUEST:	con 80;
	MSG_REQUEST_SUCCESS:	con 81;
	MSG_REQUEST_FAILURE:	con 82;
	MSG_CHANNEL_OPEN:		con 90;
	MSG_CHANNEL_OPEN_CONFIRMATION:	con 91;
	MSG_CHANNEL_OPEN_FAILURE:	con 92;
	MSG_CHANNEL_WINDOW_ADJUST:	con 93;
	MSG_CHANNEL_DATA:		con 94;
	MSG_CHANNEL_EXTENDED_DATA:	con 95;
	MSG_CHANNEL_EOF:		con 96;
	MSG_CHANNEL_CLOSE:	con 97;
	MSG_CHANNEL_REQUEST:	con 98;
	MSG_CHANNEL_SUCCESS:	con 99;
	MSG_CHANNEL_FAILURE:	con 100;

	# one direction of the encrypted transport: a sequence number and
	# the two ChaCha20 states of chacha20-poly1305@openssh.com (cs1
	# keys the 4-byte length, cs2 keys the payload and the Poly1305
	# one-time key), created from the KDF output at NEWKEYS time.
	Dir: adt {
		seq:	int;
		cs1:	ref Keyring->Chachastate;
		cs2:	ref Keyring->Chachastate;
	};

	Conn: adt {
		fd:		ref Sys->FD;
		vc:		string;			# our version string, no CRLF
		vs:		string;			# server version string, no CRLF
		snd:		ref Dir;
		rcv:		ref Dir;
		encrypted:	int;			# 0 until NEWKEYS installs the ciphers
		sid:		array of byte;		# session id (first exchange hash)
		hostkey:	array of byte;		# server host-key blob (K_S)
		thumb:		string;			# "sha256=<base64>" of the host key

		# read one decrypted packet payload (msg-type byte first);
		# returns (nil, err) at EOF or on a bad tag
		readpkt:	fn(c: self ref Conn): (array of byte, string);
		# encrypt and send one packet payload (msg-type byte first)
		writepkt:	fn(c: self ref Conn, payload: array of byte): string;
		close:		fn(c: self ref Conn);
	};

	# a client key for publickey authentication: the ssh-rsa public
	# key blob to present (identical to an authorized_keys line's
	# base64 body) and the means to sign. A key from a file carries the
	# private exponent d; a key held by factotum(4) carries an open rpc
	# fd instead and never exposes the secret (the Plan 9 model - the
	# private key stays inside the agent).
	Authkey: adt {
		blob:	array of byte;
		n:	ref Keyring->IPint;
		d:	ref Keyring->IPint;	# nil for a factotum key
		modlen:	int;
		facfd:	ref Sys->FD;		# non-nil for a factotum key
	};

	# result of running a remote command
	Result: adt {
		stdout:	array of byte;
		stderr:	array of byte;
		status:	int;		# exit status (0 = success)
	};

	init:	fn();

	# dial addr (a real dial string, e.g. "tcp!10.0.0.1!22"), run the
	# version exchange and key exchange against host (used for the
	# exchange hash and messages), and verify the host key. If
	# wantthumb is non-empty it must equal the server's computed
	# "sha256=<base64>" thumbprint or the connection is refused
	# (fail-closed; no silent trust-on-first-use here). Returns the
	# established encrypted Conn or ("", err).
	connect:	fn(addr, host, wantthumb: string): (ref Conn, string);

	# parse a PEM PKCS#1 RSA private key (the format ssh-keygen -m PEM
	# writes) into an Authkey usable for publickey auth. Returns
	# (nil, err) on a malformed key.
	rsakey_pem:	fn(pem: string): (ref Authkey, string);

	# obtain a publickey Authkey backed by factotum(4): open its rpc,
	# start proto=rsa role=client (with any extra keyspec, e.g.
	# "service=ssh"), and read the offered key's modulus and exponent.
	# Signing goes back to factotum, so the private key is never seen.
	# Returns (nil, err) if factotum has no matching rsa key.
	rsakey_factotum:	fn(keyspec: string): (ref Authkey, string);

	# authenticate to an already-connected server as user. Sends the
	# ssh-userauth service request, then tries publickey (if key is
	# non-nil) and password (if password is non-empty), in that order.
	# Returns "" once the server accepts, or an error.
	login:	fn(c: ref Conn, user: string, key: ref Authkey, password: string): string;

	# run one command on an authenticated connection: opens a session
	# channel, execs cmd, and collects its output to end of channel.
	# Returns the Result or (nil, err).
	run:	fn(c: ref Conn, cmd: string): (ref Result, string);

	# open an interactive session: request a pseudo-terminal (when
	# usepty is set, with the given term type and window size), start
	# the remote shell, and shuttle bytes between the local fds and the
	# SSH channel - the Plan 9 model, where the terminal emulation is
	# vt(1)'s job and this only moves bytes (cf. telnet(1)). Two
	# processes run: one copies `in` to the channel, one copies channel
	# output to `out` and `err`. Returns the remote exit status when the
	# channel closes. The caller sets the local terminal's raw mode
	# (/dev/consctl) around this, as ssh(1) does.
	shell:	fn(c: ref Conn, usepty: int, term: string, cols, rows: int,
			in, out, err: ref Sys->FD): (int, string);
};
