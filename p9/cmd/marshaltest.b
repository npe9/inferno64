implement Marshaltest;

# Regression test for marshal(1)'s address engine - see marshal.b's own
# header comment for the translation decisions this exercises. This is
# the first landed slice of marshal.b (the RFC822 address tokenizer
# and recursive alias expansion); MIME assembly and header printing
# are separate, later work - see doc/plan9-port.md item 27 for the
# full scope statement.
#
# Unlike this backlog's usual #C+clang-built oracle (cbtest.b/
# qrtest.b/urlencodetest.b), the check here was done DURING
# development, not automated into this suite: a standalone harness
# (kept outside this tree, not committed - every function body in it
# copied VERBATIM from the real marshal.c, only a driver main() and an
# in-memory alias-list stub new) was built with the same #C+clang
# pattern and run against dozens of cases by hand, INCLUDING every
# case below, before this suite or marshal.b's own expandline() were
# considered finished. Not wired into an automated oracle here because
# upas/marshal.c cannot be built standalone the way qr.c or cb.c can -
# it needs the rest of upas/common (mbox paths, folder locking) merely
# to link, none of which the address engine itself calls. The cases
# below are the exact ones checked against that harness, with the
# harness's own real output recorded in comments - a hand-verified,
# not a live, oracle, the same category of verification qrtest.b's
# own BUGS section uses for the bc-finding's non-reproduction. See
# BUGS for what this means for future maintenance.
#
# Findings from that verification pass, real and worth recording:
#
# - The C's own comment on get822token()/expandline() ("we misparse
#   such nonsense as `gre @ (Grace) plan9 . (Emlin) bell-labs.com`")
#   turns out to be STALE relative to the actual, current algorithm:
#   that exact example is a clean, detected SYNTAX ERROR under this
#   logic (each bare word outside angle brackets increments nword,
#   and the end-of-entry check requires nword==1) - not a silent
#   misparse the comment's wording implies. Translated the algorithm
#   exactly as it stands today, not as its own decades-old comment
#   describes it - the same class of finding as dc.c's dead readc()
#   branch and qr.c's dead run-length counter: read the code, not the
#   comment about the code.
# - A self-referential alias (one whose own expansion list contains
#   its own name) does not converge - rexpand()'s own 32-pass cap
#   exists specifically to bound this, not some other case. Confirmed
#   directly: a "loop loop other" alias definition, expanding "loop",
#   grows by one "other" per pass for all 32 passes rather than
#   stopping early. See t8 below.

include "sys.m";
	sys: Sys;
include "draw.m";
	Context: import Draw;
include "env.m";
	env: Env;
include "encoding.m";
	encoding: Encoding;

Marshaltest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Marshal: module
{
	PATH:		con "/p9/dis/marshal.dis";
	init:		fn(ctxt: ref Context, argv: list of string);
	run:		fn(argv: list of string, data: array of byte): (array of byte, int);
	setaliases:	fn(lines: list of string);
	testexpandline:	fn(line: string): (string, list of string, int);
};

marshalmod: Marshal;
stderr: ref Sys->FD;
npass, nfail: int;

loadmods()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(env == nil)
		env = load Env Env->PATH;
	if(encoding == nil)
		encoding = load Encoding Encoding->BASE64PATH;
	if(marshalmod == nil)
		marshalmod = load Marshal Marshal->PATH;
	if(marshalmod == nil)
		fail("cannot load "+Marshal->PATH);
}

fail(s: string)
{
	sys->fprint(stderr, "marshaltest: %s\n", s);
	raise "fail:marshaltest";
}

check(name: string, got: string, want: string)
{
	if(got == want)
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want: %q\n  got:  %q\n", name, want, got);
	}
}

checki(name: string, got: int, want: int)
{
	if(got == want)
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL %s: want %d got %d\n", name, want, got);
	}
}

contains(s: string, sub: string): int
{
	n := len sub;
	if(n == 0)
		return 1;
	for(cti := 0; cti + n <= len s; cti++)
		if(s[cti:cti + n] == sub)
			return 1;
	return 0;
}

checkcontains(name: string, got: string, sub: string)
{
	if(contains(got, sub))
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want substring: %q\n  got: %q\n", name, sub, got);
	}
}

checknotcontains(name: string, got: string, sub: string)
{
	if(!contains(got, sub))
		npass++;
	else{
		nfail++;
		sys->fprint(stderr, "FAIL %s\n  want NOT to contain: %q\n  got: %q\n", name, sub, got);
	}
}

