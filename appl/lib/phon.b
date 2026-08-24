implement Phon;

#
# English words, in the sounds a voice model was trained on. See phon(2).
#
include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "phon.m";

Entry: adt {
	w:	string;
	ipa:	string;
};

lex: array of Entry;		# sorted by word, so lookup is a bisection
nlex: int;

#
# The generated dictionary is not read in. It is a quarter of a million sorted
# lines, so it is searched where it lies: halve the byte range, step to the
# next line boundary, compare, repeat until the range is small enough to walk.
#
# Reading it would cost several megabytes of strings and a sort, per program,
# to answer a handful of lookups. Seeking costs a few reads and no memory,
# which is also what makes this usable on a machine that has none to spare.
#
dict: ref Sys->FD;
dsize: big;
dcount: int;

Window:	con big 8192;	# narrow to this, then walk it

#
# The punctuation the voice was trained with. espeak leaves these in the
# phoneme stream because they are how a line is paced, so they are kept rather
# than stripped; anything else in a word is dropped, since a symbol the model
# has never seen would be an error at synthesis rather than here.
#
keptpunct(c: int): int
{
	case c {
	',' or '.' or '?' or '!' or ';' or ':' or '-' or
	'(' or ')' or '"' or '\'' =>
		return 1;
	}
	return 0;
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

init(path: string): string
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return sys->sprint("cannot load bufio: %r");
	if(path == nil)
		path = LEX;

	b := bufio->open(path, Bufio->OREAD);
	if(b == nil)
		return sys->sprint("%s: %r", path);

	lex = array[256] of Entry;
	nlex = 0;
	ln := 0;
	while((l := b.gets('\n')) != nil){
		ln++;
		# strip the newline, then skip blank lines and comments
		if(len l > 0 && l[len l - 1] == '\n')
			l = l[0:len l - 1];
		if(l == nil || l[0] == '#')
			continue;
		tab := -1;
		for(i := 0; i < len l; i++)
			if(l[i] == '\t'){
				tab = i;
				break;
			}
		if(tab <= 0 || tab + 1 >= len l)
			return sys->sprint("%s:%d: want a word, a tab, then the sounds", path, ln);
		if(nlex >= len lex){
			nl := array[2 * len lex] of Entry;
			nl[0:] = lex[0:nlex];
			lex = nl;
		}
		lex[nlex].w = lower(l[0:tab]);
		lex[nlex].ipa = l[tab+1:];
		nlex++;
	}
	b = nil;
	if(nlex == 0)
		return path + " has no entries";

	# The dictionary is optional: the hand-written lexicon alone is a working
	# system, just a much smaller one.
	dict = sys->open(DICT, Sys->OREAD);
	if(dict != nil){
		(ok, d) := sys->fstat(dict);
		if(ok < 0){
			dict = nil;
		}else{
			dsize = d.length;
			dcount = -1;		# counted only if asked
		}
	}

	sortlex();
	# A duplicate is not harmless: which of the two wins would depend on
	# the sort, so the same word would be said differently depending on
	# where in the file it was added.
	for(i := 1; i < nlex; i++)
		if(lex[i].w == lex[i-1].w)
			return sys->sprint("%s: %s is in the lexicon twice", path, lex[i].w);
	return nil;
}

sortlex()
{
	# insertion sort: the lexicon is small and read once
	for(i := 1; i < nlex; i++){
		e := lex[i];
		j := i - 1;
		while(j >= 0 && lex[j].w > e.w){
			lex[j+1] = lex[j];
			j--;
		}
		lex[j+1] = e;
	}
}

word(w: string): (string, string)
{
	if(nlex == 0)
		return (nil, "no lexicon has been read");
	w = lower(w);

	# The hand-written entries first, because they are the corrections.
	lo := 0;
	hi := nlex - 1;
	while(lo <= hi){
		mid := (lo + hi) / 2;
		if(lex[mid].w == w)
			return (lex[mid].ipa, nil);
		if(lex[mid].w < w)
			lo = mid + 1;
		else
			hi = mid - 1;
	}

	ipa := dictfind(w);
	if(ipa != nil)
		return (ipa, nil);
	return (nil, w);
}

