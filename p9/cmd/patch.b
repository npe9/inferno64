implement Patch;

# A structural Limbo translation of Plan 9's real patch(1) -
# sys/src/cmd/patch.c in the 9front tree, 839 lines: parses a unified
# diff and applies it to real files. See doc/plan9-port.md for the
# translation-not-workalike discipline this follows.
#
# THE ORACLE PROBLEM, and why this one is different from split.c's.
# Every prior translation in this backlog that hit a "can't verify
# against a live binary" wall either found a real 9front-vs-plan9port
# divergence (split.c - resolved by the user's explicit permission to
# use plan9port as the fallback reference) or turned out to have no
# usable oracle at all and was left untranslated (pr.c - blocked, see
# its own note in doc/plan9-port.md). patch.c looked at first like it
# might be the same story: this machine has no working plan9port
# `patch` binary (none is installed), and a 9front binary can't be
# built here (arm64 host, plan9port's own libraries are x86_64-only -
# same wall as split.c). Worse, plan9port DOES ship a file at
# src/cmd/scat/patch.c - but diffing it shows it is a *different
# program that happens to share a filename*: "scat" is a star-catalog
# tool, and that patch.c parses declination/right-ascension sky regions
# ("41253 square degrees in the sky"), nothing to do with text diffs.
# Anyone tempted to treat that file as a divergent oracle for this one
# would be comparing against astronomy code - noted here so that
# mistake doesn't get made twice.
#
# What actually unblocks this one: patch applies the *unified diff
# format*, which is specified independently of any Plan 9 binary. For
# pr.c, "correct" only ever meant "whatever the C's Nspace/Lcolpos/
# Pcolpos bookkeeping produces" - no external ground truth existed. For
# patch.c, the correct result of applying a given hunk to a given file
# is derivable by hand from the diff format itself - "@@ -3,2 +3,3 @@"
# with one added line, applied to a known 10-line file, has exactly one
# correct 11-line result, checkable without running anyone's binary.
# patchtest.b's cases are built that way: hand-constructed files and
# hunks with hand-derived expected output, not golden output copied
# from a reference implementation.
#
# String-vs-byte tradeoff, stated up front. This file reads patch
# headers and hunk bodies as Limbo strings via bufio's line-oriented
# gets(), matching every other translation in p9/cmd, rather than
# threading array of byte the whole way through the way the C's raw
# char* buffers do. Unified diffs are, in overwhelming practice, UTF-8
# or ASCII source text - the case this is built and tested for. A
# target file containing genuinely invalid UTF-8 (a binary file, or
# text in some other encoding) is NOT guaranteed to round-trip byte-
# exactly through this translation the way it would through the C's
# byte-transparent buffers; see BUGS.
#
# parse()'s control flow: the single hardest part of this file to get
# right, and the reason it was traced by hand before being trusted (per
# the advisor's explicit instruction). The C is a goto-based state
# machine with labels comment:/patch:/hunk:/out: - Limbo has no goto.
# The key realisation that makes a structured rewrite tractable: EVERY
# "goto comment" and "goto patch" in the C jumps to the exact same
# place - re-examine the CURRENT line as a candidate new file-section
# start, without reading a fresh one - so both collapse into one
# mechanism here: a `pending` line, checked at the top of the outer
# loop, set by any point that would have done `goto comment`/`goto
# patch`. "goto hunk" is different - it reuses the already-established
# old/new paths and only re-parses a hunk header - so it gets its own
# inner per-file loop that re-enters with a fresh line but keeps old/
# new. Three explicit flags (donefile/bodydone/alldone below) replace
# the goto targets; each loop only ever exits through its own flag,
# never assumes a bare break crosses a nesting level (it doesn't, in
# Limbo, same as C).
#
# A genuine bug found by that hand-trace, deliberately NOT reproduced:
# fileheader() returns "no match" both when a line doesn't have the
# expected prefix at all, AND when it has the prefix but no filename
# follows (just "--- " with nothing but whitespace after it). The
# comment-scanning loop's `goto comment` re-examines the SAME line
# every time it's reached - which is harmless for the first case (the
# re-examined line doesn't start with "--- ", so it's discarded and a
# fresh line is read) but is a genuine infinite loop for the second: a
# "--- "-prefixed line with an empty filename fails fileheader() the
# same way on every retry, forever. Reproducing that would mean this
# translation hangs the emu VM on a malformed patch, which is a strictly
# worse failure mode than the original's own (a real patch(1) run that
# never terminates is also a bug, just one nobody has apparently hit in
# practice with real diffs). parse() below detects this one specific
# case - a "--- "-prefixed line whose filename extraction still fails -
# and raises a hard parse error instead of re-looping. Every OTHER
# fileheader()/hunkheader() failure in the C's goto-comment paths is
# translated as-is (a genuine "discard, read a fresh line, no loop
# risk" case, confirmed by tracing each one - none of them re-derive
# the same input, they're all past that one prefix-specific line).
#
# Two dead checks in hunkheader(), verified unreachable and not
# translated: `if(e == s) return -1;` appears twice, comparing the
# CURRENT scan pointer `e` (already advanced well past the start of the
# "@@ -X,Y +A,B @@" text by the time either check runs) against `s`,
# the ORIGINAL start of the whole line - not the position saved before
# parsing newln, which is what the check almost certainly meant to
# compare against. strtol's endptr only ever advances from wherever
# it's given, never resets to the start of the string, so `e == s` can
# never be true at either point. Left out rather than translated as a
# no-op that would only obscure the real validation next to it.
#
# search()/searchln()'s fuzz algorithm - the part flagged as needing
# the most care, because its correctness only shows up across MULTIPLE
# hunks in one file, not from any single-hunk test. Fbuf.lastln/
# lastfuzz carry state from one successful match to the next: fuzz=0
# (the exact expected line) is tried before any offset, and within a
# given fuzz level, backward (oldln-fuzz) is tried before forward
# (oldln+fuzz+1) - so on a tie, the closer-then-earlier candidate wins,
# translated in that exact order. patchtest.b includes a two-hunk case
# specifically to exercise this: the first hunk matches at a shifted
# offset, and the second hunk's correct match position depends on
# lastfuzz/lastln having been updated by the first - a single-hunk test
# would never touch this code path at all.
#
# finish()'s rename step, and a real, preserved behaviour worth calling
# out plainly rather than leaving implicit: when a hunk's old and new
# paths differ (a patch that renames a file, e.g. `git diff -M` output)
# and both refer to real files (not /dev/null), the temp file holding
# the new content is written next to `new` and rename()'d onto it - but
# the OLD file at `old` is never removed. A rename-shaped patch here
# leaves the old file behind. This is the C's real, observable
# behaviour (confirmed by reading finish() line by line, not guessed),
# translated as-is rather than "fixed" to also delete `old`, since
# there is no oracle to confirm which behaviour real Plan 9 patch
# intends and the C's own code only ever removes `old` in the one case
# where old==new (an in-place edit, via a real rename-within-directory
# using fwstat with just .name set - see rename1() below). See BUGS.
#
# Reused rather than reimplemented: cleanname() from this tree's own
# module/names.m (Names->cleanname), not a hand-rolled path canon-
# icaliser - same "check for an existing mechanism first" discipline as
# regex(2) for split.b and Draw for iconv.b.
#
# apply()'s own C-side dead code: apply() always `return 0;` - it has
# no other return statement anywhere in its body - yet main() checks
# `if(apply(p,fname) == -1)` as though it could fail. That check can
# never be true; not translated (there is nothing to check).
#
# close(fd)'s own failure in finish()'s C is folded into a combined ||
# condition together with rename()/remove() failing - but Limbo's Sys
# module has no close() at all (file descriptors are closed by the
# garbage collector when the last ref FD is dropped), so that specific
# sub-check has no Limbo equivalent and is simply not there; the
# rename()/remove() failure checks it was combined with are translated
# individually instead.
#
# A surprising real behaviour, found while writing patchtest.b and
# initially mistaken for a translation bug before re-reading the C: any
# leading '/' characters in a header path are stripped UNCONDITIONALLY,
# even at the default -p0. fileheader()'s strip loop only runs `strip`
# times, but the `while(*s == '/') s++;` right after it is a separate
# statement, outside that loop, that always runs regardless of `strip`.
# So "--- /a/b/c" and "--- a/b/c" name the exact same (relative!) path
# once fileheader() is done with either of them - real Plan 9 patch
# never opens a header path as absolute, it always resolves against cwd
# (or -d). patchtest.b's own cases are written with this in mind: -d
# names the test directory, and header paths inside the patch text are
# bare filenames, not full paths - the realistic way this tool is
# actually invoked (cd to a tree root, patch < some.diff naming a/foo,
# b/foo).

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "names.m";
	names: Names;

