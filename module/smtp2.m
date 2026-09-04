#
# SMTP message submission over tls12(2), enough to send through Gmail
# (smtp.gmail.com:465, implicit TLS). Greeting, EHLO, AUTH (PLAIN, an app
# password over TLS), MAIL/RCPT/DATA, QUIT. The transport is this tree's
# own verifying TLS 1.2 client, never a host command. This is the send
# half of the upas port; the plaintext smtp(2) module is separate.
#
Smtp2: module
{
	PATH:	con "/dis/lib/smtp2.dis";

	Sender: adt {
		fd:		ref Sys->FD;
		sess:		ref TLS12->Session;
		rbuf:		array of byte;
		greeting:	string;

		# EHLO; returns the multi-line 250 response text (its AUTH line
		# lists the mechanisms) or an error.
		ehlo:	fn(s: self ref Sender, me: string): (string, string);
		# AUTH PLAIN with user and an app password.
		auth:	fn(s: self ref Sender, user, pass: string): string;
		# a full MAIL FROM / RCPT TO / DATA transaction. msg is the
		# RFC 822 message (headers + blank line + body).
		mail:	fn(s: self ref Sender, from: string, rcpts: list of string, msg: array of byte): string;
		quit:	fn(s: self ref Sender): string;
	};

	init:		fn(): string;
	connect:	fn(host: string, port: int, dialip: string): (ref Sender, string);
};
