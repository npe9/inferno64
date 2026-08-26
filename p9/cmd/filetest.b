implement Filetest;

# Regression test for file(1) - see file.b's own header comment for why
# every expected result here is derived directly from the classifier
# tables' own definitions (a file starting with exactly \x89PNG *is* a
# PNG by this program's own table, checkable without any reference
# binary), not copied from a live file(1) run.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Filetest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# file.dis's real module type is declared once, in file.b itself - no
# shared module/file.m, same convention as every other p9/cmd test.
File: module
{
	PATH:	con "/p9/dis/file.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(mimeflag: int, path: string): string;
};

filemod: File;
stderr: ref FD;
npass, nfail: int;
DIR: con "/filetest";

writebytes(path: string, b: array of byte)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		fail("cannot create " + path);
	if(sys->write(fd, b, len b) != len b)
		fail("cannot write " + path);
}

writefile(path: string, content: string)
{
	writebytes(path, array of byte content);
}

removeifexists(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok != -1)
		sys->remove(path);
}

fail(s: string)
{
	sys->fprint(stderr, "filetest: %s\n", s);
	raise "fail:filetest";
}

check(name: string, got: string, want: string)
{
	if(got == want)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", name, want, got);
	}
}

bb(vals: array of int): array of byte
{
	r := array[len vals] of byte;
	for(i := 0; i < len vals; i++)
		r[i] = byte vals[i];
	return r;
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	filemod = load File File->PATH;
	if(filemod == nil){
		sys->fprint(stderr, "filetest: cannot load File\n");
		raise "fail:module";
	}

	(ok, nil) := sys->stat(DIR);
	if(ok == -1){
		fd := sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r777);
		if(fd == nil)
			fail("cannot create " + DIR);
	}

	npass = 0;
	nfail = 0;

	t1directory();
	t2empty();
	t3png();
	t4zip();
	t5udiff();
	t6tar();
	t7cbug();
	t8english();
	t9html();
	t10rfc822();
	t11utf16bom();
	t12shebang();
	t13mime();

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:filetest";
}

# T1: a real directory.
t1directory()
{
	check("t1directory", filemod->run(0, DIR), "directory\n");
}

# T2: a real empty file.
t2empty()
{
	path := DIR + "/empty";
	writebytes(path, array[0] of byte);
	check("t2empty", filemod->run(0, path), "empty file\n");
	removeifexists(path);
}

# T3: istring()'s PNG entry - the exact 4-byte magic \x89PNG, nothing
# else (istring() only looks at the leading bytes).
t3png()
{
	path := DIR + "/pic.dat";
	writebytes(path, bb(array[] of {16r89,'P','N','G',1,2,3,4,5,6,7,8}));
	check("t3png", filemod->run(0, path), "PNG image\n");
	removeifexists(path);
}

# T4: long0()'s zip magic (a real local-file-header signature, PK\x03\x04).
t4zip()
{
	path := DIR + "/pic.zip";
	writebytes(path, bb(array[] of {16r50,16r4b,16r03,16r04,0,0,0,0}));
	check("t4zip", filemod->run(0, path), "zip archive\n");
	removeifexists(path);
}

# T5: isudiff() - "diff" somewhere, then a real ---/+++/@@ triple.
t5udiff()
{
	path := DIR + "/x.diff";
	writefile(path, "diff -u a b\n--- a\n+++ b\n@@ -1,1 +1,1 @@\n-x\n+y\n");
	check("t5udiff", filemod->run(0, path), "unified diff output\n");
	removeifexists(path);
}

# T6: istar() - a real 512-byte ustar header with a correctly computed
# checksum, built the same way the classifier itself would verify it
# (sum of all 512 bytes, chksum field read as spaces).
t6tar()
{
	path := DIR + "/x.tar";
	hdr := array[512] of {* => byte 0};
	name := array of byte "hello.txt";
	hdr[0:] = name;
	mode := array of byte "0000644";
	hdr[100:] = mode;
	sizef := array of byte "00000000000";	# octal size field, 11 digits + implicit term
	hdr[124:] = sizef;
	magic := array of byte "ustar";
	hdr[257:] = magic;
	hdr[263] = byte '0';	# version[0]
	# chksum field (148..155): fill with spaces, compute, then write
	# as a 6-digit octal + NUL + space, matching real tar headers.
	for(ci := 148; ci < 156; ci++)
		hdr[ci] = byte ' ';
	sum := 0;
	for(si := 0; si < 512; si++)
		sum += int hdr[si] & 16rff;
	chkstr := octstr(sum, 6) + "\0 ";
	chkb := array of byte chkstr;
	hdr[148:] = chkb;
	writebytes(path, hdr);
	check("t6tar", filemod->run(0, path), "posix tar archive\n");
	removeifexists(path);
}

