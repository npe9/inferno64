implement Bout;

#
# Bout - a duel you cannot win by being faster, only by learning what
# the other one does before they do it.  Each opponent winds up
# visibly - a tell - and that wind-up is the only warning there is.
#
# The opponents are why this game is in the tree.  An opponent is a file
# in a little language, read at start-up, and the game reads /lib/bouts
# and fights whatever it finds there.  Adding an opponent means writing
# a file; it does not mean changing this program, and there is nothing
# here that knows the name, the rhythm or the tricks of any of them.
# Where camber(1) demonstrates authored levels, this demonstrates
# authored CONDUCT, which is the same argument about the part of a game
# that is usually hardest to get out of the source.
#
#	bout            fight what is in /lib/bouts, in turn
#	bout -l         list them and say nothing else
#	bout -c FILE    check a file and say where it is wrong
#	bout -t         the self test
#	bout -s         write a frame to bout.raw
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "keyboard.m";

include "keyhold.m";
	keyhold: Keyhold;
	Binding: import keyhold;

include "tone.m";
	tone: Tone;

include "tiles.m";
	tiles: Tiles;
	Chr, Pal, Surface, Screen: import tiles;

include "frameclock.m";
	fclock: Frameclock;

Bout: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

KLEFT, KRIGHT, KUP, KDOWN, KA, KB, KSEL, KSTART: con 1 << iota;

BINDS := array[] of {
	(Keyboard->Left, KLEFT), ('a', KLEFT), ('A', KLEFT),
	(Keyboard->Right, KRIGHT), ('d', KRIGHT), ('D', KRIGHT),
	(Keyboard->Up, KUP), ('w', KUP), ('W', KUP),
	(Keyboard->Down, KDOWN), ('s', KDOWN), ('S', KDOWN),
	('z', KB), ('Z', KB), (',', KB),
	('x', KA), ('X', KA), ('.', KA), (' ', KA),
	('\n', KSTART), ('\t', KSEL),
};

kb: ref Binding;

SCALE:	con 2;
W:	con Tiles->W;
H:	con Tiles->H;
HUDH:	con 24;

ARTFILE:	con "/lib/tiles/bout.art";
MAPFILE:	con "/lib/tiles/bout.map";
BOUTDIR:	con "/lib/bouts";

PGUARD:	con 0;
PTELLHI: con 4;
PTELLLO: con 8;
PHITHI:	con 12;
PHITLO:	con 16;
PTOOK:	con 20;
PDOWN:	con 24;

HIGH, LOW: con iota;

IWAIT, ITELL, ISTRIKE, IRECOVER, IGOTO, IHURT: con iota;

Ins: adt {
	op:	int;
	a:	int;
	b:	int;
	dest:	string;
	line:	int;
};

State: adt {
	name:	string;
	ins:	array of ref Ins;
	n:	int;
};

Fighter: adt {
	name:	string;
	health:	int;
	maxhealth: int;
	reach:	int;
	states:	array of ref State;
	ns:	int;
	cur:	int;
	pc:	int;
	timer:	int;
	hurtto:	string;
	pose:	int;
	tell:	int;
	open:	int;
	down:	int;
};

them:	ref Fighter;
files:	array of string;
which:	int;

myhealth, mymax: int;
myguard: int;
mydist:	int;
mypose:	int;
myrecover: int;
mystruck: int;
won, lost: int;
frames:	int;
msg:	string;
msgt:	int;

pad, prevpad: int;
nofolk:	int;

MAXH:	con 20;
MINDIST: con 28;
MAXDIST: con 96;
STEP:	con 3;
SWING:	con 26;
HITF:	con 16;
CHIP:	con 1;

scn:	ref Screen;
scr, hall: ref Surface;
shall, duel: ref Chr;
pyou, pthem, phud, pwarn, pgood, ptell: ref Pal;
back, panel, barlo, barhi: int;

win:	ref Window;
testmode: int;
audio:	int;

