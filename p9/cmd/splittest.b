implement Splittest;

# Regression test for p9/cmd/split.b, following this tree's *test.b
# convention. split's whole job is creating real output files, so this
# test drives it entirely with real files (writes a real input file,
# calls split.dis's run(args) seam with a real trailing file operand,
# reads the resulting output files back, cleans up) - the same "real
# files throughout" shape as jointest.b, for the same reason.
#
# Every case here was checked against plan9port's real split binary
# first (this tree's local plan9port checkout - see split.b's header
# comment for why plan9port, not 9front, is the reference for this
# specific file), not assumed from reading split.b.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Splittest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Split: module
{
	PATH:	con "/p9/dis/split.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(args: list of string): int;
};

stderr: ref FD;
sp: Split;
npass, nfail: int;
madefiles: list of string;	# every output path any check has created,
				# for cleanup at the end

writefile(path: string, text: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(stderr, "splittest: cannot create %s: %r\n", path);
		raise "fail:setup";
	}
	buf := array of byte text;
	if(sys->write(fd, buf, len buf) != len buf){
		sys->fprint(stderr, "splittest: short write to %s\n", path);
		raise "fail:setup";
	}
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	return string buf[0:n];
}

init(nil: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	sp = load Split Split->PATH;
	if(sp == nil){
		sys->fprint(stderr, "splittest: cannot load %s: %r\n", Split->PATH);
		raise "fail:bad module";
	}

	check("default mode splits every N lines into sequential files",
		"l1\nl2\nl3\nl4\nl5\n",
		"-n" :: "2" :: "-f" :: "/splittest-d" :: nil,
		("/splittest-daa", "l1\nl2\n") ::
		("/splittest-dab", "l3\nl4\n") ::
		("/splittest-dac", "l5\n") :: nil);

	check("-e with a capturing group names files from the captured text, ignoring -f entirely",
		"nomatch1\nSTART /splittest-foo\nbody1\nbody2\nSTART /splittest-bar\nbody3\n",
		"-e" :: "^START (.*)" :: nil,
		("/splittest-foo", "START /splittest-foo\nbody1\nbody2\n") ::
		("/splittest-bar", "START /splittest-bar\nbody3\n") :: nil);

	check("a line before the first pattern match is silently dropped (no output file open yet - see split.b's header comment)",
		"nomatch1\nSTART /splittest-drop1\nbody\n",
		"-e" :: "^START (.*)" :: nil,
		("/splittest-drop1", "START /splittest-drop1\nbody\n") :: nil);

	check("-x excludes the matching delimiter line from either file",
		"START /splittest-x1\nbodyA\nSTART /splittest-x2\nbodyB\n",
		"-x" :: "-e" :: "^START (.*)" :: nil,
		("/splittest-x1", "bodyA\n") ::
		("/splittest-x2", "bodyB\n") :: nil);

	check("-i folds both the match AND the resulting captured filename's case, not just matching",
		"start /splittest-FOLD\nbodyC\n",
		"-i" :: "-e" :: "^START (.*)" :: nil,
		("/splittest-fold", "start /splittest-FOLD\nbodyC\n") :: nil);

	check("no captured group falls back to sequential (stem+suffix) naming, still preserving pre-match drop",
		"a1\nSTART\nb1\nb2\nSTART\nb3\n",
		"-e" :: "^START$" :: "-f" :: "/splittest-z" :: nil,
		("/splittest-zaa", "START\nb1\nb2\n") ::
		("/splittest-zab", "START\nb3\n") :: nil);

	check("-s only affects capture-group-derived filenames, not sequential (-n) ones - checked, not assumed",
		"l1\nl2\nl3\n",
		"-n" :: "1" :: "-f" :: "/splittest-s" :: "-s" :: ".suf" :: nil,
		("/splittest-saa", "l1\n") ::
		("/splittest-sab", "l2\n") ::
		("/splittest-sac", "l3\n") :: nil);
	checkabsent("/splittest-saa.suf");

	sys->print("%d passed, %d failed\n", npass, nfail);
	for(fl := madefiles; fl != nil; fl = tl fl)
		sys->remove(hd fl);
	if(nfail > 0)
		raise "fail:test failure";
}

appendone(l: list of string, x: string): list of string
{
	# reverse l, prepend x, reverse back - the usual way to append to
	# the end of a singly-linked Limbo list.
	rev: list of string;
	for(; l != nil; l = tl l)
		rev = hd l :: rev;
	rev = x :: rev;
	fwd: list of string;
	for(; rev != nil; rev = tl rev)
		fwd = hd rev :: fwd;
	return fwd;
}

check(desc: string, input: string, args: list of string, want: list of (string, string))
{
	inpath := "/splittest-in.txt";
	writefile(inpath, input);
	madefiles = inpath :: madefiles;

	sp->run(appendone(args, inpath));

	ok := 1;
	for(w := want; w != nil; w = tl w){
		(path, wantcontent) := hd w;
		madefiles = path :: madefiles;
		got := readfile(path);
		if(got != wantcontent){
			ok = 0;
			sys->fprint(stderr, "FAIL %s\n  file: %s\n  want: %q\n  got:  %q\n",
				desc, path, wantcontent, got);
		}
	}
	if(ok)
		npass++;
	else
		nfail++;
}

checkabsent(path: string)
{
	got := readfile(path);
	if(got == nil){
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s should not exist\n  got: %q\n", path, got);
}