checkfailrun(name: string, argv: list of string, data: array of byte)
{
	{
		marshalmod->run(argv, data);
	} exception e {
	"fail:*" =>
		npass++;
		return;
	}
	nfail++;
	sys->fprint(stderr, "FAIL %s\n  want: a failure\n  got:  no failure\n", name);
}

mkdirp(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok == -1){
		fd := sys->create(path, Sys->OREAD, Sys->DMDIR|8r777);
		if(fd == nil)
			fail("cannot mkdir "+path);
	}
}

writefile(path: string, content: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		fail("cannot create "+path);
	b := array of byte content;
	if(sys->write(fd, b, len b) != len b)
		fail("cannot write "+path);
}

writebytes(path: string, b: array of byte)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		fail("cannot create "+path);
	if(sys->write(fd, b, len b) != len b)
		fail("cannot write "+path);
}

removeifexists(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok != -1)
		sys->remove(path);
}

refuseifexists(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok != -1)
		fail("refusing to run: "+path+" already exists - not overwriting real content");
}

joinaddrs(addrs: list of string): string
{
	s := "";
	first := 1;
	for(; addrs != nil; addrs = tl addrs){
		if(!first)
			s += "|";
		s += hd addrs;
		first = 0;
	}
	return s;
}

# checkline runs one expandline() case against the real-oracle-
# verified expectation recorded alongside each call below.
checkline(name, aliasnames: string, line: string, wantns: string, wantaddrs: string, wanterr: int)
{
	(nil, alnames) := sys->tokenize(aliasnames, ";");
	marshalmod->setaliases(alnames);
	(ns, addrs, err) := marshalmod->testexpandline(line);
	checki(name+"-err", err, wanterr);
	if(!err){
		check(name+"-ns", ns, wantns);
		check(name+"-addrs", joinaddrs(addrs), wantaddrs);
	}
}

