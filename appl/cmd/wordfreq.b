implement Wordfreq;

#
#	wordfreq: count words (or, with -b, adjacent word pairs) and print
#	them most frequent first.
#
#	This is the tokenize | sort | uniq -c | sort -nr pipeline as one
#	program instead of four processes and three pipes - written for
#	lib/demo/inferno-for-dante.sh, which uses no tr/sort/uniq/grep/sed at
#	all: sh(2)'s own `load regex` and `getlines` cover pattern matching
#	and substitution natively (see man/1/sh-regex), and this is the part
#	of the awk-shaped exercise that genuinely needs a real program rather
#	than a shell one-liner - counting and sorting, not just filtering.
#	See man/1/wordfreq.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "draw.m";
include "arg.m";

Wordfreq: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Rec: adt
{
	word:	string;
	count:	int;
};

Incr: con 8000;

usage()
{
	sys->fprint(sys->fildes(2), "usage: wordfreq [-b] [-n count] [file]\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	arg := load Arg Arg->PATH;
	if(sys == nil || bufio == nil || arg == nil)
		usage();

	bflag := 0;
	nlimit := 0;		# 0 means unlimited
	arg->init(args);
	while((opt := arg->opt()) != 0)
		case opt {
		'b' =>
			bflag = 1;
		'n' =>
			nlimit = int arg->earg();
		* =>
			usage();
		}
	args = arg->argv();
	if(len args > 1)
		usage();

	fd: ref Sys->FD;
	if(args != nil){
		fd = sys->open(hd args, Sys->OREAD);
		if(fd == nil){
			sys->fprint(sys->fildes(2), "wordfreq: cannot open %s: %r\n", hd args);
			raise "fail:open";
		}
	}else
		fd = sys->fildes(0);

	words := tokenize(fd, bflag);
	n := len words;
	sortstrings(words, array[n] of string, n);

	recs := collapse(words, n);
	sortrecs(recs, array[len recs] of Rec, len recs);

	stdout := bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	m := len recs;
	if(nlimit > 0 && nlimit < m)
		m = nlimit;
	for(i := 0; i < m; i++)
		stdout.puts(sys->sprint("%6d %s\n", recs[i].count, recs[i].word));
	stdout.flush();
}

isletter(r: int): int
{
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z');
}

# One pass over the runes: accumulate a run of letters into a word, any
# other rune ends it - the same rule tr -cs A-Za-z applies, kept
# deliberately identical so the two demos are doing the same operation,
# one via a pipe of processes and one natively. With -b, the words are
# paired up with the one that followed it, "w1 w2" as a single token, so
# the rest of the pipeline (sort, then collapse runs) does not need to
# know bigrams exist.
tokenize(fd: ref Sys->FD, bigram: int): array of string
{
	bio := bufio->fopen(fd, Bufio->OREAD);
	if(bio == nil){
		sys->fprint(sys->fildes(2), "wordfreq: cannot open bufio: %r\n");
		raise "fail:bufio";
	}
	a := array[Incr] of string;
	n := 0;
	prev := "";
	haveprev := 0;
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
				b := array[len a + Incr] of string;
				b[0:] = a;
				a = b;
			}
			if(bigram){
				if(haveprev)
					a[n++] = prev + " " + w;
				prev = w;
				haveprev = 1;
			}else
				a[n++] = w;
			w = "";
		}
		if(eof)
			break;
	}
	return a[0:n];
}

sortstrings(a, b: array of string, r: int)
{
	if(r > 1){
		m := (r-1)/2 + 1;
		sortstrings(a[0:m], b[0:m], m);
		sortstrings(a[m:r], b[m:r], r-m);
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

# the sorted array collapsed into runs, uniq -c's whole job
collapse(a: array of string, n: int): array of Rec
{
	recs := array[n] of Rec;
	m := 0;
	i := 0;
	while(i < n){
		j := i+1;
		while(j < n && a[j] == a[i])
			j++;
		recs[m].word = a[i];
		recs[m].count = j-i;
		m++;
		i = j;
	}
	return recs[0:m];
}

# descending by count; ties broken by word, ascending, so the output is
# the same from one run to the next
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
