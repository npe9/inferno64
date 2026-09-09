implement Ohgreat;

# TempleOS Demo/Snd/OhGreat.HC — karaoke Play(): lyrics appear syllable by
# syllable as each note sounds, exactly as Adam/ASnd.HC's Play() prints them
# (verbatim, no separator added).  The song starts immediately and loops
# forever, as the original's `while (!ScanChar)`; any key stops and exits.
#
# Timing follows Play(): quarter = JIFFY_FREQ*note_len/tempo = 1000/2.5 =
# 400ms, sounded for stacatto_factor (0.9) of the duration then gated off
# for the rest.  Octave and duration persist ACROSS Play() calls, so the
# score is parsed once as a continuous stream.  Snd(ona) frequency is
# Ona2Freq: 440*2^((ona-60)/12) (ona 60 = A440; mid C = ona 51 = 261.6Hz).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "math.m";
	math: Math;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "tone.m";
	tone: Tone;

Ohgreat: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

top: ref Toplevel;
playing := 1;
have_tone := 0;

# scores from OhGreat.HC (music strings, verbatim)
scores := array[] of {
	"6hEqDC5B6CDhE",
	"5GqFEFhG6E",
	"6qDC5B6CDhE5G",
	"5qFEFhGB6qC",
	"6DhCeDC5hBG",
	"5qFEFhG6EqD",
	"6C5B6CDhE5G",
	"5qFEFhG6EqD",
	"6C5B6CDhE5G",
	"5qFEFhG6EqD",
	"6C5B6CDhE5G",
	"5qFEFhGB6qC",
	"6DhCeDC5hBG",
	"5qFEFhG",
};

# the \0-separated lyric syllables from OhGreat.HC, one per note, verbatim
syls := array[] of {
	array[] of {"God", "is", "a", "g", "od", "of", "love.\n"},
	array[] of {"", "", "", "", "", "He"},
	array[] of {"wat", "ches", "us", "from", "a", "bove.\n", ""},
	array[] of {"", "", "", "", "Our", "world"},
	array[] of {"is", "n't", "al", "ways", "nice.\n", ""},
	array[] of {"", "", "", "", "Be", "fore"},
	array[] of {"you", "gr", "ipe", "think", "twice.\n", ""},
	array[] of {"", "", "", "", "He", "wat"},
	array[] of {"ches", "us", "from", "a", "bove.\n", ""},
	array[] of {"", "", "", "", "He'll", "smack"},
	array[] of {"you", "with", "out", "a", "glove.\n", ""},
	array[] of {"", "", "", "", "Our", "world"},
	array[] of {"is", "n't", "al", "ways", "nice.\n", ""},
	array[0] of string,
};

Event: adt {
	freq:	int;	# Hz; 0 = rest
	on:	int;	# ms sounding (stacatto_factor of the duration)
	off:	int;	# ms gated off
	syl:	string;	# printed as the note starts ("" = nothing)
};

events: array of ref Event;

FN: con "/fonts/lucida/unicode.8.font";

cfg := array[] of {
	"frame .f",
	"text .f.t -width 48 -height 12 -state disabled -font " + FN +
		" -bg white -fg black",
	"pack .f.t -side top -fill both -expand 1",
	"pack .f -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(tone != nil){
		e := tone->init();
		if(e == nil)
			have_tone = 1;
		else
			sys->fprint(sys->fildes(2), "ohgreat: tone: %s\n", e);
	}else
		sys->fprint(sys->fildes(2), "ohgreat: cannot load tone: %r\n");
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();

	mkevents();

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "TempleOS OhGreat", 0);
	for(i := 0; i < len cfg; i++)
		cmd(top, cfg[i]);
	cmd(top, "update");
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	tkclient->onscreen(top, nil);

	lyricch := chan of string;
	spawn player(lyricch);	# the song starts at once, like the original

	for(;;) alt{
	s := <-top.ctxt.kbd =>
		tk->keyboard(top, s);
		# original: while (!ScanChar) — any key ends the song
		playing = 0;
		if(have_tone)
			tone->stop();
		exit;
	s := <-top.ctxt.ptr =>
		tk->pointer(top, *s);
	syl := <-lyricch =>
		cmd(top, ".f.t configure -state normal");
		cmd(top, ".f.t insert end '" + syl);
		cmd(top, ".f.t configure -state disabled");
		cmd(top, ".f.t see end");
		cmd(top, "update");
	s := <-top.ctxt.ctl or
	s = <-top.wreq or
	s = <-menubut =>
		if(s == "exit"){
			playing = 0;
			if(have_tone)
				tone->stop();
		}
		tkclient->wmctl(top, s);
	}
}

