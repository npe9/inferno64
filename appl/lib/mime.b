implement Mime;

include "sys.m";
	sys: Sys;
include "encoding.m";
	base64: Encoding;
include "mime.m";

init()
{
	sys = load Sys Sys->PATH;
	base64 = load Encoding Encoding->BASE64PATH;
}

# parse a MIME entity: split header/body, read the content headers, and
# either split a multipart body into subparts (recursing) or decode a leaf
# body per its transfer encoding.
parse(msg: array of byte): ref Part
{
	(hdr, body) := splithdr(msg);
	headers := parsehdrs(hdr);

	p := ref Part;
	p.headers = headers;
	p.encoding = lower(strip(field(headers, "content-transfer-encoding")));
	if(p.encoding == "")
		p.encoding = "7bit";

	(ct, ctparams) := parsectype(field(headers, "content-type"));
	if(ct == "")
		ct = "text/plain";
	p.ctype = ct;
	p.params = ctparams;

	disp := field(headers, "content-disposition");
	(dval, dparams) := parsectype(disp);		# same "value; a=b" shape
	p.disp = lower(dval);
	p.filename = pparam(ctparams, "name");
	if(p.filename == "")
		p.filename = pparam(dparams, "filename");

	if(len ct > 10 && ct[0:10] == "multipart/"){
		boundary := pparam(ctparams, "boundary");
		if(boundary != "")
			p.parts = splitparts(body, boundary);
		p.body = nil;
	}else{
		p.body = decode(body, p.encoding);
	}
	return p;
}

Part.ismultipart(p: self ref Part): int
{
	return len p.ctype > 10 && p.ctype[0:10] == "multipart/";
}

Part.param(p: self ref Part, name: string): string
{
	return pparam(p.params, name);
}

Part.find(p: self ref Part, ctype: string): ref Part
{
	if(!p.ismultipart()){
		if(p.ctype == ctype)
			return p;
		return nil;
	}
	for(l := p.parts; l != nil; l = tl l){
		q := (hd l).find(ctype);
		if(q != nil)
			return q;
	}
	return nil;
}

# split a multipart body on its boundary into sub-entities and parse each.
splitparts(body: array of byte, boundary: string): list of ref Part
{
	s := string body;
	delim := "--" + boundary;
	rparts: list of ref Part;
	# find each delimiter line; content between two delimiters is a part.
	i := 0;
	inpart := 0;
	pstart := 0;
	while(i < len s){
		# a delimiter is "--boundary" at the start of a line
		if((i == 0 || s[i - 1] == '\n') && i + len delim <= len s && s[i:i + len delim] == delim){
			if(inpart)
				rparts = parse(array of byte trimpart(s[pstart:i])) :: rparts;
			# closing delimiter is "--boundary--"
			if(i + len delim + 2 <= len s && s[i + len delim:i + len delim + 2] == "--")
				break;
			# skip to end of this delimiter line
			j := i + len delim;
			while(j < len s && s[j] != '\n')
				j++;
			pstart = j + 1;
			inpart = 1;
			i = pstart;
			continue;
		}
		i++;
	}
	parts: list of ref Part;
	for(; rparts != nil; rparts = tl rparts)
		parts = hd rparts :: parts;
	return parts;
}

# strip a leading blank line's CRLF that separates a boundary from content
# and a trailing CRLF before the next boundary.
trimpart(s: string): string
{
	# leading CRLF already consumed by pstart; trim one trailing CRLF.
	if(len s >= 2 && s[len s - 2:] == "\r\n")
		return s[0:len s - 2];
	if(len s >= 1 && s[len s - 1] == '\n')
		return s[0:len s - 1];
	return s;
}

decode(data: array of byte, encoding: string): array of byte
{
	case lower(strip(encoding)) {
	"base64" =>
		return base64->dec(stripws(string data));
	"quoted-printable" =>
		return qpdecode(data);
	* =>
		return data;			# 7bit, 8bit, binary
	}
}

# RFC 2045 quoted-printable: =XX is a hex byte, "=\n" is a soft break.
qpdecode(data: array of byte): array of byte
{
	out := array[len data] of byte;
	n := 0;
	i := 0;
	while(i < len data){
		c := data[i];
		if(c == byte '='){
			if(i + 1 < len data && data[i + 1] == byte '\n'){
				i += 2;			# soft line break
				continue;
			}
			if(i + 2 < len data && data[i + 1] == byte '\r' && data[i + 2] == byte '\n'){
				i += 3;
				continue;
			}
			if(i + 2 < len data){
				h := hexval(int data[i + 1]) * 16 + hexval(int data[i + 2]);
				if(h >= 0){
					out[n++] = byte h;
					i += 3;
					continue;
				}
			}
		}
		out[n++] = c;
		i++;
	}
	return out[0:n];
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return -1;
}

# ---- RFC 2047 header decoding ----

