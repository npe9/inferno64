implement Voicewmtest;

#
# What a real window announces when it takes the keyboard.
#
# tkofftest(1) checks the announcements by building toplevels with
# tk->toplevel and handing them an image of its own, which is what lets it
# read pixels back at all. That path never goes through wmclient(2), and
# two layers meeting is exactly where an announcement can go wrong: for a
# while a window entry said its name twice, once from wmclient writing the
# title itself and once from libtk, and nothing offscreen could have seen
# it. voice(3) drops an announcement identical to the last, so the two had
# to differ to be noticed - "Colors window" and then "Colors".
#
# This runs under wm(1), makes a real client window, and reads
# /dev/voice/history to see what the whole stack said. It is in
# runtests(1)'s graphical list for that reason.
#
# What it catches, checked by putting the bug back: two layers announcing
# the same thing in DIFFERENT words - it reports "named 2 times" and
# prints both. What it does not catch is two layers announcing the same
# words exactly, because queue() drops an announcement identical to the
# one before it, so that case is already harmless. That is a property of
# the device rather than a hole here, but it is worth knowing before
# trusting this to prove a layering question.
#

include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;

Voicewmtest: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

failed := 0;

bad(s: string)
{
	print("FAIL %s\n", s);
	failed++;
}

# every line of the history, newest first
history(): list of string
{
	fd := sys->open("/dev/voice/history", Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	b := array[8192] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n <= 0)
			break;
		s += string b[0:n];
	}
	l: list of string;
	for(t := sys->tokenize(s, "\n").t1; t != nil; t = tl t)
		l = hd t :: l;
	# tokenize reversed it, so this is newest-first again
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

count(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(ctxt == nil){
		print("FAIL voicewmtest: no window context; run it under wm\n");
		raise "fail:context";
	}
	tkclient->init();

	if(sys->bind("#V", "/dev", Sys->MAFTER) < 0){
		print("     no voice device; nothing checked\n");
		return;
	}
	cfd := sys->open("/dev/voice/ctl", Sys->OWRITE);
	if(cfd == nil || sys->fprint(cfd, "announce focus") < 0){
		print("     cannot set the announce level; nothing checked\n");
		return;
	}
	if(sys->open("/dev/voice/history", Sys->OREAD) == nil){
		print("     no /dev/voice/history; nothing checked\n");
		return;
	}

	before := count(history());

	title := "Voice Audit";
	(t, nil) := tkclient->toplevel(ctxt, "", title, Tkclient->Appl);
	tk->cmd(t, "label .l -text {a window with something in it}");
	tk->cmd(t, "pack .l");
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd" :: "ptr" :: nil);
	stop := chan of int;
	spawn tkclient->handler(t, stop);

	# the window manager hands the keyboard over asynchronously
	for(i := 0; i < 40 && count(history()) == before; i++)
		sys->sleep(100);

	all := history();
	fresh: list of string;
	n := count(all) - before;
	for(l := all; l != nil && n > 0; l = tl l){
		fresh = hd l :: fresh;
		n--;
	}

	named := 0;
	for(l = fresh; l != nil; l = tl l){
		print("     said %#q\n", hd l);
		if(has(hd l, title))
			named++;
	}

	if(named == 0)
		bad(sprint("taking the keyboard announced the window: %q never said",
			title));
	else if(named > 1)
		bad(sprint("the window was named %d times, not once", named));
	else
		print("ok   a window entry names the window exactly once\n");

	stop <-= 1;
	if(failed > 0)
		raise "fail:voicewmtest";
	print("voicewmtest: %d fail\n", failed);
}
