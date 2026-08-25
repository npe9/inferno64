implement Corpus;

#
#	corpus: an interned-corpus toolchain, after the second half of
#	Church's "Unix for Poets" - intern a text once into small integers,
#	then count, generate bigrams, and score them by mutual information
#	and t-score against that integer representation instead of strings.
#
#	Church's own point wasn't mmap specifically - Limbo has no analogue
#	for that, being a garbage-collected VM language, not a route to raw
#	pages - it was interning: strings to integer ids once, so every pass
#	after that (counting, bigram generation, statistics) compares and
#	sorts small ints instead of repeatedly re-comparing strings. That
#	part ports directly. See doc/mission.ms and man/1/corpus.
#
#	File formats match his own, so this is a port and not just a
#	lookalike:
#	  wordlist      V words, NUL-delimited (not newline)
#	  wordlist.idx  V big-endian 32-bit ints: byte offset of word i
#	                in wordlist
#	  corpus        N big-endian 32-bit ints: word id of token i, in
#	                the order tokens occurred
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "draw.m";
include "math.m";
	math: Math;

Corpus: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Rec: adt
{
	word:	string;
	count:	int;
};

BRec: adt
{
	w1, w2:	string;
	count:	int;
	score:	real;
};

Bucket: adt
{
	word:	string;
	id:	int;
	next:	cyclic ref Bucket;
};

Nbuckets: con 16381;	# a prime, so a poor hash still spreads out

usage()
{
	sys->fprint(sys->fildes(2),
		"usage: corpus intern [file] wordlist widx corpus\n" +
		"       corpus print wordlist widx corpus\n" +
		"       corpus hist wordlist widx corpus\n" +
		"       corpus bigrams wordlist widx corpus\n" +
		"       corpus mi wordlist widx corpus\n" +
		"       corpus tscore wordlist widx corpus\n" +
		"       corpus refs wordlist widx corpus word\n" +
		"       corpus pconc wordlist widx corpus context [< refs]\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	if(sys == nil || bufio == nil || math == nil)
		usage();

	args = tl args;
	if(args == nil)
		usage();
	cmd := hd args;
	args = tl args;

	case cmd {
	"intern" =>
		cmd_intern(args);
	"print" =>
		cmd_print(args);
	"hist" =>
		cmd_hist(args);
	"bigrams" =>
		cmd_bigrams(args);
	"mi" =>
		cmd_mi(args);
	"tscore" =>
		cmd_tscore(args);
	"refs" =>
		cmd_refs(args);
	"pconc" =>
		cmd_pconc(args);
	* =>
		usage();
	}
}

isletter(r: int): int
{
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z');
}

# every token of the input, in order, letters only - the same rule
# wordfreq(1) and tr -cs A-Za-z apply.
tokenize(fd: ref Sys->FD): array of string
{
	bio := bufio->fopen(fd, Bufio->OREAD);
	if(bio == nil){
		sys->fprint(sys->fildes(2), "corpus: cannot open bufio: %r\n");
		raise "fail:bufio";
	}
	a := array[8000] of string;
	n := 0;
	w := "";
	for(;;){
		c := bio.getc();
		eof := c < 0;
		if(!eof && isletter(c)){
			w[len w] = c;
			continue;
		}
		if(w != ""){
			if(n >= len a){
				b := array[len a + 8000] of string;
				b[0:] = a;
				a = b;
			}
			a[n++] = w;
			w = "";
		}
		if(eof)
			break;
	}
	return a[0:n];
}

hashstr(s: string): int
{
	h := 0;
	for(i := 0; i < len s; i++)
		h = h*31 + s[i];
	if(h < 0)
		h = -h;
	return h % Nbuckets;
}

putint(fd: ref Sys->FD, v: int)
{
	b := array[4] of byte;
	b[0] = byte (v>>24);
	b[1] = byte (v>>16);
	b[2] = byte (v>>8);
	b[3] = byte v;
	if(sys->write(fd, b, 4) != 4){
		sys->fprint(sys->fildes(2), "corpus: write: %r\n");
		raise "fail:write";
	}
}

# a whole file of big-endian 32-bit ints, read at once
getints(path: string): array of int
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "corpus: cannot open %s: %r\n", path);
		raise "fail:open";
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0){
		sys->fprint(sys->fildes(2), "corpus: cannot stat %s: %r\n", path);
		raise "fail:stat";
	}
	n := int d.length / 4;
	buf := array[n*4] of byte;
	if(sys->readn(fd, buf, len buf) != len buf){
		sys->fprint(sys->fildes(2), "corpus: short read of %s\n", path);
		raise "fail:read";
	}
	r := array[n] of int;
	for(i := 0; i < n; i++){
		o := i*4;
		r[i] = (int buf[o]<<24) | (int buf[o+1]<<16) | (int buf[o+2]<<8) | int buf[o+3];
	}
	return r;
}

