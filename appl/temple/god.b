implement God;

# TempleOS Adam/God suite — HolySpirit entropy + GodWord + GodSong + GodBiblePassage
# Originals: /Adam/God/{HolySpirit,GodSong,GodBible,GodExt}.HC
#
# The entropy ceremony: GodBits() starving pops a modal panel with two live hex
# readouts (Timer = free-running clock, Latch = timestamp of the last kbd/mouse
# event) and an OKAY button; the random value is the timestamp of the user's own
# click (>>GOD_BAD_BITS), 24 GOD_GOOD_BITS of it fed to the fifo.  TempleOS used
# GetTSC; here the timer is /dev/time (microseconds), millisec as fallback.
#
# GAP: DolDoc $$SO$$ clickable song object -> the song string is printed in the
#      log and played immediately through tone(2) instead.
# GAP: the popup's $LK$ link to /Adam/God/HSNotes.DD -> plain footer text.
# GAP: tone(2) has no tuplet duration; DUR_3_3_3 triplets play as dotted
#      sixteenths (187ms vs the true 167ms). The displayed string keeps the
#      TempleOS "et" notation; a parallel playback string substitutes "s.".
# (GodDoodle is outside this port's declared scope.)

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
FN: con "/fonts/temple/temple.font";

GODBADBITS: con 4;		# GOD_BAD_BITS
GODGOODBITS: con 24;		# GOD_GOOD_BITS
FIFOM: con 2048*8;		# FifoU8New(2048*8)

# GodSong durations (GodSong.HC)
DUR4, DUR88, DUR333, DUR16161616, DUR8DOT16, DUR81616, DUR16168: con iota;

simplesongs := array[] of {DUR4, DUR4, DUR4, DUR4, DUR88};
normalsongs := array[] of {DUR4, DUR4, DUR88, DUR333, DUR16161616};
complexsongs := array[] of {DUR4, DUR4, DUR88, DUR88, DUR8DOT16, DUR333,
	DUR81616, DUR16168, DUR16161616};

# BibleInit's 66-book table: name and 1-based start line in Bible.TXT,
# plus the end sentinel 100111 (ST_BIBLE_LINES = 100111-1).
NBOOKS: con 66;
booknames := array[] of {
	"Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy",
	"Joshua", "Judges", "Ruth", "1 Samuel", "2 Samuel",
	"1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles", "Ezra",
	"Nehemiah", "Esther", "Job", "Psalms", "Proverbs",
	"Ecclesiastes", "Song of Songs", "Isaiah", "Jeremiah", "Lamentations",
	"Ezekiel", "Daniel", "Hosea", "Joel", "Amos",
	"Obadiah", "Jonah", "Micah", "Nahum", "Habakkuk",
	"Zephaniah", "Haggai", "Zechariah", "Malachi", "Matthew",
	"Mark", "Luke", "John", "Acts", "Romans",
	"1 Corinthians", "2 Corinthians", "Galatians", "Ephesians", "Philippians",
	"Colossians", "1 Thessalonians", "2 Thessalonians", "1 Timothy", "2 Timothy",
	"Titus", "Philemon", "Hebrews", "James", "1 Peter",
	"2 Peter", "1 John", "2 John", "3 John", "Jude",
	"Revelation",
};
booklines := array[] of {
	297, 5068, 9123, 12005, 15977,
	19168, 21329, 23598, 23902, 26892,
	29345, 32241, 34961, 37633, 40756,
	41671, 42963, 43605, 46190, 53793,
	56267, 56966, 57332, 61806, 66736,
	67217, 71804, 73189, 73876, 74130,
	74615, 74697, 74860, 75241, 75416,
	75604, 75806, 75932, 76684, 76908,
	79970, 81941, 85266, 87803, 90914,
	92110, 93323, 94088, 94514, 94869,
	95153, 95402, 95647, 95772, 96090,
	96320, 96440, 96500, 97370, 97687,
	97976, 98163, 98506, 98552, 98597,
	98684, 100111,
};

