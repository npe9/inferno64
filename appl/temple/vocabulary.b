implement Vocabulary;

# TempleOS Apps/Vocabulary/VocabQuiz.HC — Tk stand-in
# GAP: No AutoComplete dictionary (ACDDefGet). Quiz uses /lib/temple/vocab.txt
# and asks which of 4 words matches the prompt word (identify), not definition choice.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "rand.m";
	rand: Rand;

include "tone.m";
	tone: Tone;

Vocabulary: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

VOCAB: con "/lib/temple/vocab.txt";

top: ref Toplevel;
words: array of string;
choices: array of string;
right := 0;
have_tone := 0;
score_ok := 0;
score_bad := 0;

cfg := array[] of {
	"frame .f",
	"label .f.gap -fg #884400 -text {GAP: no ACD definitions — identify the word}",
	"label .f.q -font /fonts/lucida/unicode.8.font -text {Word:}",
	"frame .f.b",
	"button .f.b.b0 -text {1:} -width 40 -command {send cmd 0}",
	"button .f.b.b1 -text {2:} -width 40 -command {send cmd 1}",
	"button .f.b.b2 -text {3:} -width 40 -command {send cmd 2}",
	"button .f.b.b3 -text {4:} -width 40 -command {send cmd 3}",
	"pack .f.b.b0 .f.b.b1 .f.b.b2 .f.b.b3 -side top -anchor w -pady 2",
	"label .f.s -text {score 0/0}",
	"label .f.h -text {1-4 select · n next · q quit}",
	"pack .f.gap .f.q .f.b .f.s .f.h -side top -anchor w -pady 2",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	bufio = load Bufio Bufio->PATH;
	rand = load Rand Rand->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(rand != nil)
		rand->init(sys->millisec());
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	if(loadvocab() < 0){
		sys->fprint(sys->fildes(2), "vocabulary: cannot read %s\n", VOCAB);
		raise "fail:vocab";
	}

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Vocabulary", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	nextq();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		case s {
		16r1b or 'q' or 'Q' =>
			exit;
		'n' or 'N' =>
			nextq();
		'1' to '4' =>
			answer(s - '1');
		}
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		answer(int c);
	}
}

loadvocab(): int
{
	if(bufio == nil)
		return -1;
	b := bufio->open(VOCAB, Bufio->OREAD);
	if(b == nil)
		return -1;
	wl: list of string;
	n := 0;
	while((s := b.gets('\n')) != nil){
		if(len s > 0 && s[len s - 1] == '\n')
			s = s[0:len s - 1];
		if(len s >= 2){
			wl = s :: wl;
			n++;
		}
	}
	words = array[n] of string;
	for(i := n-1; i >= 0; i--){
		words[i] = hd wl;
		wl = tl wl;
	}
	return n;
}

nextq()
{
	choices = array[4] of string;
	right = rn(4);
	for(i := 0; i < 4; i++)
		choices[i] = words[rn(len words)];
	# ensure unique-ish
	for(i = 0; i < 4; i++)
		for(j := i+1; j < 4; j++)
			while(choices[j] == choices[i])
				choices[j] = words[rn(len words)];
	w := choices[right];
	cmd(top, ".f.q configure -text {Which word is: "+w+"?}");
	for(i = 0; i < 4; i++)
		cmd(top, sys->sprint(".f.b.b%d configure -text {%d: %s}", i, i+1, choices[i]));
	cmd(top, sys->sprint(".f.s configure -text {score %d correct / %d wrong}", score_ok, score_bad));
	cmd(top, "update");
}

answer(i: int)
{
	if(i < 0 || i > 3)
		return;
	if(i == right){
		score_ok++;
		if(have_tone) tone->beep(600, 120);
		cmd(top, ".f.q configure -text {Correct}");
	}else{
		score_bad++;
		if(have_tone) tone->beep(200, 200);
		cmd(top, ".f.q configure -text {Incorrect — was "+choices[right]+"}");
	}
	cmd(top, sys->sprint(".f.s configure -text {score %d correct / %d wrong}", score_ok, score_bad));
	cmd(top, "update");
	sys->sleep(400);
	if(have_tone) tone->stop();
	nextq();
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "vocabulary tk: %s\n", e);
	return e;
}

rn(n: int): int
{
	if(n <= 0) return 0;
	if(rand == nil) return sys->millisec() % n;
	return rand->rand(n);
}