playing(): int
{
	return testmode == 0;
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	keyhold = load Keyhold Keyhold->PATH;
	tone = load Tone Tone->PATH;
	kb = keyhold->mk(BINDS);
	tiles = load Tiles Tiles->PATH;
	fclock = load Frameclock Frameclock->PATH;
	if(tiles == nil){
		sys->fprint(sys->fildes(2), "bout: cannot load tiles: %r\n");
		raise "fail:load";
	}
	e := tiles->init();
	if(e != nil){
		sys->fprint(sys->fildes(2), "bout: %s\n", e);
		raise "fail:init";
	}
	if(fclock != nil)
		fclock->init();

	check := "";
	listonly := 0;
	for(a := tl argv; a != nil; a = tl a){
		case hd a {
		"-t" =>	testmode = 1;
		"-s" =>	testmode = 2;
		"-q" =>	audio = -1;
		"-l" =>	listonly = 1;
		"-c" =>
			if(tl a == nil){
				sys->fprint(sys->fildes(2), "bout: -c wants a file\n");
				raise "fail:usage";
			}
			a = tl a;
			check = hd a;
		* =>
			sys->fprint(sys->fildes(2),
				"usage: bout [-l | -c file | -t | -s] [-q]\n");
			raise "fail:usage";
		}
	}

	if(check != ""){
		# A checker, so that writing an opponent is like writing any
		# other program: you are told where it is wrong.
		(f, err) := readbout(check);
		if(err != nil){
			sys->fprint(sys->fildes(2), "%s\n", err);
			raise "fail:check";
		}
		sys->print("%s: %s, %d health, reach %d, %d states\n",
			check, f.name, f.maxhealth, f.reach, f.ns);
		return;
	}

	files = boutfiles();
	if(len files == 0){
		sys->fprint(sys->fildes(2), "bout: no opponents in %s\n", BOUTDIR);
		raise "fail:none";
	}
	if(listonly){
		for(i := 0; i < len files; i++){
			(f, err) := readbout(files[i]);
			if(err != nil)
				sys->print("%s\n", err);
			else
				sys->print("%-28s %-12s %3d health  reach %d\n",
					files[i], f.name, f.maxhealth, f.reach);
		}
		return;
	}

	d: ref Display;
	if(testmode){
		d = Display.allocate(nil);
		if(d == nil){
			sys->fprint(sys->fildes(2), "bout: no display: %r\n");
			raise "fail:display";
		}
	}else{
		wmclient = load Wmclient Wmclient->PATH;
		sys->pctl(Sys->NEWPGRP, nil);
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
		win = wmclient->window(ctxt, "Bout", Wmclient->Appl);
		d = win.display;
	}
	setup(d);
	if(audio == 0 && playing() && tone != nil && tone->init() == nil)
		audio = 1;
	which = 0;
	if(!startbout()){
		sys->fprint(sys->fildes(2), "bout: %s\n", msg);
		raise "fail:bout";
	}
	if(testmode == 1){
		selftest();
		return;
	}
	if(testmode == 2){
		shot();
		return;
	}
	win.reshape(Rect((0,0),(W*SCALE, H*SCALE)));
	win.onscreen("place");
	win.startinput("kbd" :: "keyup" :: "ptr" :: nil);
	play();
}

docmd(c: string)
{
	r := scn.cmd(c);
	if(len r > 0 && r[0] == '!'){
		sys->fprint(sys->fildes(2), "bout: %s\n", r);
		raise "fail:cmd";
	}
}

slurp(path: string): (array of byte, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || d.length <= big 0 || d.length > big (1024*1024))
		return (nil, "unreasonable file: " + path);
	b := array[int d.length] of byte;
	if(sys->readn(fd, b, len b) != len b)
		return (nil, sys->sprint("cannot read %s: %r", path));
	return (b, nil);
}

runcmds(path: string)
{
	(b, err) := slurp(path);
	if(err != nil)
		barf(err);
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		if(len l == 0 || l[0] == ';')
			continue;
		docmd(l);
	}
}

setup(d: ref Display)
{
	scn = tiles->screen(d, Draw->RGB24, SCALE);
	if(scn == nil)
		barf("no screen");
	runcmds(ARTFILE);
	back = colourof("cback");
	panel = colourof("cpanel");
	barlo = colourof("cbarlo");
	barhi = colourof("cbarhi");
	docmd(sys->sprint("surface scr %d %d %d", W, H, back));
	docmd(sys->sprint("surface hall %d %d %d", W, H, back));
	docmd("map hall hall " + MAPFILE);
	scr = scn.named("scr");
	hall = scn.named("hall");
	shall = scn.sheet("hall");
	duel = scn.sheet("duel");
	pyou = scn.pal("pyou");
	pthem = scn.pal("pthem");
	phud = scn.pal("phud");
	pwarn = scn.pal("pwarn");
	pgood = scn.pal("pgood");
	ptell = scn.pal("ptell");
	if(scr == nil || hall == nil || duel == nil || pyou == nil || ptell == nil)
		barf("the screen made nothing");
}