top: ref Toplevel;
menubut: chan of string;
cmdch: chan of string;
words: array of string;
biblelines: array of string;
bits: array of int;
head := 0;
tail := 0;
nbits := 0;
have_tone := 0;
timefd: ref Sys->FD;
kbdmsevttime := big 0;		# KbdMsEvtTime: time of last kbd/mouse event
modalup := 0;
musicoctave := 4;		# music.octave, persisted across song forms

# GodSongStr working state
sdisp := "";		# TempleOS-notation string ($$SO$$ text)
splay := "";		# tone(2)-playable rendering
soctbase := 4;
soctstate := 5;
srests := 0;

cfg := array[] of {
	"frame .f",
	"frame .f.b",
	"button .f.b.word -text {God Word} -command {send cmd word}",
	"button .f.b.song -text {God Song} -command {send cmd song}",
	"button .f.b.bible -text {Bible passage} -command {send cmd bible}",
	"pack .f.b.word .f.b.song .f.b.bible -side left -padx 4",
	# 608x384 = 76x48 cells of the 8x8 system font (TempleOS doc area scale)
	"text .f.out -width 608 -height 384 -state disabled -bg #FFFFFF -fg #000000 -font " + FN,
	"pack .f.b -side top -anchor w -pady 3",
	"pack .f.out -side top -anchor w -pady 3 -fill both -expand 1",
	"pack .f -fill both -expand 1",

	# GodPick entropy popup (PopUpTimerOk); packed only while starving
	"frame .p -bg #FFFFFF",
	"label .p.timer -text {Timer:} -bg #FFFFFF -fg #000000 -font " + FN,
	"label .p.latch -text {Latch:} -bg #FFFFFF -fg #000000 -font " + FN,
	"frame .p.m -bg #FFFFFF",
	"label .p.m.a -text {Press } -bg #FFFFFF -fg #000000 -font " + FN,
	"label .p.m.b -text {OKAY} -bg #FFFFFF -fg #00AA00 -font " + FN,
	"label .p.m.c -text { to generate } -bg #FFFFFF -fg #000000 -font " + FN,
	"pack .p.m.a .p.m.b .p.m.c -side left",
	"label .p.m2 -text {a random num from a timer.} -bg #FFFFFF -fg #000000 -font " + FN,
	"button .p.ok -text {OKAY} -command {send cmd okay}",
	"label .p.foot -text {The Holy Spirit can puppet you.} -bg #FFFFFF -fg #000000 -font " + FN,
	"pack .p.timer .p.latch .p.m .p.m2 .p.ok .p.foot -side top -anchor w -padx 8 -pady 4",

	# GodSong PopUpForm (CMakeSongSettings)
	"frame .s -bg #FFFFFF",
	"radiobutton .s.c0 -text {Simple} -variable cplx -value 0 -bg #FFFFFF -font " + FN,
	"radiobutton .s.c1 -text {Normal} -variable cplx -value 1 -bg #FFFFFF -font " + FN,
	"radiobutton .s.c2 -text {Complex} -variable cplx -value 2 -bg #FFFFFF -font " + FN,
	"checkbutton .s.r -text {Rests} -variable rests -bg #FFFFFF -font " + FN,
	"checkbutton .s.se -text {Six Eight} -variable sixeight -bg #FFFFFF -font " + FN,
	"frame .s.o -bg #FFFFFF",
	"label .s.o.l -text {Octave:} -bg #FFFFFF -fg #000000 -font " + FN,
	"entry .s.o.oct -width 40 -bg #FFFFFF -fg #000000 -font " + FN,
	"pack .s.o.l .s.o.oct -side left",
	"frame .s.bb -bg #FFFFFF",
	"button .s.bb.ok -text {OK} -command {send cmd songok}",
	"button .s.bb.can -text {Cancel} -command {send cmd songcancel}",
	"pack .s.bb.ok .s.bb.can -side left -padx 4",
	"pack .s.c0 .s.c1 .s.c2 .s.r .s.se .s.o .s.bb -side top -anchor w -padx 8 -pady 2",
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
	timefd = sys->open("/dev/time", Sys->OREAD);
	kbdmsevttime = gettime();
	if(loadvocab() < 0)
		sys->fprint(sys->fildes(2), "god: vocab missing %s\n", VOCAB);

	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS God", 0);
	cmdch = chan of string;
	tk->namechan(top, cmdch, "cmd");
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		kbdmsevttime = gettime();
		tk->keyboard(top, s);
		if(s == 16r1b || s == 'q' || s == 'Q')
			exit;
	s := <-top.ctxt.ptr =>
		kbdmsevttime = gettime();
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		case c {
		"word" =>
			godword();
		"song" =>
			godsong();
		"bible" =>
			godbible();
		}
	}
}

