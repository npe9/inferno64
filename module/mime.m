#
# MIME (RFC 2045-2047) message parsing: split an RFC 822 message into a
# tree of parts, decode Content-Transfer-Encoding (base64,
# quoted-printable, 7bit/8bit/binary), and expose each part's content
# type, parameters, disposition and attachment filename. Used by upas/fs
# to decompose a message into per-part files, the way Plan 9 upas/fs does.
#
Mime: module
{
	PATH:	con "/dis/lib/mime.dis";

	Part: adt {
		ctype:		string;			# "type/subtype", lowercased
		params:		list of (string, string);	# content-type params
		disp:		string;			# content-disposition (inline/attachment)
		filename:	string;			# attachment filename, if any
		encoding:	string;			# content-transfer-encoding
		headers:	list of (string, string);	# this part's headers
		body:		array of byte;		# DECODED body (leaf parts)
		parts:		list of ref Part;	# subparts (multipart)

		ismultipart:	fn(p: self ref Part): int;
		param:		fn(p: self ref Part, name: string): string;
		# the first leaf part whose ctype matches (e.g. "text/plain"),
		# searched depth-first; nil if none.
		find:		fn(p: self ref Part, ctype: string): ref Part;
	};

	init:	fn();
	# parse a whole message (headers + body) into a Part tree.
	parse:	fn(msg: array of byte): ref Part;
	# decode a body under a named transfer encoding.
	decode:	fn(data: array of byte, encoding: string): array of byte;
	# decode RFC 2047 encoded-words (=?charset?B|Q?text?=) in a header
	# value; text outside encoded-words is left as is.
	hdrdecode:	fn(s: string): string;
};
