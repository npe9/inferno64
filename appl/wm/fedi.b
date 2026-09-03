implement Fedi;

# wm/fedi - a Fediverse browser for rio: Bluesky and Mastodon in one
# Tk window, over this tree's own TLS (https(2)/tls12(2)). All the
# fetching and decoding lives in bsky(1)/masto(1) - this loads their
# modules and displays the lines they return, so the GUI can never
# drift from what the commands themselves would print.
#
# Public views (an account's feed or profile on either network) need
# no credentials. Home timelines appear only when a credentials file
# was given (-b for Bluesky, -m for Mastodon - the same files bsky(1)
# and masto(1) take).
#
# -t resultfile runs the self-test instead: build the UI, fetch one
# real public view per network into the text widget, read the widget
# back, write PASS/FAIL to resultfile, and end the wm session (so
# an automated run can do `emu wm/wm wm/fedi -t /fedi.result` and
# read the file; emu carries no Dis exit status out, the same reason
# runtests(1) writes a result file).

include "sys.m";
	sys: Sys;
include "draw.m";
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "arg.m";

Fedi: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# the reuse surfaces bsky.b and masto.b export (a structural subset
# of each module's full interface, matched by name at load time)
Bskymod: module
{
	publicfeed: fn(actor: string, limit: int): (list of string, string);
	publicprofile: fn(actor: string): (list of string, string);
	hometimeline: fn(credfile: string, limit: int): (list of string, string);
};
Mastomod: module
{
	publicstatuses: fn(inst, acct: string, limit: int): (list of string, string);
	publicprofile: fn(inst, acct: string): (list of string, string);
	hometimeline: fn(credfile: string, limit: int): (list of string, string);
};

Quitter: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;
bsky: Bskymod;
masto: Mastomod;
bskycreds := "";
mastocreds := "";

DEFAULTINST: con "mastodon.social";

cfg := array[] of {
	"frame .f",
	"label .f.l -text {target:}",
	"entry .f.e -width 24w",
	"button .f.bf -text {Bsky feed} -command {send cmd bskyfeed}",
	"button .f.bp -text {Bsky profile} -command {send cmd bskyprof}",
	"button .f.mf -text {Masto feed} -command {send cmd mastofeed}",
	"button .f.mp -text {Masto profile} -command {send cmd mastoprof}",
	"pack .f.l .f.e .f.bf .f.bp .f.mf .f.mp -side left -padx 2",
	"label .s -text {enter a handle (bsky) or acct@instance (mastodon)} -anchor w",
	"frame .t",
	"scrollbar .t.scroll -command {.t.t yview}",
	"text .t.t -width 90w -height 24h -yscrollcommand {.t.scroll set} -wrap word",
	"pack .t.scroll -side left -fill y",
	"pack .t.t -fill both -expand 1",
	"pack .Wm_t -fill x",
	"pack .f -anchor w -fill x",
	"pack .s -anchor w -fill x",
	"pack .t -fill both -expand 1",
	"pack propagate . 0",
	"bind .f.e {<Key-\n>} {send cmd enter}",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	arg := load Arg Arg->PATH;
	if(tk == nil || tkclient == nil || arg == nil){
		sys->fprint(stderr, "fedi: cannot load support modules: %r\n");
		raise "fail:load";
	}
	bsky = load Bskymod "/dis/bsky.dis";
	masto = load Mastomod "/dis/masto.dis";
	if(bsky == nil || masto == nil){
		sys->fprint(stderr, "fedi: cannot load bsky/masto modules: %r\n");
		raise "fail:load";
	}
	tkclient->init();

	testfile := "";
	arg->init(argv);
	while((opt := arg->opt()) != 0){
		case opt {
		'b' =>	bskycreds = arg->earg();
		'm' =>	mastocreds = arg->earg();
		't' =>	testfile = arg->earg();
		* =>
			sys->fprint(stderr, "usage: wm/fedi [-b bskycreds] [-m mastocreds] [-t resultfile]\n");
			raise "fail:usage";
		}
	}

	if(ctxt == nil){
		sys->fprint(stderr, "fedi: no window context - run under wm(1)\n");
		raise "fail:no context";
	}
	sys->pctl(Sys->NEWPGRP, nil);

	(top, wmchan) := tkclient->toplevel(ctxt, "", "Fediverse", Tkclient->Appl);
	if(top == nil){
		sys->fprint(stderr, "fedi: cannot make window: %r\n");
		raise "fail:no window";
	}
	cmd := chan of string;
	tk->namechan(top, cmd, "cmd");
	for(c := 0; c < len cfg; c++)
		tk->cmd(top, cfg[c]);
	if(bskycreds != ""){
		tk->cmd(top, "button .f.bh -text {Bsky home} -command {send cmd bskyhome}");
		tk->cmd(top, "pack .f.bh -side left -padx 2");
	}
	if(mastocreds != ""){
		tk->cmd(top, "button .f.mh -text {Masto home} -command {send cmd mastohome}");
		tk->cmd(top, "pack .f.mh -side left -padx 2");
	}
	if((err := tk->cmd(top, "variable lasterror")) != nil){
		sys->fprint(stderr, "fedi: tk error: %s\n", err);
		raise "fail:tk";
	}
	tk->cmd(top, ".f.e insert 0 'bsky.app");
	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	if(testfile != ""){
		selftest(top, testfile);
		quitsession();
		return;
	}

	# fetches run in their own proc so the window keeps redrawing;
	# results come back on this channel
	results := chan of (string, list of string, string);
	busy := 0;

	for(;;) alt {
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-wmchan =>
		if(s == "exit")
			return;
		tkclient->wmctl(top, s);
	msg := <-cmd =>
		if(busy)
			break;
		target := tk->cmd(top, ".f.e get");
		kind := msg;
		if(kind == "enter"){
			# a bare handle reads as Bluesky; acct@instance as Mastodon
			kind = "bskyfeed";
			if(contains(target, "@"))
				kind = "mastofeed";
		}
		busy = 1;
		status(top, "fetching...");
		spawn fetchproc(kind, target, results);
	(title, lines, ferr) := <-results =>
		busy = 0;
		if(ferr != nil){
			status(top, "error: "+ferr);
			break;
		}
		showlines(top, title, lines);
		status(top, title);
	}
}

