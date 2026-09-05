implement Psalmody;

# TempleOS Apps/Psalmody — staff-notation music editor with JukeBox
#   (Psalmody.HC, PsalmodyMain.HC, PsalmodyDraw.HC, PsalmodyCtrls.HC,
#    PsalmodyFile.HC, JukeBox.HC) — Wmclient+Draw, temple font, tone(2).
# Sprites: /icons/temple/psalmodydraw_1..17 (durations 1-5, buttons 6-11,
#   clef/cursor 12, sharp 13, flat 14, dot 15, triplet 16, piano kbd 17).
# GAP: Shift-ESC abort is 'Q' (shift state not visible in the kbd stream);
#      shift-arrow selection extend unavailable — use the box tool instead
# GAP: GodSongStr settings form fixed at Normal complexity, no rests, 4/4
# GAP: Help.DD viewer replaced by an F1 key-summary overlay
# GAP: JukeBox reward words shown immediately and appended as // comments,
#      not embedded as a CallExtStr DocTree; ratings on the read-only
#      /lib/temple/psalmody examples are not persisted
# GAP: compressed .HC.Z songs unsupported (plain .HC only); graphics code
#      embedded in example songs is not executed (audio and words only)

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

include "math.m";
	math: Math;

include "rand.m";
	rand: Rand;

include "readdir.m";
	readdir: Readdir;

include "tone.m";
	tone: Tone;

Psalmody: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

GRW: con 640;
GRH: con 480;
FONTH: con 8;
FONTW: con 8;

# TempleOS 16-color palette (index = TempleOS color)
BLACK, BLUE, GREEN, CYAN, RED, PURPLE, BROWN, LTGRAY,
DKGRAY, LTBLUE, LTGREEN, LTCYAN, LTRED, LTPURPLE, YELLOW, WHITE: con iota;

NOTE_SPACING: con 9;
DURN: con 12;

# note types
NNOTE, NMETER: con 1+iota;
# flags
FSEL: con 1;
FSHARP: con 2;
FFLAT: con 4;
FTIE: con 8;

# tools
TPTR, TBOX: con iota;

# UI modes
MNORM, MMENU, MWORD, MJUKE, MREWARD, MHELP: con iota;

# drag modes
DNONE, DPITCH, DBOX, DNOTE, DMETER, DTEMPO: con iota;

# layout (all from the original)
NOTE_BOX_X: con 220;
NOTE_BOX_Y: con 13*FONTH+14;	# 118
TOOLS_X: con 450;
TOOLS_Y: con 13*FONTH;		# 104
METER_X: con 485;
METER_Y: con 13*FONTH;
METER_W: con 12;
METERSN: con 7;
TEMPO_SPACING: con 15;
TEMPO_RANGE: con 80;
TEMPO_BORDER: con 2;
TEMPO_LEFT: con 396;
TEMPO_TOP: con 96;
KBD_Y: con 13*FONTH;		# 104
HINT_Y: con 144;
BTN_Y: con 176;
ECHO_Y: con 208;
ECHOLINES: con 32;
ECHOW: con 78;

SHIFTSP: con 16r1F;		# TempleOS CH_SHIFT_SPACE word placeholder

Note: adt {
	ntype: int;
	flags: int;
	ona: int;		# 0 = rest
	mtop, mbot: int;
	dur: int;		# 0..11
	word: string;
	x, y, w: int;
};

win: ref Window;
disp: ref Display;
font: ref Font;
ink: array of ref Image;
spr, msk: array of ref Image;
have_tone := 0;

# song state
song := array[0] of ref Note;
clip := array[0] of ref Note;
cur := 0;			# 0..len song; len song = head sentinel
scrnx := 0;
headx := 8;
tool := TPTR;
octv := 4;			# psm_octave
curdur := 1.0;			# psm_duration (loader state)
recording := 0;
incomplete := 0;
tempo_sl := 36;			# Round(80*(2.5-0.5)/4.4)
stac_sl := 71;			# Round(80*(0.9-0.12)/0.88)
filename := "";
dirname := "";

# live-sound / record state
last_ona := 0;
was_null := 1;
evt_time := 0.0;
note_down_time := 0.0;
pend: ref Note;

# playback
playing := 0;
stopreq := 0;
playgen := 0;

# ui mode state
mode := MNORM;
menuitems: array of string;
menusel := 0;
wordbuf := "";
wordidx := -1;
helpfrom := MNORM;

# drag state
dragmode := DNONE;
dragidx := -1;
dragdur := 0;
dragtop := 4;
dragbot := 4;
dragx := 0;
dragy := 0;
boxx := 0;
boxy := 0;
prevbut := 0;
kbdheld := 0;
o_orig := 0;
n_orig := 0;

# echo area
elines: list of string;
ecur := "";

# jukebox
JEntry: adt {
	path: string;
	name: string;
	rating: int;
	color: int;
	writable: int;
};
jents := array[0] of ref JEntry;
jsel := 0;
rewardlines: list of string;

# god
vocab: array of string;

# music tables (Adam/ASnd.HC + PsalmodyDraw.HC)
durs := array[] of {
	2.0*0.25/3.0, 0.25, 2.0*0.5/3.0, 0.5, 2.0/3.0, 0.5*1.5,
	1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 1000000.0
};
durlst := array[] of { "st", "s", "et", "e", "qt", "e.", "q", "q.", "h", "h.", "w", "w." };
durimgs := array[] of { 1, 1, 2, 2, 3, 2, 3, 3, 4, 4, 5, 5 };
durtrip := array[] of { 1, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0 };
notelst := array[] of { "A", "A#", "B", "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#" };
note_map := array[] of { 0, 2, 3, 5, 7, 8, 10 };		# A..G -> chromatic
staff_map := array[] of { 6, 6, 5, 4, 4, 3, 3, 2, 1, 1, 0, 0 };	# psm_note_map
inverse_map := array[] of { 10, 8, 7, 5, 3, 2, 0 };		# psm_note_inverse_map
meter_tops := array[] of { 2, 3, 4, 5, 6, 7, 9 };
meter_bottoms := array[] of { 4, 4, 4, 4, 8, 8, 8 };

# on-screen piano (psm_kbd): x, w, h, ascii
kbx := array[] of { 28, 44, 60, 92, 108, 140, 156, 172,
	0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176 };
kbw := array[] of { 8, 8, 8, 8, 8, 8, 8, 8,
	16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16 };
kbh := array[] of { 20, 20, 20, 20, 20, 20, 20, 20,
	36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36, 36 };
kbch := array[] of { 'e', 'r', 't', 'u', 'i', 'p', '[', ']',
	'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '\n' };

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	math = load Math Math->PATH;
	rand = load Rand Rand->PATH;
	readdir = load Readdir Readdir->PATH;
	tone = load Tone Tone->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(tone != nil && tone->init() == nil)
		have_tone = 1;
	if(rand != nil)
		rand->init(sys->millisec());
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();

	if(argv != nil)
		argv = tl argv;
	if(argv != nil)
		dirname = hd argv;
	else
		dirname = "/usr/" + username() + "/Psalmody";

	win = wmclient->window(ctxt, "TempleOS Psalmody", Wmclient->Appl);
	disp = win.display;
	font = Font.open(disp, "/fonts/temple/temple.font");
	if(font == nil)
		font = Font.open(disp, "*default*");
	pal := array[] of {
		int 16r000000FF, int 16r0000AAFF, int 16r00AA00FF, int 16r00AAAAFF,
		int 16rAA0000FF, int 16rAA00AAFF, int 16rAA5500FF, int 16rAAAAAAFF,
		int 16r555555FF, int 16r5555FFFF, int 16r55FF55FF, int 16r55FFFFFF,
		int 16rFF5555FF, int 16rFF55FFFF, int 16rFFFF55FF, int 16rFFFFFFFF
	};
	ink = array[16] of ref Image;
	for(i := 0; i < 16; i++)
		ink[i] = disp.color(pal[i]);
	spr = array[18] of ref Image;
	msk = array[18] of ref Image;
	for(i = 1; i <= 17; i++){
		spr[i] = disp.open(sys->sprint("/icons/temple/psalmodydraw_%d.bit", i));
		msk[i] = disp.open(sys->sprint("/icons/temple/psalmodydraw_%d.mask", i));
	}
	loadvocab();
	mkmenu();

	win.reshape(Rect((0, 0), (GRW, GRH)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);

	ticks := chan of int;
	spawn timer(ticks, 33);		# winmgr.fps is ~30 in TempleOS
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	k := <-win.ctxt.kbd =>
		dokey(k);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		doptr(p);
	<-ticks =>
		redraw();
	}
}

username(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd != nil){
		buf := array[64] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0)
			return string buf[0:n];
	}
	return "inferno";
}

quit()
{
	stopsnd();
	if(have_tone)
		tone->stop();
	exit;
}

# --- sound -------------------------------------------------------------