octstr(v: int, width: int): string
{
	s := "";
	x := v;
	for(i := 0; i < width; i++){
		d := x & 7;
		s = string d + s;
		x >>= 3;
	}
	return s;
}

# T7: the preserved dict[] binary-search bug (see file.b's header
# comment) - two structurally identical two-line #include texts,
# differing only in which header is named. "stdio" is found correctly
# by the (partly broken) search; "bio" is not, because "bio" sits out
# of sorted order in the original table and this translation preserves
# that exactly. Same isc() heuristic, same word counts otherwise - the
# only difference is whether wfreq[I2] ends up 2 (stdio) or 0 (bio).
t7cbug()
{
	good := DIR + "/good.c";
	writefile(good, "#include <stdio.h>\n#include <stdio.h>\n");
	check("t7cbug control (stdio, not affected by the bug)",
		filemod->run(0, good), "c program\n");
	removeifexists(good);

	bad := DIR + "/bad.c";
	writefile(bad, "#include <bio.h>\n#include <bio.h>\n");
	check("t7cbug (bio, silently not recognised as C - preserved bug)",
		filemod->run(0, bad), "short Ascii\n");
	removeifexists(bad);
}

# T8: isenglish() - ordinary English prose. Deliberately NOT a pangram:
# isenglish()'s own heuristic (common ETAION letters must outnumber
# rare VJKQXZ ones by 10x) fails on text engineered to include every
# letter (a first draft used "the quick brown fox...", which packs in
# enough of q/x/z/j/k to fail the real threshold - checked by
# simulating the exact heuristic against candidate text, not assumed).
t8english()
{
	path := DIR + "/prose.txt";
	writefile(path,
		"There is a nice house near the river. The weather has been fine all week, "+
		"and the neighbors seem content. Everyone enjoys walking in the evening air. "+
		"It is a fine season indeed, and nothing seems out of place. "+
		"The residents love their calm street and their peaceful home.");
	check("t8english", filemod->run(0, path), "English text\n");
	removeifexists(path);
}

# T9: ishtml() - needs 3+ recognised tags each followed by a
# whitespace/>//, in order.
t9html()
{
	path := DIR + "/page.html";
	writefile(path, "<html>\n<head><title>hi</title></head>\n<body><p>hello</p></body>\n</html>\n");
	check("t9html", filemod->run(0, path), "HTML file\n");
	removeifexists(path);
}

# T10: isrfc822() - 3+ recognised header lines.
t10rfc822()
{
	path := DIR + "/mail.txt";
	writefile(path, "From: a@example.com\nTo: b@example.com\nSubject: hi\n\nbody text\n");
	check("t10rfc822", filemod->run(0, path), "email file\n");
	removeifexists(path);
}

# T11: utfconv()'s UTF-16LE BOM handling, re-encoded to UTF-8 in place
# before the histogram runs. "12" (digits, no vowels/common/rare
# letters) rather than a real word - picked specifically so isenglish()
# and the word-frequency classifiers can't match it either way,
# leaving only the plain "short Ascii" fallback as the unambiguous
# rest of the output after utfconv()'s own "utf-16le " report.
t11utf16bom()
{
	path := DIR + "/u16.txt";
	writebytes(path, bb(array[] of {16rff,16rfe, '1',0, '2',0}));
	check("t11utf16bom", filemod->run(0, path), "utf-16le short Ascii\n");
	removeifexists(path);
}

# T12: isexecscript() - a "#!" shebang naming a recognised interpreter.
t12shebang()
{
	path := DIR + "/script";
	writefile(path, "#!/bin/rc\necho hi\n");
	check("t12shebang", filemod->run(0, path), "rc executable file\n");
	removeifexists(path);
}

# T13: the -m (mime) flag changes the same PNG detection's own output.
t13mime()
{
	path := DIR + "/pic2.dat";
	writebytes(path, bb(array[] of {16r89,'P','N','G',1,2,3,4}));
	check("t13mime", filemod->run(1, path), "image/png\n");
	removeifexists(path);
}
