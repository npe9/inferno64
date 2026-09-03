#define Extern
#include "ember.h"

/*
 * hand written lexer for ember.
 *
 * unlike limbo, ember has no textual include mechanism (imports are
 * resolved from compiled interfaces), so there is no include stack.
 * ember also follows go's automatic semicolon insertion rule:
 * a newline terminates a statement when the last token could
 * plausibly end one.
 */

enum
{
	Linestart	= 0,

	Mlower		= 1,
	Mupper		= 2,
	Munder		= 4,
	Malpha		= Mupper|Mlower|Munder,
	Mdigit		= 8,
	Mhex		= 16,

	HashSize	= 1024,
	Nlook		= 2,		/* lookahead depth */
};

typedef	struct Keywd	Keywd;
struct	Keywd
{
	char	*name;
	int	token;
};

	File	**files;
	int	nfiles;
static	int	lenfiles;
static	int	lastfile;

static	Sym	*symbols[HashSize];
static	char	map[256];
static	char	escmap[256];
static	Biobuf	*bin;
static	int	lineno;
static	int	linepos;
static	int	ineof;
static	int	lasttok;	/* for semicolon insertion */
static	Tok	look[Nlook];
static	int	nlook;

static	Keywd	keywords[] =
{
	"alt",		Kalt,
	"break",	Kbreak,
	"case",		Kcase,
	"chan",		Kchan,
	"const",	Kconst,
	"continue",	Kcontinue,
	"default",	Kdefault,
	"else",		Kelse,
	"for",		Kfor,
	"func",		Kfunc,
	"if",		Kif,
	"import",	Kimport,
	"interface",	Kinterface,
	"list",		Klist,
	"load",		Kload,
	"match",	Kmatch,
	"module",	Kmodule,
	"nil",		Knil,
	"pick",		Kpick,
	"raise",	Kraise,
	"try",		Ktry,
	"catch",	Kcatch,
	"range",	Krange,
	"ref",		Kref,
	"return",	Kreturn,
	"spawn",	Kspawn,
	"struct",	Kstruct,
	"type",		Ktype,
	"var",		Kvar,
	0,
};

static	Keywd	tokwords[] =
{
	"&&",	Eandand,
	"||",	Eoror,
	"==",	Eeq,
	"!=",	Eneq,
	"<=",	Eleq,
	">=",	Egeq,
	"<<",	Elsh,
	">>",	Ersh,
	"<-",	Ecomm,
	":=",	Edeclas,
	"++",	Einc,
	"--",	Edec,
	"+=",	Eaddeq,
	"-=",	Esubeq,
	"*=",	Emuleq,
	"/=",	Ediveq,
	"%=",	Emodeq,
	"&=",	Eandeq,
	"|=",	Eoreq,
	"^=",	Exoreq,
	"<<=",	Elsheq,
	">>=",	Ersheq,
	"...",	Edots,
	"::",	Econs,
	"identifier",	Eid,
	"integer constant",	Econst,
	"real constant",	Erconst,
	"string constant",	Esconst,
	"eof",	Beof,
	0,
};

static	int	lex(Tok*);
int	_efgfmt(Fmt*);

void
lexinit(void)
{
	Keywd *k;
	int i;

	for(i = 0; i < 256; i++){
		if(i == '_' || i > 0xa0)
			map[i] |= Munder;
		if(i >= 'A' && i <= 'Z')
			map[i] |= Mupper;
		if(i >= 'a' && i <= 'z')
			map[i] |= Mlower;
		if(i >= 'A' && i <= 'F' || i >= 'a' && i <= 'f')
			map[i] |= Mhex;
		if(i >= '0' && i <= '9')
			map[i] |= Mdigit;
	}

	memset(escmap, -1, sizeof(escmap));
	escmap['\''] = '\'';
	escmap['"'] = '"';
	escmap['\\'] = '\\';
	escmap['a'] = '\a';
	escmap['b'] = '\b';
	escmap['f'] = '\f';
	escmap['n'] = '\n';
	escmap['r'] = '\r';
	escmap['t'] = '\t';
	escmap['v'] = '\v';
	escmap['0'] = '\0';

	for(k = keywords; k->name != nil; k++)
		enter(k->name, k->token);

	fmtinstall('L', lineconv);
	fmtinstall('O', opconv);
	fmtinstall('e', _efgfmt);
	fmtinstall('f', _efgfmt);
	fmtinstall('g', _efgfmt);
}