# TempleOS Snd(ona): 88-key ona, freq = 440*2^((ona-60)/12), 0 = off
sndona(ona: int)
{
	if(!have_tone)
		return;
	if(ona <= 0)
		tone->snd(0);
	else
		tone->snd(int (440.0 * math->pow(2.0, real(ona-60)/12.0)));
}

stopsnd()
{
	stopreq = 1;
	playgen++;
	if(have_tone)
		tone->snd(0);
}

note2ona(note, oct: int): int
{
	if(note < 3)
		return (oct+1)*12 + note;
	return oct*12 + note;
}

ona2note(ona: int): int
{
	return ona % 12;
}

ona2octave(ona: int): int
{
	if(ona % 12 < 3)
		return ona/12 - 1;
	return ona/12;
}

curtempo(): real
{
	return 4.4 * real tempo_sl / real TEMPO_RANGE + 0.5;
}

curstac(): real
{
	return 0.88 * real stac_sl / real TEMPO_RANGE + 0.12;
}

# --- song list helpers -------------------------------------------------

insnote(i: int, nt: ref Note)
{
	ns := array[len song + 1] of ref Note;
	ns[0:] = song[0:i];
	ns[i] = nt;
	ns[i+1:] = song[i:];
	song = ns;
}

delnote(i: int)
{
	ns := array[len song - 1] of ref Note;
	ns[0:] = song[0:i];
	ns[i:] = song[i+1:];
	song = ns;
}

clone(n: ref Note): ref Note
{
	c := ref Note;
	*c = *n;
	return c;
}

setwidth(n: ref Note)
{
	if(n.ntype == NMETER){
		n.w = 12;
		return;
	}
	n.w = NOTE_SPACING;
	if(isdotted(n.dur))
		n.w += NOTE_SPACING/2;
	if(n.flags & (FSHARP|FFLAT))
		n.w += NOTE_SPACING;
}

isdotted(d: int): int
{
	return len durlst[d] > 1 && durlst[d][1] == '.';
}

haswords(w: string): int
{
	if(w == "")
		return 0;
	if(len w == 1 && (w[0] == ' ' || w[0] == SHIFTSP))
		return 0;
	return 1;
}

clearsong()
{
	song = array[0] of ref Note;
	cur = 0;
	scrnx = 0;
	filename = "";
	curdur = 1.0;
	octv = 4;
}

clearsel()
{
	for(i := 0; i < len song; i++)
		song[i].flags &= ~FSEL;
}

marksel(x1, x2: int)
{
	for(i := 0; i < len song; i++)
		if(x1 <= song[i].x && song[i].x <= x2)
			song[i].flags |= FSEL;
}

cutclip()
{
	cl: list of ref Note;
	i := 0;
	while(i < len song){
		if(song[i].flags & FSEL){
			song[i].flags &= ~FSEL;
			cl = song[i] :: cl;
			delnote(i);
			if(cur > i)
				cur--;
		}else
			i++;
	}
	nc := 0;
	for(l := cl; l != nil; l = tl l)
		nc++;
	clip = array[nc] of ref Note;
	for(l = cl; l != nil; l = tl l)
		clip[--nc] = hd l;
}

copyclip()
{
	cl: list of ref Note;
	for(i := 0; i < len song; i++)
		if(song[i].flags & FSEL){
			song[i].flags &= ~FSEL;
			cl = clone(song[i]) :: cl;
		}
	nc := 0;
	for(l := cl; l != nil; l = tl l)
		nc++;
	clip = array[nc] of ref Note;
	for(l = cl; l != nil; l = tl l)
		clip[--nc] = hd l;
}

pasteclip()
{
	for(j := 0; j < len clip; j++){
		insnote(cur, clone(clip[j]));
		cur++;
	}
}

# --- layout (PsmRecalcNoteXY) ------------------------------------------

notey(n: ref Note): int
{
	ona := n.ona;
	if(n.flags & FSHARP)
		ona--;
	if(n.flags & FFLAT)
		ona++;
	oct := ona2octave(ona);
	nt := ona2note(ona);
	nt = note_map[notelst[nt][0] - 'A'];
	if(nt < 3)
		oct++;
	return (15 + (staff_map[nt] - 7*(oct-4))) * 4;
}

recalcxy()
{
	measure_len := 4.0;
	measure_left := measure_len;
	x := 8 - scrnx;
	for(i := 0; i < len song; i++){
		n := song[i];
		n.x = x;
		n.y = 50;
		if(n.ntype != NMETER && n.ona != 0)
			n.y = notey(n);
		x += n.w;
		if(n.ntype == NMETER){
			measure_len = real n.mtop * 4.0 / real n.mbot;
			measure_left = 0.0;
		}else
			measure_left -= durs[n.dur];
		if(measure_left < 0.001){
			x += NOTE_SPACING;
			measure_left = measure_len;
		}
	}
	headx = x;
}

curx(): int
{
	if(cur < len song)
		return song[cur].x;
	return headx;
}

# PsmFindNote: returns index 0..len song (len song = head)
findnote(x: int): int
{
	recalcxy();
	xx := x + NOTE_SPACING/2;
	n := len song;
	if(n == 0)
		return 0;
	i := 0;
	for(;;){
		nx := headx;
		if(i+1 < n)
			nx = song[i+1].x;
		if(xx > nx && i < n)
			i++;
		else
			break;
	}
	return i;
}

# y -> ona (PsmLeftClickPickNoteBox / move_note math)
y2ona(y: int): int
{
	a2 := y/4 - 15;
	nn := a2 % 7;
	o := 4 + a2 / -7;
	if(nn < 0){
		nn += 7;
		o++;
	}
	nn = inverse_map[nn];
	if(nn < 3)
		o--;
	return note2ona(nn, o);
}

# --- key handling ------------------------------------------------------

pianooffset(c: int): int
{
	case c {
	'a' =>	return -8;
	's' =>	return -7;
	'e' =>	return -6;
	'd' =>	return -5;
	'r' =>	return -4;
	'f' =>	return -3;
	't' =>	return -2;
	'g' =>	return -1;
	'h' =>	return 0;
	'u' =>	return 1;
	'j' =>	return 2;
	'i' =>	return 3;
	'k' =>	return 4;
	'l' =>	return 5;
	'p' =>	return 6;
	';' =>	return 7;
	'[' =>	return 8;
	'\'' =>	return 9;
	']' =>	return 10;
	}
	return -99;
}

now(): real
{
	return real sys->millisec() / 1000.0;
}

# original main-loop tail: sound + record on every ona/null transition
onachange(ona, isnull: int)
{
	if(isnull)
		ona = 0;
	if(ona == last_ona && isnull == was_null)
		return;
	st := "";
	if(ona == 0){
		if(!isnull)
			st = "R";
	}else
		st = notelst[ona2note(ona)];
	sndona(ona);
	if(recording){
		if(!was_null && pend != nil){
			pend.dur = cvtdur(curtempo() * (evt_time - note_down_time));
			setwidth(pend);
			insnote(cur, pend);
			cur++;
			pend = nil;
		}
		if(!isnull){
			note_down_time = now();
			pend = ref Note(NNOTE, 0, ona, 0, 0, 6, "", 0, 0, 0);
			if(len notelst[ona2note(ona)] > 1)
				pend.flags |= FSHARP;
		}
	}
	last_ona = ona;
	was_null = isnull;
	echo(st);
}

# PsmCvtDuration
cvtdur(d: real): int
{
	for(j := 0; j < DURN; j++){
		d1 := durs[j];
		d2 := durs[j+1];
		if(d < d1*d2/(d1+d2))
			return j;
	}
	return 0;
}

