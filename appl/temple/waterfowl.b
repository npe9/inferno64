implement Waterfowl;

# TempleOS Demo/Snd/WaterFowl.HC — Bryant's poem, a bird, and a song.
#
#	DrawIt: t=1.04-(0.35+0.65*Caw(tS-t0,20))`3;  s=1.0-0.5*t;
#	        x=w*t;  y=h*(0.35-.1*t);
#	        WHITE: GrPrint(dc, w>>1-(POEM_COLS*FONT_WIDTH)>>1,
#	                       Caw(tS-t0,POEM_TIME)*(h-3*FONT_HEIGHT), poem);
#	        BLACK: GrLine(dc,x,y,x-8*s,y+6*s*FullTri(tS,0.4));
#	               GrLine(dc,x,y,x+8*s,y+6*s*FullTri(tS,0.4));
#
# The whole bird is two lines from a point, and the wings flap because
# their far ends are driven by FullTri, the plus-and-minus triangle wave,
# on a period of 0.4 seconds.  The bird's distance is a cawtooth cubed —
# the backtick is TempleOS's power operator — so it comes in fast and
# drifts away slowly, and its size and height follow from that one number.
# The poem scrolls up on a second cawtooth of period POEM_TIME=65s.
#
# The song is Terry's own, three Play() strings looped.

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "math.m";
	math: Math;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "tone.m";
	tone: Tone;

Waterfowl: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

POEM_COLS: con 53;
POEM_TIME: con 65.0;
FW: con 8;
FH: con 8;

win: ref Window;
font: ref Font;
white, black, cyan: ref Image;
bird, birdmask: ref Image;
t0: int;
have_tone := 0;

poem := array[] of {
	"To a Waterfowl",
	"by William Cullen Bryant",
	"",
	"Whither, 'midst falling dew,",
	"While glow the heavens with the last steps of day,",
	"Far, through their rosy depths, dost thou pursue",
	"Thy solitary way?",
	"",
	"Vainly the fowler's eye",
	"Might mark thy distant flight to do thee wrong,",
	"As, darkly painted on the crimson sky,",
	"Thy figure floats along.",
	"",
	"Seek'st thou the plashy brink",
	"Of weedy lake, or marge of river wide,",
	"Or where the rocking billows rise and sink",
	"On the chafed ocean side?",
	"",
	"There is a Power whose care",
	"Teaches thy way along that pathless coast,--",
	"The desert and illimitable air,--",
	"Lone wandering, but not lost.",
	"",
	"All day thy wings have fann'd",
	"At that far height, the cold thin atmosphere:",
	"Yet stoop not, weary, to the welcome land,",
	"Though the dark night is near.",
	"",
	"And soon that toil shall end,",
	"Soon shalt thou find a summer home, and rest,",
	"And scream among thy fellows; reed shall bend",
	"Soon o'er thy sheltered nest.",
	"",
	"Thou'rt gone, the abyss of heaven",
	"Hath swallowed up thy form; yet, on my heart",
	"Deeply hath sunk the lesson thou hast given,",
	"And shall not soon depart.",
	"",
	"He, who, from zone to zone,",
	"Guides through the boundless sky thy certain flight,",
	"In the long way that I must tread alone,",
	"Will lead my steps aright.",};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS WaterFowl", Wmclient->Appl);
	d := win.display;
	font = Font.open(d, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(d, "/fonts/lucida/unicode.8.font");
	white = d.color(int 16rFFFFFFFF);
	black = d.color(int 16r000000FF);
	cyan = d.color(int 16r00AAAAFF);
	bird = d.open("/icons/temple/waterfowl_1.bit");
	birdmask = d.open("/icons/temple/waterfowl_1.mask");
	t0 = sys->millisec();

	win.reshape(Rect((0, 0), (640, 480)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	if(have_tone)
		spawn songtask();

	ticks := chan of int;
	spawn timer(ticks, 33);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	pointerev := <-win.ctxt.ptr =>
		# The titlebar is drawn by this window and only sees a click
		# if the program hands it one: without this arm the move,
		# resize and menu buttons on the window do nothing at all.
		win.pointer(*pointerev);
	k := <-win.ctxt.kbd =>
		if((k & Keyboard->Keyup) != Keyboard->Keyup){
			if(have_tone)
				tone->stop();
			exit;
		}
	<-ticks =>
		redraw();
	}
}

now(): real
{
	return real(sys->millisec() - t0) / 1000.0;
}

# Adam/ASnd.HC: Cawtooth, 1.0 down to 0.0
caw(t, period: real): real
{
	if(period == 0.0)
		return 1.0;
	if(t >= 0.0)
		return 1.0 - math->fmod(t, period)/period;
	return -math->fmod(t, period)/period;
}

# Plus&Minus Triangle: 0, 1, 0, -1, 0
fulltri(t, period: real): real
{
	if(period == 0.0)
		return 0.0;
	u := 4.0*math->fmod(t, period)/period;
	if(u <= -1.0){
		if(u <= -3.0)
			return u + 4.0;
		return -2.0 - u;
	}
	if(u <= 1.0)
		return u;
	if(u <= 3.0)
		return 2.0 - u;
	return u - 4.0;
}

redraw()
{
	img := win.image;
	if(img == nil || font == nil)
		return;
	o := img.r.min;
	w := img.r.dx();
	h := img.r.dy();
	tS := now();
	img.draw(img.r, cyan, nil, Point(0, 0));

	# the sprite the original prints once at the top
	if(bird != nil)
		img.draw(bird.r.addpt(Point(o.x + w/2 - bird.r.dx()/2, o.y + 4)),
			bird, birdmask, bird.r.min);

	# the poem, scrolling on a cawtooth of period POEM_TIME
	py := int(caw(tS, POEM_TIME) * real(h - 3*FH));
	px := w/2 - (POEM_COLS*FW)/2;
	for(i := 0; i < len poem; i++){
		y := o.y + py + i*FH;
		if(y > o.y - FH && y < img.r.max.y)
			img.text(Point(o.x + px, y), white, Point(0, 0), font, poem[i]);
	}

	# the bird: two lines from a point, flapping on FullTri
	t := 1.04 - pow3(0.35 + 0.65*caw(tS, 20.0));
	s := 1.0 - 0.5*t;
	x := real w * t;
	y := real h * (0.35 - 0.1*t);
	f := 6.0*s*fulltri(tS, 0.4);
	img.line(Point(o.x + int x, o.y + int y),
		Point(o.x + int(x - 8.0*s), o.y + int(y + f)),
		Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
	img.line(Point(o.x + int x, o.y + int y),
		Point(o.x + int(x + 8.0*s), o.y + int(y + f)),
		Draw->Endsquare, Draw->Endsquare, 0, black, Point(0, 0));
	img.flush(Draw->Flushnow);
}

# the original's backtick: x`3
pow3(x: real): real
{
	return x*x*x;
}

songtask()
{
	# "Song by Terry A. Davis", the three Play() strings looped
	for(;;){
		tone->play("5eEDC4B5C4B5C4BA5qReEDC4B5C");
		tone->play("4B5C4BA5qReFEDEDEDC4qB");
		tone->play("5ReFEDEDEDC4BqR");
	}
}

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