Patch: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: applies the patch already sitting in the
	# real file patchpath against whatever real files its own "--- "/
	# "+++ " headers name (patch has no separate "target file"
	# argument - the paths are IN the patch text, same as the real
	# binary). opts carries flags only. Returns the captured stdout
	# (one changed-filename per line, same as the real binary) and the
	# ok/failed status finish() produced (1 == success, matching the
	# exit code the C's main() would report via exits()).
	run:	fn(opts: list of string, patchpath: string): (string, int);
};

stdin, stderr: ref FD;
capturing:	int;
outbuf:		string;

emit(s: string)
{
	if(capturing)
		outbuf += s;
	else
		sys->print("%s", s);
}

fail(msg: string)
{
	# the C's fail() calls finish(0) before ever printing/exiting,
	# unconditionally - every hard-failure path (a malformed patch, a
	# hunk that can't be found with no -r, blat()'s own I/O errors)
	# goes through this same helper, so this is the one place that
	# needs to clean up any .tmp files already written by an earlier,
	# successful part of the same apply() before unwinding. Tested
	# directly (patchtest.b's reject/cleanup case) rather than assumed,
	# per the advisor's flagged risk on finish()'s !ok path.
	finish(0);
	sys->fprint(stderr, "patch: %s\n", msg);
	raise "fail:patch";
}