dokey(k: int)
{
	iskeyup := (k & Keyboard->Keyup) == Keyboard->Keyup;
	if(playing && !iskeyup){
		stopsnd();		# any key stops playback, then is processed
		playing = 0;
	}
	case mode {
	MMENU =>
		if(!iskeyup)
			menukey(k);
		return;
	MWORD =>
		if(!iskeyup)
			wordkey(k);
		return;
	MJUKE =>
		if(!iskeyup)
			jukekey(k);
		return;
	MREWARD =>
		if(!iskeyup)
			mode = MJUKE;
		return;
	MHELP =>
		if(!iskeyup){
			mode = helpfrom;
			helpfrom = MNORM;
		}
		return;
	}

	if(iskeyup){
		evt_time = now();
		onachange(0, 1);
		return;
	}
	evt_time = now();

	if(k >= '0' && k <= '9'){
		octv = k - '0';
		onachange(0, 1);
		return;
	}
	off := pianooffset(k);
	if(off != -99){
		onachange(note2ona(3, octv+1) + off, 0);
		return;
	}
	if(k == ' '){
		onachange(0, 0);	# audible rest
		return;
	}
	onachange(0, 1);
	case k {
	'x' =>
		startplay();
	'z' =>
		if(recording)
			recording = 0;
		else{
			recording = 1;
			curdur = 1.0;
			octv = 4;
			scrnx = 0;
		}
	',' =>
		filename = "";
		st := godsongstr();
		if(st != "")
			loadsongstr(st);
	'.' =>
		clearsong();
	'm' or 'M' =>
		incomplete = !incomplete;
		if(incomplete)
			echo("[incomplete]");
		else
			echo("[complete]");
	'\n' =>
		if(cur < len song)
			openmenu();
	8 =>	# backspace deletes note before cursor
		if(cur > 0){
			delnote(cur-1);
			cur--;
		}
	Keyboard->Left =>
		if(cur > 0){
			cur--;
			song[cur].flags &= ~FSEL;
		}
	Keyboard->Right =>
		if(cur < len song){
			song[cur].flags &= ~FSEL;
			cur++;
		}
	Keyboard->Home =>
		cur = 0;
		clearsel();
	Keyboard->End =>
		cur = len song;
		clearsel();
	Keyboard->Del =>
		if(cur < len song)
			delnote(cur);
	24 =>	# ctrl-x
		cutclip();
	3 =>	# ctrl-c
		copyclip();
	22 =>	# ctrl-v
		pasteclip();
	15 =>	# ctrl-o: JukeBox
		openjuke();
	1 =>	# ctrl-a: SaveAs
		e := savesong();
		if(e != nil)
			echo("[save failed: "+e+"]");
		else
			echo("[saved "+filename+"]");
	Keyboard->KF|1 or Keyboard->KF =>
		helpfrom = MNORM;
		mode = MHELP;
	Keyboard->Esc =>	# save song, then exit
		e := savesong();
		if(e != nil){
			echo("[save failed: "+e+"] Q aborts without saving");
			return;
		}
		quit();
	'Q' =>	# abort without saving (original Shift-ESC)
		quit();
	}
}

startplay()
{
	if(playing)
		return;
	stopreq = 0;
	playgen++;
	playing = 1;
	spawn player(playgen);
}

player(gen: int)
{
	i := cur;
	while(i < len song && !stopreq && gen == playgen){
		n := song[i];
		if(n.ntype != NMETER){
			cur = i;
			recalcxy();
			scrnx += n.x - GRW/3;
			if(haswords(n.word))
				echo(n.word);
			sndona(n.ona);
			d := 1000.0 * durs[n.dur] / curtempo();
			if(n.flags & FTIE)
				sys->sleep(int d);
			else{
				on := d * curstac();
				sys->sleep(int on);
				if(!stopreq && gen == playgen)
					sndona(0);
				sys->sleep(int (d - on));
			}
		}
		i++;
	}
	sndona(0);
	if(gen == playgen){
		cur = len song;
		recalcxy();
		scrnx += headx - GRW/2;
		playing = 0;
	}
}

# jukebox preview player: loops the parsed song at the file's tempo
pvplayer(gen: int, notes: array of ref Note, tempo, stac: real)
{
	for(;;){
		for(i := 0; i < len notes && !stopreq && gen == playgen; i++){
			n := notes[i];
			if(n.ntype == NMETER)
				continue;
			sndona(n.ona);
			d := 1000.0 * durs[n.dur] / tempo;
			if(n.flags & FTIE)
				sys->sleep(int d);
			else{
				on := d * stac;
				sys->sleep(int on);
				if(!stopreq && gen == playgen)
					sndona(0);
				sys->sleep(int (d - on));
			}
		}
		if(stopreq || gen != playgen)
			break;
	}
	sndona(0);
}

# --- popup menu (PopUpDuration / PsmRightClick) ------------------------

MENU_ACTIONS: con 7;

mkmenu()
{
	menuitems = array[MENU_ACTIONS + DURN + 1] of string;
	menuitems[0] = "Set Word";
	menuitems[1] = "Toggle Sharp";
	menuitems[2] = "Toggle Flat";
	menuitems[3] = "Toggle Tie";
	menuitems[4] = "Make Rest";
	menuitems[5] = "Insert Note";
	menuitems[6] = "Delete Note";
	for(i := 0; i < DURN; i++)
		menuitems[MENU_ACTIONS+i] = sys->sprint("%7.5f", durs[i]);
	menuitems[MENU_ACTIONS+DURN] = "CANCEL";
}

openmenu()
{
	if(cur >= len song)
		return;
	menusel = MENU_ACTIONS + DURN;
	mode = MMENU;
}

menukey(k: int)
{
	case k {
	Keyboard->Up =>
		if(menusel > 0)
			menusel--;
	Keyboard->Down =>
		if(menusel < len menuitems - 1)
			menusel++;
	'\n' =>
		menuact(menusel);
	Keyboard->Esc or 'q' or 'Q' =>
		mode = MNORM;
	}
}

menuact(i: int)
{
	mode = MNORM;
	if(cur >= len song)
		return;
	n := song[cur];
	if(i >= MENU_ACTIONS && i < MENU_ACTIONS+DURN){
		if(n.ntype == NNOTE)
			n.dur = i - MENU_ACTIONS;
	}else case i {
	0 =>	# Set Word
		if(n.ntype == NNOTE){
			wordidx = cur;
			wordbuf = "";
			if(haswords(n.word))
				wordbuf = n.word;
			mode = MWORD;
			return;
		}
	1 =>	# Toggle Sharp
		if(n.ntype == NNOTE && n.ona != 0){
			if(n.flags & FFLAT){
				n.flags &= ~FFLAT;
				n.ona++;
			}
			if(n.flags & FSHARP){
				n.flags &= ~FSHARP;
				n.ona--;
			}else{
				n.flags |= FSHARP;
				n.ona++;
			}
		}
	2 =>	# Toggle Flat
		if(n.ntype == NNOTE && n.ona != 0){
			if(n.flags & FSHARP){
				n.flags &= ~FSHARP;
				n.ona--;
			}
			if(n.flags & FFLAT){
				n.flags &= ~FFLAT;
				n.ona++;
			}else{
				n.flags |= FFLAT;
				n.ona--;
			}
		}
	3 =>	# Toggle Tie
		n.flags ^= FTIE;
	4 =>	# Make Rest
		if(n.ntype == NNOTE)
			n.ona = 0;
	5 =>	# Insert Note
		insnote(cur+1, clone(n));
	6 =>	# Delete Note
		delnote(cur);
		return;
	}
	if(cur < len song)
		setwidth(song[cur]);
}

wordkey(k: int)
{
	case k {
	'\n' =>
		if(wordidx >= 0 && wordidx < len song)
			song[wordidx].word = wordbuf;
		wordidx = -1;
		mode = MNORM;
	Keyboard->Esc =>
		wordidx = -1;
		mode = MNORM;
	8 =>
		if(len wordbuf > 0)
			wordbuf = wordbuf[0:len wordbuf - 1];
	* =>
		if(k >= ' ' && k < 16rE000)
			wordbuf[len wordbuf] = k;
	}
}

# --- mouse -------------------------------------------------------------

doptr(p: ref Draw->Pointer)
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	x := p.xy.x - o.x;
	y := p.xy.y - o.y;
	but := p.buttons;
	down := but & ~prevbut;
	up := prevbut & ~but;
	prevbut = but;
	dragx = x;
	dragy = y;

	if(mode == MMENU){
		menuptr(x, y, down);
		return;
	}
	if(mode == MJUKE){
		jukeptr(x, y, down);
		return;
	}
	if(mode == MREWARD){
		if(down)
			mode = MJUKE;
		return;
	}
	if(mode == MHELP){
		if(down){
			mode = helpfrom;
			helpfrom = MNORM;
		}
		return;
	}
	if(mode != MNORM)
		return;

	if(down && playing){
		stopsnd();
		playing = 0;
	}

	if(down & 1)
		leftdown(x, y);
	else if(but & 1)
		leftdrag(x, y);
	if(up & 1)
		leftup(x, y);
	if(up & 4)
		rightup(x, y);
}

