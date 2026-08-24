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
	return (nil, w);
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