usage()
{
	fail("usage: patch [-nR] [-d dir] [-p nstrip] [-r rejfile] [patch...]");
}

Hunk: adt
{
	lnum:		int;

	orig:		string;		# the hunk's own text, verbatim, for -r

	oldpath:	string;
	oldln:		int;
	oldcnt:		int;
	old:		string;		# context+deleted lines, marker stripped

	newpath:	string;
	newln:		int;
	newcnt:		int;
	new:		string;		# context+added lines, marker stripped
};

PatchFile: adt
{
	name:	string;
	hunk:	array of ref Hunk;	# sorted by (oldpath, oldln)
};

Fbuf: adt
{
	buf:		string;		# the whole slurped target file
	lines:		array of int;	# lines[i] = byte offset of line i's
					# start; lines[nlines] = len buf, a
					# sentinel past the last real entry
	nlines:		int;
	lastln:		int;		# search()/searchln() cross-hunk state
	lastfuzz:	int;
	mode:		int;		# Sys->Dir.mode, for re-creating with
					# the same permission bits
};

Fchg: adt
{
	tmp:	string;		# nil if dryrun, or new == "/dev/null"
	old:	string;
	new:	string;
};

strip:		int;
reverse:	int;
rejfd:		ref FD;		# nil == no -r given (C's rejfd == -1)
rejfile:	string;
workdir:	string;
dryrun:		int;
changed:	list of ref Fchg;	# consed in reverse; see revfchg()