colourof(name: string): int
{
	p := scn.pal(name);
	if(p == nil || len p.c == 0)
		barf(name + ": no such colour");
	return p.c[0];
}

barf(s: string)
{
	sys->fprint(sys->fildes(2), "bout: %s\n", s);
	raise "fail:data";
}

number(w: string): (int, int)
{
	if(len w == 0)
		return (0, 0);
	v := 0;
	for(i := 0; i < len w; i++){
		if(w[i] < '0' || w[i] > '9')
			return (0, 0);
		v = v*10 + (w[i] - '0');
	}
	return (v, 1);
}

side(w: string): int
{
	case w {
	"high" =>	return HIGH;
	"low" =>	return LOW;
	}
	return -1;
}

sidename(v: int): string
{
	if(v == HIGH)
		return "high";
	if(v == LOW)
		return "low";
	return "-";
}

# Every opponent in the directory, by path.  The directory IS the list:
# there is no table of opponents anywhere in this program.
boutfiles(): array of string
{
	fd := sys->open(BOUTDIR, Sys->OREAD);
	if(fd == nil)
		return array[0] of string;
	out := array[16] of string;
	n := 0;
	for(;;){
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++){
			nm := d[i].name;
			if(len nm < 6 || nm[len nm-5:] != ".bout")
				continue;
			if(n >= len out){
				a := array[2 * len out] of string;
				a[0:] = out[0:n];
				out = a;
			}
			out[n++] = BOUTDIR + "/" + nm;
		}
	}
	for(i := 1; i < n; i++){
		v := out[i];
		j := i - 1;
		while(j >= 0 && out[j] > v){
			out[j+1] = out[j];
			j--;
		}
		out[j+1] = v;
	}
	return out[0:n];
}

addins(st: ref State, ins: ref Ins)
{
	if(st.n >= len st.ins){
		a := array[2 * len st.ins] of ref Ins;
		a[0:] = st.ins[0:st.n];
		st.ins = a;
	}
	st.ins[st.n++] = ins;
}

readbout(path: string): (ref Fighter, string)
{
	(b, err) := slurp(path);
	if(err != nil)
		return (nil, err);
	f := ref Fighter;
	f.name = "";
	f.health = f.maxhealth = 0;
	f.reach = 0;
	f.states = array[4] of ref State;
	f.ns = 0;
	f.hurtto = "";
	cur: ref State;
	body := 0;
	ln := 0;
	(nil, lines) := sys->tokenize(string b, "\n");
	for(; lines != nil; lines = tl lines){
		ln++;
		l := hd lines;
		if(len l > 0 && l[0] == ';')
			continue;
		(nw, w) := sys->tokenize(l, " \t");
		if(nw == 0)
			continue;
		where := sys->sprint("%s:%d: ", path, ln);
		if(hd w == "%"){
			body = 1;
			continue;
		}
		if(!body){
			case hd w {
			"name" =>
				f.name = joinwords(tl w);
			"health" =>
				if(nw != 2)
					return (nil, where + "health wants one number");
				(v, ok) := number(hd tl w);
				if(!ok)
					return (nil, where + "not a number: " + hd tl w);
				f.health = f.maxhealth = v;
			"reach" =>
				if(nw != 2)
					return (nil, where + "reach wants one number");
				(v, ok) := number(hd tl w);
				if(!ok)
					return (nil, where + "not a number: " + hd tl w);
				f.reach = v;
			* =>
				return (nil, where + "no such setting: " + hd w);
			}
			continue;
		}
		if(hd w == "state"){
			if(nw != 2)
				return (nil, where + "state wants a name");
			if(findstate(f, hd tl w) >= 0)
				return (nil, where + "there is already a state called " + hd tl w);
			cur = ref State(hd tl w, array[8] of ref Ins, 0);
			if(f.ns >= len f.states){
				a := array[2 * len f.states] of ref State;
				a[0:] = f.states[0:f.ns];
				f.states = a;
			}
			f.states[f.ns++] = cur;
			continue;
		}
		if(cur == nil)
			return (nil, where + "an instruction before any state");
		(ins, ie) := readins(w, nw, ln, where);
		if(ie != nil)
			return (nil, ie);
		addins(cur, ins);
	}
	if(f.name == "")
		return (nil, path + ": no name");
	if(f.maxhealth < 1)
		return (nil, path + ": no health");
	if(f.reach < MINDIST)
		return (nil, sys->sprint("%s: reach must be at least %d", path, MINDIST));
	if(f.ns == 0)
		return (nil, path + ": no states");
	# Every goto and hurt must name a state that exists.  Without this a
	# typo is a fighter that stops moving in the middle of a bout, which
	# reads as the game being broken rather than the file being wrong.
	for(i := 0; i < f.ns; i++){
		st := f.states[i];
		if(st.n == 0)
			return (nil, sys->sprint("%s: state %s is empty", path, st.name));
		for(k := 0; k < st.n; k++){
			in := st.ins[k];
			if((in.op == IGOTO || in.op == IHURT) && findstate(f, in.dest) < 0)
				return (nil, sys->sprint("%s:%d: no state called %s",
					path, in.line, in.dest));
		}
	}
	return (f, nil);
}