fetchproc(kind, target: string, results: chan of (string, list of string, string))
{
	lines: list of string;
	err: string;
	title := kind;
	case kind {
	"bskyfeed" =>
		if(target == "")
			target = "bsky.app";
		(lines, err) = bsky->publicfeed(target, 30);
		title = "bsky feed @"+target;
	"bskyprof" =>
		if(target == "")
			target = "bsky.app";
		(lines, err) = bsky->publicprofile(target);
		title = "bsky profile @"+target;
	"mastofeed" =>
		(acct, inst) := mastotarget(target);
		(lines, err) = masto->publicstatuses(inst, acct, 30);
		title = sys->sprint("masto feed @%s@%s", acct, inst);
	"mastoprof" =>
		(acct, inst) := mastotarget(target);
		(lines, err) = masto->publicprofile(inst, acct);
		title = sys->sprint("masto profile @%s@%s", acct, inst);
	"bskyhome" =>
		(lines, err) = bsky->hometimeline(bskycreds, 30);
		title = "bsky home timeline";
	"mastohome" =>
		(lines, err) = masto->hometimeline(mastocreds, 30);
		title = "masto home timeline";
	* =>
		err = "unknown request "+kind;
	}
	results <-= (title, lines, err);
}

# "acct@instance" -> (acct, instance); a bare name is looked up on
# mastodon.social. The split is at the LAST @, so a leading @ or a
# webfinger-style user@domain both do the right thing.

mastotarget(target: string): (string, string)
{
	if(target != "" && target[0] == '@')
		target = target[1:];
	at := -1;
	for(i := 0; i < len target; i++)
		if(target[i] == '@')
			at = i;
	if(at < 0){
		if(target == "")
			target = "Mastodon";
		return (target, DEFAULTINST);
	}
	return (target[0:at], target[at+1:]);
}

showlines(top: ref Tk->Toplevel, title: string, lines: list of string)
{
	tk->cmd(top, ".t.t delete 1.0 end");
	tk->cmd(top, ".t.t insert end '== "+title+" ==\n");
	for(; lines != nil; lines = tl lines)
		tk->cmd(top, ".t.t insert end '"+hd lines+"\n");
	tk->cmd(top, "update");
}

status(top: ref Tk->Toplevel, s: string)
{
	tk->cmd(top, ".s configure -text '"+s);
	tk->cmd(top, "update");
}

# --- self-test (-t resultfile) ---
# one real public fetch per network, through the same fetch/show
# paths the buttons use, verified by reading the text WIDGET back -
# what the user would see, not just what the decoders returned.

selftest(top: ref Tk->Toplevel, resultfile: string)
{
	verdict := "PASS\n";

	(blines, berr) := bsky->publicfeed("bsky.app", 5);
	if(berr != nil)
		verdict = "FAIL: bsky publicfeed: "+berr+"\n";
	else{
		showlines(top, "bsky feed @bsky.app", blines);
		got := tk->cmd(top, ".t.t get 1.0 end");
		if(!contains(got, "== bsky feed @bsky.app ==") || !contains(got, "@bsky.app:"))
			verdict = "FAIL: bsky feed not in widget: "+got+"\n";
	}

	if(verdict == "PASS\n"){
		(mlines, merr) := masto->publicstatuses(DEFAULTINST, "Mastodon", 5);
		if(merr != nil)
			verdict = "FAIL: masto publicstatuses: "+merr+"\n";
		else{
			showlines(top, "masto feed @Mastodon", mlines);
			got := tk->cmd(top, ".t.t get 1.0 end");
			if(!contains(got, "== masto feed @Mastodon ==") || !contains(got, "@Mastodon"))
				verdict = "FAIL: masto feed not in widget: "+got+"\n";
		}
	}

	fd := sys->create(resultfile, Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%s", verdict);
	sys->print("%s", verdict);
}

# end the wm session, so an automated -t run can tell "finished" from
# "hung" (same reasoning and mechanism as wmtest(1)'s own)

quitsession()
{
	q := load Quitter "/dis/quitall.dis";
	if(q == nil){
		sys->fprint(stderr, "fedi: cannot load /dis/quitall.dis: %r\n");
		return;
	}
	q->init(nil, "quitall" :: nil);
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}