resetstate()
{
	strip = 0;
	reverse = 0;
	rejfd = nil;
	rejfile = nil;
	workdir = nil;
	dryrun = 0;
	changed = nil;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

iswhite(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

prefix(s: string, p: string): int
{
	n := len p;
	return len s >= n && s[0:n] == p;
}

# atoi(3)'s leniency - see join.b/crc32.b for the same idiom repeated
# in this tree: leading optional sign, digits, stop silently at the
# first non-digit, 0 if none were seen at all.
catoi(s: string): int
{
	i := 0;
	n := len s;
	neg := 0;
	if(i < n && s[i] == '-'){
		neg = 1;
		i++;
	}
	v := 0;
	while(i < n && isdigit(s[i])){
		v = v*10 + (s[i]-'0');
		i++;
	}
	if(neg)
		v = -v;
	return v;
}

# strtol(e,&e,10)'s shape: an optional sign then digits, returning
# (value, indexPastWhatWasConsumed). If no digits were found at all,
# strtol leaves its endptr equal to what it was handed (not even past
# a lone sign) - startidx is returned unchanged in that case, matching
# that "no conversion performed" convention exactly.
strtolint(s: string, i: int): (int, int)
{
	n := len s;
	start := i;
	neg := 0;
	if(i < n && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	digstart := i;
	v := 0;
	while(i < n && isdigit(s[i])){
		v = v*10 + (s[i]-'0');
		i++;
	}
	if(i == digstart)
		return (0, start);
	if(neg)
		v = -v;
	return (v, i);
}

# fileheader: "--- path" / "+++ path", with -p's component-stripping.
# (name, ok) - ok==0 covers both "wrong prefix" and "prefix present but
# no filename follows" - see the header comment on why parse() must
# treat the second case specially only for the "--- " call.
fileheader(s: string, pfx: string): (string, int)
{
	if(!prefix(s, pfx))
		return (nil, 0);
	n := len s;
	i := len pfx;
	while(i < n && iswhite(s[i]))
		i++;
	e := i;
	while(e < n && !iswhite(s[e]))
		e++;
	if(i == e)
		return (nil, 0);
	name := s[i:e];
	if(name != "/dev/null"){
		nstrip := strip;
		si := i;
		while(si != e && nstrip > 0){
			while(si != e && s[si] == '/')
				si++;
			while(si != e && s[si] != '/')
				si++;
			nstrip--;
		}
		while(si < e && s[si] == '/')
			si++;
		if(si >= e)
			fail("too many components stripped");
		name = s[si:e];
	}
	return (name, 1);
}

# hunkheader: "@@ -oldln,oldcnt +newln,newcnt @@". (h, ok) - ok==0 means
# "doesn't look like a hunk header at all" (goto comment, safe - see
# header comment); a header that parses but has a negative count/line
# number is a hard failure in the C (sysfatal-class), translated as
# fail() here too, not a retry.
hunkheader(s: string, oldpath: string, newpath: string, lnum: int): (ref Hunk, int)
{
	if(oldpath == nil || len oldpath == 0 || newpath == nil || len newpath == 0)
		fail("empty path in patch");
	if(!prefix(s, "@@ -"))
		return (nil, 0);
	n := len s;
	(oldln, i) := strtolint(s, 4);
	oldcnt := 1;
	if(i < n && s[i] == ','){
		(oc, i2) := strtolint(s, i+1);
		oldcnt = oc;
		i = i2;
	}
	while(i < n && (s[i] == ' ' || s[i] == '\t'))
		i++;
	if(i >= n || s[i] != '+')
		return (nil, 0);
	i++;
	(newln, i3) := strtolint(s, i);
	i = i3;
	newcnt := 1;
	if(i < n && s[i] == ','){
		(nc, i4) := strtolint(s, i+1);
		newcnt = nc;
		i = i4;
	}
	if(i >= n || s[i] != ' ')
		return (nil, 0);
	if(!prefix(s[i:], " @@"))
		return (nil, 0);
	if(oldln > 0)
		oldln--;
	if(newln > 0)
		newln--;
	if(oldln < 0 || newln < 0 || oldcnt < 0 || newcnt < 0)
		fail("malformed hunk " + s);
	h := ref Hunk;
	h.lnum = lnum;
	h.oldpath = names->cleanname(oldpath);
	h.newpath = names->cleanname(newpath);
	h.orig = "";
	h.old = "";
	h.new = "";
	h.oldln = oldln;
	h.oldcnt = oldcnt;
	h.newln = newln;
	h.newcnt = newcnt;
	return (h, 1);
}

trimhunk(c: int, h: ref Hunk)
{
	if((c == ' ' || c == '-') && len h.old > 0 && h.old[len h.old-1] == '\n'){
		h.oldcnt--;
		h.old = h.old[0:len h.old-1];
	}
	if((c == ' ' || c == '+') && len h.new > 0 && h.new[len h.new-1] == '\n'){
		h.newcnt--;
		h.new = h.new[0:len h.new-1];
	}
}

hunkcmp(a: ref Hunk, b: ref Hunk): int
{
	if(a.oldpath < b.oldpath)
		return -1;
	if(a.oldpath > b.oldpath)
		return 1;
	return a.oldln - b.oldln;
}

# parse(): see the header comment above for the whole design - this is
# a structured rewrite of the C's goto-based state machine, traced by
# hand against it rather than assumed correct from the shape alone.
parse(f: ref Iobuf, name: string): ref PatchFile
{
	lnum := 0;
	hunks: list of ref Hunk = nil;	# consed in reverse order
	nhunk := 0;
	old := "";
	new := "";
	pending: string = nil;

	for(;;){
		ln: string;
		if(pending != nil){
			ln = pending;
			pending = nil;
		} else {
			ln = f.gets('\n');
			if(ln == nil)
				break;			# true EOF -> out:
			lnum++;
		}
		if(!prefix(ln, "--- "))
			continue;			# comment: discard, read fresh

		(oldp, ok1) := fileheader(ln, "--- ");
		if(!ok1)
			# a genuine infinite loop in the C for this one specific
			# case - not reproduced, see header comment.
			fail(name + ": malformed --- header (no filename)");
		old = oldp;

		ln2 := f.gets('\n');
		if(ln2 == nil)
			break;
		lnum++;
		(newp, ok2) := fileheader(ln2, "+++ ");
		if(!ok2){
			pending = ln2;
			continue;
		}
		new = newp;

		ln3 := f.gets('\n');
		if(ln3 == nil)
			break;
		lnum++;
		if(!prefix(ln3, "@@ ")){
			pending = ln3;
			continue;
		}
		hln := ln3;

		alldone := 0;
		donefile := 0;
		while(!donefile){
			(h, hok) := hunkheader(hln, old, new, lnum);
			if(!hok){
				pending = hln;
				donefile = 1;
				break;
			}
			oldcnt := 0;
			newcnt := 0;
			bodydone := 0;
			while(!bodydone){
				bln := f.gets('\n');
				if(bln == nil){
					if(oldcnt != h.oldcnt)
						fail(sys->sprint("%s:%d: malformed hunk: mismatched -hunk size %d != %d", name, lnum, oldcnt, h.oldcnt));
					if(newcnt != h.newcnt)
						fail(sys->sprint("%s:%d: malformed hunk: mismatched +hunk size %d != %d", name, lnum, newcnt, h.newcnt));
					hunks = h :: hunks;
					nhunk++;
					alldone = 1;
					donefile = 1;
					break;
				}
				lnum++;
				c := bln[0];
				h.orig += bln;
				case c {
				'\\' =>
					if(prefix(bln, "\\ No newline"))
						trimhunk(c, h);
					# else: ignore unknown directives, as the C does
				'-' =>
					h.old += bln[1:];
					oldcnt++;
				'+' =>
					h.new += bln[1:];
					newcnt++;
				'\n' =>
					h.old += "\n";
					h.new += "\n";
					oldcnt++;
					newcnt++;
				' ' =>
					h.old += bln[1:];
					h.new += bln[1:];
					oldcnt++;
					newcnt++;
				* =>
					fail(sys->sprint("%s:%d: malformed hunk: leading junk", name, lnum));
				}
				if(oldcnt > h.oldcnt || newcnt > h.newcnt)
					fail(sys->sprint("%s:%d: malformed hunk: oversized hunk", name, lnum));
				if(oldcnt < h.oldcnt || newcnt < h.newcnt)
					continue;

				hunks = h :: hunks;
				nhunk++;
				nln := f.gets('\n');
				if(nln == nil){
					alldone = 1;
					donefile = 1;
					break;
				}
				lnum++;
				if(prefix(nln, "\\ No newline"))
					trimhunk(c, h);
				if(prefix(nln, "--- ")){
					pending = nln;
					donefile = 1;
					break;
				}
				if(prefix(nln, "@@ ")){
					hln = nln;
					break;		# re-loop the per-file while
							# with donefile still 0
				}
				pending = nln;
				donefile = 1;
				break;
			}
		}
		if(alldone)
			break;
	}

	if(nhunk == 0)
		fail(name + ": could not find start of patch");

	hunkarr := array[nhunk] of ref Hunk;
	i := 0;
	for(l := hunks; l != nil; l = tl l){
		hunkarr[nhunk-1-i] = hd l;
		i++;
	}
	if(reverse)
		for(rk := 0; rk < nhunk; rk++){
			hh := hunkarr[rk];
			ti := hh.oldln; hh.oldln = hh.newln; hh.newln = ti;
			ti = hh.oldcnt; hh.oldcnt = hh.newcnt; hh.newcnt = ti;
			ts := hh.oldpath; hh.oldpath = hh.newpath; hh.newpath = ts;
			ts = hh.old; hh.old = hh.new; hh.new = ts;
		}
	# insertion sort by (oldpath, oldln) - patch files hold a modest
	# hunk count, O(n^2) is fine; Limbo has no qsort for arbitrary ADTs.
	for(k := 1; k < nhunk; k++){
		key := hunkarr[k];
		j := k - 1;
		while(j >= 0 && hunkcmp(hunkarr[j], key) > 0){
			hunkarr[j+1] = hunkarr[j];
			j--;
		}
		hunkarr[j+1] = key;
	}

	p := ref PatchFile;
	p.name = name;
	p.hunk = hunkarr;
	return p;
}

lastslash(s: string): int
{
	i := -1;
	for(k := 0; k < len s; k++)
		if(s[k] == '/')
			i = k;
	return i;
}

# rename1: the C's rename(fd,name) - a wstat with only .name set, which
# is a rename WITHIN THE SAME DIRECTORY only (Sys->nulldir's other
# fields are all "don't change" sentinels). Renaming a temp file across
# directories this way is not possible - see BUGS.
rename1(fd: ref FD, name: string): int
{
	d := sys->nulldir;
	i := lastslash(name);
	if(i < 0)
		d.name = name;
	else
		d.name = name[i+1:];
	return sys->fwstat(fd, d);
}

# mkpath: create every parent directory of path (not path's own final
# component) that doesn't already exist. The C treats "the directory
# now exists" (even if it was another process that just created it) as
# success by string-matching its own error text for "exist" - translated
# here as "re-stat after a failed create; a directory that exists now
# is success regardless of why create() itself reported an error",
# same intent, more portable than matching an error string.
mkpath(path: string): int
{
	if(len path == 0)
		return 0;
	n := len path;
	i := 1;
	while(i < n){
		while(i < n && path[i] != '/')
			i++;
		if(i >= n)
			break;
		dir := path[0:i];
		(ok, nil) := sys->stat(dir);
		if(ok == -1){
			fd := sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
			if(fd == nil){
				(ok2, nil) := sys->stat(dir);
				if(ok2 == -1)
					return -1;
			}
		}
		i++;
	}
	return 0;
}

revfchg(l: list of ref Fchg): list of ref Fchg
{
	r: list of ref Fchg = nil;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# blat: write out one file's whole new content (already built up by
# apply() into o) to a same-directory .tmp<pid> sibling of `new`, or -
# for a dry run, or when new == "/dev/null" (deletion) - do no I/O at
# all beyond bookkeeping the change for finish() to report.
blat(old: string, new: string, o: string, mode: int)
{
	tmp: string = nil;
	if(old == "/dev/null" && !dryrun){
		(ok, nil) := sys->stat(new);
		if(ok != -1)
			fail("would clobber: " + new);
	}
	if(new != "/dev/null" && !dryrun){
		if(mkpath(new) == -1)
			fail(sys->sprint("mkpath %s: %r", new));
		tmp = sys->sprint("%s.tmp%d", new, sys->pctl(0, nil));
		fd := sys->create(tmp, Sys->OWRITE, mode|8r200);
		if(fd == nil)
			fail(sys->sprint("open %s: %r", tmp));
		ob := array of byte o;
		if(sys->write(fd, ob, len ob) != len ob)
			fail(sys->sprint("write %s: %r", tmp));
	}
	c := ref Fchg;
	c.tmp = tmp;
	c.old = old;
	c.new = new;
	changed = c :: changed;
}

# finish: rename every .tmp into place (or remove, for a deletion), or
# - if ok is already 0 (some earlier hunk failed with no -r to reject
# into) - clean up every .tmp written so far instead and leave the
# originals untouched. See header comment for the old!=new rename
# behaviour this preserves rather than "fixes".
finish(ok: int): int
{
	l := revfchg(changed);
	for(; l != nil; l = tl l){
		c := hd l;
		if(!ok){
			if(c.tmp != nil && sys->remove(c.tmp) == -1)
				sys->fprint(stderr, "remove %s: %r\n", c.tmp);
			continue;
		}
		doprint := 1;
		if(!dryrun){
			if(c.new == "/dev/null"){
				if(sys->remove(c.old) == -1){
					ok = 0;
					sys->fprint(stderr, "remove %s: %r\n", c.old);
					doprint = 0;
				}
			} else {
				fd := sys->open(c.tmp, Sys->ORDWR);
				if(fd == nil){
					ok = 0;
					sys->fprint(stderr, "open %s: %r\n", c.tmp);
					doprint = 0;
				} else {
					failed := 0;
					if(c.old == c.new && sys->remove(c.old) == -1)
						failed = 1;
					if(!failed && rename1(fd, c.new) == -1)
						failed = 1;
					if(failed){
						ok = 0;
						sys->fprint(stderr, "cleanup: %r\n");
					}
				}
			}
		}
		if(doprint){
			if(c.new == "/dev/null")
				emit(c.old + "\n");
			else
				emit(c.new + "\n");
		}
	}
	changed = nil;
	return ok;
}

slurp(path: string): (ref Fbuf, int)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, -1);
	(ok, d) := sys->fstat(fd);
	if(ok == -1)
		fail(sys->sprint("stat %s: %r", path));
	buf := array[Sys->ATOMICIO] of byte;
	all := "";
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n == 0)
			break;
		if(n < 0)
			fail(sys->sprint("read %s: %r", path));
		all += string buf[0:n];
	}

	# see header comment on non-UTF8 content: `all` above went through
	# a byte->string conversion, which can already have lost fidelity
	# for a binary target file before this point is even reached.

	lines := array[32] of int;
	nlines := 0;
	lines[nlines++] = 0;
	flen := len all;
	i := 0;
	while(i < flen){
		if(all[i] == '\n'){
			if(nlines >= len lines){
				nl := array[len lines*2] of int;
				nl[0:] = lines;
				lines = nl;
			}
			lines[nlines++] = i+1;
		}
		i++;
	}
	if(nlines >= len lines){
		nl := array[len lines+1] of int;
		nl[0:] = lines;
		lines = nl;
	}
	lines[nlines] = flen;		# sentinel, not counted in nlines

	f := ref Fbuf;
	f.buf = all;
	f.lines = lines;
	f.nlines = nlines;
	f.lastln = 0;
	f.lastfuzz = 0;
	f.mode = d.mode;
	return (f, 0);
}