readins(w: list of string, nw, ln: int, where: string): (ref Ins, string)
{
	case hd w {
	"wait" or "recover" =>
		if(nw != 2)
			return (nil, where + hd w + " wants a number of frames");
		(v, ok) := number(hd tl w);
		if(!ok)
			return (nil, where + "not a number: " + hd tl w);
		op := IWAIT;
		if(hd w == "recover")
			op = IRECOVER;
		return (ref Ins(op, v, 0, "", ln), nil);
	"tell" =>
		if(nw != 3)
			return (nil, where + "tell wants high or low and a number of frames");
		s := side(hd tl w);
		if(s < 0)
			return (nil, where + "high or low, not " + hd tl w);
		(v, ok) := number(hd tl tl w);
		if(!ok)
			return (nil, where + "not a number: " + hd tl tl w);
		return (ref Ins(ITELL, s, v, "", ln), nil);
	"strike" =>
		if(nw != 3)
			return (nil, where + "strike wants high or low and a damage");
		s := side(hd tl w);
		if(s < 0)
			return (nil, where + "high or low, not " + hd tl w);
		(v, ok) := number(hd tl tl w);
		if(!ok)
			return (nil, where + "not a number: " + hd tl tl w);
		if(v < 1)
			return (nil, where + "a strike that does nothing");
		return (ref Ins(ISTRIKE, s, v, "", ln), nil);
	"goto" or "hurt" =>
		if(nw != 2)
			return (nil, where + hd w + " wants a state");
		op := IGOTO;
		if(hd w == "hurt")
			op = IHURT;
		return (ref Ins(op, 0, 0, hd tl w, ln), nil);
	}
	return (nil, where + "no such instruction: " + hd w);
}

findstate(f: ref Fighter, name: string): int
{
	for(i := 0; i < f.ns; i++)
		if(f.states[i].name == name)
			return i;
	return -1;
}

joinwords(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != "")
			s += " ";
		s += hd l;
	}
	return s;
}

# One frame of the opponent's program.  An instruction that takes time
# sets timer and is left in place; one that does not is executed and the
# counter moves on.  The guard count is there because a state of nothing
# but gotos would otherwise spin for ever inside one frame.
stepthem()
{
	if(them.down)
		return;
	if(them.timer > 0){
		them.timer--;
		if(them.timer > 0)
			return;
		them.pc++;
	}
	guard := 0;
	for(;;){
		if(++guard > 64){
			them.timer = 30;
			return;
		}
		st := them.states[them.cur];
		if(them.pc >= st.n){
			them.pc = 0;
			continue;
		}
		in := st.ins[them.pc];
		case in.op {
		IHURT =>
			them.hurtto = in.dest;
			them.pc++;
		IGOTO =>
			enter(in.dest);
		IWAIT =>
			them.timer = in.a;
			them.tell = -1;
			them.open = 0;
			them.pose = PGUARD;
			if(them.timer <= 0){
				them.pc++;
				continue;
			}
			return;
		ITELL =>
			them.timer = in.b;
			them.tell = in.a;
			them.open = 0;
			if(in.a == HIGH)
				them.pose = PTELLHI;
			else
				them.pose = PTELLLO;
			if(them.timer <= 0){
				them.pc++;
				continue;
			}
			return;
		ISTRIKE =>
			resolve(in.a, in.b);
			them.timer = HITF;
			them.tell = -1;
			if(in.a == HIGH)
				them.pose = PHITHI;
			else
				them.pose = PHITLO;
			them.open = 0;
			return;
		IRECOVER =>
			them.timer = in.a;
			them.tell = -1;
			them.open = 1;
			them.pose = PGUARD;
			if(them.timer <= 0){
				them.pc++;
				continue;
			}
			return;
		}
	}
}