# Parse the 14 Play() calls as one continuous stream: octave and
# note_len live in CMusicGlbls and persist from call to call
# (MusicSettingsRst runs once: octave 4, note_len q, tempo 2.5).
mkevents()
{
	notemap := array[] of {0, 2, 3, 5, 7, 8, 10};	# A..G
	oct := 4;
	notelen := 1.0;		# quarter
	tempo := 2.5;		# quarter-notes per second
	stacatto := 0.9;

	evl: list of ref Event;
	nev := 0;
	for(p := 0; p < len scores; p++){
		sc := scores[p];
		wi := 0;	# lyric syllable index, advances per note
		i := 0;
		n := len sc;
		while(i < n){
			c := sc[i++];
			case c {
			'0' to '9' =>
				oct = c - '0';
			'w' =>
				notelen = 4.0;
			'h' =>
				notelen = 2.0;
			'q' =>
				notelen = 1.0;
			'e' =>
				notelen = 0.5;
			's' =>
				notelen = 0.25;
			't' =>
				notelen = 2.0 * notelen / 3.0;
			'.' =>
				notelen = 1.5 * notelen;
			'A' to 'G' =>
				note := notemap[c - 'A'];
				o := oct;
				if(i < n && sc[i] == 'b'){
					note--;
					if(note == 2)
						o--;
					i++;
				}else if(i < n && sc[i] == '#'){
					note++;
					if(note == 3)
						o++;
					i++;
				}
				ona: int;
				if(note < 3)
					ona = (o+1)*12 + note;	# Note2Ona
				else
					ona = o*12 + note;
				f := int (440.0 * math->pow(2.0, real (ona - 60) / 12.0));
				d := 1000.0 * notelen / tempo;
				on := int (d * stacatto);
				syl := "";
				if(wi < len syls[p])
					syl = syls[p][wi];
				wi++;
				evl = ref Event(f, on, int d - on, syl) :: evl;
				nev++;
			* =>
				# rests (note >= 7) would be Snd(0);
				# none occur in this song
				;
			}
		}
	}
	events = array[nev] of ref Event;
	for(; evl != nil; evl = tl evl)
		events[--nev] = hd evl;
}

# Sing forever, restarting the song each pass, until a key stops us.
# Absolute millisecond targets (as Play()'s SleepUntil) so timing
# does not drift; sleeps are sliced so a keypress stops us quickly.
player(lyricch: chan of string)
{
	t0 := sys->millisec();
	target := 0;
	for(;;){
		for(i := 0; i < len events && playing; i++){
			ev := events[i];
			if(ev.syl != "")
				sendsyl(lyricch, ev.syl);
			if(!playing)
				break;
			if(have_tone && ev.freq > 0)
				tone->beep(ev.freq, ev.on);
			target += ev.on;
			sleepuntil(t0 + target);
			target += ev.off;
			sleepuntil(t0 + target);
		}
		if(!playing)
			break;
	}
	if(have_tone)
		tone->stop();	# original: Snd; after the loop
}

sendsyl(lyricch: chan of string, syl: string)
{
	while(playing){
		alt{
		lyricch <-= syl =>
			return;
		* =>
			sys->sleep(5);
		}
	}
}

sleepuntil(t: int)
{
	while(playing){
		d := t - sys->millisec();
		if(d <= 0)
			return;
		if(d > 50)
			d = 50;
		sys->sleep(d);
	}
}

cmd(win: ref Toplevel, s: string): string
{
	return tk->cmd(win, s);
}