# searchln: does hunk h's own "old" text (context+deletions) match the
# target file at line ln, byte for byte? On success, records lastln/
# lastfuzz for the NEXT hunk's search() to build on - this cross-hunk
# state is the whole point of the fuzz mechanism, see header comment.
searchln(f: ref Fbuf, h: ref Hunk, ln: int): int
{
	off := f.lines[ln];
	if(off + len h.old > len f.buf)
		return -1;
	if(f.buf[off:off+len h.old] != h.old)
		return -1;
	f.lastln = ln + h.oldcnt;
	f.lastfuzz = ln - h.oldln;
	return off;
}

# search: try the hunk's expected line first (adjusted by the fuzz
# carried from the last successful match), then alternate outward -
# backward before forward at each fuzz level - up to 250 lines either
# way, stopping early once both directions run out of room. Returns the
# byte offset of a match, or -1.
search(f: ref Fbuf, h: ref Hunk): int
{
	oldln := h.oldln + f.lastfuzz;
	if(oldln + h.oldcnt > f.nlines)
		oldln = f.nlines - h.oldcnt;
	scanning := oldln >= f.lastln;
	fuzz := 0;
	while(scanning && fuzz < 250){
		scanning = 0;
		ln := oldln - fuzz;
		if(ln >= f.lastln){
			scanning = 1;
			p := searchln(f, h, ln);
			if(p != -1)
				return p;
		}
		ln = oldln + fuzz + 1;
		if(ln + h.oldcnt <= f.nlines){
			scanning = 1;
			p := searchln(f, h, ln);
			if(p != -1)
				return p;
		}
		fuzz++;
	}
	return -1;
}