hdrdecode(s: string): string
{
	r := "";
	pend := "";			# whitespace pending between tokens
	lastword := 0;
	i := 0;
	while(i < len s){
		if(s[i] == ' ' || s[i] == '\t'){
			pend[len pend] = s[i];
			i++;
			continue;
		}
		if(s[i] == '=' && i + 1 < len s && s[i + 1] == '?'){
			(word, after, ok) := decodeword(s, i);
			if(ok){
				# whitespace between two encoded words is dropped
				if(!lastword)
					r += pend;
				pend = "";
				r += word;
				lastword = 1;
				i = after;
				continue;
			}
		}
		r += pend;
		pend = "";
		r[len r] = s[i];
		lastword = 0;
		i++;
	}
	return r + pend;
}

# decode one =?charset?enc?text?= starting at p; returns (text, index
# after the word, ok).
decodeword(s: string, p: int): (string, int, int)
{
	i := p + 2;			# past "=?"
	c1 := findfrom(s, i, '?');
	if(c1 < 0)
		return ("", p, 0);
	i = c1 + 1;			# past charset "?"
	if(i + 1 >= len s || s[i + 1] != '?')
		return ("", p, 0);
	enc := s[i];
	i += 2;				# past "enc?"
	te := findstrfrom(s, i, "?=");
	if(te < 0)
		return ("", p, 0);
	text := s[i:te];
	after := te + 2;
	dec: array of byte;
	case enc {
	'B' or 'b' =>
		dec = base64->dec(stripws(text));
	'Q' or 'q' =>
		dec = qword(text);
	* =>
		return ("", p, 0);
	}
	return (string dec, after, 1);
}

# RFC 2047 "Q" encoding: like quoted-printable but '_' means space.
qword(s: string): array of byte
{
	out := array[len s] of byte;
	n := 0;
	i := 0;
	while(i < len s){
		c := s[i];
		if(c == '_'){
			out[n++] = byte ' ';
			i++;
		}else if(c == '=' && i + 2 < len s){
			h := hexval(s[i + 1]) * 16 + hexval(s[i + 2]);
			if(h >= 0){
				out[n++] = byte h;
				i += 3;
			}else{
				out[n++] = byte c;
				i++;
			}
		}else{
			out[n++] = byte c;
			i++;
		}
	}
	return out[0:n];
}

findfrom(s: string, from, c: int): int
{
	for(i := from; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

findstrfrom(s: string, from: int, sub: string): int
{
	for(i := from; i + len sub <= len s; i++)
		if(s[i:i + len sub] == sub)
			return i;
	return -1;
}

# ---- header parsing ----

splithdr(msg: array of byte): (string, array of byte)
{
	s := string msg;
	for(i := 0; i + 1 < len s; i++)
		if(s[i] == '\n' && (s[i + 1] == '\n' || (s[i + 1] == '\r' && i + 2 < len s && s[i + 2] == '\n'))){
			bstart := i + 2;
			if(s[i + 1] == '\r')
				bstart = i + 3;
			return (s[0:i + 1], array of byte s[bstart:]);
		}
	return (s, array[0] of byte);
}

parsehdrs(hdr: string): list of (string, string)
{
	(nil, lines) := sys->tokenize(hdr, "\n");
	rf: list of (string, string);
	name := "";
	val := "";
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		if(line != "" && (line[0] == ' ' || line[0] == '\t')){
			val += " " + strip(line);
			continue;
		}
		if(name != "")
			rf = (name, val) :: rf;
		name = "";
		val = "";
		colon := index(line, ':');
		if(colon > 0){
			name = lower(line[0:colon]);
			val = strip(line[colon + 1:]);
		}
	}
	if(name != "")
		rf = (name, val) :: rf;
	fields: list of (string, string);
	for(; rf != nil; rf = tl rf)
		fields = hd rf :: fields;
	return fields;
}

field(headers: list of (string, string), name: string): string
{
	for(; headers != nil; headers = tl headers){
		(n, v) := hd headers;
		if(n == name)
			return v;
	}
	return "";
}

# parse a "value; p1=v1; p2="v2"" header into (value, params).
parsectype(s: string): (string, list of (string, string))
{
	semi := index(s, ';');
	val := s;
	rest := "";
	if(semi >= 0){
		val = s[0:semi];
		rest = s[semi + 1:];
	}
	val = lower(strip(val));
	params: list of (string, string);
	while(rest != ""){
		semi = index(rest, ';');
		one := rest;
		if(semi >= 0){
			one = rest[0:semi];
			rest = rest[semi + 1:];
		}else
			rest = "";
		eq := index(one, '=');
		if(eq > 0){
			pn := lower(strip(one[0:eq]));
			pv := strip(one[eq + 1:]);
			pv = unquote(pv);
			params = (pn, pv) :: params;
		}
	}
	return (val, params);
}

pparam(params: list of (string, string), name: string): string
{
	for(; params != nil; params = tl params){
		(n, v) := hd params;
		if(n == name)
			return v;
	}
	return "";
}

# ---- string helpers ----

unquote(s: string): string
{
	if(len s >= 2 && s[0] == '"' && s[len s - 1] == '"')
		return s[1:len s - 1];
	return s;
}

lower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j - 1] == ' ' || s[j - 1] == '\t' || s[j - 1] == '\r' || s[j - 1] == '\n'))
		j--;
	return s[i:j];
}

# remove all whitespace (base64 bodies are line-wrapped).
stripws(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] != ' ' && s[i] != '\t' && s[i] != '\r' && s[i] != '\n')
			r[len r] = s[i];
	return r;
}

index(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}