enter(name: string)
{
	i := findstate(them, name);
	if(i < 0)
		i = 0;
	them.cur = i;
	them.pc = 0;
	them.timer = 0;
	them.tell = -1;
	them.open = 0;
	them.pose = PGUARD;
}

# A blow lands unless it is out of reach or guarded on the side it comes
# from.  Guarding the wrong side is worth nothing at all, which is what
# makes the tell the whole game.
resolve(kind, dmg: int)
{
	if(mydist > them.reach){
		say("short");
		return;
	}
	if(myguard == kind){
		myhealth -= CHIP;
		say("blocked");
		sfx(1, 220, 60);
	}else{
		myhealth -= dmg;
		mystruck = HITF;
		say("hit");
		sfx(2, 130, 160);
	}
	if(myhealth <= 0){
		myhealth = 0;
		lost = 1;
	}
}

say(s: string)
{
	msg = s;
	msgt = 70;
}

sfx(pri, freq, ms: int)
{
	if(audio == 1 && tone != nil)
		tone->sfx(pri, freq, ms);
}

startbout(): int
{
	if(which >= len files){
		won = 1;
		return 1;
	}
	(f, err) := readbout(files[which]);
	if(f == nil){
		msg = err;
		return 0;
	}
	them = f;
	enter(them.states[0].name);
	them.health = them.maxhealth;
	them.down = 0;
	them.hurtto = "";
	myhealth = mymax = MAXH;
	myguard = HIGH;
	mydist = MAXDIST;
	mypose = PGUARD;
	myrecover = 0;
	mystruck = 0;
	frames = 0;
	won = lost = 0;
	msg = them.name;
	msgt = 120;
	pad = prevpad = 0;
	return 1;
}

step()
{
	if(won || lost)
		return;
	frames++;
	edge := pad & ~prevpad;
	prevpad = pad;
	if(mystruck > 0)
		mystruck--;
	if(msgt > 0)
		msgt--;
	if(myrecover > 0)
		myrecover--;

	if(pad & KUP)
		myguard = HIGH;
	if(pad & KDOWN)
		myguard = LOW;
	if(pad & KLEFT)
		mydist += STEP;
	if(pad & KRIGHT)
		mydist -= STEP;
	if(mydist < MINDIST)
		mydist = MINDIST;
	if(mydist > MAXDIST)
		mydist = MAXDIST;

	if((edge & KA) && myrecover == 0){
		myrecover = SWING;
		mypose = PHITHI;
		if(myguard == LOW)
			mypose = PHITLO;
		strike();
	}else if(myrecover == 0){
		mypose = PGUARD;
		if(myguard == LOW)
			mypose = PTELLLO;
	}
	if(mystruck > 0)
		mypose = PTOOK;

	stepthem();

	if(them.health <= 0 && !them.down){
		them.down = 1;
		them.pose = PDOWN;
		say(them.name + " is down");
		sfx(2, 90, 400);
	}
	if(them.down)
		won = 1;
}

# Your blow lands hard only while they are open - in recover - which is
# the window their own program gives you.  Any other time it is turned.
strike()
{
	if(mydist > them.reach - 6){
		say("short");
		return;
	}
	if(them.down)
		return;
	if(them.open){
		them.health -= 3;
		them.pose = PTOOK;
		say("in!");
		sfx(1, 700, 70);
		if(them.hurtto != "" && them.health > 0)
			enter(them.hurtto);
	}else{
		them.health -= 1;
		say("turned");
		sfx(1, 300, 50);
	}
	if(them.health < 0)
		them.health = 0;
}

folkat(x, y, t: int, p: ref Pal, flags: int)
{
	old := scr.chr;
	scr.chr = duel;
	scr.put16(x, y, t, p, flags);
	scr.chr = old;
}

FLOOR:	con 19*8;		# where they stand; the map puts the floor here

draw1()
{
	hall.blit(scr, 0, 0);
	if(!nofolk){
		mx := 56;
		folkat(mx, FLOOR - 16, mypose, pyou, 0);
		tx := mx + mydist;
		folkat(tx, FLOOR - 16, them.pose, pthem, Tiles->FLIPX);
		# The tell, as a mark you can see without reading: a bar above
		# their head for high, across their feet for low.  The word in
		# the corner is for learning what the mark means; the mark is
		# what you actually play by.
		if(them.tell >= 0){
			c := tiles->entry(Tiles->LIGHT, Tiles->YELLOW);
			y := FLOOR - 22;
			if(them.tell == LOW)
				y = FLOOR - 2;
			scr.fill(Rect((tx, y), (tx+16, y+4)), c);
		}
	}
	hud();
}