static int
cmap(int c)
{
	if(c < 0)
		return 0;
	if(c < 256)
		return map[c];
	return Mlower;
}

static File*
mkfile(char *name, int abs, int off)
{
	File *f;

	f = allocmem(sizeof *f);
	f->name = name;
	f->abs = abs;
	f->off = off;
	return f;
}

static int
addfile(File *f)
{
	if(nfiles >= lenfiles){
		lenfiles = nfiles+32;
		files = reallocmem(files, lenfiles*sizeof(File*));
	}
	files[nfiles] = f;
	return nfiles++;
}

int
lexstart(char *in)
{
	bin = Bopen(in, OREAD);
	if(bin == nil)
		return -1;
	ineof = 0;
	lastfile = 0;
	nlook = 0;
	lasttok = 0;
	/*
	 * line numbers are absolute across every file this run ever
	 * lexes, limbo-style: a Line stored in a Node only carries the
	 * bare number, and fline() maps it back to (file, line-in-file)
	 * through files[]'s abs/off table.  the first file starts at 1;
	 * every later one -- an imported .ei parsed by iface.c's
	 * loadiface() long after the main file has been read in full --
	 * picks up where the count left off, with off chosen so its own
	 * first line prints as 1.  resetting nfiles to 0 here instead
	 * (the original) threw the main file's entry away the moment
	 * the first import was parsed, so every check.c diagnostic
	 * against the main file printed as "sys.ei:N".
	 */
	if(nfiles == 0){
		lineno = 1;
		addfile(mkfile(strdup(in), 1, 0));
	}else
		addfile(mkfile(strdup(in), lineno, 1-lineno));
	linepos = Linestart;
	return 0;
}

void
lexend(void)
{
	if(bin != nil)
		Bterm(bin);
	bin = nil;
}

static int
getrune(void)
{
	int c;

	if(ineof)
		return Beof;
	c = Bgetrune(bin);
	if(c == Beof)
		ineof = 1;
	linepos++;
	return c;
}

static void
ungetrune(void)
{
	if(ineof)
		return;
	Bungetrune(bin);
	linepos--;
}

static int
Getc(void)
{
	int c;

	if(ineof)
		return Beof;
	c = BGETC(bin);
	if(c == Beof)
		ineof = 1;
	linepos++;
	return c;
}

static void
unGetc(void)
{
	if(ineof)
		return;
	Bungetc(bin);
	linepos--;
}

/*
 * convert an absolute Line into a file and line within the file
 */
Fline
fline(int absline)
{
	Fline fl;
	int l, r, m, s;

	if(absline < files[lastfile]->abs
	|| lastfile+1 < nfiles && absline >= files[lastfile+1]->abs){
		lastfile = 0;
		l = 0;
		r = nfiles - 1;
		while(l <= r){
			m = (r + l) / 2;
			s = files[m]->abs;
			if(s <= absline){
				l = m + 1;
				lastfile = m;
			}else
				r = m - 1;
		}
	}

	fl.file = files[lastfile];
	fl.line = absline + files[lastfile]->off;
	return fl;
}

Line
curline(void)
{
	Line line;

	line.line = lineno;
	line.pos = linepos;
	return line;
}