leftdown(x, y: int)
{
	# on-screen piano (PsmDownKey)
	ky := y - KBD_Y;
	if(ky >= 0 && ky < 36){
		kx := x - 16;
		for(i := 0; i < len kbx; i++)
			if(kx >= kbx[i] && kx < kbx[i]+kbw[i] && ky < kbh[i]){
				kbdheld = kbch[i];
				dokey(kbch[i]);
				return;
			}
	}
	if(y < 13*FONTH){
		# staff region (PsmLeftClick)
		if(tool == TPTR){
			i := findnote(x);
			cur = i;
			if(i < len song && song[i].ntype == NNOTE){
				dragmode = DPITCH;
				dragidx = i;
				o_orig = ona2octave(song[i].ona);
				n_orig = ona2note(song[i].ona);
				movepitch(y);
			}
		}else{
			dragmode = DBOX;
			boxx = x;
			boxy = y;
		}
		return;
	}
	# pick note box
	d := pickdur(x, y);
	if(d >= 0){
		dragmode = DNOTE;
		dragdur = d;
		return;
	}
	# meter box
	(mt, mb) := pickmeter(x, y);
	if(mt > 0){
		dragmode = DMETER;
		dragtop = mt;
		dragbot = mb;
		return;
	}
	# tools box
	if(x >= TOOLS_X && x < TOOLS_X+27 && y >= TOOLS_Y && y < TOOLS_Y+15){
		clearsel();
		if(x < TOOLS_X+13)
			tool = TBOX;
		else
			tool = TPTR;
		return;
	}
	# tempo/stacatto sliders
	if(x >= TEMPO_LEFT && x < TEMPO_LEFT+TEMPO_SPACING*3+2 &&
	   y >= TEMPO_TOP && y < TEMPO_TOP+TEMPO_SPACING*2+TEMPO_RANGE){
		dragmode = DTEMPO;
		tempoclick(x, y);
		return;
	}
	# button row: left, play/stop, record, right
	if(y >= BTN_Y && y < BTN_Y+21){
		b := -1;
		if(x >= 8 && x < 32)
			b = 0;
		else if(x >= 40 && x < 64)
			b = 1;
		else if(x >= 72 && x < 96)
			b = 2;
		else if(x >= 104 && x < 128)
			b = 3;
		case b {
		0 =>
			cur = 0;
			clearsel();
		1 =>
			if(playing){
				stopsnd();
				playing = 0;
			}else
				startplay();
		2 =>
			dokey('z');
		3 =>
			cur = len song;
			clearsel();
		}
	}
}

leftdrag(x, y: int)
{
	case dragmode {
	DPITCH =>
		movepitch(y);
	DTEMPO =>
		tempoclick(x, y);
	}
}

leftup(x, y: int)
{
	if(kbdheld != 0){
		kbdheld = 0;
		evt_time = now();
		onachange(0, 1);
	}
	case dragmode {
	DPITCH =>
		i := findnote(x);
		if(dragidx >= 0 && dragidx < len song){
			n := song[dragidx];
			if(i != len song && i != dragidx && i < len song){
				# drop on another note: shift the word there
				song[i].word = n.word;
				n.word = "";
				n.ona = note2ona(n_orig, o_orig);
			}else
				movepitch(y);
			setwidth(n);
		}
	DBOX =>
		x1 := boxx;
		x2 := x;
		if(x1 > x2){
			t := x1;
			x1 = x2;
			x2 = t;
		}
		marksel(x1, x2);
	DNOTE =>
		if(y < 13*FONTH)
			dropnote(x, y);
	DMETER =>
		if(y < 13*FONTH)
			dropmeter(x, y);
	}
	dragmode = DNONE;
	dragidx = -1;
}

rightup(x: int, nil: int)
{
	i := findnote(x);
	if(i < len song){
		cur = i;
		openmenu();
	}
}

movepitch(y: int)
{
	if(dragidx >= 0 && dragidx < len song)
		song[dragidx].ona = y2ona(y);
}

# PsmLeftClickPickNoteBox drop
dropnote(x, y: int)
{
	at: int;
	n := len song;
	recalcxy();
	if(n > 0 && x > song[n-1].x)
		at = n;			# after last
	else if(n == 0 || x < song[0].x)
		at = 0;			# after head = start
	else
		at = findnote(x - NOTE_SPACING/2) + 1;
	if(at > n)
		at = n;
	nt := ref Note(NNOTE, 0, y2ona(y), 0, 0, dragdur, "", 0, 0, 0);
	setwidth(nt);
	insnote(at, nt);
	cur = at + 1;
}

dropmeter(x: int, nil: int)
{
	at: int;
	n := len song;
	recalcxy();
	if(n > 0 && x >= headx)
		at = n;
	else if(n == 0 || x < song[0].x)
		at = 0;
	else
		at = findnote(x - NOTE_SPACING/2) + 1;
	if(at > n)
		at = n;
	nt := ref Note(NMETER, 0, 0, dragtop, dragbot, 6, "", 0, 0, 0);
	setwidth(nt);
	insnote(at, nt);
	cur = at + 1;
}

pickdurx(d: int): int
{
	x := NOTE_BOX_X;
	for(i := 0; i < d; i++){
		if(isdotted(i))
			x += NOTE_SPACING/2;
		x += NOTE_SPACING + 4;
	}
	return x;
}

pickdur(xx, yy: int): int
{
	if(yy >= NOTE_BOX_Y-14 && yy < NOTE_BOX_Y+6)
		for(i := 0; i < DURN; i++)
			if(pickdurx(i) <= xx+NOTE_SPACING/2 && xx+NOTE_SPACING/2 < pickdurx(i+1))
				return i;
	return -1;
}

pickmeter(xx, yy: int): (int, int)
{
	if(xx >= METER_X && xx < METER_X+METER_W*METERSN &&
	   yy >= METER_Y && yy < METER_Y+2*FONTH){
		i := (xx-METER_X)/METER_W;
		return (meter_tops[i], meter_bottoms[i]);
	}
	return (0, 0);
}

tempoclick(x, y: int)
{
	v := TEMPO_RANGE-1 - (y - (TEMPO_TOP+TEMPO_SPACING));
	if(v < 0)
		v = 0;
	if(v > TEMPO_RANGE-1)
		v = TEMPO_RANGE-1;
	if(x < TEMPO_LEFT + (TEMPO_SPACING*3+2)/2)
		tempo_sl = v;
	else
		stac_sl = v;
}

menuptr(x, y: int, down: int)
{
	mx := GRW/2 - 76;
	my := 120;
	if(x >= mx && x < mx+152 && y >= my+4 && y < my+4+len menuitems*10){
		menusel = (y-my-4)/10;
		if(down & 1)
			menuact(menusel);
	}else if(down)
		mode = MNORM;
}

# --- echo area (Doc note-name / word output) ---------------------------

echo(s: string)
{
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == '$'){		# strip DolDoc $...$ codes
			j := i+1;
			while(j < len s && s[j] != '$')
				j++;
			i = j;
			continue;
		}
		if(c == '\n'){
			pushline();
			continue;
		}
		if(c < ' ')
			c = ' ';
		ecur[len ecur] = c;
		if(len ecur >= ECHOW)
			pushline();
	}
}

pushline()
{
	elines = ecur :: elines;
	ecur = "";
	n := 0;
	keep: list of string;
	for(l := elines; l != nil && n < ECHOLINES; l = tl l){
		keep = hd l :: keep;
		n++;
	}
	elines = nil;
	for(; keep != nil; keep = tl keep)
		elines = hd keep :: elines;
}

# --- drawing -----------------------------------------------------------

blinkon(): int
{
	if(playing)
		return 1;
	return (sys->millisec()/400) & 1;
}

gprint(img: ref Image, o: Point, x, y, col: int, s: string)
{
	if(font == nil)
		return;
	d := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c < ' ')
			c = ' ';
		d[len d] = c;
	}
	img.text(Point(o.x+x, o.y+y), ink[col], Point(0, 0), font, d);
}

gvprint(img: ref Image, o: Point, x, y, col: int, s: string)
{
	for(i := 0; i < len s; i++)
		gprint(img, o, x, y+i*FONTH, col, s[i:i+1]);
}

drawspr(img: ref Image, o: Point, x, y, idx: int)
{
	if(spr[idx] == nil)
		return;
	p := Point(o.x+x, o.y+y);
	img.draw(spr[idx].r.addpt(p), spr[idx], msk[idx], spr[idx].r.min);
}

# glyph sprites are single-color: paint the ink through the mask
drawglyph(img: ref Image, o: Point, x, y, idx, col: int)
{
	if(msk[idx] == nil){
		drawspr(img, o, x, y, idx);
		return;
	}
	p := Point(o.x+x, o.y+y);
	img.draw(spr[idx].r.addpt(p), ink[col], msk[idx], spr[idx].r.min);
}

drawnote(img: ref Image, o: Point, x, y, d, col: int)
{
	if(d < 0 || d >= DURN)
		return;
	drawglyph(img, o, x, y, durimgs[d], col);
	if(durtrip[d])
		drawglyph(img, o, x, y, 16, col);
	if(isdotted(d))
		drawglyph(img, o, x, y, 15, col);
}

drawtimesig(img: ref Image, o: Point, x, y, top, bot, col: int)
{
	gprint(img, o, x, y, col, sys->sprint("%d", top));
	gprint(img, o, x, y+FONTH, col, sys->sprint("%d", bot));
}

hline(img: ref Image, o: Point, x1, x2, y, col: int)
{
	img.draw(Rect((o.x+x1, o.y+y), (o.x+x2, o.y+y+1)), ink[col], nil, Point(0, 0));
}

vline(img: ref Image, o: Point, x, y1, y2, col: int)
{
	img.draw(Rect((o.x+x, o.y+y1), (o.x+x+1, o.y+y2)), ink[col], nil, Point(0, 0));
}