hud()
{
	scr.fill(Rect((0,0),(W, HUDH)), panel);
	scr.text(4, 2, "you", phud);
	bar(4, 12, myhealth * 100 / mymax, barlo);
	scr.text(W-4-8*4, 2, "them", phud);
	bar(W-4-100, 12, them.health * 100 / them.maxhealth, barhi);
	nm := them.name;
	if(len nm > 12)
		nm = nm[0:12];
	scr.text(W/2 - 4*len nm, 2, nm, phud);

	if(msgt > 0 && msg != ""){
		p := phud;
		if(msg == "hit")
			p = pwarn;
		else if(msg == "in!")
			p = pgood;
		m := msg;
		if(len m > 18)
			m = m[0:18];
		scr.text(4, H - 14, m, p);
	}
	# The tell, in words as well as in the pose: a tell nobody can see
	# is not a tell.
	if(them.tell >= 0)
		scr.text(W - 4 - 8*4, H - 14, sidename(them.tell), ptell);
	g := "high";
	if(myguard == LOW)
		g = "low";
	scr.text(W/2 - 16, H - 14, g, phud);
	if(won)
		scr.text(W/2 - 20, H - 28, "down!", pgood);
	if(lost)
		scr.text(W/2 - 24, H - 28, "beaten", pwarn);
}

bar(x, y, v, c: int)
{
	if(v < 0)
		v = 0;
	if(v > 100)
		v = 100;
	scr.fill(Rect((x, y), (x+100, y+6)), tiles->entry(Tiles->DARK, Tiles->GREY));
	if(v > 0)
		scr.fill(Rect((x, y), (x+v, y+6)), c);
}

play()
{
	ticks := chan of int;
	spawn fclock->ticker(ticks, 60);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
	k := <-win.ctxt.kbd =>
		if(k == 16r1b || k == 'q' || k == 'Q'){
			if(tone != nil)
				tone->stop();
			exit;
		}
		if(k == '\n'){
			if(won){
				which++;
				startbout();
				continue;
			}
			if(lost){
				startbout();
				continue;
			}
		}
		pad = kb.key(pad, k);
	<-ticks =>
		step();
		draw1();
		win.image.draw(win.image.r, scr.img, nil, scr.img.r.min);
		win.image.flush(Draw->Flushnow);
	}
}

shot()
{
	audio = 0;
	for(i := 0; i < 400; i++){
		pad = play1();
		step();
		draw1();
	}
	w := scr.img.r.dx();
	h := scr.img.r.dy();
	b := array[w*h*3] of byte;
	if(scr.img.readpixels(scr.img.r, b) < 0){
		sys->print("readpixels: %r\n");
		return;
	}
	fd := sys->create("bout.raw", Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->print("create: %r\n");
		return;
	}
	sys->write(fd, b, len b);
	sys->print("wrote bout.raw %dx%d bgr\n", w, h);
}

# A player who reads the tell: guard the side shown, close when they are
# open and hit them, stay out of reach otherwise.  The self test uses
# this to check a bout can be won at all.
play1(): int
{
	p := 0;
	if(them.tell == HIGH)
		p |= KUP;
	else if(them.tell == LOW)
		p |= KDOWN;
	if(them.open){
		if(mydist > them.reach - 12)
			p |= KRIGHT;
		else if(myrecover == 0)
			p |= KA;
	}else if(them.tell >= 0){
		if(mydist <= them.reach)
			p |= KLEFT;
	}
	return p;
}

nfail := 0;

ck(what: string, got, want: int)
{
	if(got == want){
		sys->print("ok   %s = %d\n", what, got);
		return;
	}
	sys->print("FAIL %s = %d, want %d\n", what, got, want);
	nfail++;
}

cktrue(what: string, v: int)
{
	if(v){
		sys->print("ok   %s\n", what);
		return;
	}
	sys->print("FAIL %s\n", what);
	nfail++;
}

run(n, held: int)
{
	for(i := 0; i < n; i++){
		pad = held;
		step();
		draw1();
	}
}