int
lineconv(Fmt *f)
{
	Fline fl;
	Line line;

	line = va_arg(f->args, Line);
	if(line.line < 0 || nfiles == 0)
		return fmtstrcpy(f, "<noline>");
	fl = fline(line.line);
	return fmtprint(f, "%s:%d", fl.file->name, fl.line);
}

Sym*
enter(char *name, int token)
{
	Sym *s;
	char *p;
	ulong h;
	int c0, c, n;

	c0 = name[0];
	h = 0;
	for(p = name; c = *p; p++){
		c ^= c << 6;
		h += (c << 11) ^ (c >> 1);
		c = *p;
		h ^= (c << 14) + (c << 7) + (c << 4) + c;
	}
	n = p - name;

	h %= HashSize;
	for(s = symbols[h]; s != nil; s = s->next)
		if(s->name[0] == c0 && strcmp(s->name, name) == 0)
			return s;

	s = allocmem(sizeof(Sym));
	memset(s, 0, sizeof(Sym));
	s->name = allocmem(n+1);
	memmove(s->name, name, n+1);
	if(token == 0)
		token = Eid;
	s->token = token;
	s->next = symbols[h];
	s->len = n;
	symbols[h] = s;
	return s;
}

static int
lexid(Tok *tok, int c)
{
	Sym *sym;
	char id[StrSize*UTFmax+1], *p;
	Rune r;
	int i;

	p = id;
	i = 0;
	for(;;){
		if(i < StrSize){
			if(c < Runeself)
				*p++ = c;
			else{
				r = c;
				p += runetochar(p, &r);
			}
			i++;
		}
		c = getrune();
		if(c == Beof || !(cmap(c) & (Malpha|Mdigit))){
			ungetrune();
			break;
		}
	}
	*p = '\0';
	sym = enter(id, Eid);
	tok->sym = sym;
	return sym->token;
}

static int
digit(int c, int base)
{
	int ck;

	ck = cmap(c);
	if(ck & Mdigit)
		c -= '0';
	else if(ck & Mlower)
		c = c - 'a' + 10;
	else if(ck & Mupper)
		c = c - 'A' + 10;
	else
		return -1;
	if(c >= base)
		return -1;
	return c;
}

/*
 * numeric literals in the go style:
 * 123, 0x1f, 0o17, 0b101, 1.5, 1e9, 1.5e-3, .5
 */
static int
lexnum(Tok *tok, int c)
{
	char buf[StrSize];
	Long v;
	int i, d, base, isreal;

	i = 0;
	base = 10;
	isreal = 0;
	if(c == '0'){
		c = Getc();
		if(c == 'x' || c == 'X'){
			base = 16;
			c = Getc();
		}else if(c == 'o' || c == 'O'){
			base = 8;
			c = Getc();
		}else if(c == 'b' || c == 'B'){
			base = 2;
			c = Getc();
		}else{
			unGetc();
			c = '0';
		}
	}
	if(c == '.'){
		isreal = 1;
		buf[i++] = '.';
		c = Getc();
	}
	for(;;){
		if(c == '_'){
			c = Getc();
			continue;
		}
		if(base == 10 && !isreal && c == '.'){
			isreal = 1;
			if(i < StrSize-1)
				buf[i++] = c;
			c = Getc();
			continue;
		}
		if(base == 10 && (c == 'e' || c == 'E')){
			isreal = 1;
			if(i < StrSize-1)
				buf[i++] = c;
			c = Getc();
			if(c == '+' || c == '-'){
				if(i < StrSize-1)
					buf[i++] = c;
				c = Getc();
			}
			continue;
		}
		d = digit(c, base == 10 && isreal ? 10 : base);
		if(d < 0)
			break;
		if(i < StrSize-1)
			buf[i++] = c;
		c = Getc();
	}
	buf[i] = '\0';
	unGetc();
	if(i == 0){
		error(curline(), "malformed numeric constant");
		tok->ival = 0;
		return Econst;
	}
	if(isreal){
		tok->rval = strtod(buf, nil);
		tok->sym = enter(buf, Eid);	/* the literal's text, for -T */
		return Erconst;
	}
	v = 0;
	for(i = 0; buf[i]; i++)
		v = v*base + digit(buf[i], base);
	tok->ival = v;
	return Econst;
}

