implement Smoketest;

# Load every temple/*.dis as Command; optionally spawn init briefly.
# Usage: temple/smoketest           — load-only
#        temple/smoketest run       — load + 300ms init under wmclient context

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;

Command: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Smoketest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

mods := array[] of {
	"asciiorgan", "battlelines", "bigguns", "blackdiamond", "bombergolf",
	"bounce", "box", "budget", "cartesian", "castlefrankenstein",
	"chardemo", "circletrace", "collision", "digits", "doodle",
	"population", "ecology", "epidemic", "tennis", "orbit", "chaos",
	"harvest", "competition", "foodchain", "migration", "sirs", "vaccination",
	"strains", "drug", "price", "firms", "boom", "arms",
	"dungen", "elephantwalk", "flapbat", "flattops", "fonted",
	"god", "grmodels", "halogen", "hanoi", "keepaway",
	"life", "lines", "logic", "massspring", "maze",
	"netofdots", "ohgreat", "pdelab", "psalmody", "raindrops", "rawhide",
	"rocket", "rocketscience", "span", "squirt", "stadium",
	"strut", "symmetry", "talons", "thedead", "tictactoe",
	"timeclock", "titanium", "tothefront", "treecheckers", "varoom",
	"vocabulary", "wenceslas", "whap", "xcaliber", "zing",
	"zoneout"
};

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;

	dorun := 0;
	for(a := argv; a != nil; a = tl a)
		if(hd a == "run")
			dorun = 1;

	sys->print("smoke: probing /dis/lib/ode.dis, pde.dis, numerics.dis and tone.dis\n");
	ofd := sys->open("/dis/lib/ode.dis", Sys->OREAD);
	if(ofd == nil)
		sys->print("FAIL lib ode open: %r\n");
	else
		sys->print("OK   lib ode.dis\n");
	pfd := sys->open("/dis/lib/pde.dis", Sys->OREAD);
	if(pfd == nil)
		sys->print("FAIL lib pde open: %r\n");
	else
		sys->print("OK   lib pde.dis\n");
	nfd := sys->open("/dis/lib/numerics.dis", Sys->OREAD);
	if(nfd == nil){
		sys->print("FAIL lib numerics open: %r\n");
	}else
		sys->print("OK   lib numerics.dis\n");
	tfd := sys->open("/dis/lib/tone.dis", Sys->OREAD);
	if(tfd == nil)
		sys->print("FAIL lib tone open: %r\n");
	else
		sys->print("OK   lib tone.dis\n");

	if(dorun){
		if(wmclient == nil){
			sys->print("FAIL cannot load wmclient for run mode\n");
			raise "fail:wmclient";
		}
		wmclient->init();
		if(ctxt == nil)
			ctxt = wmclient->makedrawcontext();
	}

	ok := 0;
	bad := 0;
	for(i := 0; i < len mods; i++){
		path := "/dis/temple/" + mods[i] + ".dis";
		c := load Command path;
		if(c == nil){
			sys->print("FAIL load %s: %r\n", mods[i]);
			bad++;
			continue;
		}
		sys->print("OK   load %s\n", mods[i]);
		ok++;
		if(dorun){
			pidc := chan of int;
			spawn runone(c, ctxt, mods[i], pidc);
			pid := <-pidc;
			sys->sleep(350);
			# kill the spawned process group member
			fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
			if(fd != nil)
				sys->fprint(fd, "killgrp");
			sys->sleep(50);
		}
	}
	mode := " [load]";
	if(dorun)
		mode = " [run]";
	sys->print("smoke: %d ok, %d fail (of %d)%s\n", ok, bad, len mods, mode);
	if(bad)
		raise "fail:smoke";
}

runone(c: Command, ctxt: ref Context, name: string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	{
		c->init(ctxt, name :: nil);
	} exception e {
	"*" =>
		sys->print("FAIL init %s: %s\n", name, e);
	}
}