frect(img: ref Image, o: Point, x, y, w, h, col: int)
{
	img.draw(Rect((o.x+x, o.y+y), (o.x+x+w, o.y+y+h)), ink[col], nil, Point(0, 0));
}

border(img: ref Image, o: Point, x1, y1, x2, y2, col: int)
{
	if(x1 > x2){
		t := x1; x1 = x2; x2 = t;
	}
	if(y1 > y2){
		t := y1; y1 = y2; y2 = t;
	}
	hline(img, o, x1, x2+1, y1, col);
	hline(img, o, x1, x2+1, y2, col);
	vline(img, o, x1, y1, y2+1, col);
	vline(img, o, x2, y1, y2+1, col);
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	o := img.r.min;
	img.draw(img.r, ink[WHITE], nil, Point(0, 0));	# $BG,WHITE$
	case mode {
	MJUKE =>
		drawjuke(img, o);
	MREWARD =>
		drawreward(img, o);
	MHELP =>
		drawhelp(img, o);
	* =>
		drawmain(img, o);
		if(mode == MMENU)
			drawmenu(img, o);
		if(mode == MWORD)
			gprint(img, o, 8, GRH-12, BLACK,
				sys->sprint("Word(\"%s\"):%s_", wordword(), wordbuf));
	}
	img.flush(Draw->Flushnow);
}

wordword(): string
{
	if(wordidx >= 0 && wordidx < len song && haswords(song[wordidx].word))
		return song[wordidx].word;
	return "";
}

drawmain(img: ref Image, o: Point)
{
	recalcxy();
	# scroll to keep the cursor visible (DrawIt)
	if(curx() < 64){
		scrnx -= 128;
		recalcxy();
	}
	if(curx() >= GRW-64){
		scrnx += 128;
		recalcxy();
	}
	drawstaff(img, o);
	drawpicknotebox(img, o);
	drawpickmeterbox(img, o);
	drawpicktools(img, o);
	drawtempoctl(img, o);
	drawspr(img, o, 1, KBD_Y+1, 17);	# piano keyboard graphic
	drawhints(img, o);
	drawbuttons(img, o);
	drawecho(img, o);
	drawdrag(img, o);
}

drawstaff(img: ref Image, o: Point)
{
	blink := blinkon();
	for(i := 1; i < 6; i++)
		hline(img, o, 0, GRW, i*8, BLACK);
	for(i = 7; i < 12; i++)
		hline(img, o, 0, GRW, i*8, BLACK);

	measure_len := 4.0;
	measure_left := measure_len;
	for(i = 0; i < len song; i++){
		n := song[i];
		x := n.x;
		y := n.y;
		if(measure_left < 0.001){
			vline(img, o, x-NOTE_SPACING, 8, 11*8, BLACK);
			measure_left = measure_len;
		}
		if(n.ntype == NMETER){
			col := BLACK;
			if(i == cur && blink)
				col = BROWN;
			drawtimesig(img, o, x, 5*8, n.mtop, n.mbot, col);
			measure_len = real n.mtop * 4.0 / real n.mbot;
			measure_left = 0.0;
		}else{
			col := BLACK;
			if(i == cur && blink){
				col = BROWN;
				gprint(img, o, x+8, y, BROWN, n.word);
			}else if(n.flags & FSEL)
				col = RED;
			else{
				if(n.ona == 0)
					col = LTGRAY;
				if(haswords(n.word))
					col = GREEN;
			}
			drawnote(img, o, x, y, n.dur, col);
			ax := x;
			if(isdotted(n.dur))
				ax += NOTE_SPACING/2;
			if(n.flags & FSHARP)
				drawglyph(img, o, ax, y, 13, col);
			else if(n.flags & FFLAT)
				drawglyph(img, o, ax, y, 14, col);
			measure_left -= durs[n.dur];
		}
	}
	col := BLACK;
	if(cur == len song && blink)
		col = BROWN;
	drawglyph(img, o, headx, 50, 12, col);	# clef / end-of-song cursor
}

drawpicknotebox(img: ref Image, o: Point)
{
	for(i := 0; i < DURN; i++){
		col := BLACK;
		if(isdotted(i))
			col = RED;
		else if(durtrip[i])
			col = LTRED;
		drawnote(img, o, pickdurx(i), NOTE_BOX_Y, i, col);
	}
}

drawpickmeterbox(img: ref Image, o: Point)
{
	for(i := 0; i < METERSN; i++)
		drawtimesig(img, o, METER_X+i*METER_W, METER_Y,
			meter_tops[i], meter_bottoms[i], BLACK);
}

drawpicktools(img: ref Image, o: Point)
{
	col := DKGRAY;			# ROPF_DITHER WHITE/BLACK approx
	if(tool == TBOX)
		col = LTRED;		# ROPF_DITHER WHITE/RED approx
	border(img, o, TOOLS_X, TOOLS_Y, TOOLS_X+10, TOOLS_Y+10, col);
	col = BLACK;
	if(tool == TPTR)
		col = RED;
	# small mouse-pointer arrow (gr.fp_draw_ms)
	ax := TOOLS_X+15;
	ay := TOOLS_Y;
	for(i := 0; i < 8; i++)
		vline(img, o, ax+i, ay+i, ay+11-i, col);
	vline(img, o, ax+2, ay+8, ay+13, col);
	vline(img, o, ax+3, ay+8, ay+13, col);
}

drawtempoctl(img: ref Image, o: Point)
{
	l := TEMPO_LEFT;
	t := TEMPO_TOP;
	frect(img, o, l, t, TEMPO_SPACING*3+2, TEMPO_SPACING*2+TEMPO_RANGE, LTGREEN);
	frect(img, o, l+TEMPO_BORDER, t+TEMPO_BORDER,
		TEMPO_SPACING*3+2-2*TEMPO_BORDER,
		TEMPO_SPACING*2+TEMPO_RANGE-2*TEMPO_BORDER, BLACK);
	vline(img, o, l+TEMPO_SPACING, t+TEMPO_SPACING, t+TEMPO_SPACING+TEMPO_RANGE, WHITE);
	vline(img, o, l+2*TEMPO_SPACING+1, t+TEMPO_SPACING, t+TEMPO_SPACING+TEMPO_RANGE, WHITE);
	gprint(img, o, l+TEMPO_SPACING-FONTW/2, t+TEMPO_SPACING+TEMPO_RANGE+3,
		LTGREEN, sys->sprint("%d", tempo_sl*10/TEMPO_RANGE));
	gprint(img, o, l+2*TEMPO_SPACING+1-FONTW/2, t+TEMPO_SPACING+TEMPO_RANGE+3,
		LTGREEN, sys->sprint("%d", stac_sl*10/TEMPO_RANGE));
	frect(img, o, l+TEMPO_SPACING-3, t+TEMPO_SPACING+TEMPO_RANGE-1-tempo_sl-2, 7, 5, LTGREEN);
	frect(img, o, l+2*TEMPO_SPACING+1-3, t+TEMPO_SPACING+TEMPO_RANGE-1-stac_sl-2, 7, 5, LTGREEN);
	frect(img, o, l+TEMPO_SPACING-2, t+TEMPO_SPACING+TEMPO_RANGE-1-tempo_sl-1, 5, 3, YELLOW);
	frect(img, o, l+2*TEMPO_SPACING+1-2, t+TEMPO_SPACING+TEMPO_RANGE-1-stac_sl-1, 5, 3, YELLOW);
	gvprint(img, o, l+TEMPO_BORDER+2, t+TEMPO_SPACING+2, GREEN, "Tempo");
	gvprint(img, o, l+TEMPO_SPACING*3-TEMPO_BORDER-FONTW, t+TEMPO_SPACING+2, GREEN, "Stacatto");
}

hintline(img: ref Image, o: Point, y: int, key, txt: string)
{
	gprint(img, o, 0, y, LTGREEN, key);
	gprint(img, o, 16*FONTW, y, GREEN, txt);
}

drawhints(img: ref Image, o: Point)
{
	hintline(img, o, HINT_Y, "<SPACE>", "Rest");
	hintline(img, o, HINT_Y+8, "<BACKSPACE>", "Deletes Last Note");
	hintline(img, o, HINT_Y+16, "Left Mouse", "Drag note or shift word");
	hintline(img, o, HINT_Y+24, "Right Mouse", "Change duration or set word");
}

drawbuttons(img: ref Image, o: Point)
{
	drawspr(img, o, 9, BTN_Y+1, 6);		# go begin
	if(playing)
		drawspr(img, o, 41, BTN_Y+1, 9);	# stop
	else
		drawspr(img, o, 41, BTN_Y+1, 8);	# play
	if(recording)
		drawspr(img, o, 73, BTN_Y+1, 10);	# record on
	else
		drawspr(img, o, 73, BTN_Y+1, 11);	# record off
	drawspr(img, o, 105, BTN_Y+1, 7);	# go end
	gprint(img, o, 144, BTN_Y+6, GREEN,
		sys->sprint("Octave %d  %s", octv, filetail()));
}