static int
escchar(void)
{
	char buf[4+1];
	int c, i;

	c = getrune();
	if(c == Beof)
		return Beof;
	if(c == 'u'){
		for(i = 0; i < 4; i++){
			c = getrune();
			if(c == Beof || !(cmap(c) & (Mdigit|Mhex))){
				error(curline(), "malformed \\u escape sequence");
				ungetrune();
				break;
			}
			buf[i] = c;
		}
		buf[i] = 0;
		return strtoul(buf, 0, 16);
	}
	if(c < 256 && (i = escmap[c]) >= 0)
		return i;
	error(curline(), "unrecognized escape \\%C", c);
	return c;
}

static Sym*
lexstring(int israw)
{
	char *str;
	Rune r;
	int c, len, alloc;
	Sym *s;

	alloc = 32;
	len = 0;
	str = allocmem(alloc);
	for(;;){
		c = getrune();
		if(israw){
			if(c == '`')
				break;
			if(c == Beof){
				error(curline(), "end of file in raw string constant");
				break;
			}
			if(c == '\n'){
				lineno++;
				linepos = Linestart;
			}
		}else{
			if(c == '"')
				break;
			if(c == Beof){
				error(curline(), "end of file in string constant");
				break;
			}
			if(c == '\n'){
				error(curline(), "newline in string constant");
				lineno++;
				linepos = Linestart;
				break;
			}
			if(c == '\\'){
				c = escchar();
				if(c == Beof){
					error(curline(), "end of file in string constant");
					break;
				}
			}
		}
		while(len+UTFmax+1 >= alloc){
			alloc += 32;
			str = reallocmem(str, alloc);
		}
		r = c;
		len += runetochar(&str[len], &r);
	}
	str[len] = '\0';
	s = enter(str, Eid);
	free(str);
	return s;
}

/*
 * a newline ends a statement if the last token could end one.
 * this is go's automatic semicolon insertion rule.
 */
static int
endsstmt(int t)
{
	switch(t){
	case Eid:
	case Econst:
	case Erconst:
	case Esconst:
	case Kbreak:
	case Kcontinue:
	case Kreturn:
	case Knil:
	case Einc:
	case Edec:
	case ')':
	case ']':
	case '}':
	case '?':
		return 1;
	}
	return 0;
}

static int
lexcom(void)
{
	int c;

	c = Getc();
	if(c == '/'){
		while((c = Getc()) != '\n')
			if(c == Beof)
				return Beof;
		return '\n';
	}
	if(c == '*'){
		for(;;){
			c = Getc();
			if(c == Beof){
				error(curline(), "end of file in comment");
				return Beof;
			}
			if(c == '\n'){
				lineno++;
				linepos = Linestart;
			}
			if(c == '*'){
				c = Getc();
				if(c == '/')
					return 0;
				unGetc();
			}
		}
	}
	unGetc();
	return -2;			/* plain / */
}