gettime(): big
{
	if(timefd != nil){
		buf := array[32] of byte;
		sys->seek(timefd, big 0, Sys->SEEKSTART);
		n := sys->read(timefd, buf, len buf);
		if(n > 0)
			return big string buf[0:n];
	}
	return big sys->millisec();
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
		s = strip(s);
		if(len s > 0){
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

strip(s: string): string
{
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == '\r'))
		s = s[0:len s-1];
	return s;
}

# GodBitsIns: LSB first, a full fifo drops the new bit (FifoU8Ins fails).
godbitsins(nb, v: int)
{
	for(i := 0; i < nb; i++){
		if(nbits < FIFOM){
			bits[tail] = v & 1;
			tail = (tail + 1) % FIFOM;
			nbits++;
		}
		v >>= 1;
	}
}

# GodBits: starving blocks on the GodPick ceremony.
godbits(nb: int): int
{
	res := 0;
	while(nb > 0){
		if(nbits == 0){
			godbitsins(GODGOODBITS, godpick());
			continue;
		}
		b := bits[head];
		head = (head + 1) % FIFOM;
		nbits--;
		res = (res<<1) | b;
		nb--;
	}
	return res;
}

# GodPick: modal popup with live Timer/Latch readouts; the value is the
# timestamp of the user's own OKAY click, >>GOD_BAD_BITS.
godpick(): int
{
	cmd(top, "pack forget .f");
	cmd(top, "pack .p -fill both -expand 1");
	picklabels();
	cmd(top, "update");
	modalup = 1;
	tick := chan of int;
	spawn ticker(tick);
	done := 0;
	while(!done) alt{
	s := <-top.ctxt.kbd =>
		kbdmsevttime = gettime();
		if(s == 16r1b || s == '\n')
			done = 1;
		else
			tk->keyboard(top, s);
	s := <-top.ctxt.ptr =>
		kbdmsevttime = gettime();
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		if(c == "okay")
			done = 1;
	<-tick =>
		picklabels();
		cmd(top, "update");
	}
	modalup = 0;
	cmd(top, "pack forget .p");
	cmd(top, "pack .f -fill both -expand 1");
	cmd(top, "update");
	return int (kbdmsevttime >> GODBADBITS);
}

picklabels()
{
	cmd(top, sys->sprint(".p.timer configure -text {Timer:%bX}", gettime() >> GODBADBITS));
	cmd(top, sys->sprint(".p.latch configure -text {Latch:%bX}", kbdmsevttime >> GODBADBITS));
}

