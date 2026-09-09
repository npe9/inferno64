implement Vocabulary;

# TempleOS Apps/Vocabulary/VocabQuiz.HC
# Shows a word (RED, blinking); pick which of four numbered definitions
# matches it. After answering, the full dictionary entry of the quizzed
# word pops up (ACDPopUpDef), formatted like ACDDefsPut.
#
# Data: the original quizzed the AutoComplete dictionary
# (Adam/AutoComplete/ACDefs.DATA, from the public-domain 1913 Webster's).
# /lib/temple/vocab.dict is that file converted to UTF-8, same record
# structure: [marker byte][string][NUL], markers 1=word 2=definition
# 3=pronunciation 4=part of speech 5=extra. /lib/temple/vocab.ndx lists
# the byte offset of every entry that has at least one definition.

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

DICT: con "/lib/temple/vocab.dict";
NDX: con "/lib/temple/vocab.ndx";
MAXENT: con 32768;	# largest dictionary entry is 23749 bytes
TFONT: con "/fonts/lucida/unicode.8.font";

# record markers (TempleOS ACD_WORD_CHAR etc.)
Kword: con 1;
Kdef: con 2;
Kpron: con 3;
Kpos: con 4;
Kextra: con 5;

# TempleOS Snd(ona): freq = 440*2^((ona-49)/12)
SNDHI: con 988;	# Snd(74), correct
SNDLO: con 196;		# Snd(46), incorrect

Entry: adt {
	word: string;
	kind: array of int;
	text: array of string;
};

top: ref Toplevel;
gctxt: ref Context;
dictfd: ref Sys->FD;
offsets: array of int;
choices: array of ref Entry;
rightent: ref Entry;
right := 0;
have_tone := 0;
bkon := 1;

cfg := array[] of {
	"frame .f",
	"scrollbar .f.sb -command {.f.t yview}",
	"text .f.t -font " + TFONT + " -background #FFFFFF -foreground #000000 " +
		"-wrap word -width 608 -height 440 -yscrollcommand {.f.sb set}",
	"pack .f.sb -side right -fill y",
	"pack .f.t -side left -fill both -expand 1",
	"pack .f -fill both -expand 1",
	# TempleOS palette: RED AA0000, GREEN 00AA00, LTBLUE 5555FF,
	# LTGREEN 55FF55, LTRED FF5555
	".f.t tag configure bk -foreground #AA0000",	# $$BK,1$$ blinker toggles this
	".f.t tag configure red -foreground #AA0000",
	".f.t tag configure grn -foreground #00AA00",
	".f.t tag configure ltblue -foreground #5555FF",
	".f.t tag configure ltgreen -foreground #55FF55",
	".f.t tag configure ltred -foreground #FF5555",
	# $$LM,4$$ button / $$LM,7$$ definition margins, 8x8 cells
	".f.t tag configure dfmt -lmargin1 32 -lmargin2 56",
	# DolDoc $$BT-X,"n",LM="n"$$ buttons inject the digit when clicked
	".f.t tag bind ans0 <ButtonRelease-1> {send cmd 0}",
	".f.t tag bind ans1 <ButtonRelease-1> {send cmd 1}",
	".f.t tag bind ans2 <ButtonRelease-1> {send cmd 2}",
	".f.t tag bind ans3 <ButtonRelease-1> {send cmd 3}",
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
	gctxt = ctxt;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS Vocabulary", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);

	if(loaddict() < 0){
		# original: if(!FileFind(ACD_DEF_FILENAME))
		#	"Uncompressed dictionary not present.\n"
		ins(top, "Uncompressed dictionary not present.\n", nil);
		cmd(top, "update");
		tkclient->startinput(top, "kbd" :: "ptr" :: nil);
		tkclient->onscreen(top, nil);
		for(;;) alt{
		<-top.ctxt.kbd =>
			exit;
		s := <-top.ctxt.ptr =>
			tk->pointer(top, *s);
		s := <-top.ctxt.ctl or
		s = <-top.wreq or
		s = <-menubut =>
			tkclient->wmctl(top, s);
		<-cmdch =>
			;
		}
	}

	nextq();
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	# DolDoc $$BK,1$$ blink
	tick := chan of int;
	spawn blinker(tick);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		case s {
		16r1b or 'q' or 'Q' =>	# CH_ESC / CH_SHIFT_ESC
			exit;
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
	<-tick =>
		blinkstep();
	}
}