static int
lex(Tok *tok)
{
	int c, t;

	tok->sym = nil;
	tok->ival = 0;
loop:
	tok->src.start.line = lineno;
	tok->src.start.pos = linepos;
	c = getrune();
	switch(c){
	case Beof:
		if(endsstmt(lasttok))
			return ';';
		return Beof;

	case '\n':
		lineno++;
		linepos = Linestart;
		if(endsstmt(lasttok))
			return ';';
		goto loop;
	case ' ':
	case '\t':
	case '\r':
	case '\v':
	case '\f':
		goto loop;

	case '"':
		tok->sym = lexstring(0);
		return Esconst;
	case '`':
		tok->sym = lexstring(1);
		return Esconst;
	case '\'':
		c = getrune();
		if(c == '\\')
			c = escchar();
		if(c == Beof){
			error(curline(), "end of file in character constant");
			return Beof;
		}
		tok->ival = c;
		c = Getc();
		if(c != '\''){
			error(curline(), "missing closing '");
			unGetc();
		}
		return Econst;

	case '(':
	case ')':
	case '[':
	case ']':
	case '{':
	case '}':
	case ',':
	case ';':
	case '~':
	case '?':
		return c;

	case ':':
		c = Getc();
		if(c == '=')
			return Edeclas;
		if(c == ':')
			return Econs;
		unGetc();
		return ':';

	case '.':
		c = Getc();
		if(c != Beof && (cmap(c) & Mdigit)){
			unGetc();
			return lexnum(tok, '.');
		}
		if(c == '.'){
			c = Getc();
			if(c == '.')
				return Edots;
			unGetc();
			error(curline(), "unknown token '..'");
			return '.';
		}
		unGetc();
		return '.';

	case '|':
		c = Getc();
		if(c == '=')
			return Eoreq;
		if(c == '|')
			return Eoror;
		unGetc();
		return '|';

	case '&':
		c = Getc();
		if(c == '=')
			return Eandeq;
		if(c == '&')
			return Eandand;
		unGetc();
		return '&';

	case '^':
		c = Getc();
		if(c == '=')
			return Exoreq;
		unGetc();
		return '^';

	case '*':
		c = Getc();
		if(c == '=')
			return Emuleq;
		unGetc();
		return '*';

	case '/':
		t = lexcom();
		if(t == 0)
			goto loop;
		if(t == '\n'){
			lineno++;
			linepos = Linestart;
			if(endsstmt(lasttok))
				return ';';
			goto loop;
		}
		if(t == Beof){
			if(endsstmt(lasttok))
				return ';';
			return Beof;
		}
		c = Getc();
		if(c == '=')
			return Ediveq;
		unGetc();
		return '/';

	case '%':
		c = Getc();
		if(c == '=')
			return Emodeq;
		unGetc();
		return '%';

	case '=':
		c = Getc();
		if(c == '=')
			return Eeq;
		unGetc();
		return '=';

	case '!':
		c = Getc();
		if(c == '=')
			return Eneq;
		unGetc();
		return '!';

	case '>':
		c = Getc();
		if(c == '=')
			return Egeq;
		if(c == '>'){
			c = Getc();
			if(c == '=')
				return Ersheq;
			unGetc();
			return Ersh;
		}
		unGetc();
		return '>';

	case '<':
		c = Getc();
		if(c == '=')
			return Eleq;
		if(c == '-')
			return Ecomm;
		if(c == '<'){
			c = Getc();
			if(c == '=')
				return Elsheq;
			unGetc();
			return Elsh;
		}
		unGetc();
		return '<';

	case '+':
		c = Getc();
		if(c == '=')
			return Eaddeq;
		if(c == '+')
			return Einc;
		unGetc();
		return '+';

	case '-':
		c = Getc();
		if(c == '=')
			return Esubeq;
		if(c == '-')
			return Edec;
		unGetc();
		return '-';

	case '0': case '1': case '2': case '3': case '4':
	case '5': case '6': case '7': case '8': case '9':
		return lexnum(tok, c);

	default:
		if(cmap(c) & Malpha)
			return lexid(tok, c);
		error(curline(), "unknown character %C", c);
		goto loop;
	}
}

static void
lexfill(void)
{
	Tok *tok;

	while(nlook < Nlook){
		tok = &look[nlook];
		tok->t = lex(tok);
		tok->src.stop.line = lineno;
		tok->src.stop.pos = linepos;
		lasttok = tok->t;
		nlook++;
	}
}

/*
 * peek at the nth (0 or 1) unconsumed token
 */
