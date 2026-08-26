implement Tartest;

# Regression test for tar(1) - see tar.b's own header comment for the
# translation decisions this exercises.
#
# THE STRONGER ORACLE, run manually, not automatically. tar.b's own
# header comment explains why this suite can't shell out to a real
# tar binary from inside a running test (no fork/exec in Limbo) - so
# everything below is either a hand-built ustar/PAX/GNU-longname byte
# sequence (an independently-derivable format, like file.b/patch.b's
# own fixtures) or a self-round-trip through tar.dis's own c and x
# verbs. The stronger, bidirectional check against a REAL host tar was
# done once, by hand, outside emu, during development, and is recorded
# here rather than re-run every time:
#
#   host tar --format ustar -cf host.tar src/   (a dir with 2 files)
#   emu tar xvf host.tar                        -> content byte-identical
#   emu tar cvf mine.tar src/
#   host tar xvf mine.tar                       -> content byte-identical
#   host tar -cf pax.tar src/  (host's own default = PAX format)
#   emu tar xvf pax.tar                         -> content byte-identical
#   a 130-character filename, both directions (host writes PAX long
#   name / emu reads it, and emu writes PAX long name / host reads it)
#                                                -> both byte-identical
#
# All four passed on the real macOS host tar (bsdtar 3.5.3/libarchive)
# during development. Not re-run by this suite; see BUGS.
#
# A related environmental finding, also from manual probing, also not
# re-runnable as an automated case: this host filesystem backend's
# fwstat rejects an attempt to set an arbitrary string gid (rc -1) -
# so the preserved uname/gname bug documented in tar.b's own header
# comment (parsehdr() reads bp's owner-name field into hdr->gid instead
# of the group-name field) has no reliable way to be shown via a real
# extract-then-restat round trip in this environment, real bug or not.
# Recorded rather than worked around with a fragile test.

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Tartest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# tar.dis's real module type is declared once, in tar.b itself - same
# convention as every other p9/cmd test.
Tar: module
{
	PATH:	con "/p9/dis/tar.dis";
	init:	fn(ctxt: ref Context, argv: list of string);
	run:	fn(argv: list of string): (string, int);
};

tarmod: Tar;
stderr: ref FD;
npass, nfail: int;
DIR: con "/tartest";
Tblock: con 512;

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

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		fail("cannot open " + path);
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		fail("cannot read " + path);
	return string buf[0:n];
}

mkdirp(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok == -1){
		fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r777);
		if(fd == nil)
			fail("cannot mkdir " + path);
	}
}

removeifexists(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok != -1)
		sys->remove(path);
}

