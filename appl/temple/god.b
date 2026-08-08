implement God;

# TempleOS Adam/God suite — Tk UI
# HolySpirit entropy + GodWord + GodSong + GodBiblePassage
# GAP: DolDoc PopUpTimerOk / TSC latch → button + millisec/kbd entropy
# GAP: GodSong PopUpForm → fixed Normal complexity, octave 4

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

include "tone.m";
	tone: Tone;

God: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

VOCAB: con "/lib/temple/vocab.txt";
BIBLE: con "/lib/temple/Bible.TXT";
GOODBITS: con 12;
FIFOM: con 4096;

top: ref Toplevel;
words: array of string;
bits: array of int;
head := 0;
tail := 0;
nbits := 0;
have_tone := 0;

cfg := array[] of {
	"frame .f",
	"label .f.t -text {TempleOS Holy Spirit / GodBits}",
	"label .f.gap -fg #884400 -text {GAP: entropy from millisec+kbd, not TSC latch UI}",
	"frame .f.b",
	"button .f.b.ent -text {Add entropy} -command {send cmd ent}",
	"button .f.b.word -text {God Word} -command {send cmd word}",
	"button .f.b.song -text {God Song} -command {send cmd song}",
	"button .f.b.bible -text {Bible passage} -command {send cmd bible}",
	"pack .f.b.ent .f.b.word .f.b.song .f.b.bible -side left -padx 4",
	"label .f.bits -text {fifo bits: 0}",
	"text .f.out -width 72 -height 18 -state disabled",
	"pack .f.t .f.gap .f.b .f.bits .f.out -side top -anchor w -pady 3",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	bufio = load Bufio Bufio->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	bits = array[FIFOM] of int;
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(loadvocab() < 0)
		sys->fprint(sys->fildes(2), "god: vocab missing %s\n", VOCAB);

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS God", 0);
	cmdch := chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		godbitsins(GOODBITS, sys->millisec() ^ (s<<3));
		bitstatus();
		if(s == 16r1b || s == 'q' || s == 'Q')
			exit;
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		case c {
		"ent" =>
			godbitsins(GOODBITS, sys->millisec());
			bitstatus();
			puts("entropy inserted from timer\n");
		"word" =>
			godword();
		"song" =>
			godsong();
		"bible" =>
			godbible();
		}
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
		if(len s > 0 && s[len s-1] == '\n')
			s = s[0:len s-1];
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

godbitsins(nb, v: int)
{
	for(i := 0; i < nb; i++){
		if(nbits >= FIFOM){
			# drop oldest
			head = (head + 1) % FIFOM;
			nbits--;
		}
		bits[tail] = v & 1;
		tail = (tail + 1) % FIFOM;
		nbits++;
		v >>= 1;
	}
}

godbits(nb: int): int
{
	res := 0;
	for(i := 0; i < nb; i++){
		if(nbits == 0)
			godbitsins(GOODBITS, sys->millisec() ^ (i*9973));
		b := bits[head];
		head = (head + 1) % FIFOM;
		nbits--;
		res = (res<<1) | b;
	}
	bitstatus();
	return res;
}

bitstatus()
{
	cmd(top, sys->sprint(".f.bits configure -text {fifo bits: %d}", nbits));
	cmd(top, "update");
}

godword()
{
	if(words == nil || len words == 0){
		puts("(no vocab)\n");
		return;
	}
	w := words[godbits(17) % len words];
	puts(w + " ");
}

godsong()
{
	buf := "4";
	for(i := 0; i < 8; i++){
		dur := godbits(8) % 5;
		case dur {
		0 or 1 =>
			buf[len buf] = 'q';
			buf += note(godbits(4));
		2 =>
			buf[len buf] = 'e';
			buf += note(godbits(4));
			buf += note(godbits(4));
		* =>
			buf[len buf] = 's';
			buf += note(godbits(4));
			buf += note(godbits(4));
			buf += note(godbits(4));
			buf += note(godbits(4));
		}
	}
	puts("\nSong: "+buf+"\n");
	if(have_tone)
		spawn playscore(buf);
}

note(k: int): string
{
	if(k == 0)
		return "R";
	k = k / 2;
	notes := array[] of {"G", "A", "B", "C", "D", "E", "F", "G"};
	if(k < 0)
		k = 0;
	if(k >= len notes)
		k = len notes - 1;
	return notes[k];
}

playscore(s: string)
{
	tone->play(s);
}

godbible()
{
	b := bufio->open(BIBLE, Bufio->OREAD);
	if(b == nil){
		puts("cannot open Bible at "+BIBLE+"\n");
		return;
	}
	nlines := 0;
	while(b.gets('\n') != nil)
		nlines++;
	b.close();
	if(nlines < 30){
		puts("bible too short\n");
		return;
	}
	num := 20;
	start := godbits(21) % (nlines - (num - 1));
	if(start < 0)
		start = 0;
	b = bufio->open(BIBLE, Bufio->OREAD);
	puts(sys->sprint("\n--- Bible lines %d..%d ---\n", start+1, start+num));
	for(i := 0; i < start; i++)
		b.gets('\n');
	for(i = 0; i < num; i++){
		s := b.gets('\n');
		if(s == nil)
			break;
		puts(s);
	}
	puts("\n");
	b.close();
}

puts(s: string)
{
	cmd(top, ".f.out configure -state normal");
	cmd(top, ".f.out insert end {"+s+"}");
	cmd(top, ".f.out see end");
	cmd(top, ".f.out configure -state disabled");
	cmd(top, "update");
}

cmd(win: ref Toplevel, s: string): string
{
	e := tk->cmd(win, s);
	if(len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "god tk: %s\n", e);
	return e;
}