# the line beginning at off, and where the next one begins
lineat(off: big): (string, big)
{
	buf := array[512] of byte;
	n := sys->pread(dict, buf, len buf, off);
	if(n <= 0)
		return (nil, off);
	for(i := 0; i < n; i++)
		if(buf[i] == byte '\n')
			return (string buf[0:i], off + big (i+1));
	# a line longer than the buffer is not one of ours; skip it whole
	return (string buf[0:n], off + big n);
}

# where the line containing or following off begins
linestart(off: big): big
{
	if(off <= big 0)
		return big 0;
	buf := array[512] of byte;
	p := off;
	while(p < dsize){
		n := sys->pread(dict, buf, len buf, p);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(buf[i] == byte '\n')
				return p + big (i+1);
		p += big n;
	}
	return dsize;
}

keyof(l: string): string
{
	for(i := 0; i < len l; i++)
		if(l[i] == '\t')
			return l[0:i];
	return nil;
}

#
# Narrow by halving, then walk what is left. Both ends are always at a line
# boundary and each step strictly shrinks the range, so this cannot fail to
# terminate - which matters more than the last few comparisons being optimal,
# because a lookup that loops would hang whatever asked for it.
#
dictfind(want: string): string
{
	if(dict == nil || dsize <= big 0)
		return nil;
	lo := big 0;
	hi := dsize;
	while(hi - lo > Window){
		mid := lo + (hi - lo) / big 2;
		p := linestart(mid);
		if(p >= hi || p <= lo)
			break;
		(l, nil) := lineat(p);
		k := keyof(l);
		if(k != nil && k < want)
			lo = p;
		else
			hi = p;
	}
	p := lo;
	while(p < hi){
		(l, next) := lineat(p);
		if(l == nil)
			break;
		k := keyof(l);
		if(k != nil){
			if(k == want)
				return l[len k + 1:];
			if(k > want)
				break;
		}
		p = next;
	}
	return nil;
}

dictwords(): int
{
	if(dict == nil)
		return 0;
	if(dcount >= 0)
		return dcount;
	n := 0;
	p := big 0;
	while(p < dsize){
		(l, next) := lineat(p);
		if(l == nil)
			break;
		if(len l > 0 && l[0] != '#')
			n++;
		p = next;
	}
	dcount = n;
	return n;
}

text(s: string): (string, string)
{
	out := "";
	i := 0;
	while(i < len s){
		# skip whatever separates one word from the next
		while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n')){
			i++;
			continue;
		}
		if(i >= len s)
			break;

		#
		# Leading punctuation, then the word, then trailing punctuation.
		# An apostrophe is stripped at either end and kept in between, so
		# a quoted 'watch' loses its quotes and don't keeps its own - which
		# is the only rule that gets both right without looking further.
		#
		pre := "";
		while(i < len s && keptpunct(s[i])){
			pre[len pre] = s[i];
			i++;
		}
		start := i;
		while(i < len s && s[i] != ' ' && s[i] != '\t' && s[i] != '\n')
			i++;
		tok := s[start:i];

		post := "";
		while(len tok > 0 && keptpunct(tok[len tok - 1])){
			post = tok[len tok - 1:] + post;
			tok = tok[0:len tok - 1];
		}
		# anything else that is not a letter is dropped rather than sent
		core := "";
		for(j := 0; j < len tok; j++){
			c := tok[j];
			if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			   c == '\'' || (c >= '0' && c <= '9'))
				core[len core] = c;
		}
		if(core == nil){
			if(pre != nil || post != nil)
				out = join(out, pre + post);
			continue;
		}
		(ipa, err) := word(core);
		if(err != nil)
			return (nil, err);
		out = join(out, pre + ipa + post);
	}
	return (out, nil);
}

join(a, b: string): string
{
	if(a == nil)
		return b;
	return a + " " + b;
}

words(): list of string
{
	l: list of string;

	for(i := nlex - 1; i >= 0; i--)
		l = lex[i].w :: l;
	return l;
}