fail(s: string)
{
	sys->fprint(stderr, "tartest: %s\n", s);
	raise "fail:tartest";
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

checki(name: string, got: int, want: int)
{
	if(got == want)
		npass++;
	else {
		nfail++;
		sys->fprint(stderr, "FAIL %s: want %d got %d\n", name, want, got);
	}
}

contains(s: string, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 1;
	for(cti := 0; cti+n <= len s; cti++)
		if(s[cti:cti+n] == sub)
			return 1;
	return 0;
}

repeatstr(s: string, n: int): string
{
	r := "";
	for(rpi := 0; rpi < n; rpi++)
		r += s;
	return r;
}

# checkfail: same bare-exception-block convention as patchtest.b's own
# checkfail()/jointest.b's - run() is expected to raise, caught here.
checkfail(name: string, argv: list of string)
{
	{
		tarmod->run(argv);
	} exception e {
	"fail:*" =>
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: a failure\n  got:  no failure\n", name);
}

# --- hand-built ustar/PAX/GNU-longname block fixtures ---
# Independently reimplemented here (not calling into tar.b's own
# helpers) so this stays a real black-box check of the wire format,
# not a test that only agrees with itself.

putstr(b: array of byte, off: int, s: string)
{
	b[off:] = array of byte s;
}

nulterm(s: string): array of byte
{
	b := array of byte s;
	r := array[len b + 1] of byte;
	r[0:] = b;
	r[len b] = byte 0;
	return r;
}

chksumof(b: array of byte): int
{
	old := b[148:156];
	for(csi := 0; csi < 8; csi++)
		b[148+csi] = byte ' ';
	sum := 0;
	for(csi2 := 0; csi2 < Tblock; csi2++)
		sum += int b[csi2];
	for(csi3 := 0; csi3 < 8; csi3++)
		b[148+csi3] = old[csi3];
	return sum;
}

mkustar(name: string, contentlen: int, mode: int): array of byte
{
	b := array[Tblock] of {* => byte 0};
	putstr(b, 0, name);
	putstr(b, 100, sys->sprint("%6o ", mode));
	putstr(b, 108, sys->sprint("%6o ", 0));
	putstr(b, 116, sys->sprint("%6o ", 0));
	putstr(b, 124, sys->sprint("%11o ", contentlen));
	putstr(b, 136, sys->sprint("%11o ", 0));
	if(contentlen == 0 && len name > 0 && name[len name-1] == '/')
		b[156] = byte '5';	# LF_DIR
	else
		b[156] = byte '0';	# LF_PLAIN2
	putstr(b, 257, "ustar");
	putstr(b, 263, "00");
	putstr(b, 265, "owner");
	putstr(b, 297, "group");
	putstr(b, 148, sys->sprint("%6o", chksumof(b)));
	return b;
}

mkdatablocksb(c: array of byte): array of byte
{
	nblks := (len c + Tblock - 1)/Tblock;
	if(nblks == 0)
		return array[0] of byte;
	out := array[nblks*Tblock] of {* => byte 0};
	out[0:] = c;
	return out;
}

mkdatablocks(content: string): array of byte
{
	return mkdatablocksb(array of byte content);
}

mkeoa(): array of byte
{
	return array[2*Tblock] of {* => byte 0};
}

catblocks(parts: array of array of byte): array of byte
{
	n := 0;
	for(cbi := 0; cbi < len parts; cbi++)
		n += len parts[cbi];
	out := array[n] of byte;
	p := 0;
	for(cbi2 := 0; cbi2 < len parts; cbi2++){
		out[p:] = parts[cbi2];
		p += len parts[cbi2];
	}
	return out;
}

mkpaxrec(attr: string): array of byte
{
	kv := " " + attr + "\n";
	n := len kv + 1;
	nn := n;
	do{
		n = nn;
		nn = len string n + len kv;
	} while(n != nn);
	return array of byte (string n + kv);
}

mkpaxhdrblk(content: array of byte): array of byte
{
	b := array[Tblock] of {* => byte 0};
	b[156] = byte 'x';	# LF_PAXHDR
	putstr(b, 0, "pax/x");
	putstr(b, 100, sys->sprint("%6o ", 8r644));
	putstr(b, 108, sys->sprint("%6o ", 0));
	putstr(b, 116, sys->sprint("%6o ", 0));
	putstr(b, 124, sys->sprint("%11o ", len content));
	putstr(b, 136, sys->sprint("%11o ", 0));
	putstr(b, 257, "ustar");
	putstr(b, 263, "00");
	putstr(b, 148, sys->sprint("%6o", chksumof(b)));
	return b;
}

mkgnulongnameblk(nameterm: array of byte): array of byte
{
	b := array[Tblock] of {* => byte 0};
	b[156] = byte 'L';	# LF_LONGNAME
	putstr(b, 0, "././@LongLink");
	putstr(b, 100, sys->sprint("%6o ", 0));
	putstr(b, 108, sys->sprint("%6o ", 0));
	putstr(b, 116, sys->sprint("%6o ", 0));
	putstr(b, 124, sys->sprint("%11o ", len nameterm));
	putstr(b, 136, sys->sprint("%11o ", 0));
	putstr(b, 148, sys->sprint("%6o", chksumof(b)));
	return b;
}

# T1: a hand-built single-file ustar archive - the extraction path
# with no PAX/GNU-longname involvement at all.
t1basicfile()
{
	path := DIR + "/t1.tar";
	writebytes(path, catblocks(array[] of {
		mkustar("hello.txt", len "hi there\n", 8r644),
		mkdatablocks("hi there\n"),
		mkeoa(),
	}));
	outdir := DIR + "/t1out";
	mkdirp(outdir);
	sys->chdir(outdir);
	tarmod->run(list of {"xf", path});
	check("t1basicfile", readfile(outdir+"/hello.txt"), "hi there\n");
	removeifexists(path);
	removeifexists(outdir+"/hello.txt");
	removeifexists(outdir);
}

# T2: a directory entry followed by a file inside it - exercises
# openfname()'s mkpdirs() fallback and nested-path handling.
t2nested()
{
	path := DIR + "/t2.tar";
	writebytes(path, catblocks(array[] of {
		mkustar("sub/", 0, 8r755),
		mkustar("sub/inner.txt", len "nested content\n", 8r644),
		mkdatablocks("nested content\n"),
		mkeoa(),
	}));
	outdir := DIR + "/t2out";
	mkdirp(outdir);
	sys->chdir(outdir);
	tarmod->run(list of {"xf", path});
	check("t2nested", readfile(outdir+"/sub/inner.txt"), "nested content\n");
	removeifexists(path);
	removeifexists(outdir+"/sub/inner.txt");
	removeifexists(outdir+"/sub");
	removeifexists(outdir);
}

# T3: table of contents (t, non-verbose) on a two-file archive.
t3toc()
{
	path := DIR + "/t3.tar";
	writebytes(path, catblocks(array[] of {
		mkustar("one.txt", len "1\n", 8r644), mkdatablocks("1\n"),
		mkustar("two.txt", len "22\n", 8r644), mkdatablocks("22\n"),
		mkeoa(),
	}));
	(out, nil) := tarmod->run(list of {"tf", path});
	check("t3toc", out, "one.txt\ntwo.txt\n");
	removeifexists(path);
}

# T4: our own create (c) piped into our own extract (x) - a real
# directory tree with a subdirectory, round-tripped through both
# halves of this translation together.
t4roundtrip()
{
	srcdir := DIR + "/t4src";
	mkdirp(srcdir);
	writefile(srcdir+"/a.txt", "alpha\n");
	mkdirp(srcdir+"/sub");
	writefile(srcdir+"/sub/b.txt", "beta content here\n");

	sys->chdir(DIR);
	tarmod->run(list of {"cf", "t4.tar", "t4src"});

	outdir := DIR + "/t4out";
	mkdirp(outdir);
	sys->chdir(outdir);
	tarmod->run(list of {"xf", DIR+"/t4.tar"});

	check("t4roundtrip-a", readfile(outdir+"/t4src/a.txt"), "alpha\n");
	check("t4roundtrip-b", readfile(outdir+"/t4src/sub/b.txt"), "beta content here\n");

	removeifexists(srcdir+"/a.txt");
	removeifexists(srcdir+"/sub/b.txt");
	removeifexists(srcdir+"/sub");
	removeifexists(srcdir);
	removeifexists(DIR+"/t4.tar");
	removeifexists(outdir+"/t4src/a.txt");
	removeifexists(outdir+"/t4src/sub/b.txt");
	removeifexists(outdir+"/t4src/sub");
	removeifexists(outdir+"/t4src");
	removeifexists(outdir);
}

# T5: a PAX extended header overriding path= ahead of a regular ustar
# header carrying a short placeholder name - parsepax()'s precedence
# over the plain name field.
t5pax()
{
	path := DIR + "/t5.tar";
	paxcontent := mkpaxrec("path=paxlongname.txt");
	writebytes(path, catblocks(array[] of {
		mkpaxhdrblk(paxcontent),
		mkdatablocksb(paxcontent),
		mkustar("shortname.txt", len "pax body\n", 8r644),
		mkdatablocks("pax body\n"),
		mkeoa(),
	}));
	outdir := DIR + "/t5out";
	mkdirp(outdir);
	sys->chdir(outdir);
	tarmod->run(list of {"xf", path});
	check("t5pax", readfile(outdir+"/paxlongname.txt"), "pax body\n");
	(sok, nil) := sys->stat(outdir+"/shortname.txt");
	checki("t5pax-noshortname", sok, -1);
	removeifexists(path);
	removeifexists(outdir+"/paxlongname.txt");
	removeifexists(outdir);
}

# T6: a GNU LF_LONGNAME record ahead of a regular ustar header - the
# other long-name mechanism, independent of PAX, going through
# getname() instead of parsepax().
t6gnulongname()
{
	longname := "gnulong_" + repeatstr("x", 110) + ".txt";
	nameterm := nulterm(longname);
	buf := catblocks(array[] of {
		mkgnulongnameblk(nameterm),
		mkdatablocksb(nameterm),
		mkustar("SHORT", len "gnu body\n", 8r644),
		mkdatablocks("gnu body\n"),
		mkeoa(),
	});
	path := DIR + "/t6.tar";
	writebytes(path, buf);
	outdir := DIR + "/t6out";
	mkdirp(outdir);
	sys->chdir(outdir);
	tarmod->run(list of {"xf", path});
	check("t6gnulongname", readfile(outdir+"/"+longname), "gnu body\n");
	removeifexists(path);
	removeifexists(outdir+"/"+longname);
	removeifexists(outdir);
}

# T7: a corrupted header checksum, resync (-s) NOT given - readhdrblk()
# must fail loudly rather than silently misreading garbage as a header.
t7badchecksum()
{
	path := DIR + "/t7.tar";
	b := mkustar("bad.txt", len "x\n", 8r644);
	b[148] = byte '9';
	writebytes(path, catblocks(array[] of {b, mkdatablocks("x\n"), mkeoa()}));
	checkfail("t7badchecksum", list of {"tf", path});
	removeifexists(path);
}

# T8: the same corrupted header, resync (-s) given - readhdrblk() must
# skip block-by-block past the bad header and its data block and
# recover the next good one.
t8resync()
{
	path := DIR + "/t8.tar";
	bad := mkustar("bad.txt", len "x\n", 8r644);
	bad[148] = byte '9';
	good := mkustar("good.txt", len "y\n", 8r644);
	writebytes(path, catblocks(array[] of {
		bad, mkdatablocks("x\n"),
		good, mkdatablocks("y\n"),
		mkeoa(),
	}));
	(out, nil) := tarmod->run(list of {"stf", path});
	checki("t8resync", contains(out, "good.txt"), 1);
	removeifexists(path);
}

# T9: an archive named as if compressed (.tar.gz) but containing
# perfectly valid plain ustar bytes - extract() must refuse by suffix
# alone, matching the original's own unconditional-by-suffix check,
# just refusing instead of silently decompressing (no fork/exec to
# actually decompress with). See tar.b's own header comment.
t9compsuffix()
{
	path := DIR + "/t9.tar.gz";
	writebytes(path, catblocks(array[] of {
		mkustar("z.txt", len "z\n", 8r644), mkdatablocks("z\n"), mkeoa(),
	}));
	checkfail("t9compsuffix", list of {"xf", path});
	removeifexists(path);
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	tarmod = load Tar Tar->PATH;
	if(tarmod == nil){
		sys->fprint(stderr, "tartest: cannot load Tar\n");
		raise "fail:module";
	}

	mkdirp(DIR);

	npass = 0;
	nfail = 0;

	t1basicfile();
	t2nested();
	t3toc();
	t4roundtrip();
	t5pax();
	t6gnulongname();
	t7badchecksum();
	t8resync();
	t9compsuffix();

	removeifexists(DIR);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail)
		raise "fail:tartest";
}