boxsum(r: Rect): int
{
	o := scr.img.r.min;
	q := Rect((o.x + r.min.x*SCALE, o.y + r.min.y*SCALE),
		(o.x + r.max.x*SCALE, o.y + r.max.y*SCALE));
	(cq, inside) := q.clip(scr.img.r);
	if(!inside)
		return -1;
	b := array[cq.dx()*cq.dy()*3] of byte;
	if(scr.img.readpixels(cq, b) < 0)
		return -1;
	sum := 0;
	for(i := 0; i < len b; i += 3)
		sum = (sum * 31 + int b[i]) & 16r3FFFFFFF;
	return sum;
}

badfile(text: string): string
{
	p := "bout-selftest.bout";
	fd := sys->create(p, Sys->OWRITE, 8r666);
	if(fd == nil)
		return nil;
	b := array of byte text;
	sys->write(fd, b, len b);
	return p;
}

refused(what, text: string)
{
	p := badfile(text);
	if(p == nil){
		sys->print("FAIL %s (could not write the file)\n", what);
		nfail++;
		return;
	}
	(f, e) := readbout(p);
	sys->remove(p);
	if(f == nil && e != nil){
		sys->print("ok   %s\n", what);
		return;
	}
	sys->print("FAIL %s was accepted\n", what);
	nfail++;
}

HEAD:	con "name X\nhealth 5\nreach 40\n%\n";