filetail(): string
{
	if(filename == "")
		return "";
	s := filename;
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == '/')
			return s[i+1:];
	return s;
}

drawecho(img: ref Image, o: Point)
{
	n := 0;
	for(l := elines; l != nil; l = tl l)
		n++;
	avail := (GRH - 8 - ECHO_Y)/FONTH - 1;
	while(n > avail){
		# drop oldest lines from display
		nl: list of string;
		i := 0;
		for(l = elines; l != nil && i < avail; l = tl l){
			nl = hd l :: nl;
			i++;
		}
		elines = nil;
		for(; nl != nil; nl = tl nl)
			elines = hd nl :: elines;
		n = avail;
	}
	rev: list of string;
	for(l = elines; l != nil; l = tl l)
		rev = hd l :: rev;
	y := ECHO_Y;
	for(; rev != nil; rev = tl rev){
		gprint(img, o, 4, y, GREEN, hd rev);
		y += FONTH;
	}
	gprint(img, o, 4, y, GREEN, ecur);
}

drawdrag(img: ref Image, o: Point)
{
	case dragmode {
	DNOTE =>
		drawnote(img, o, dragx, dragy, dragdur, BLACK);
	DMETER =>
		drawtimesig(img, o, dragx, dragy, dragtop, dragbot, BLACK);
	DBOX =>
		border(img, o, boxx, boxy, dragx, dragy, DKGRAY);
	}
}

drawmenu(img: ref Image, o: Point)
{
	mx := GRW/2 - 76;
	my := 120;
	h := len menuitems*10 + 8;
	frect(img, o, mx-2, my-2, 156, h+4, WHITE);
	border(img, o, mx-2, my-2, mx+153, my+h+1, BLACK);
	for(i := 0; i < len menuitems; i++){
		y := my + 4 + i*10;
		if(i == menusel){
			frect(img, o, mx, y-1, 152, 10, GREEN);
			gprint(img, o, mx+4, y, WHITE, menuitems[i]);
		}else
			gprint(img, o, mx+4, y, GREEN, menuitems[i]);
	}
}

drawhelp(img: ref Image, o: Point)
{
	lines := array[] of {
	"Psalmody",
	"",
	"1-7        octave    (0-9 accepted)",
	"a s d f g h j k l ; '   white piano keys (hold to sound)",
	"e r t   u i   p [ ]     black piano keys",
	"<SPACE>    rest        <BACKSPACE> deletes last note",
	"x          play/stop   z           record from key timing",
	",          random God song",
	".          clear song  m           mark incomplete",
	"arrows     move cursor Home/End    begin/end",
	"<DEL>      delete note <ENTER>     note menu",
	"^X ^C ^V   cut/copy/paste selection (box tool selects)",
	"^O         JukeBox     ^A          save",
	"<ESC>      save+exit   Q           abort without saving",
	"",
	"Left mouse drags notes, words, sliders, and pick-box glyphs.",
	"Right mouse opens the duration/word menu on a note.",
	"",
	"any key continues",
	};
	y := 32;
	for(i := 0; i < len lines; i++){
		gprint(img, o, 32, y, GREEN, lines[i]);
		y += 12;
	}
}

# --- god ---------------------------------------------------------------

loadvocab()
{
	buf := readfile("/lib/temple/vocab.txt");
	if(buf == ""){
		vocab = array[0] of string;
		return;
	}
	(nil, l) := sys->tokenize(buf, "\n");
	vocab = array[nw(l)] of string;
	i := 0;
	for(; l != nil; l = tl l)
		vocab[i++] = hd l;
}