Wordlist: adt
{
	data:	array of byte;
	idx:	array of int;
};

loadwordlist(wlpath, widxpath: string): ref Wordlist
{
	fd := sys->open(wlpath, Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "corpus: cannot open %s: %r\n", wlpath);
		raise "fail:open";
	}
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		raise "fail:stat";
	data := array[int d.length] of byte;
	if(sys->readn(fd, data, len data) != len data)
		raise "fail:read";
	idx := getints(widxpath);
	return ref Wordlist(data, idx);
}

wordat(wl: ref Wordlist, id: int): string
{
	start := wl.idx[id];
	e := start;
	while(e < len wl.data && wl.data[e] != byte 0)
		e++;
	return string wl.data[start:e];
}

# intern [file] wordlist widx corpus
cmd_intern(args: list of string)
{
	if(len args != 3 && len args != 4)
		usage();
	textfile := "-";
	if(len args == 4){
		textfile = hd args;
		args = tl args;
	}
	wlpath := hd args; args = tl args;
	widxpath := hd args; args = tl args;
	corpuspath := hd args;

	fd: ref Sys->FD;
	if(textfile == "-")
		fd = sys->fildes(0);
	else{
		fd = sys->open(textfile, Sys->OREAD);
		if(fd == nil){
			sys->fprint(sys->fildes(2), "corpus: cannot open %s: %r\n", textfile);
			raise "fail:open";
		}
	}

	words := tokenize(fd);
	buckets := array[Nbuckets] of ref Bucket;
	uniq := array[8000] of string;
	nuniq := 0;
	ids := array[len words] of int;

	for(i := 0; i < len words; i++){
		w := words[i];
		h := hashstr(w);
		id := -1;
		for(bb := buckets[h]; bb != nil; bb = bb.next)
			if(bb.word == w){
				id = bb.id;
				bb = nil;
				break;
			}
		if(id < 0){
			if(nuniq >= len uniq){
				g := array[len uniq + 4000] of string;
				g[0:] = uniq;
				uniq = g;
			}
			id = nuniq;
			uniq[nuniq++] = w;
			buckets[h] = ref Bucket(w, id, buckets[h]);
		}
		ids[i] = id;
	}

	wlfd := sys->create(wlpath, Sys->OWRITE, 8r666);
	widxfd := sys->create(widxpath, Sys->OWRITE, 8r666);
	corpusfd := sys->create(corpuspath, Sys->OWRITE, 8r666);
	if(wlfd == nil || widxfd == nil || corpusfd == nil){
		sys->fprint(sys->fildes(2), "corpus: cannot create output files: %r\n");
		raise "fail:create";
	}

	off := 0;
	nul := array[1] of byte;
	nul[0] = byte 0;
	for(i = 0; i < nuniq; i++){
		putint(widxfd, off);
		b := array of byte uniq[i];
		sys->write(wlfd, b, len b);
		sys->write(wlfd, nul, 1);
		off += len b + 1;
	}
	for(i = 0; i < len ids; i++)
		putint(corpusfd, ids[i]);

	sys->fprint(sys->fildes(2), "corpus: %d tokens, %d unique words\n", len ids, nuniq);
}

# print wordlist widx corpus - the exact inverse of intern
cmd_print(args: list of string)
{
	if(len args != 3)
		usage();
	wl := loadwordlist(hd args, hd tl args);
	corp := getints(hd tl tl args);
	stdout := bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	for(i := 0; i < len corp; i++)
		stdout.puts(wordat(wl, corp[i]) + "\n");
	stdout.flush();
}

sortrecs(a, b: array of Rec, r: int)
{
	if(r > 1){
		m := (r-1)/2 + 1;
		sortrecs(a[0:m], b[0:m], m);
		sortrecs(a[m:r], b[m:r], r-m);
		b[0:] = a[0:r];
		(i, j, k) := (0, m, 0);
		for(; i < m && j < r; k++){
			if(before(b[j], b[i]))
				a[k] = b[j++];
			else
				a[k] = b[i++];
		}
		if(i < m)
			a[k:] = b[i:m];
		else if(j < r)
			a[k:] = b[j:r];
	}
}

before(x, y: Rec): int
{
	if(x.count != y.count)
		return x.count > y.count;
	return x.word < y.word;
}