selftest()
{
	sys->print("bout: self test\n");
	audio = 0;

	# --- the opponents are files, and the directory is the list ---
	cktrue("there are opponents in the directory", len files >= 3);
	allok := 1;
	for(i := 0; i < len files; i++){
		(f, e) := readbout(files[i]);
		if(f == nil){
			sys->print("FAIL %s\n", e);
			allok = 0;
			nfail++;
			continue;
		}
		sys->print("\t%-26s %-10s %2d health, reach %2d, %d states\n",
			files[i], f.name, f.maxhealth, f.reach, f.ns);
	}
	cktrue("and every one of them reads", allok);
	(a, nil) := readbout(files[0]);
	(b, nil) := readbout(files[1]);
	if(a != nil && b != nil)
		cktrue("and they are not all the same fighter",
			a.name != b.name || a.maxhealth != b.maxhealth);

	# --- the checker says what is wrong ---
	refused("a file with no name", "health 5\nreach 40\n%\nstate s\n\twait 1\n");
	refused("a file with no states", "name X\nhealth 5\nreach 40\n%\n");
	refused("an empty state", HEAD + "state s\n");
	refused("a setting that does not exist",
		"name X\nhat 3\nreach 40\n%\nstate s\n\twait 1\n");
	refused("an instruction that does not exist", HEAD + "state s\n\tdance 4\n");
	refused("a tell that is neither high nor low",
		HEAD + "state s\n\ttell sideways 10\n");
	refused("a number that is not one", HEAD + "state s\n\twait ten\n");
	refused("a goto with nowhere to go", HEAD + "state s\n\tgoto elsewhere\n");
	refused("a hurt with nowhere to go",
		HEAD + "state s\n\thurt nowhere\n\twait 3\n");
	refused("two states of the same name",
		HEAD + "state s\n\twait 1\nstate s\n\twait 1\n");
	refused("an instruction before any state",
		"name X\nhealth 5\nreach 40\n%\n\twait 3\n");
	refused("a strike that does nothing", HEAD + "state s\n\tstrike high 0\n");
	refused("a reach too short to fight at",
		"name X\nhealth 5\nreach 2\n%\nstate s\n\twait 1\n");
	# The control for all of those: a file that is RIGHT is accepted.
	p := badfile(HEAD + "state s\n\thurt s\n\twait 4\n\ttell high 6\n" +
		"\tstrike high 2\n\trecover 8\n\tgoto s\n");
	(gf, ge) := readbout(p);
	sys->remove(p);
	cktrue("and a file that is right is accepted", gf != nil && ge == nil);

	# --- the program runs, and tells before it strikes ---
	which = 0;
	cktrue("the first opponent starts", startbout());
	ck("and is at the start of its first state", them.pc, 0);
	saw := -1;
	tellframes := 0;
	struck := 0;
	mydist = MINDIST;
	h0 := myhealth;
	for(i = 0; i < 400; i++){
		run(1, 0);
		if(them.tell >= 0){
			saw = them.tell;
			tellframes++;
		}
		if(myhealth < h0){
			struck = 1;
			break;
		}
	}
	cktrue("it tells before it strikes", saw >= 0);
	cktrue("and the tell lasts a while", tellframes > 8);
	cktrue("and then it strikes", struck);

	# --- guarding the told side works; guarding the other does not ---
	# The measure is surviving, not a ratio.  A ratio was the first
	# attempt and it failed on the opponent that is alphabetically
	# first, because that one lies about its tell once on purpose -
	# which is the point of it, and not something a test should be
	# tuned around.
	(guarded, glost) := hitstaken(1);
	(wrong, wlost) := hitstaken(0);
	sys->print("\tguarding right cost %d, guarding wrong cost %d\n", guarded, wrong);
	cktrue("guarding the side they tell costs less", guarded < wrong);
	cktrue("and you are still standing", glost == 0);
	cktrue("guarding the other side loses", wlost != 0);

	# --- out of reach, nothing lands ---
	which = 0;
	startbout();
	mydist = MAXDIST;
	h0 = myhealth;
	for(i = 0; i < 600; i++)
		run(1, KLEFT);
	ck("out of reach, nothing lands", myhealth, h0);

	# --- a counter lands hard only while they are open ---
	which = 0;
	startbout();
	mydist = MINDIST;
	opened := 0;
	for(i = 0; i < 600; i++){
		if(them.open){
			opened = 1;
			break;
		}
		run(1, 0);
	}
	cktrue("they are open at some point", opened);
	if(opened){
		t0 := them.health;
		myrecover = 0;
		run(1, KA);
		cktrue("and a blow then lands hard", them.health <= t0 - 3);
		for(i = 0; i < 600 && them.open && !won; i++)
			run(1, 0);
		t1 := them.health;
		myrecover = 0;
		run(1, KA);
		cktrue("and is turned when they are not", them.health > t1 - 3);
	}

	# --- every one of them can be beaten by reading the tells ---
	for(k := 0; k < len files; k++){
		which = k;
		startbout();
		nm := them.name;
		got := fight(1);
		cktrue("this one can be beaten: " + nm, got);
	}
	# The negative control: the same fight, doing nothing.  If this ever
	# passes, none of the above is testing anything.
	which = 0;
	startbout();
	# In reach, and not reacting.  Started out of reach - which is where
	# a bout begins - nothing lands at all, so the fight neither is won
	# nor lost and "standing still loses" was false for a reason that
	# had nothing to do with the rules.
	mydist = MINDIST;
	idle := fight(0);
	ck("and not one of them by standing still", idle, 0);
	cktrue("standing still in reach loses", lost != 0);

	# --- drawing ---
	which = 0;
	startbout();
	run(20, 0);
	box := Rect((0, HUDH), (W, H - 20));
	nofolk = 0;
	draw1();
	with := boxsum(box);
	nofolk = 1;
	draw1();
	without := boxsum(box);
	nofolk = 0;
	cktrue("the frame could be read back", with >= 0 && without >= 0);
	cktrue("the duellists are drawn", with != without);
	# The pose changes with what they are doing: it is the only thing
	# telling the player anything, and a state check cannot see it.
	p1 := -1;
	p2 := -1;
	for(i = 0; i < 400; i++){
		run(1, 0);
		if(them.tell >= 0 && p1 < 0){
			draw1();
			p1 = boxsum(box);
		}else if(them.tell < 0 && p1 >= 0){
			draw1();
			p2 = boxsum(box);
			break;
		}
	}
	cktrue("and the picture changes when the tell does",
		p1 >= 0 && p2 >= 0 && p1 != p2);

	if(nfail == 0)
		sys->print("bout: PASSED\n");
	else{
		sys->print("bout: FAILED (%d)\n", nfail);
		raise "fail:test";
	}
}

# Stand in reach and take a beating, guarding either the side they tell
# or the other one.  Returns the damage taken and whether it was fatal.
hitstaken(right: int): (int, int)
{
	which = 0;
	startbout();
	mydist = MINDIST;
	dmg := 0;
	for(i := 0; i < 600; i++){
		p := KUP;
		if(right){
			if(them.tell == LOW)
				p = KDOWN;
			else if(them.tell == HIGH)
				p = KUP;
		}else{
			if(them.tell == HIGH)
				p = KDOWN;
			else
				p = KUP;
		}
		hb := myhealth;
		run(1, p);
		if(myhealth < hb)
			dmg += hb - myhealth;
		if(lost)
			break;
	}
	return (dmg, lost);
}

# Fight the current opponent, reading the tells or not.  Returns whether
# it was won.
fight(read: int): int
{
	for(i := 0; i < 20000; i++){
		p := 0;
		if(read)
			p = play1();
		pad = p;
		step();
		if(won)
			return 1;
		if(lost)
			return 0;
	}
	return 0;
}
