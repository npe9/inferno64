implement Eliza;

# Nelson's Dream Machines chapter on AI singles out Weizenbaum's ELIZA
# (1966) - not because it understands anything, but precisely because
# it doesn't, and that's the point he wants made: a keyword-ranked
# pattern match, a captured span reflected back with pronouns swapped
# (I/you, my/your, ...), and it reads as a therapist. This is that
# trick, not a language model - the whole "engine" is under 200 lines.
#
# A script (plain text, see lib/eliza/doctor.el) supplies:
#   GREETING <text>              printed once, at the start
#   DEFAULT <text>                a fallback reply, cycled when nothing
#                                  else matches
#   PRE <word> <replacement...>   word substituted before matching, so
#                                  e.g. "im" expands to "i am"
#   POST <word> <replacement...>  word substituted while reflecting a
#                                  captured span back (i -> you, my ->
#                                  your, ...)
#   KEY <word> <rank>             a single trigger word; the
#                                  highest-ranked trigger word actually
#                                  present in the input picks which
#                                  keyword's rules get tried (ties go to
#                                  whichever trigger appears first)
#   DECOMP <pattern...>            a pattern for the current KEY - words
#                                  and "*" wildcards, matched against the
#                                  *entire* input, not just text near the
#                                  trigger word
#   REASSEMBLE <template...>       one of several replies for the
#                                  preceding DECOMP - words and "(N)"
#                                  placeholders for the Nth "*"'s
#                                  captured (and POST-reflected) span,
#                                  cycled round-robin like DEFAULT
#
# Real ELIZA/DOCTOR scripts also had a MEMORY mechanism (certain
# keywords stashed a reflected sentence to bring up later, once nothing
# else matched) and per-keyword "goto"-like precedence overrides beyond
# straight rank comparison - neither is implemented here, a genuine
# scope cut in favour of the core trick actually working end to end.
#
# KEY words match by exact string only - no stemming, so a script's
# "feel"/"computer" keys won't trigger on "feeling"/"computers". Real
# ELIZA scripts mostly dodged this by listing a separate KEY per
# word-form rather than by stemming either; lib/eliza/doctor.el doesn't
# attempt that exhaustively (it's a demo script, not a production one) -
# a sentence built around a word-form it didn't anticipate just falls
# through to the DEFAULT cycle, same as any other unmatched input.

include "sys.m";
	sys: Sys;

include "dreammachines/eliza.m";

init()
{
	sys = load Sys Sys->PATH;
}

loadscript(path: string): (ref Script, string)
{
	(text, err) := readfile(path);
	if(text == nil)
		return (nil, err);

	s := ref Script("", nil, 0, nil, nil, nil);
	curkey: ref Keyword;
	currule: ref Rule;

	(nil, lines) := sys->tokenize(text, "\n");
	for(l := lines; l != nil; l = tl l){
		line := hd l;
		if(len line == 0 || line[0] == '#')
			continue;
		(n, toks) := sys->tokenize(line, " \t");
		if(n == 0)
			continue;
		dir := hd toks;
		rest := tl toks;
		case dir {
		"GREETING" =>
			txt := jointoks(rest);
			if(s.greeting == "")
				s.greeting = txt;
			else
				s.greeting += "\n" + txt;
		"DEFAULT" =>
			s.defaults = jointoks(rest) :: s.defaults;
		"PRE" =>
			if(rest != nil)
				s.pre = ref Repl(lower(hd rest), lowerlist(tl rest)) :: s.pre;
		"POST" =>
			if(rest != nil)
				s.post = ref Repl(lower(hd rest), lowerlist(tl rest)) :: s.post;
		"KEY" =>
			if(rest != nil){
				wd := lower(hd rest);
				rk := 0;
				if(tl rest != nil)
					rk = toint(hd tl rest);
				curkey = ref Keyword(wd, rk, nil);
				s.keys = curkey :: s.keys;
				currule = nil;
			}
		"DECOMP" =>
			if(curkey != nil){
				currule = ref Rule(lowerlist(rest), nil, 0);
				curkey.rules = currule :: curkey.rules;
			}
		"REASSEMBLE" =>
			if(currule != nil)
				currule.reassemblies = jointoks(rest) :: currule.reassemblies;
		* =>
			;
		}
	}

	s.defaults = revstrs(s.defaults);
	s.pre = revrepls(s.pre);
	s.post = revrepls(s.post);
	s.keys = revkeys(s.keys);
	for(k := s.keys; k != nil; k = tl k){
		(hd k).rules = revrules((hd k).rules);
		for(r := (hd k).rules; r != nil; r = tl r)
			(hd r).reassemblies = revstrs((hd r).reassemblies);
	}
	return (s, nil);
}

respond(script: ref Script, input: string): string
{
	(nil, raw) := sys->tokenize(input, " \t");
	words := applyrepl(lowerlist(raw), script.pre);

	best: ref Keyword;
	bestrank := -1;
	for(w := words; w != nil; w = tl w){
		k := findkey(script.keys, hd w);
		if(k != nil && k.rank > bestrank){
			best = k;
			bestrank = k.rank;
		}
	}

	if(best != nil){
		for(r := best.rules; r != nil; r = tl r){
			rule := hd r;
			(ok, caps) := matchrec(rule.pattern, words);
			if(ok)
				return buildreply(rule, caps, script.post);
		}
	}

	return nextdefault(script);
}

