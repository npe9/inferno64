implement Ix;

# Nelson's Dream Machines chapter on Information Retrieval: indexed,
# ranked full-text search, as distinct from a linear grep - build an
# inverted index once (word -> which documents it appears in, and how
# often), then answer a multi-word query by ranking every document that
# contains any query word, not just listing lines that match.
#
# Ranking is classic TF-IDF: a word's contribution to a document's score
# is how often it appears there (relative to the document's own length,
# so a short document isn't penalised for using a word only twice)
# times how rare that word is across the whole indexed set (a word only
# a few documents use is a stronger signal than one nearly all of them
# use). Both the on-disk index and the query/rank pass are plain text
# and plain lists with linear search - fine at the scale a demo actually
# needs (tens of files, thousands of words), not written to scale to a
# real corpus.
#
# usage: ix build index.ix file...
#        ix search index.ix word...

include "sys.m";
	sys: Sys;

include "draw.m";
	Context: import Draw;

include "math.m";
	math: Math;

Ix: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

stdout, stderr: ref Sys->FD;

Doc: adt {
	path: string;
	nwords: int;
};

Posting: adt {
	docid: int;
	count: int;
};

Term: adt {
	word: string;
	postings: list of ref Posting;
};

LocalCount: adt {
	word: string;
	count: int;
};

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	stdout = sys->fildes(1);
	stderr = sys->fildes(2);

	argv = tl argv;
	if(argv == nil)
		usage();
	cmd := hd argv;
	argv = tl argv;
	if(argv == nil)
		usage();
	indexpath := hd argv;
	argv = tl argv;
	if(argv == nil)
		usage();

	case cmd {
	"build" =>
		build(indexpath, argv);
	"search" =>
		search(indexpath, argv);
	* =>
		usage();
	}
}

usage()
{
	sys->fprint(stderr, "usage: ix build index.ix file...\n       ix search index.ix word...\n");
	raise "fail:usage";
}

build(indexpath: string, files: list of string)
{
	ndocs := 0;
	for(f := files; f != nil; f = tl f)
		ndocs++;
	docs := array[ndocs] of ref Doc;
	terms: list of ref Term;

	i := 0;
	for(f = files; f != nil; f = tl f){
		path := hd f;
		(text, err) := readfile(path);
		if(err != nil){
			sys->fprint(stderr, "ix: %s\n", err);
			docs[i] = ref Doc(path, 0);
			i++;
			continue;
		}
		words := tokenize(text);
		nwords := 0;
		for(w := words; w != nil; w = tl w)
			nwords++;
		docs[i] = ref Doc(path, nwords);
		terms = addterms(terms, i, words);
		i++;
	}

	if((err := writeindex(indexpath, docs, terms)) != nil){
		sys->fprint(stderr, "ix: %s\n", err);
		raise "fail:write";
	}
	sys->fprint(stdout, "ix: indexed %d files\n", ndocs);
}

addterms(terms: list of ref Term, docid: int, words: list of string): list of ref Term
{
	local: list of ref LocalCount;
	for(w := words; w != nil; w = tl w){
		word := hd w;
		lc := findlocal(local, word);
		if(lc == nil){
			lc = ref LocalCount(word, 0);
			local = lc :: local;
		}
		lc.count++;
	}
	for(l := local; l != nil; l = tl l){
		lc := hd l;
		t := findterm(terms, lc.word);
		if(t == nil){
			t = ref Term(lc.word, nil);
			terms = t :: terms;
		}
		t.postings = ref Posting(docid, lc.count) :: t.postings;
	}
	return terms;
}

findlocal(local: list of ref LocalCount, word: string): ref LocalCount
{
	for(l := local; l != nil; l = tl l)
		if((hd l).word == word)
			return hd l;
	return nil;
}

findterm(terms: list of ref Term, word: string): ref Term
{
	for(t := terms; t != nil; t = tl t)
		if((hd t).word == word)
			return hd t;
	return nil;
}