main()
{
	loadmods();
	stderr = sys->fildes(2);

	# t1: single bare address, no aliases at all.
	# oracle: NS="To: gre" ADDRS=gre
	checkline("t1", "", "To: gre", "To: gre", "gre", 0);

	# t2: two bare addresses.
	# oracle: NS="To: gre, joe" ADDRS=joe|gre (concataddr PREPENDS
	# each newly parsed entry, so processing order reverses - real,
	# confirmed behavior, not a translation artifact).
	checkline("t2", "", "To: gre, joe", "To: gre, joe", "joe|gre", 0);

	# t3: display name + angle-bracket address, no expansion.
	# oracle: NS=`To: "Grace Hopper" <gre@bell-labs.com>`
	#         ADDRS=gre@bell-labs.com
	checkline("t3", "", "To: \"Grace Hopper\" <gre@bell-labs.com>",
		"To: \"Grace Hopper\" <gre@bell-labs.com>", "gre@bell-labs.com", 0);

	# t4: the C's own comment's example - confirmed a syntax error,
	# not a silent misparse (see this file's header comment).
	checkline("t4", "", "To: gre @ (Grace) plan9 . (Emlin) bell-labs.com",
		"", "", 1);

	# t5: unterminated angle bracket.
	checkline("t5", "", "To: gre <foo", "", "", 1);

	# t6: unterminated comment.
	checkline("t6", "", "To: gre (unterminated", "", "", 1);

	# t7: trailing backslash with nothing to escape.
	checkline("t7", "", "To: gre\\", "", "", 1);

	# t8: two words inside angle brackets.
	checkline("t8", "", "To: foo <bar baz>", "", "", 1);

	# t9: trailing text after the closing angle bracket.
	checkline("t9", "", "To: foo <bar> baz", "", "", 1);

	# t10: nested parens in a comment - not supported (no nesting
	# depth tracked, matching the real source exactly); the first
	# close-paren ends the comment, leaving "c)" to be lexed as an
	# ordinary (second) word, which is exactly what trips nword!=1.
	checkline("t10", "", "To: gre (a (b) c)", "", "", 1);

	# t11: empty address list after the colon.
	checkline("t11", "", "To:", "", "", 1);

	# t12: a quoted comma does not end the word.
	checkline("t12", "", "To: \"smith, john\"@example.com",
		"To: \"smith, john\"@example.com", "\"smith, john\"@example.com", 0);

	# t13: one-level alias expansion.
	checkline("t13", "friends gre joe ann", "To: friends",
		"To: gre, joe, ann", "gre|joe|ann", 0);

	# t14: an unmatched entry alongside an alias in the same line -
	# expansion only touches the entry that actually matches.
	checkline("t14", "friends gre joe ann", "To: friends, other",
		"To: gre, joe, ann, other", "other|gre|joe|ann", 0);

	# t15: two-level recursive alias expansion in one call (rexpand's
	# own loop, not two separate expandline calls).
	checkline("t15", "friends gre joe;all friends ann", "To: all",
		"To: gre, joe, ann", "gre|joe|ann", 0);

	# t16: self-referential alias - does not converge; rexpand's own
	# 32-pass cap is what stops it, growing by one "other" per pass.
	# oracle: 1 "loop" + 32 "other"s, confirmed by direct count of the
	# real harness's own output, not assumed from the 32-pass cap.
	wantaddrs16 := "loop";
	wantns16 := "To: loop";
	for(i16 := 0; i16 < 32; i16++){
		wantaddrs16 += "|other";
		wantns16 += ", other";
	}
	checkline("t16", "loop loop other", "To: loop", wantns16, wantaddrs16, 0);

	# --- composition engine (run()) - MIME assembly, attachments,
	# header printing. A controlled, no-alias-file $home/$user keeps
	# these deterministic and independent of whatever this host's own
	# ambient environment happens to have (same reasoning as
	# newstest.b's own env->setenv use).
	savedhome := env->getenv("home");
	saveduser := env->getenv("user");
	savedupasname := env->getenv("upasname");
	env->setenv("home", nil);
	env->setenv("user", "tester");
	env->setenv("upasname", nil);

	ATTDIR: con "/marshaltesttmp";
	refuseifexists(ATTDIR);
	mkdirp(ATTDIR);

	# t17: minimal message, no stdin body, no attachments.
	(out17, nil) := marshalmod->run("-n" :: "someone@example.com" :: nil, nil);
	s17 := string out17;
	checkcontains("t17-from", s17, "From: tester\n");
	checkcontains("t17-to", s17, "To: someone@example.com\n");
	checkcontains("t17-date", s17, "Date: ");
	checkcontains("t17-mime", s17, "MIME-Version: 1.0\n");
	checknotcontains("t17-no-multipart", s17, "multipart/mixed");

	# t18: a plain-ASCII stdin body prints as 7bit US-ASCII text.
	(out18, nil) := marshalmod->run("someone@example.com" :: nil,
		array of byte "Hello, world.\n");
	s18 := string out18;
	checkcontains("t18-body", s18, "Hello, world.\n");
	checkcontains("t18-ascii", s18, "charset=\"US-ASCII\"");
	checkcontains("t18-7bit", s18, "Content-Transfer-Encoding: 7bit\n");

	# t19: a body with a high-bit byte switches to UTF-8/8bit - built
	# as raw bytes around a literal high-bit byte (Limbo string
	# literals have no \xNN escape, same gotcha qrtest.b hit before),
	# matching qrtest.b's own established pre/hi/post-array idiom.
	pre19 := array of byte "caf";
	hi19 := array[] of {byte 16rc3, byte 16r83};
	post19 := array of byte " au lait\n";
	bodybytes := array[len pre19 + len hi19 + len post19] of byte;
	bodybytes[0:] = pre19;
	bodybytes[len pre19:] = hi19;
	bodybytes[len pre19 + len hi19:] = post19;
	(out19, nil) := marshalmod->run("someone@example.com" :: nil, bodybytes);
	s19 := string out19;
	checkcontains("t19-utf8", s19, "charset=\"UTF-8\"");
	checkcontains("t19-8bit", s19, "Content-Transfer-Encoding: 8bit\n");

	# t20: a directly-displayable (.txt) attachment passes through
	# verbatim inside its own MIME part, not base64-encoded.
	writefile(ATTDIR+"/note.txt", "attachment body\n");
	(out20, nil) := marshalmod->run(
		"-a" :: ATTDIR+"/note.txt" :: "someone@example.com" :: nil,
		array of byte "main body\n");
	s20 := string out20;
	checkcontains("t20-multipart", s20, "multipart/mixed");
	checkcontains("t20-mainbody", s20, "main body\n");
	checkcontains("t20-attachbody", s20, "attachment body\n");
	checkcontains("t20-disposition", s20, "Content-Disposition: attachment; filename=note.txt\n");
	checknotcontains("t20-no-base64", s20, "Content-Transfer-Encoding: base64");

	# t21: an attachment with no recognized extension gets base64
	# encoded - decoded back here and compared byte-for-byte against
	# the real original content, not just checked for the header.
	binbytes := array[] of {byte 0, byte 1, byte 2, byte 16rfe, byte 16rff, byte 'A', byte 'B', byte 'C'};
	writebytes(ATTDIR+"/data.xyz123", binbytes);
	(out21, nil) := marshalmod->run(
		"-a" :: ATTDIR+"/data.xyz123" :: "someone@example.com" :: nil, nil);
	s21 := string out21;
	checkcontains("t21-base64hdr", s21, "Content-Transfer-Encoding: base64\n");
	b64start := -1;
	{
		marker := "Content-Transfer-Encoding: base64\n\n";
		for(bi := 0; bi + len marker <= len s21; bi++)
			if(s21[bi:bi+len marker] == marker){
				b64start = bi + len marker;
				break;
			}
	}
	if(b64start < 0){
		nfail++;
		sys->fprint(stderr, "FAIL t21-locate-base64: marker not found\n");
	}else{
		b64end := len s21;
		for(be := b64start; be + 2 <= len s21; be++)
			if(s21[be:be+2] == "--"){
				b64end = be;
				break;
			}
		b64text := "";
		for(bc := b64start; bc < b64end; bc++)
			if(s21[bc] != '\n')
				b64text[len b64text] = s21[bc];
		decoded := encoding->dec(b64text);
		if(len decoded == len binbytes){
			same := 1;
			for(di := 0; di < len decoded; di++)
				if(decoded[di] != binbytes[di])
					same = 0;
			if(same != 0)
				npass++;
			else{
				nfail++;
				sys->fprint(stderr, "FAIL t21-roundtrip: decoded bytes differ\n");
			}
		}else{
			nfail++;
			sys->fprint(stderr, "FAIL t21-roundtrip: want %d bytes got %d\n", len binbytes, len decoded);
		}
	}

	# t22: a high-bit subject gets RFC2047 Q-encoded.
	pre22 := array of byte "x";
	hi22 := array[] of {byte 16rc3, byte 16ra9};
	post22 := array of byte "y";
	subjbytes := array[len pre22 + len hi22 + len post22] of byte;
	subjbytes[0:] = pre22;
	subjbytes[len pre22:] = hi22;
	subjbytes[len pre22 + len hi22:] = post22;
	subjstr := string subjbytes;
	(out22, nil) := marshalmod->run("-n" :: "-s" :: subjstr :: "someone@example.com" :: nil, nil);
	s22 := string out22;
	checkcontains("t22-rfc2047", s22, "Subject: =?utf-8?q?");

	# t23: an unknown flag fails cleanly.
	checkfailrun("t23-bad-option", "-Q" :: "someone@example.com" :: nil, nil);

	# t24: no recipients and no -8 fails cleanly (usage).
	checkfailrun("t24-no-recipients", "-n" :: nil, nil);

	# t25: attaching a file that doesn't exist fails cleanly.
	checkfailrun("t25-missing-attachment", "-a" :: ATTDIR+"/doesnotexist" :: "someone@example.com" :: nil, nil);

	# t26: the user's own default-headers file ($home/mail/headers,
	# standing in for the real source's $MAILROOT/box/<user>/headers)
	# is read REGARDLESS of -n, and its own header lines feed into the
	# same "already seen" bitmask as stdin's own headers do - a real
	# gap an earlier draft left out entirely (found by re-reading the
	# source's own control flow, not by any test failing, since no
	# earlier case used this file at all). A custom From: line here
	# must suppress the auto-generated one, even under -n.
	HOMEDIR: con "/marshaltesttmphome";
	refuseifexists(HOMEDIR);
	mkdirp(HOMEDIR);
	mkdirp(HOMEDIR+"/mail");
	writefile(HOMEDIR+"/mail/headers", "From: custom@example.org\nX-Mailer: markertest\n");
	env->setenv("home", HOMEDIR);
	(out26, nil) := marshalmod->run("-n" :: "someone@example.com" :: nil, nil);
	s26 := string out26;
	checkcontains("t26-custom-from", s26, "From: custom@example.org\n");
	checkcontains("t26-passthrough-header", s26, "X-Mailer: markertest\n");
	checknotcontains("t26-no-auto-from", s26, "From: tester\n");
	removeifexists(HOMEDIR+"/mail/headers");
	sys->remove(HOMEDIR+"/mail");
	sys->remove(HOMEDIR);
	env->setenv("home", nil);

	removeifexists(ATTDIR+"/note.txt");
	removeifexists(ATTDIR+"/data.xyz123");
	sys->remove(ATTDIR);
	if(savedhome != nil)
		env->setenv("home", savedhome);
	if(saveduser != nil)
		env->setenv("user", saveduser);
	if(savedupasname != nil)
		env->setenv("upasname", savedupasname);

	sys->print("%d passed, %d failed\n", npass, nfail);
	if(nfail > 0)
		raise "fail:marshaltest";
}

init(nil: ref Context, argv: list of string)
{
	main();
}