# hist wordlist widx corpus - word frequencies, counted by indexing an
# int array with the corpus's own ids, not by sorting or hashing strings
cmd_hist(args: list of string)
{
	if(len args != 3)
		usage();
	wl := loadwordlist(hd args, hd tl args);
	corp := getints(hd tl tl args);
	v := len wl.idx;
	counts := array[v] of int;
	for(i := 0; i < len corp; i++)
		counts[corp[i]]++;

	recs := array[v] of Rec;
	for(i = 0; i < v; i++)
		recs[i] = Rec(wordat(wl, i), counts[i]);
	sortrecs(recs, array[v] of Rec, v);
	for(i = 0; i < v; i++)
		if(recs[i].count > 0)
			sys->print("%6d %s\n", recs[i].count, recs[i].word);
}

sortints(a, b: array of int, r: int)
{
	if(r > 1){
		m := (r-1)/2 + 1;
		sortints(a[0:m], b[0:m], m);
		sortints(a[m:r], b[m:r], r-m);
		b[0:] = a[0:r];
		(i, j, k) := (0, m, 0);
		for(; i < m && j < r; k++){
			if(b[i] > b[j])
				a[k] = b[j++];
			else
				a[k] = b[i++];
		}
		if(i < m)
			a[k:] = b[i:m];
		else if(j < r)
			a[k:] = b[j:r];
	}
}

# the bigrams present, as (id1*m+id2) ints sorted and collapsed into
# runs - count_by_sorting, in Church's own naming; count_by_hashing is
# the faster alternative he also shows and this does not implement,
# on purpose, to keep this bounded to one working technique
bigramcounts(wl: ref Wordlist, corp: array of int): array of BRec
{
	v := len wl.idx;
	m := v + 1;
	n := len corp;
	if(n < 2)
		return array[0] of BRec;
	pairs := array[n-1] of int;
	for(i := 0; i < n-1; i++)
		pairs[i] = corp[i]*m + corp[i+1];
	sortints(pairs, array[n-1] of int, n-1);

	recs := array[n-1] of BRec;
	nr := 0;
	i = 0;
	while(i < len pairs){
		j := i+1;
		while(j < len pairs && pairs[j] == pairs[i])
			j++;
		id1 := pairs[i] / m;
		id2 := pairs[i] % m;
		recs[nr++] = BRec(wordat(wl, id1), wordat(wl, id2), j-i, 0.0);
		i = j;
	}
	return recs[0:nr];
}

sortbrecs(a, b: array of BRec, r: int)
{
	if(r > 1){
		m := (r-1)/2 + 1;
		sortbrecs(a[0:m], b[0:m], m);
		sortbrecs(a[m:r], b[m:r], r-m);
		b[0:] = a[0:r];
		(i, j, k) := (0, m, 0);
		for(; i < m && j < r; k++){
			if(bbefore(b[j], b[i]))
				a[k] = b[j++];
			else
				a[k] = b[i++];
		}
		if(i < m)
			a[k:] = b[i:m];
		else if(j < r)
			a[k:] = b[j:r];
	}
}

bbefore(x, y: BRec): int
{
	if(x.count != y.count)
		return x.count > y.count;
	if(x.w1 != y.w1)
		return x.w1 < y.w1;
	return x.w2 < y.w2;
}

sbefore(x, y: BRec): int
{
	if(x.score != y.score)
		return x.score > y.score;
	if(x.w1 != y.w1)
		return x.w1 < y.w1;
	return x.w2 < y.w2;
}

# mi and tscore both routinely tie a great many bigrams at the same
# score - anything where two words occur exactly once, and only next
# to each other, gets the same maximal mi score regardless of which
# words they are - so an unbroken tie is not a rare edge case here, it
# is the common one, and a sort with no secondary key would give a
# different answer on every run for no principled reason
sortbyscore(a, b: array of BRec, r: int)
{
	if(r > 1){
		m := (r-1)/2 + 1;
		sortbyscore(a[0:m], b[0:m], m);
		sortbyscore(a[m:r], b[m:r], r-m);
		b[0:] = a[0:r];
		(i, j, k) := (0, m, 0);
		for(; i < m && j < r; k++){
			if(sbefore(b[j], b[i]))
				a[k] = b[j++];
			else
				a[k] = b[i++];
		}
		if(i < m)
			a[k:] = b[i:m];
		else if(j < r)
			a[k:] = b[j:r];
	}
}