search(indexpath: string, query: list of string)
{
	(docs, terms, err) := readindex(indexpath);
	if(err != nil){
		sys->fprint(stderr, "ix: %s\n", err);
		raise "fail:read";
	}
	ndocs := len docs;
	if(ndocs == 0){
		sys->fprint(stdout, "ix: empty index\n");
		return;
	}
	scores := array[ndocs] of real;
	for(i := 0; i < ndocs; i++)
		scores[i] = 0.0;

	for(q := query; q != nil; q = tl q){
		word := lower(hd q);
		t := findterm(terms, word);
		if(t == nil)
			continue;
		df := 0;
		for(p := t.postings; p != nil; p = tl p)
			df++;
		if(df == 0)
			continue;
		idf := math->log(real ndocs / real df);
		if(idf < 0.0)
			idf = 0.0;
		for(p2 := t.postings; p2 != nil; p2 = tl p2){
			post := hd p2;
			nw := docs[post.docid].nwords;
			if(nw < 1)
				nw = 1;
			tf := real post.count / real nw;
			scores[post.docid] += tf*idf;
		}
	}

	order := array[ndocs] of int;
	for(i = 0; i < ndocs; i++)
		order[i] = i;
	for(i = 1; i < ndocs; i++){
		key := order[i];
		keyscore := scores[key];
		j := i-1;
		while(j >= 0 && scores[order[j]] < keyscore){
			order[j+1] = order[j];
			j--;
		}
		order[j+1] = key;
	}

	nshown := 0;
	for(i = 0; i < ndocs; i++){
		d := order[i];
		if(scores[d] <= 0.0)
			continue;
		sys->fprint(stdout, "%6.3f  %s\n", scores[d], docs[d].path);
		nshown++;
	}
	if(nshown == 0)
		sys->fprint(stdout, "ix: no matches\n");
}

writeindex(path: string, docs: array of ref Doc, terms: list of ref Term): string
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	sys->fprint(fd, "DOCS %d\n", len docs);
	for(i := 0; i < len docs; i++)
		sys->fprint(fd, "%d\t%d\t%s\n", i, docs[i].nwords, docs[i].path);
	nterms := 0;
	for(t := terms; t != nil; t = tl t)
		nterms++;
	sys->fprint(fd, "TERMS %d\n", nterms);
	for(t = terms; t != nil; t = tl t){
		term := hd t;
		sys->fprint(fd, "%s", term.word);
		for(p := term.postings; p != nil; p = tl p){
			post := hd p;
			sys->fprint(fd, " %d:%d", post.docid, post.count);
		}
		sys->fprint(fd, "\n");
	}
	return nil;
}

readindex(path: string): (array of ref Doc, list of ref Term, string)
{
	(text, err) := readfile(path);
	if(err != nil)
		return (nil, nil, err);
	(nil, lines) := sys->tokenize(text, "\n");
	if(lines == nil)
		return (nil, nil, "empty index");

	hdr := hd lines;
	lines = tl lines;
	(nh, htoks) := sys->tokenize(hdr, " ");
	if(nh != 2 || hd htoks != "DOCS")
		return (nil, nil, "bad index header");
	ndocs := int hd tl htoks;
	docs := array[ndocs] of ref Doc;
	for(i := 0; i < ndocs; i++){
		if(lines == nil)
			return (nil, nil, "truncated index");
		line := hd lines;
		lines = tl lines;
		(nf, f) := sys->tokenize(line, "\t");
		if(nf != 3)
			return (nil, nil, "bad doc line");
		id := int hd f; f = tl f;
		nwords := int hd f; f = tl f;
		path2 := hd f;
		docs[id] = ref Doc(path2, nwords);
	}

	if(lines == nil)
		return (nil, nil, "truncated index");
	thdr := hd lines;
	lines = tl lines;
	(nth, ttoks) := sys->tokenize(thdr, " ");
	if(nth != 2 || hd ttoks != "TERMS")
		return (nil, nil, "bad terms header");
	nterms := int hd tl ttoks;
	terms: list of ref Term;
	for(i = 0; i < nterms; i++){
		if(lines == nil)
			return (nil, nil, "truncated index");
		line := hd lines;
		lines = tl lines;
		(nf, f) := sys->tokenize(line, " ");
		if(nf < 1)
			continue;
		word := hd f;
		f = tl f;
		postings: list of ref Posting;
		for(; f != nil; f = tl f){
			(nc, parts) := sys->tokenize(hd f, ":");
			if(nc != 2)
				continue;
			docid := int hd parts;
			count := int hd tl parts;
			postings = ref Posting(docid, count) :: postings;
		}
		terms = ref Term(word, postings) :: terms;
	}
	return (docs, terms, nil);
}

tokenize(text: string): list of string
{
	words: list of string;
	n := len text;
	i := 0;
	while(i < n){
		while(i < n && !isalnum(text[i]))
			i++;
		if(i >= n)
			break;
		j := i;
		while(j < n && isalnum(text[j]))
			j++;
		words = lower(text[i:j]) :: words;
		i = j;
	}
	return words;
}

isalnum(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

lower(s: string): string
{
	r := s;
	for(i := 0; i < len r; i++)
		if(r[i] >= 'A' && r[i] <= 'Z')
			r[i] = r[i]-'A'+'a';
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