# text[0..] is either literal words or "*" wildcards; inp is the
# (already lowercased, PRE-substituted) tokenized user input. "*"
# matches the shortest possible run of words that still lets the rest
# of the pattern match - which is what makes an early literal word in
# the pattern bind to its *first* occurrence in the input, matching how
# real ELIZA patterns like "* my *" are meant to read ("whatever comes
# right before the first 'my'", not "... right before the last word").
matchrec(pat: list of string, inp: list of string): (int, list of list of string)
{
	if(pat == nil)
		return (inp == nil, nil);
	p := hd pat;
	if(p == "*"){
		n := lenstrs(inp);
		for(k := 0; k <= n; k++){
			(pre, rest) := taketokens(inp, k);
			(ok, caps) := matchrec(tl pat, rest);
			if(ok)
				return (1, pre :: caps);
		}
		return (0, nil);
	}
	if(inp == nil || p != hd inp)
		return (0, nil);
	return matchrec(tl pat, tl inp);
}

taketokens(inp: list of string, k: int): (list of string, list of string)
{
	pre: list of string;
	rest := inp;
	for(i := 0; i < k; i++){
		pre = hd rest :: pre;
		rest = tl rest;
	}
	return (revstrs(pre), rest);
}

buildreply(rule: ref Rule, caps: list of list of string, post: list of ref Repl): string
{
	if(rule.reassemblies == nil)
		return "";
	tmpl := nthstr(rule.reassemblies, rule.next % lenstrs(rule.reassemblies));
	rule.next++;
	(nil, toks) := sys->tokenize(tmpl, " \t");
	out := "";
	for(t := toks; t != nil; t = tl t){
		tok := hd t;
		idx := placeholder(tok);
		if(idx > 0){
			seg := applyrepl(nthcap(caps, idx-1), post);
			for(w := seg; w != nil; w = tl w)
				out = addword(out, hd w);
		}else
			out = addword(out, tok);
	}
	return out;
}

addword(out: string, w: string): string
{
	if(out == "")
		return w;
	return out + " " + w;
}

# tok is a placeholder iff it's exactly "(" digits ")"; returns the
# (1-based) N, or -1 if tok isn't one.
placeholder(tok: string): int
{
	n := len tok;
	if(n < 3 || tok[0] != '(' || tok[n-1] != ')')
		return -1;
	v := 0;
	for(i := 1; i < n-1; i++){
		if(tok[i] < '0' || tok[i] > '9')
			return -1;
		v = v*10 + (tok[i]-'0');
	}
	if(v <= 0)
		return -1;
	return v;
}

nextdefault(script: ref Script): string
{
	if(script.defaults == nil)
		return "Please continue.";
	d := nthstr(script.defaults, script.defnext % lenstrs(script.defaults));
	script.defnext++;
	return d;
}

applyrepl(words: list of string, repls: list of ref Repl): list of string
{
	out: list of string;
	for(w := words; w != nil; w = tl w){
		r := findrepl(repls, hd w);
		if(r != nil){
			for(t := r.repl; t != nil; t = tl t)
				out = hd t :: out;
		}else
			out = hd w :: out;
	}
	return revstrs(out);
}

findrepl(repls: list of ref Repl, word: string): ref Repl
{
	for(r := repls; r != nil; r = tl r)
		if((hd r).word == word)
			return hd r;
	return nil;
}

findkey(keys: list of ref Keyword, word: string): ref Keyword
{
	for(k := keys; k != nil; k = tl k)
		if((hd k).word == word)
			return hd k;
	return nil;
}

nthstr(l: list of string, n: int): string
{
	i := 0;
	for(; l != nil; l = tl l){
		if(i == n)
			return hd l;
		i++;
	}
	return "";
}

nthcap(l: list of list of string, n: int): list of string
{
	i := 0;
	for(; l != nil; l = tl l){
		if(i == n)
			return hd l;
		i++;
	}
	return nil;
}

lenstrs(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

lowerlist(l: list of string): list of string
{
	out: list of string;
	for(; l != nil; l = tl l)
		out = lower(hd l) :: out;
	return revstrs(out);
}

lower(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] = r[i]-'A'+'a';
	return r;
}

toint(s: string): int
{
	i := 0;
	n := len s;
	v := 0;
	while(i < n && s[i] >= '0' && s[i] <= '9'){
		v = v*10 + (s[i]-'0');
		i++;
	}
	return v;
}

jointoks(toks: list of string): string
{
	s := "";
	for(t := toks; t != nil; t = tl t)
		s = addword(s, hd t);
	return s;
}

revstrs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revrepls(l: list of ref Repl): list of ref Repl
{
	r: list of ref Repl;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revrules(l: list of ref Rule): list of ref Rule
{
	r: list of ref Rule;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revkeys(l: list of ref Keyword): list of ref Keyword
{
	r: list of ref Keyword;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || (d.mode & Sys->DMDIR))
		return (nil, "not a regular file: "+path);
	a := array[int d.length] of byte;
	n := sys->read(fd, a, len a);
	if(n < 0)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (string a[0:n], nil);
}
