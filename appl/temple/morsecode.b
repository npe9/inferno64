implement Morsecode;

# TempleOS Demo/Snd/MorseCode.HC — a straight key you tap.
#
#	#define M_DASH_THRESHOLD  0.140
#	#define M_SPACE_THRESHOLD 0.300
#	MorseWaitKey:
#	  if (m_start) { wait MSG_KEY_UP; m_end=tS; Snd;
#	                 dt_down=m_end-m_start; m_start=0; space_sent=FALSE;
#	                 return dt_down<M_DASH_THRESHOLD ? '.' : '-'; }
#	  else { while (!ScanMsg(&ch,,1<<MSG_KEY_DOWN)) {
#	           if (tS-m_end>=M_SPACE_THRESHOLD) { space_sent=TRUE;
#	                                              return CH_SPACE; } }
#	         m_start=tS; Snd(74);
#	         dt_up=m_start-m_end;
#	         if (!space_sent && dt_up>=M_SPACE_THRESHOLD) ... }
#
# The whole decoder is two numbers.  A key held under 140 milliseconds is
# a dot and longer is a dash; a gap of 300 milliseconds or more ends the
# letter.  Nothing is calibrated to your speed and nothing adapts — those
# two thresholds are the program.  The tone sounds while the key is down,
# at Snd(74), and stops on release, which is what a real straight key
# does.
#
# The table above it is the whole International Morse alphabet, letters,
# digits and punctuation, laid out in four columns of thirteen exactly as
# the original prints it.
#
# GAP: the original watches for MSG_KEY_UP.  Inferno delivers a release
#      as Keyup|k on the same channel, which is what this reads, but a
#      host that does not send key-up events at all would leave the key
#      stuck down; the space threshold still ends the letter.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "tone.m";
	tone: Tone;

Morsecode: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

M_DASH_THRESHOLD: con 0.140;
M_SPACE_THRESHOLD: con 0.300;
FW: con 8;
FH: con 8;

# morse_lst, verbatim: the character then its code
morse := array[] of {
	"A.-", "B-...", "C-.-.", "D-..", "E.", "F..-.", "G--.", "H....",
	"I..", "J.---", "K-.-", "L.-..", "M--", "N-.", "O---", "P.--.",
	"Q--.-", "R.-.", "S...", "T-", "U..-", "V...-", "W.--", "X-..-",
	"Y-.--", "Z--..",
	"1.----", "2..---", "3...--", "4....-", "5.....", "6-....",
	"7--...", "8---..", "9----.", "0-----",
	"/-..-.", "+.-.-.", "..-.-.-", ",--..--", "?..--..", "(-.--.",
	")-.--.-", "--....-", "\".-..-.", "_..--.-", "'.----.", ":---...",
	";-.-.-.", "=-...-",
};

win: ref Window;
font: ref Font;
white, black, red, green, blue: ref Image;
have_tone := 0;

down := 0;			# the key is held
mstart, mend: real;
dtdown, dtup: real;
spacesent := 1;
elem := "";			# dots and dashes of the letter in progress
text := "";			# what has been decoded

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS MorseCode", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	red = d.color(int 16rAA0000FF);
	green = d.color(int 16r00AA00FF);
	blue = d.color(int 16r0000AAFF);
	mend = now();

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 20);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		redraw();
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) == Keyboard->Keyup)
			keyup();
		else
			keydown(k & 16r7FF);
		redraw();
	<-ticks =>
		# the gap that ends a letter is a timeout, not an event
		if(!down && !spacesent && now() - mend >= M_SPACE_THRESHOLD){
			spacesent = 1;
			endletter();
			redraw();
		}
	}
}

keydown(k: int)
{
	if(k == 16r1b || k == 'q' || k == 'Q'){
		if(have_tone)
			tone->stop();
		exit;
	}
	if(down)
		return;
	down = 1;
	mstart = now();
	dtup = mstart - mend;
	if(have_tone)
		tone->snd(ona2freq(74.0));	# Snd(74) while the key is down
}

keyup()
{
	if(!down)
		return;
	down = 0;
	mend = now();
	if(have_tone)
		tone->stop();			# Snd, no argument: silence
	dtdown = mend - mstart;
	spacesent = 0;
	if(dtdown < M_DASH_THRESHOLD)
		elem += ".";
	else
		elem += "-";
}

# the letter is finished; look it up
endletter()
{
	if(elem == ""){
		if(text != "" && text[len text - 1] != ' ')
			text += " ";
		return;
	}
	for(i := 0; i < len morse; i++)
		if(morse[i][1:] == elem){
			text[len text] = morse[i][0];
			elem = "";
			return;
		}
	text += "?";
	elem = "";
}

ona2freq(ona: real): int
{
	# Kernel/KMisc.HC Ona2Freq
	f := 440.0/32.0;
	n := ona;
	while(n >= 12.0){
		f *= 2.0;
		n -= 12.0;
	}
	while(n > 0.0){
		f *= 1.0594630943592953;
		n -= 1.0;
	}
	return int f;
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	img.draw(img.r, white, nil, Point(0, 0));

	# MorseTable: four columns of thirteen
	for(row := 0; row < 13; row++){
		x := o.x;
		for(col := 0; col < 4; col++){
			i := row + col*13;
			if(i < len morse){
				img.text(Point(x, o.y + row*(FH+2)), red, Point(0, 0),
					font, morse[i][0:1]);
				img.text(Point(x + 2*FW, o.y + row*(FH+2)), black,
					Point(0, 0), font,
					sys->sprint("%-7s", morse[i][1:]));
			}
			x += 11*FW;
		}
	}

	y := o.y + 14*(FH+2) + 8;
	# the tag the original attaches to the document
	img.text(Point(o.x, y), green, Point(0, 0), font,
		sys->sprint("Down:%10.6f Up:%10.6f", dtdown, dtup));
	y += FH + 6;
	st := "key up";
	if(down)
		st = "KEY DOWN";
	img.text(Point(o.x, y), blue, Point(0, 0), font,
		sys->sprint("%s   dot under %.3fs, dash over; %.3fs ends a letter",
			st, M_DASH_THRESHOLD, M_SPACE_THRESHOLD));
	y += FH + 6;
	img.text(Point(o.x, y), black, Point(0, 0), font, "sending: " + elem);
	y += FH + 6;
	img.text(Point(o.x, y), black, Point(0, 0), font, text);
	img.text(Point(o.x, img.r.max.y - font.height), blue, Point(0, 0), font,
		"tap any key to send; Esc or q exits");
	img.flush(Draw->Flushnow);
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