# bigrams wordlist widx corpus
cmd_bigrams(args: list of string)
{
	if(len args != 3)
		usage();
	wl := loadwordlist(hd args, hd tl args);
	corp := getints(hd tl tl args);
	recs := bigramcounts(wl, corp);
	sortbrecs(recs, array[len recs] of BRec, len recs);
	for(i := 0; i < len recs; i++)
		sys->print("%6d %s %s\n", recs[i].count, recs[i].w1, recs[i].w2);
}

hist(wl: ref Wordlist, corp: array of int): array of int
{
	v := len wl.idx;
	counts := array[v] of int;
	for(i := 0; i < len corp; i++)
		counts[corp[i]]++;
	return counts;
}

# id of a word, or -1
wordid(wl: ref Wordlist, w: string): int
{
	for(i := 0; i < len wl.idx; i++)
		if(wordat(wl, i) == w)
			return i;
	return -1;
}

# mi wordlist widx corpus - pointwise mutual information of each bigram:
# log2(N * count(w1,w2) / (count(w1) * count(w2))), where N is the
# TOKEN count (len corpus), not the number of distinct word types -
# using the type count here would scale every score by the same wrong
# constant and the ranking would still look plausible, which is exactly
# why this is spelled out rather than left to be gotten right by luck
cmd_mi(args: list of string)
{
	if(len args != 3)
		usage();
	wl := loadwordlist(hd args, hd tl args);
	corp := getints(hd tl tl args);
	counts := hist(wl, corp);
	recs := bigramcounts(wl, corp);
	logn := real len corp;
	for(i := 0; i < len recs; i++){
		id1 := wordid(wl, recs[i].w1);
		id2 := wordid(wl, recs[i].w2);
		f1 := real counts[id1];
		f2 := real counts[id2];
		fb := real recs[i].count;
		recs[i].score = math->log(logn * fb / (f1*f2)) / math->log(2.0);
	}
	sortbyscore(recs, array[len recs] of BRec, len recs);
	for(i = 0; i < len recs; i++)
		sys->print("%8.4f %s %s\n", recs[i].score, recs[i].w1, recs[i].w2);
}

# tscore wordlist widx corpus - (observed - expected)/sqrt(observed);
# same N-is-tokens-not-types caution as mi above
cmd_tscore(args: list of string)
{
	if(len args != 3)
		usage();
	wl := loadwordlist(hd args, hd tl args);
	corp := getints(hd tl tl args);
	counts := hist(wl, corp);
	recs := bigramcounts(wl, corp);
	bign := real len corp;
	for(i := 0; i < len recs; i++){
		id1 := wordid(wl, recs[i].w1);
		id2 := wordid(wl, recs[i].w2);
		f1 := real counts[id1];
		f2 := real counts[id2];
		fb := real recs[i].count;
		recs[i].score = (fb - f1*f2/bign) / math->sqrt(fb);
	}
	sortbyscore(recs, array[len recs] of BRec, len recs);
	for(i = 0; i < len recs; i++)
		sys->print("%8.4f %s %s\n", recs[i].score, recs[i].w1, recs[i].w2);
}

# refs wordlist widx corpus word - every position of word in corpus,
# one per line: the inverted-index half of concordancing. A real
# inverted index (Church's conc/conc.idx) is worth building only once
# the same lookup is done often enough on the same corpus to be worth
# precomputing; a linear scan is the honest thing to do once, which is
# what a concordance query actually is here
cmd_refs(args: list of string)
{
	if(len args != 4)
		usage();
	wl := loadwordlist(hd args, hd tl args);
	corp := getints(hd tl tl args);
	word := hd tl tl tl args;
	id := wordid(wl, word);
	if(id < 0)
		return;
	for(i := 0; i < len corp; i++)
		if(corp[i] == id)
			sys->print("%d\n", i);
}

# pconc wordlist widx corpus context [< refs]
cmd_pconc(args: list of string)
{
	if(len args != 4)
		usage();
	wl := loadwordlist(hd args, hd tl args);
	corp := getints(hd tl tl args);
	context := int hd tl tl tl args;

	bio := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	line: string;
	while((line = bio.gets('\n')) != nil){
		if(len line > 0 && line[len line-1] == '\n')
			line = line[0:len line-1];
		pos := int line;
		lo := pos - context;
		if(lo < 0)
			lo = 0;
		hi := pos + context + 1;
		if(hi > len corp)
			hi = len corp;
		s := "";
		for(i := lo; i < hi; i++){
			if(i > lo)
				s += " ";
			s += wordat(wl, corp[i]);
		}
		sys->print("%s\n", s);
	}
}