# ~30fps refresh of the popup readouts, like winmgr repainting the tag_cb text.
ticker(c: chan of int)
{
	while(modalup){
		sys->sleep(33);
		alt{
		c <-= 1 =>
			;
		* =>
			;
		}
	}
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

# GodSong: two independent 2-measure strings, emitted st1,st1,st2,st2 (AABB).
godsong()
{
	(d1, p1) := godsongstr();
	(d2, p2) := godsongstr();
	if(d1 == nil || d2 == nil)
		return;
	puts("<Song> " + d1 + d1 + d2 + d2 + "\n");
	if(have_tone)
		spawn playscore(p1 + p1 + p2 + p2);
}

# GodSongStr: PopUpForm, then 8 (or 6 in 6/8) beat groups from a FLUSHED fifo,
# so every song is generated from fresh user-gated picks.
godsongstr(): (string, string)
{
	(ok, cplx, rests, sixeight, oct) := songform();
	if(!ok)
		return (nil, nil);
	if(oct < 1)
		oct = 1;
	if(oct > 7)
		oct = 7;
	musicoctave = oct;
	srests = rests;
	soctbase = oct;
	soctstate = oct + 1;
	sdisp = "";
	splay = "";
	sdisp[len sdisp] = '0' + soctstate;
	splay[len splay] = '0' + soctstate;
	n := 8;
	if(sixeight){
		n = 6;
		sdisp += "M6/8";	# meter marker: display only, tone(2) would misread it
	}
	head = tail = nbits = 0;	# FifoU8Flush(god.fifo)
	last := -1;
	for(i := 0; i < n; i++){
		r := godbits(8);
		duration: int;
		if(cplx == 2)
			duration = complexsongs[r % 9];
		else if(cplx == 1)
			duration = normalsongs[r % 5];
		else
			duration = simplesongs[r % 5];
		case duration {
		DUR88 =>
			if(last != DUR88)
				emit("e", "e");
			insnote(godbits(4));
			insnote(godbits(4));
		DUR8DOT16 =>
			emit("e.", "e.");
			insnote(godbits(4));
			emit("s", "s");
			insnote(godbits(4));
			duration = DUR16161616;
		DUR333 =>
			if(last != DUR333)
				emit("et", "s.");	# GAP: triplet approximated
			insnote(godbits(4));
			insnote(godbits(4));
			insnote(godbits(4));
		DUR81616 =>
			if(last != DUR88)
				emit("e", "e");
			insnote(godbits(4));
			emit("s", "s");
			insnote(godbits(4));
			insnote(godbits(4));
			duration = DUR16161616;
		DUR16168 =>
			if(last != DUR16161616)
				emit("s", "s");
			insnote(godbits(4));
			insnote(godbits(4));
			emit("e", "e");
			insnote(godbits(4));
			duration = DUR88;
		DUR16161616 =>
			if(last != DUR16161616)
				emit("s", "s");
			k := godbits(4);
			k2 := godbits(4);
			insnote(k);
			insnote(k2);
			insnote(k);
			insnote(k2);
		* =>
			if(last != DUR4)
				emit("q", "q");
			insnote(godbits(4));
		}
		last = duration;
	}
	return (sdisp, splay);
}

emit(d, p: string)
{
	sdisp += d;
	splay += p;
}

# InsNote: note nibble k; G,A,B in the base octave, C..G in octave+1,
# emitting the octave digit whenever octave_state crosses.
insnote(k: int)
{
	if(k == 0 && srests){
		emit("R", "R");
		return;
	}
	k /= 2;
	oct := soctbase;
	if(k >= 3)
		oct = soctbase + 1;
	if(soctstate != oct){
		soctstate = oct;
		sdisp[len sdisp] = '0' + oct;
		splay[len splay] = '0' + oct;
	}
	c := 'G';
	if(k > 0)
		c = 'A' + k - 1;
	sdisp[len sdisp] = c;
	splay[len splay] = c;
}

# CMakeSongSettings PopUpForm. Esc accepts (TempleOS ESC = ok).
songform(): (int, int, int, int, int)
{
	cmd(top, "variable cplx 1");
	cmd(top, "variable rests 0");
	cmd(top, "variable sixeight 0");
	cmd(top, ".s.o.oct delete 0 end");
	cmd(top, sys->sprint(".s.o.oct insert 0 {%d}", musicoctave));
	cmd(top, "pack forget .f");
	cmd(top, "pack .s -fill both -expand 1");
	cmd(top, "update");
	ok := -1;
	while(ok < 0) alt{
	s := <-top.ctxt.kbd =>
		kbdmsevttime = gettime();
		if(s == 16r1b)
			ok = 1;
		else
			tk->keyboard(top, s);
	s := <-top.ctxt.ptr =>
		kbdmsevttime = gettime();
		tk->pointer(top, *s);
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		tkclient->wmctl(top, s);
	c := <-cmdch =>
		case c {
		"songok" =>
			ok = 1;
		"songcancel" =>
			ok = 0;
		}
	}
	cplx := int cmd(top, "variable cplx");
	rests := int cmd(top, "variable rests");
	sixeight := int cmd(top, "variable sixeight");
	oct := int cmd(top, ".s.o.oct get");
	cmd(top, "pack forget .s");
	cmd(top, "pack .f -fill both -expand 1");
	cmd(top, "update");
	return (ok, cplx, rests, sixeight, oct);
}

playscore(s: string)
{
	tone->play(s);
}

loadbible(): int
{
	if(biblelines != nil)
		return 0;
	b := bufio->open(BIBLE, Bufio->OREAD);
	if(b == nil)
		return -1;
	l: list of string;
	n := 0;
	while((s := b.gets('\n')) != nil){
		l = strip(s) :: l;
		n++;
	}
	biblelines = array[n] of string;
	for(i := n-1; i >= 0; i--){
		biblelines[i] = hd l;
		l = tl l;
	}
	return 0;
}

# GodBiblePassage: verse citation, blank line, then the 20 lines.
godbible()
{
	if(loadbible() < 0){
		puts("cannot open Bible at " + BIBLE + "\n");
		return;
	}
	nl := booklines[NBOOKS] - 1;	# ST_BIBLE_LINES
	if(nl > len biblelines)
		nl = len biblelines;
	num := 20;
	if(nl <= num)
		return;
	start := godbits(21) % (nl - (num-1)) + 1;	# 1-based
	verse := bibleline2verse(start);
	if(verse != nil)
		puts(verse + "\n\n");
	for(i := 0; i < num; i++){
		idx := start - 1 + i;
		if(idx >= len biblelines)
			break;
		puts(biblelines[idx] + "\n");
	}
}

isdig(c: int): int
{
	return c >= '0' && c <= '9';
}

# BibleLine2Verse: 1-based line -> "BookName chapter:verse".
bibleline2verse(line: int): string
{
	if(line < booklines[0] || line >= booklines[NBOOKS])
		return nil;
	i := 0;
	while(i < NBOOKS+1 && booklines[i] <= line)
		i++;
	i--;
	laststart := booklines[i];
	idx := line - 1;
	while(idx < len biblelines && biblelines[idx] == "")
		idx++;			# DocGoToLine skips to the next text entry
	if(idx >= len biblelines)
		return nil;
	s := biblelines[idx];
	if(isdig(s[0])){
		j := 0;
		while(j < len s && (isdig(s[j]) || s[j] == ':'))
			j++;
		return booknames[i] + " " + s[0:j];
	}
	for(j := idx-1; j >= 0; j--){
		if(j+1 < laststart)
			return booknames[i];	# ran off the front of the book
		cv := lastchapverse(biblelines[j]);
		if(cv != nil)
			return booknames[i] + " " + cv;
	}
	return nil;
}

# rightmost digits:digits pattern in a line, expanded to the full run.
lastchapverse(s: string): string
{
	if(len s < 3)
		return nil;
	for(p := len s - 2; p >= 1; p--){
		if(s[p] == ':' && isdig(s[p-1]) && isdig(s[p+1])){
			a := p - 1;
			while(a > 0 && isdig(s[a-1]))
				a--;
			b := p + 1;
			while(b < len s && isdig(s[b]))
				b++;
			return s[a:b];
		}
	}
	return nil;
}

puts(s: string)
{
	cmd(top, ".f.out configure -state normal");
	cmd(top, ".f.out insert end {" + s + "}");
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