blinker(c: chan of int)
{
	for(;;){
		sys->sleep(250);
		c <-= 1;
	}
}

blinkstep()
{
	bkon ^= 1;
	if(bkon)
		cmd(top, ".f.t tag configure bk -foreground #AA0000");
	else
		cmd(top, ".f.t tag configure bk -foreground #FFFFFF");
	cmd(top, "update");
}

loaddict(): int
{
	if(bufio == nil)
		return -1;
	dictfd = sys->open(DICT, Sys->OREAD);
	if(dictfd == nil)
		return -1;
	b := bufio->open(NDX, Bufio->OREAD);
	if(b == nil)
		return -1;
	ol: list of int;
	n := 0;
	while((s := b.gets('\n')) != nil){
		if(len s > 0 && s[len s - 1] == '\n')
			s = s[0:len s - 1];
		if(len s > 0){
			ol = int s :: ol;
			n++;
		}
	}
	if(n < 4)
		return -1;
	offsets = array[n] of int;
	for(i := n-1; i >= 0; i--){
		offsets[i] = hd ol;
		ol = tl ol;
	}
	return n;
}

readentry(off: int): ref Entry
{
	if(dictfd == nil || off < 0)
		return nil;
	sys->seek(dictfd, big off, Sys->SEEKSTART);
	buf := array[MAXENT] of byte;
	n := sys->read(dictfd, buf, len buf);
	if(n < 3 || int buf[0] != Kword)
		return nil;
	kl: list of int;
	tl_: list of string;
	word := "";
	nrec := 0;
	p := 0;
	while(p < n){
		m := int buf[p];
		if(m == Kword && p > 0)
			break;		# next entry
		z := p + 1;
		while(z < n && buf[z] != byte 0)
			z++;
		if(z >= n)
			break;		# truncated tail record
		s := string buf[p+1:z];
		if(m == Kword)
			word = s;
		else{
			kl = m :: kl;
			tl_ = s :: tl_;
			nrec++;
		}
		p = z + 1;
	}
	if(word == "")
		return nil;
	e := ref Entry(word, array[nrec] of int, array[nrec] of string);
	for(i := nrec-1; i >= 0; i--){
		e.kind[i] = hd kl;
		e.text[i] = hd tl_;
		kl = tl kl;
		tl_ = tl tl_;
	}
	return e;
}

randentry(): ref Entry
{
	# RandVocabWord(): uniform pick from the word list
	for(t := 0; t < 20; t++){
		e := readentry(offsets[rn(len offsets)]);
		if(e != nil)
			return e;
	}
	return nil;
}

firstdef(e: ref Entry): string
{
	# ACDDefGet(word): first definition record
	if(e == nil)
		return "";
	for(i := 0; i < len e.kind; i++)
		if(e.kind[i] == Kdef)
			return e.text[i];
	return "";
}

nextq()
{
	# original: right_word=RandVocabWord; 4 random decoys;
	# words[RandU32&3]=right_word (duplicates among decoys possible)
	rightent = randentry();
	if(rightent == nil){
		ins(top, "Uncompressed dictionary not present.\n", nil);
		cmd(top, "update");
		return;
	}
	choices = array[4] of ref Entry;
	for(i := 0; i < 4; i++)
		choices[i] = randentry();
	right = rn(4);
	choices[right] = rightent;

	# "$$WW,1$$$$CM-LE,5$$$$RED$$$$BK,1$$%s$$BK,0$$:$$FG$$$$LM,4$$\n"
	ins(top, rightent.word, "bk");
	ins(top, ":\n", "red");
	for(i = 0; i < 4; i++){
		# "\n\n$$GREEN$$$$BT-X,"%d",LM="%d"$$$$FG$$$$LM,7$$%s\n$$LM,4$$"
		ins(top, "\n\n", nil);
		ins(top, sys->sprint("[%d]", i+1), "grn dfmt ans" + string i);
		ins(top, " " + firstdef(choices[i]) + "\n", "dfmt");
	}
	ins(top, "\n\nAnswer:", "ltblue");
	cmd(top, ".f.t see end");
	cmd(top, "update");
}