nw(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

godword(): string
{
	if(rand == nil || len vocab == 0)
		return "God";
	return vocab[rand->rand(len vocab)];
}

godbits(n: int): int
{
	if(rand == nil)
		return sys->millisec() & ((1<<n)-1);
	return rand->rand(1<<n);
}

god_normal := array[] of { 0, 0, 1, 2, 3 };	# DUR_4 DUR_4 DUR_8_8 DUR_3_3_3 DUR_16^4

# Adam/God/GodSong.HC GodSongStr: Normal complexity, no rests, 4/4
godsongstr(): string
{
	oct := octv;
	if(oct < 1)
		oct = 1;
	if(oct > 7)
		oct = 7;
	buf := "";
	ostate := oct + 1;
	buf[len buf] = '0' + ostate;
	lastd := -1;
	for(i := 0; i < 8; i++){
		d := god_normal[godbits(8) % 5];
		case d {
		1 =>	# eighth pair
			if(lastd != 1)
				buf += "e";
			(buf, ostate) = godnote(buf, godbits(4), oct, ostate);
			(buf, ostate) = godnote(buf, godbits(4), oct, ostate);
		2 =>	# triplet
			if(lastd != 2)
				buf += "et";
			(buf, ostate) = godnote(buf, godbits(4), oct, ostate);
			(buf, ostate) = godnote(buf, godbits(4), oct, ostate);
			(buf, ostate) = godnote(buf, godbits(4), oct, ostate);
		3 =>	# four sixteenths
			if(lastd != 3)
				buf += "s";
			k := godbits(4);
			k2 := godbits(4);
			(buf, ostate) = godnote(buf, k, oct, ostate);
			(buf, ostate) = godnote(buf, k2, oct, ostate);
			(buf, ostate) = godnote(buf, k, oct, ostate);
			(buf, ostate) = godnote(buf, k2, oct, ostate);
		* =>	# quarter
			if(lastd != 0)
				buf += "q";
			(buf, ostate) = godnote(buf, godbits(4), oct, ostate);
		}
		lastd = d;
	}
	return buf;
}

godnote(buf: string, k, oct, ostate: int): (string, int)
{
	k /= 2;
	if(k < 3){
		if(ostate != oct){
			ostate = oct;
			buf[len buf] = '0' + ostate;
		}
		if(k == 0)
			buf += "G";
		else
			buf[len buf] = k - 1 + 'A';
	}else{
		if(ostate != oct+1){
			ostate = oct + 1;
			buf[len buf] = '0' + ostate;
		}
		buf[len buf] = k - 1 + 'A';
	}
	return (buf, ostate);
}

# --- song file format (PsalmodyFile.HC) --------------------------------

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

writefile(path, s: string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("%r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

duridx(d: real): int
{
	if(d <= 2.0*0.25/3.0)
		return 0;
	else if(d <= 0.25)
		return 1;
	else if(d <= 2.0*0.5/3.0)
		return 2;
	else if(d <= 0.5)
		return 3;
	else if(d <= 2.0/3.0)
		return 4;
	else if(d <= 0.5*1.5)
		return 5;
	else if(d <= 1.0)
		return 6;
	else if(d <= 1.5)
		return 7;
	else if(d <= 2.0)
		return 8;
	else if(d <= 3.0)
		return 9;
	else if(d <= 4.0)
		return 10;
	return 11;
}

# PsmLoadSongStr: parse a Play() score string, inserting before the cursor
loadsongstr(st: string)
{
	i := 0;
	L := len st;
	while(i < L){
		nt := ref Note(NNOTE, 0, 0, 0, 0, 6, "", 0, 0, 0);
		# prefix: meters, ties, octaves, durations
		for(;;){
			if(i >= L)
				break;
			c := st[i];
			if((c >= 'A' && c <= 'G') || c == 'R')
				break;
			if(c == 'M'){
				i++;
				mt := 4;
				mb := 4;
				if(i < L && st[i] >= '1' && st[i] <= '9')
					mt = st[i++] - '0';
				if(i < L && st[i] == '/')
					i++;
				if(i < L && st[i] >= '1' && st[i] <= '9')
					mb = st[i++] - '0';
				m := ref Note(NMETER, 0, 0, mt, mb, 6, "", 0, 0, 0);
				setwidth(m);
				atend := cur == len song;
				insnote(len song, m);	# meters append at the tail
				if(atend)
					cur = len song;
				continue;
			}
			if(c == '('){
				nt.flags |= FTIE;
				i++;
				continue;
			}
			if(c >= '0' && c <= '9'){
				octv = c - '0';
				i++;
				continue;
			}
			case c {
			'w' =>	curdur = 4.0; i++;
			'h' =>	curdur = 2.0; i++;
			'q' =>	curdur = 1.0; i++;
			'e' =>	curdur = 0.5; i++;
			's' =>	curdur = 0.25; i++;
			't' =>	curdur = 2.0*curdur/3.0; i++;
			'.' =>	curdur = 1.5*curdur; i++;
			* =>	i++;	# skip junk (original grammar has none)
			}
		}
		if(i >= L)
			break;
		c := st[i++];
		if(c != 'R'){
			note := note_map[c - 'A'];
			if(i < L && st[i] == 'b'){
				nt.flags |= FFLAT;
				note--;
				i++;
				if(note < 0)		# Ab
					note = 11;
				else if(note == 2)	# Cb
					octv--;
			}else if(i < L && st[i] == '#'){
				nt.flags |= FSHARP;
				note++;
				i++;
				if(note > 11)		# G#
					note = 0;
				else if(note == 3)	# B#
					octv++;
			}
			nt.ona = note2ona(note, octv);
		}else
			nt.ona = 0;
		nt.dur = duridx(curdur);
		nt.ntype = NNOTE;
		setwidth(nt);
		insnote(cur, nt);
		cur++;
	}
}

# scan a HolyC string literal (with adjacent-literal concatenation) into
# \0-separated segments; returns (segments, position after the literals)
scanstrings(txt: string, i: int): (array of string, int)
{
	segs: list of string;
	curseg := "";
	L := len txt;
	for(;;){
		while(i < L && (txt[i] == ' ' || txt[i] == '\t' || txt[i] == '\n' || txt[i] == '\r'))
			i++;
		if(i >= L || txt[i] != '"')
			break;
		i++;
		while(i < L && txt[i] != '"'){
			c := txt[i];
			if(c == '\\' && i+1 < L){
				i++;
				case txt[i] {
				'0' =>
					segs = curseg :: segs;
					curseg = "";
				'n' =>	curseg[len curseg] = '\n';
				't' =>	curseg[len curseg] = '\t';
				'r' =>	curseg[len curseg] = '\r';
				* =>	curseg[len curseg] = txt[i];
				}
			}else
				curseg[len curseg] = c;
			i++;
		}
		if(i < L)
			i++;	# closing quote
	}
	segs = curseg :: segs;
	n := 0;
	for(l := segs; l != nil; l = tl l)
		n++;
	a := array[n] of string;
	for(l = segs; l != nil; l = tl l)
		a[--n] = hd l;
	return (a, i);
}

isident(c: int): int
{
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9');
}

scanfloat(txt: string, i: int): (real, int)
{
	L := len txt;
	while(i < L && (txt[i] == ' ' || txt[i] == '\t'))
		i++;
	s := "";
	while(i < L && ((txt[i] >= '0' && txt[i] <= '9') || txt[i] == '.' || txt[i] == '-'))
		s[len s] = txt[i++];
	if(s == "")
		return (0.0, i);
	return (real s, i);
}

# PsmLoadSong: lex a saved HolyC song program
loadsong(path: string): string
{
	txt := readfile(path);
	if(txt == "")
		return "cannot read " + path;
	incomplete = 0;
	nl := 0;
	for(j := 0; j < len txt && txt[j] != '\n'; j++)
		nl = j+1;
	if(nl > 0 && contains(txt[0:nl], "incomplete"))
		incomplete = 1;
	i := 0;
	L := len txt;
	while(i < L){
		c := txt[i];
		if(c == '/' && i+1 < L && txt[i+1] == '/'){
			while(i < L && txt[i] != '\n')
				i++;
			continue;
		}
		if(c == '/' && i+1 < L && txt[i+1] == '*'){
			i += 2;
			while(i+1 < L && !(txt[i] == '*' && txt[i+1] == '/'))
				i++;
			i += 2;
			continue;
		}
		if(c == '"'){
			(nil, ni) := scanstrings(txt, i);
			i = ni;
			continue;
		}
		if(isident(c) && (c < '0' || c > '9')){
			j = i;
			while(j < L && isident(txt[j]))
				j++;
			id := txt[i:j];
			i = j;
			if(id == "Play"){
				while(i < L && (txt[i] == ' ' || txt[i] == '\t' || txt[i] == '\n'))
					i++;
				if(i < L && txt[i] == '('){
					i++;
					(segs, ni) := scanstrings(txt, i);
					i = ni;
					score := "";
					for(k := 0; k < len segs; k++)
						score += segs[k];
					lastn := len song;
					loadsongstr(score);
					while(i < L && (txt[i] == ' ' || txt[i] == '\t' || txt[i] == '\n'))
						i++;
					if(i < L && txt[i] == ','){
						i++;
						(words, ni2) := scanstrings(txt, i);
						i = ni2;
						assignwords(lastn, words);
					}
				}
			}else if(id == "music"){
				while(i < L && (txt[i] == ' ' || txt[i] == '\t'))
					i++;
				if(i < L && txt[i] == '.'){
					i++;
					j = i;
					while(j < L && isident(txt[j]))
						j++;
					fld := txt[i:j];
					i = j;
					while(i < L && (txt[i] == ' ' || txt[i] == '\t'))
						i++;
					if(i < L && txt[i] == '='){
						i++;
						(v, ni3) := scanfloat(txt, i);
						i = ni3;
						if(fld == "tempo"){
							t := v - 0.0005;
							tempo_sl = clampsl(int (real TEMPO_RANGE*(t-0.5)/4.4));
						}else if(fld == "stacatto_factor"){
							t := v - 0.0005;
							stac_sl = clampsl(int (real TEMPO_RANGE*(t-0.12)/0.88));
						}
					}
				}
			}
			continue;
		}
		i++;
	}
	return nil;
}

clampsl(v: int): int
{
	if(v < 0)
		return 0;
	if(v > TEMPO_RANGE-1)
		return TEMPO_RANGE-1;
	return v;
}

contains(s, t: string): int
{
	n := len t;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == t)
			return 1;
	return 0;
}

# original do/while: assignment stops after the entry before an empty one
assignwords(lastn: int, w: array of string)
{
	if(len w == 0)
		return;
	ni := lastn;
	wi := 0;
	for(;;){
		while(ni < len song && song[ni].ntype == NMETER)
			ni++;
		if(ni >= len song)
			break;
		song[ni].word = w[wi];
		ni++;
		wi++;
		if(wi >= len w || w[wi] == "")
			break;
	}
}

# PsmCvtSong: one note's Play-string fragment
# (persistent octave/duration state lives in the caller)
cvtnote(n: ref Note, lastoct, lastdur, octave, note: int): (string, int, int, int, int)
{
	dst := "";
	if(n.ntype == NMETER){
		dst = sys->sprint("M%d/%d", n.mtop, n.mbot);
		return (dst, lastoct, lastdur, octave, note);
	}
	if(n.ona != 0){
		ona := n.ona;
		if(n.flags & FSHARP)
			ona--;
		if(n.flags & FFLAT)
			ona++;
		octave = ona2octave(ona);
		note = note_map[notelst[ona2note(ona)][0] - 'A'];
	}
	if(n.flags & FTIE)
		dst += "(";
	if(octave != lastoct && n.ona != 0){
		dst[len dst] = octave + '0';
		lastoct = octave;
	}
	if(n.dur != lastdur){
		dst += durlst[n.dur];
		lastdur = n.dur;
	}
	if(n.ona != 0){
		s := notelst[note];
		dst += s;
		if(len s == 1){
			if(n.flags & FFLAT)
				dst += "b";
			else if(n.flags & FSHARP)
				dst += "#";
		}
	}else
		dst += "R";
	return (dst, lastoct, lastdur, octave, note);
}

quoteword(w: string): string
{
	s := "";
	for(i := 0; i < len w; i++){
		c := w[i];
		if(c == ' ')
			c = SHIFTSP;	# original converts spaces on save
		case c {
		'"' =>	s += "\\\"";
		'\\' =>	s += "\\\\";
		'\n' =>	s += "\\n";
		* =>	s[len s] = c;
		}
	}
	return s;
}

wordsarg(gs, ge: int): string
{
	s := "\",\n\t\t\"";
	for(i := gs; i < ge; i++){
		n := song[i];
		if(n.ntype == NMETER)
			continue;
		if(haswords(n.word))
			s += quoteword(n.word) + "\\0";
		else{
			s[len s] = SHIFTSP;
			s += "\\0";
		}
	}
	return s;
}

# PsmSaveSong
savesong(): string
{
	if(filename == ""){
		sys->create(dirname, Sys->OREAD, Sys->DMDIR|8r775);
		filename = dirname + "/Tmp.HC";
	}
	tempo := curtempo();
	stac := curstac();
	anywords := 0;
	for(i := 0; i < len song; i++)
		if(haswords(song[i].word))
			anywords = 1;
	s := "";
	if(incomplete)
		s += "//0 incomplete\n";
	else if(anywords)
		s += "//0 has words\n";
	else
		s += "//0 no nothing\n";
	s += "U0 Song()\n{\nFs->task_end_cb=&SndTaskEndCB;\nMusicSettingsRst;\n";
	s += sys->sprint("music.tempo=%6.3f;\n", tempo+0.0005);
	s += sys->sprint("music.stacatto_factor=%6.3f;\n", stac+0.0005);
	s += "try {\nwhile (!ScanKey) {\n\tPlay(\"";

	measure_len := 4.0;
	two_left := 2.0*measure_len;
	lastoct := -1000;
	lastdur := -1;
	octave := 4;
	note := 3;
	gs := 0;
	ghas := 0;
	frag: string;
	for(i = 0; i < len song; i++){
		n := song[i];
		(frag, lastoct, lastdur, octave, note) = cvtnote(n, lastoct, lastdur, octave, note);
		s += frag;
		if(haswords(n.word))
			ghas = 1;
		if(n.ntype == NMETER){
			measure_len = real n.mtop * 4.0 / real n.mbot;
			two_left = 0.0;
		}else
			two_left -= durs[n.dur];
		if(two_left < 0.001 && i+1 < len song){
			if(ghas)
				s += wordsarg(gs, i+1);
			s += "\");\n\tPlay(\"";
			two_left = 2.0*measure_len;
			gs = i+1;
			ghas = 0;
		}
	}
	if(ghas)
		s += wordsarg(gs, len song);
	s += "\");\n}\n} catch\nPutExcept;\nSnd;\n}\n\nSong;\n";
	return writefile(filename, s);
}

# --- JukeBox -----------------------------------------------------------

openjuke()
{
	buildjuke();
	jsel = 0;
	mode = MJUKE;
}

buildjuke()
{
	l: list of ref JEntry;
	l = jukedir(dirname, 1, l);
	if(dirname != "/lib/temple/psalmody")
		l = jukedir("/lib/temple/psalmody", 0, l);
	n := 0;
	for(t := l; t != nil; t = tl t)
		n++;
	jents = array[n] of ref JEntry;
	for(t = l; t != nil; t = tl t)
		jents[--n] = hd t;
}

jukedir(dir: string, writable: int, l: list of ref JEntry): list of ref JEntry
{
	if(readdir == nil)
		return l;
	(d, nil) := readdir->init(dir, Readdir->NAME);
	for(i := 0; i < len d; i++){
		name := d[i].name;
		if(d[i].mode & Sys->DMDIR)
			continue;
		if(len name < 4 || name[len name-3:] != ".HC")
			continue;
		path := dir + "/" + name;
		txt := readfile(path);
		if(!contains(txt, "Play("))
			continue;
		nl := 0;
		for(j := 0; j < len txt && txt[j] != '\n'; j++)
			nl = j+1;
		tag := "";
		if(nl > 0)
			tag = txt[0:nl];
		rating := '0';
		if(len tag > 2 && tag[2] >= '0' && tag[2] <= '9')
			rating = tag[2];
		color := RED;
		if(contains(tag, "incomplete"))
			color = BLACK;
		else if(contains(tag, "has graphics"))
			color = GREEN;
		else if(contains(tag, "has words"))
			color = BLUE;
		else if(contains(tag, "special"))
			color = CYAN;
		else if(contains(tag, "no nothing")){
			color = RED;
			# JukeBox quirk: no-nothing song containing \0 words
			# gets its tag repaired to "has words"
			if(writable && contains(txt, "\\0"))
				retag(path, txt, rating, "has words");
		}
		e := ref JEntry(path, basename(name), rating, color, writable);
		l = e :: l;
	}
	return l;
}

basename(name: string): string
{
	if(len name > 3 && name[len name-3:] == ".HC")
		return name[0:len name-3];
	return name;
}

retag(path, txt: string, rating: int, tag: string)
{
	nl := 0;
	for(j := 0; j < len txt && txt[j] != '\n'; j++)
		nl = j+1;
	r := "";
	r[0] = rating;
	writefile(path, "//" + r + " " + tag + txt[nl:]);
}

jukekey(k: int)
{
	nent := len jents + 1;	# + DONE
	case k {
	Keyboard->Left or Keyboard->Up =>
		if(k == Keyboard->Up)
			jsel -= 5;
		else
			jsel--;
		if(jsel < 0)
			jsel = 0;
	Keyboard->Right or Keyboard->Down =>
		if(k == Keyboard->Down)
			jsel += 5;
		else
			jsel++;
		if(jsel >= nent)
			jsel = nent-1;
	' ' or '\n' =>
		if(jsel < len jents)
			preview(jents[jsel].path);
		else
			jukedone(0);
	Keyboard->Esc =>
		jukedone(jsel < len jents);
	'q' or 'Q' =>
		jukedone(0);
	'0' to '9' =>
		if(jsel < len jents)
			ratesong(jents[jsel], k);
	Keyboard->Del =>
		if(jsel < len jents){
			e := jents[jsel];
			if(e.writable && sys->remove(e.path) >= 0){
				buildjuke();
				if(jsel >= len jents)
					jsel = len jents;
			}
		}
	'r' =>
		if(jsel < len jents)
			reward(jents[jsel]);
	}
}

jukeptr(x, y: int, down: int)
{
	if(!(down & 1) || x < 16)
		return;
	col := (x-16)/100;
	row := (y-64)/16;
	if(col < 0 || col > 4 || row < 0)
		return;
	i := row*5 + col;
	if(i <= len jents){
		jsel = i;
		if(jsel < len jents)
			preview(jents[jsel].path);
		else
			jukedone(0);
	}
}

jukedone(choose: int)
{
	stopsnd();
	mode = MNORM;
	if(choose && jsel < len jents){
		path := jents[jsel].path;
		scrnx = 0;
		curdur = 1.0;
		octv = 4;
		song = array[0] of ref Note;
		cur = 0;
		e := loadsong(path);
		if(e != nil)
			echo("[load failed: "+e+"]");
		else{
			filename = path;
			recording = 0;
			echo("[loaded "+filetail()+"]");
		}
		cur = 0;
	}
}

preview(path: string)
{
	stopsnd();
	# parse into a scratch copy of the globals, then restore
	osong := song;
	ocur := cur;
	ooct := octv;
	odur := curdur;
	otempo := tempo_sl;
	ostac := stac_sl;
	oinc := incomplete;
	song = array[0] of ref Note;
	cur = 0;
	e := loadsong(path);
	notes := song;
	ptempo := curtempo();
	pstac := curstac();
	song = osong;
	cur = ocur;
	octv = ooct;
	curdur = odur;
	tempo_sl = otempo;
	stac_sl = ostac;
	incomplete = oinc;
	if(e != nil || len notes == 0)
		return;
	stopreq = 0;
	playgen++;
	spawn pvplayer(playgen, notes, ptempo, pstac);
}

ratesong(e: ref JEntry, k: int)
{
	e.rating = k;
	if(!e.writable)
		return;
	txt := readfile(e.path);
	if(len txt > 2 && txt[0] == '/' && txt[1] == '/'){
		s := txt[0:2];
		r := "";
		r[0] = k;
		writefile(e.path, s + r + txt[3:]);
	}
}

reward(e: ref JEntry)
{
	rewardlines = nil;
	app := "";
	for(i := 0; i < 5; i++){
		st := godword() + " " + godword() + " " + godword() + " " + godword() + " ";
		rewardlines = st :: rewardlines;
		app += "//Reward: \"" + st + "\"\n";
	}
	if(e.writable){
		txt := readfile(e.path);
		if(txt != "")
			writefile(e.path, txt + app);
	}
	mode = MREWARD;
}

drawjuke(img: ref Image, o: Point)
{
	gprint(img, o, 16, 8, BLACK, "Key:");
	gprint(img, o, 56, 8, GREEN, "Graphics");
	gprint(img, o, 132, 8, BLUE, "Words");
	gprint(img, o, 184, 8, RED, "No Nothing");
	gprint(img, o, 272, 8, BLACK, "Incomplete");
	gprint(img, o, 360, 8, CYAN, "Special");
	gprint(img, o, 16, 24, GREEN, "<DEL> delete   0-9 rate   r reward from God");
	gprint(img, o, 16, 32, GREEN, "arrows move   <SPACE> preview   <ESC> load into Psalmody   Q cancel");
	for(i := 0; i < len jents; i++){
		e := jents[i];
		x := 16 + (i%5)*100;
		y := 64 + (i/5)*16;
		nm := e.name;
		if(len nm > 8)
			nm = nm[0:8];
		r := "";
		r[0] = e.rating;
		if(i == jsel)
			frect(img, o, x-2, y-2, 92, 12, LTGRAY);
		gprint(img, o, x, y, e.color, r + nm);
	}
	dy := 64 + ((len jents)/5)*16;
	if(len jents == jsel)
		frect(img, o, 14, dy+14, 44, 12, LTGRAY);
	gprint(img, o, 16, dy+16, CYAN, "DONE");
}

drawreward(img: ref Image, o: Point)
{
	y := 120;
	gprint(img, o, 48, 96, RED, "Your reward from God:");
	for(l := rewardlines; l != nil; l = tl l){
		gprint(img, o, 48, y, RED, hd l);
		y += 12;
	}
	gprint(img, o, 48, y+12, GREEN, "any key continues");
}

# --- misc --------------------------------------------------------------

timer(c: chan of int, ms: int)
{
	for(;;){
		sys->sleep(ms);
		c <-= 1;
	}
}