Tok*
lexlook(int n)
{
	if(n >= Nlook)
		fatal("lexlook depth %d too deep", n);
	lexfill();
	return &look[n];
}

void
lexskip(void)
{
	lexfill();
	look[0] = look[1];
	nlook--;
	lexfill();
}

/*
 * -T: print every token of a file, one per line, as
 * "line:pos name [value]" -- the oracle the self-hosted lexer
 * (appl/cmd/ember/lex.e) is compared against, token for token.
 * strings print with control characters and backslashes as \xHH so
 * the dump is one line per token whatever the string holds.
 */
static void
dumpstr(char *s, int n)
{
	char *buf, *p;
	int i, c;

	buf = allocmem(4*n + 1);
	p = buf;
	for(i = 0; i < n; i++){
		c = s[i] & 0xff;
		if(c == '\\' || c < 32 || c == 127)
			p += sprint(p, "\\x%02x", c);
		else
			*p++ = c;	/* raw bytes: %c would re-encode a UTF-8 byte as a rune */
	}
	*p = 0;
	print("%s", buf);
	free(buf);
}

void
lexdump(char *file)
{
	Tok *t;

	if(lexstart(file) < 0){
		fprint(2, "ember: can't open %s: %r\n", file);
		errors++;
		return;
	}
	for(;;){
		t = lexlook(0);
		print("%d:%d %s", t->src.start.line, t->src.start.pos, lextokname(t->t));
		switch(t->t){
		case Eid:
			print(" %s", t->sym->name);
			break;
		case Esconst:
			print(" ");
			dumpstr(t->sym->name, t->sym->len);
			break;
		case Econst:
			print(" %lld", (vlong)t->ival);
			break;
		case Erconst:
			print(" %s", t->sym->name);	/* the text: no %g on this host */
			break;
		}
		print("\n");
		if(t->t == Beof)
			break;
		lexskip();
	}
	lexend();
}

char*
lextokname(int t)
{
	Keywd *k;
	static char bufs[4][32];
	static int nbuf;
	char *buf;

	/* rotate: a message naming two tokens ("expected ) in call, near
	 * ` } `") formats both before printing, and one static buffer
	 * made both print the second -- found by the self-hosted parser's
	 * differential test */
	buf = bufs[nbuf++ & 3];

	for(k = keywords; k->name != nil; k++)
		if(t == k->token)
			return k->name;
	for(k = tokwords; k->name != nil; k++)
		if(t == k->token)
			return k->name;
	if(t < 0 || t > 255){
		snprint(buf, sizeof(buf), "token %d", t);
		return buf;
	}
	buf[0] = t;
	buf[1] = '\0';
	return buf;
}

void
error(Line line, char *fmt, ...)
{
	char buf[4096];
	va_list arg;

	errors++;
	if(errors >= MaxErr){
		if(errors == MaxErr)
			fprint(2, "too many errors, stopping\n");
		return;
	}
	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, arg);
	va_end(arg);
	fprint(2, "%L: %s\n", line, buf);
}

void
fatal(char *fmt, ...)
{
	char buf[4096];
	va_list arg;

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, arg);
	va_end(arg);
	fprint(2, "fatal ember compiler error: %s\n", buf);
	if(isfatal)
		abort();
	exits(buf);
}

void*
allocmem(ulong n)
{
	void *p;

	p = malloc(n != 0? n: 1);
	if(p == nil)
		fatal("out of memory");
	return p;
}

void*
reallocmem(void *p, ulong n)
{
	if(p == nil)
		p = malloc(n);
	else
		p = realloc(p, n);
	if(p == nil)
		fatal("out of memory");
	return p;
}

char*
secpy(char *p, char *e, char *s)
{
	int c;

	if(p == e){
		p[-1] = '\0';
		return p;
	}
	for(; c = *s; s++){
		*p++ = c;
		if(p == e){
			p[-1] = '\0';
			return p;
		}
	}
	*p = '\0';
	return p;
}