# rejected: record a hunk that couldn't be applied. Called unconditionally
# when a target file is entirely missing, even without -r (the C does
# the same - fprint(rejfd,...) with rejfd==-1 there just silently fails
# on Plan 9's write(); Limbo has no such "write to an invalid fd is a
# harmless no-op" convenience, a nil ref FD can't be written to at all -
# so the reject-file writes are explicitly skipped here when there is
# no reject file, to reproduce the same observable outcome (a stderr
# warning, the hunk silently dropped) without a runtime error).
rejected(h: ref Hunk, fname: string)
{
	sys->fprint(stderr, "%s:%d: skipping failed hunk %s:%d\n", fname, h.lnum, h.oldpath, h.oldln);
	if(rejfd == nil)
		return;
	sys->fprint(rejfd, "--- %s:%d \n", h.oldpath, h.oldln);
	sys->fprint(rejfd, "+++ %s:%d \n", h.newpath, h.newln);
	sys->fprint(rejfd, "@@ -%d,%d +%d,%d @@\n", h.oldln, h.oldcnt, h.newln, h.newcnt);
	ob := array of byte h.orig;
	sys->write(rejfd, ob, len ob);
}

# apply: walk the sorted hunks, grouping consecutive ones by target
# file (curfile), slurping each target once, splicing search()'s
# matched region out and h.new in, and blat()ing the whole rebuilt file
# when the group ends. A missing target file, or a hunk offset that
# can't be found, either raises (no -r) or is recorded via rejected()
# and skipped (-r) - matching the C precisely, including that a missing
# target retries (and re-fails) independently for EVERY hunk destined
# for it, not just the first, since curfile is only advanced past a
# group's start on success (see the C's own goto Next skipping that
# assignment - translated the same way here via `continue`).
apply(p: ref PatchFile, fname: string)
{
	o := "";
	n := 0;
	curfile: string = nil;
	f: ref Fbuf;
	prevh: ref Hunk;
	changed = nil;

	for(i := 0; i < len p.hunk; i++){
		h := p.hunk[i];
		nextfile: string;
		if(h.newpath == "/dev/null")
			nextfile = h.oldpath;
		else
			nextfile = h.newpath;
		if(curfile == nil || curfile != nextfile){
			if(curfile != nil){
				if(!dryrun)
					o += f.buf[n:len f.buf];
				blat(prevh.oldpath, prevh.newpath, o, fmode(f));
				o = "";
			}
			if(!dryrun){
				(nf, ok) := slurp(h.oldpath);
				if(ok == -1){
					rejected(h, fname);
					prevh = h;
					continue;
				}
				f = nf;
				n = 0;
			}
			curfile = nextfile;
		}
		if(!dryrun){
			s := n;
			e := search(f, h);
			if(e == -1){
				if(rejfd == nil)
					fail(sys->sprint("%s:%d: unable to find hunk offset near %s:%d", fname, h.lnum, h.oldpath, h.oldln));
				rejected(h, fname);
				prevh = h;
				continue;
			}
			o += f.buf[s:e];
			o += h.new;
			n = e + len h.old;
		}
		prevh = h;
	}
	if(curfile != nil){
		if(!dryrun)
			o += f.buf[n:len f.buf];
		blat(prevh.oldpath, prevh.newpath, o, fmode(f));
	}
	# apply() in the C always returns 0 - main()'s "==-1" check on it
	# is dead code, not translated; see header comment.
}