answer(i: int)
{
	if(i < 0 || i > 3)
		return;
	old := rightent;
	ins(top, "\n", nil);
	if(i == right){
		ins(top, "Correct\n", "ltgreen");
		if(have_tone) tone->snd(SNDHI);	# Snd(74)
	}else{
		ins(top, "Incorrect\n", "ltred");
		if(have_tone) tone->snd(SNDLO);	# Snd(46)
	}
	cmd(top, ".f.t see end");
	cmd(top, "update");
	sys->sleep(500);			# Sleep(500); Snd;
	if(have_tone) tone->stop();
	ins(top, "\n", nil);			# "$$LM,0$$\n"
	nextq();				# main loop prints next question...
	popupdef(old);				# ...under the ACDPopUpDef popup
}

# ACDPopUpDef(word): popup window with the full dictionary entry,
# formatted as ACDDefsPut does. ESC (or q/space/Enter) dismisses it.
popupdef(e: ref Entry)
{
	if(e == nil)
		return;
	(t, tc) := tkclient->toplevel(gctxt, "", "Definition", Tkclient->Popup);
	cmd(t, "frame .f");
	cmd(t, "scrollbar .f.sb -command {.f.t yview}");
	cmd(t, "text .f.t -font " + TFONT + " -background #FFFFFF -foreground #000000 " +
		"-wrap word -width 480 -height 320 -yscrollcommand {.f.sb set}");
	cmd(t, "pack .f.sb -side right -fill y");
	cmd(t, "pack .f.t -side left -fill both -expand 1");
	cmd(t, "pack .f -fill both -expand 1");
	cmd(t, ".f.t tag configure red -foreground #AA0000");
	cmd(t, ".f.t tag configure grn -foreground #00AA00");
	cmd(t, ".f.t tag configure ltgreen -foreground #55FF55");
	cmd(t, ".f.t tag configure ltblue -foreground #5555FF");

	# ACDDefsPut: "$$WW,1$$$$RED$$%s:$$FG$$\n\n" then each record
	ins(t, e.word + ":\n\n", "red");
	n := 0;
	for(i := 0; i < len e.kind; i++){
		case e.kind[i] {
		Kdef =>
			n++;
			ins(t, sys->sprint("(%d)", n), "grn");
			ins(t, " " + e.text[i] + "\n", nil);
		Kpron =>
			ins(t, e.text[i] + "\n", "ltgreen");
		Kpos =>
			ins(t, e.text[i] + "\n", nil);	# BLACK
		Kextra =>
			ins(t, e.text[i] + "\n", "ltblue");
		}
	}
	cmd(t, "update");
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd" :: "ptr" :: nil);

	for(;;) alt{
	c := <-t.ctxt.kbd =>
		case c {
		16r1b or 'q' or 'Q' or ' ' or '\n' =>
			return;
		}
	p := <-t.ctxt.ptr =>
		tk->pointer(t, *p);
	c := <-t.ctxt.ctl or
	c = <-t.wreq =>
		tkclient->wmctl(t, c);
	c := <-tc =>
		if(c == "exit")
			return;
		tkclient->wmctl(t, c);
	}
}

ins(t: ref Toplevel, s: string, tags: string)
{
	if(s == "")
		return;
	if(tags != nil)
		cmd(t, ".f.t insert end " + tk->quote(s) + " {" + tags + "}");
	else
		cmd(t, ".f.t insert end " + tk->quote(s));
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