# fmode: f is nil in dry-run mode (slurp() is never called - see the
# !dryrun guards above), but blat() is still called for its filename
# bookkeeping. The C reads the same field off an uninitialised stack
# Fbuf there - harmless garbage in C (dry run never uses the value for
# a real create() call either), but Fbuf here is a ref, and a nil ref's
# field is a hard fault in Limbo, not a harmless garbage read. This was
# caught by patchtest.b's -n case crashing outright, not reasoned out
# in advance - a real translation bug, not a preserved C quirk.
fmode(f: ref Fbuf): int
{
	if(f == nil)
		return 8r644;
	return f.mode;
}

# getarg: EARGF(3)'s convention as used by ARGBEGIN for -d/-r/-p, which
# (unlike join.b's -a/-e/-t) can also appear combined with other single-
# letter flags in the same word (e.g. "-np3"): the value is whatever of
# the CURRENT word remains after this option letter, if non-empty,
# else the entire next argv word.
getarg(w: string, k: int, rest: list of string): (string, list of string)
{
	if(k+1 < len w)
		return (w[k+1:], rest);
	if(rest == nil)
		fail("incomplete option -" + string w[k]);
	return (hd rest, tl rest);
}

# parseopts: ARGBEGIN/ARGEND's -d/-r/-p/-n/-R, including combined
# no-argument flags in one word (-nR) the way ARGBEGIN really supports,
# not just one flag per word. Any other option is a hard error (usage),
# unlike join's silent-ignore - matching the C's own `default: usage()`.
parseopts(args: list of string): list of string
{
	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		if(w == "--"){
			l = tl l;
			return l;
		}
		rest := tl l;
		k := 1;
		while(k < len w){
			c := w[k];
			consumed := 0;
			case c {
			'd' =>
				(v, r2) := getarg(w, k, rest);
				workdir = v;
				rest = r2;
				consumed = 1;
			'r' =>
				(v, r2) := getarg(w, k, rest);
				rejfile = v;
				rest = r2;
				consumed = 1;
			'p' =>
				(v, r2) := getarg(w, k, rest);
				strip = catoi(v);
				rest = r2;
				consumed = 1;
			'n' =>
				dryrun++;
			'R' =>
				reverse++;
			* =>
				usage();
			}
			if(consumed)
				break;
			k++;
		}
		l = rest;
	}
	return l;
}

# doone: parse one patch file/stream and apply it - main()'s per-file
# body, minus the loop that drives it (init()/run() do that, since they
# differ in how ok gates the NEXT file). Always starts finish() from 1,
# unlike the C's `ok = finish(ok)` which threads the RUNNING ok through
# - but init()'s own loop condition (ok != 0) already stops calling
# doone() again the moment one file's result is 0, exactly mirroring
# the C's `for(i = 0; ok && i < argc; i++)`, so finish() is never
# actually reached with an already-0 ok in either version: checked by
# tracing the loop, not assumed.
doone(pathorname: string, iob: ref Iobuf): int
{
	if(iob == nil)
		fail("open " + pathorname + ": cannot open");
	p := parse(iob, pathorname);
	if(workdir != nil && sys->chdir(workdir) == -1)
		fail("chdir " + workdir + ": cannot chdir");
	apply(p, pathorname);
	return finish(1);
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stdin = sys->fildes(0);
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	names = load Names Names->PATH;
	if(bufio == nil || names == nil){
		sys->fprint(stderr, "patch: cannot load a required module\n");
		raise "fail:module";
	}

	resetstate();
	files := parseopts(tl argv);

	if(rejfile != nil){
		rejfd = sys->create(rejfile, Sys->OWRITE, 8r644);
		if(rejfd == nil)
			fail("open " + rejfile + ": cannot create");
	}

	ok := 1;
	if(files == nil)
		ok = doone("stdin", bufio->fopen(stdin, Bufio->OREAD));
	else {
		for(; ok != 0 && files != nil; files = tl files)
			ok = doone(hd files, bufio->open(hd files, Bufio->OREAD));
	}
	if(!ok)
		raise "fail:patch";
}

run(opts: list of string, patchpath: string): (string, int)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(bufio == nil)
		bufio = load Bufio Bufio->PATH;
	if(names == nil)
		names = load Names Names->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);

	resetstate();
	parseopts(opts);
	if(rejfile != nil){
		rejfd = sys->create(rejfile, Sys->OWRITE, 8r644);
		if(rejfd == nil)
			fail("open " + rejfile + ": cannot create");
	}

	outbuf = "";
	capturing = 1;
	ok := doone(patchpath, bufio->open(patchpath, Bufio->OREAD));
	capturing = 0;
	return (outbuf, ok);
}
