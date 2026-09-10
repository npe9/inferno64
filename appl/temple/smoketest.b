implement Smoketest;

# Load every appl/temple and appl/danby module as Command; optionally spawn
# init briefly.
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

include "plot.m";
	plot: Plot;
	Plotter: import plot;

Command: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

Smoketest: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

# appl/temple/*.b, installed by appl/temple/mkfile into /dis/temple.
tmods := array[] of {
	"3dpoly", "arms", "asciiorgan", "balloon", "battlelines",
	"bigguns", "blackdiamond", "blot", "bombergolf", "bounce",
	"box", "bspline", "budget", "cartesian", "castlefrankenstein",
	"chaosdynamics", "chaosintro", "chapter1assignments", "charanimation", "chardemo",
	"circletrace", "collision", "commonancestor", "danbytest", "delab",
	"digits", "doodle", "drug", "dungen", "edsprite",
	"elephant", "elephantwalk", "euler", "eulerorder", "existence",
	"extents", "firms", "flapbat", "flattops",
	"fonted", "god", "griddemo", "grmodels", "halogen",
	"hanoi", "harvest", "heun", "instructions", "keepaway",
	"lattice", "life", "lighttable", "lines", "logic",
	"lowpassfilter", "massspring", "mathaudiodemo", "maze", "meaning",
	"methodorder", "methods", "modeling", "morsecode",
	"mousedemo", "netofdots", "numericstest", "odesystems", "ohgreat",
	"orbit", "palette", "pantext", "pdelab",
	"pick", "pick3d", "polezeros", "population",
	"predatorprey", "price", "psalmody", "raindrops",
	"rawhide", "rkf45", "rkf45scalar", "rkf45system", "rocket",
	"rocketscience", "ropcollision", "rotatetank", "rungekutta", "scrncapture",
	"scrollbars", "shading", "shadow", "sirs", "slider",
	"solutions", "solverdebug", "solverlab", "solverrun", "span",
	"speedline", "spriteedit", "spriteplot", "spriteplot3d", "spriteput",
	"spriteputext", "spriteraw", "spritetext", "squirt", "stability",
	"stadium", "stepsize", "strains", "strut", "sunmoon",
	"symmetry", "talons", "tennis", "thedead", "tictactoe",
	"timeclock", "titanium", "tothefront", "transform",
	"treecheckers", "truncation", "varoom", "vocabulary", "wallpaperctrl",
	"wallpaperfish", "waterfowl", "wenceslas", "whap", "winzbuf",
	"xcaliber", "zing", "zoneout"
};

# appl/danby/*.b, installed by appl/danby/mkfile into /dis/danby — a
# separate DISBIN, so these must NOT be looked for under /dis/temple.
# The eleven that are model libraries rather than Commands (atmosphere,
# ballistics, cartpendulum, doublependulumlib, gravity, oscillator, pendulum,
# propulsion, reaction, rotatinghoop, spinorbit) have no init(ctxt, argv) and
# are left out: "load Command" on one is a link typecheck failure, not a bug.
dmods := array[] of {
	"aerobraking", "alternativepredation", "amusementchaos", "attractingwires", "atwoodpendulum",
	"badfootball", "badminton", "balloon", "baseballpitch", "basketball",
	"bernoulli", "boom", "brusselator", "budworm", "bungee",
	"cannibalism", "carbonmicrophone", "carrierlanding", "catastrophemachine", "changingenvironment",
	"chaosmap", "chaoticwheel", "childcare", "clockpendulum", "columnbuckling",
	"cometcatch", "compass", "competition", "cooperation", "cricketbowl",
	"cricketswing", "crossinfection", "dampedpendulum", "decomposition", "discus",
	"diseasebirthdeath1", "diseasebirthdeath2", "diving", "doublependulum", "drypendulum",
	"duffing", "dumbbellsatellite", "dynamoreversal", "ecology", "enzymeapplication",
	"enzymekinetics", "epidemic", "fireflies", "fireworks", "fishingone",
	"fishingtwo", "flight", "flyball", "foodchain", "forcedpendulum",
	"galaxies", "golfdrive", "gonorrhea", "grandtour", "gravitypendulum",
	"heartbeat", "heliumburning", "hiv", "hovercraft", "hyperionrotation",
	"icbmaccuracy", "icbmrange", "incubation", "internalcompetition", "javelin",
	"joggingcompanion", "jupiterboost", "knuckleball", "lagrange1", "lagrange2",
	"lakepollution", "lanchester", "limitstogrowth", "loadedpendulum", "logisticpredators",
	"logisticprey", "lorenz", "lowbombing", "lowthrust", "magneticpendulum2d",
	"magneticpendulum3d", "malaria", "manyspecies", "maypredator", "mercuryrotation",
	"migration", "moonrotation", "moontrip", "moreenzyme", "movingpivot",
	"multistagerocket", "nonlinearsprings", "oregonator", "parasite", "pegpendulum",
	"pendulumperiod", "perihelion", "periodicvolterra", "pistonflywheel", "polevault",
	"poyntingrobertson", "predatorfishing", "productionexchange", "projectile", "pursuit", "reactorstability",
	"reentry", "reservoir", "rocket2d", "rocketintro", "rotatingring1",
	"rotatingring2", "running", "schrodinger", "seasonaldisease", "shipmotion",
	"simplependulum",
	"skijump", "skylab", "slidingpendulum1", "slidingpendulum2", "soccerkick",
	"softballpitch", "spacestationball", "spaceyoyo", "spinningball", "springpendulum",
	"springpivot", "stability", "starmodel", "stillmoreenzyme", "stretchyoyo",
	"swing1", "swing2", "swingingcenser", "synchronousmotor", "tablependulum",
	"tabletennis", "tankcontrol", "threebody", "tidalrotation", "twocapital",
	"twomagnet", "vaccination", "vanderpol", "variationparameters", "varyingpendulum",
	"venushead", "violetsantsrodents", "violinbow", "wattgovernor", "weightchange",
	"wheelpendulum", "whitedwarf", "windpendulum", "yoyo"
};

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	plot = load Plot Plot->PATH;
	if(plot == nil){
		sys->print("FAIL load plot module: %r\n");
		raise "fail:plot";
	}
	plotchanneltest();

	dorun := 0;
	for(a := argv; a != nil; a = tl a)
		if(hd a == "run")
			dorun = 1;

	sys->print("smoke: probing numerical and plotting libraries\n");
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
	plotlibs := array[] of {"plot"};
	for(pi := 0; pi < len plotlibs; pi++){
		path := "/dis/lib/"+plotlibs[pi]+".dis";
		fd := sys->open(path, Sys->OREAD);
		if(fd == nil)
			sys->print("FAIL lib %s open: %r\n", plotlibs[pi]);
		else
			sys->print("OK   lib %s.dis\n", plotlibs[pi]);
	}

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
	total := 0;
	# Two DISBINs: appl/temple installs into /dis/temple, appl/danby into
	# /dis/danby.  Looking for both under /dis/temple used to "pass" only
	# because stale copies of the danby models were left there by an older
	# layout; a clean tree would have failed 155 of them.
	for(pass := 0; pass < 2; pass++){
		dir := "/dis/temple/";
		mods := tmods;
		if(pass){
			dir = "/dis/danby/";
			mods = dmods;
		}
		for(i := 0; i < len mods; i++){
			if(!wanted(mods[i],argv))
				continue;
			total++;
			path := dir + mods[i] + ".dis";
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
				outcome := chan of int;
				spawn runone(c, ctxt, mods[i], pidc, outcome);
				pid := <-pidc;
				deadline := chan of int;
				spawn delay(deadline,350);
				alt {
				failed := <-outcome =>
					if(failed){
						ok--;
						bad++;
					}
				<-deadline =>
					# A healthy graphical command remains in its event loop.
					fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
					if(fd != nil)
						sys->fprint(fd, "killgrp");
				}
				sys->sleep(50);
			}
		}
	}
	mode := " [load]";
	if(dorun)
		mode = " [run]";
	sys->print("smoke: %d ok, %d fail (of %d)%s\n", ok, bad, total, mode);
	if(bad)
		raise "fail:smoke";
}

wanted(name: string, argv: list of string): int
{
	hasfilter := 0;
	# The first argument is the command name, not a filter.
	for(arguments := tl argv; arguments != nil; arguments = tl arguments){
		argument := hd arguments;
		if(argument == "run")
			continue;
		hasfilter = 1;
		if(argument == name)
			return 1;
	}
	return !hasfilter;
}

plotchanneltest()
{
	p := plot->new(nil,nil);
	error := p.cmd("table samples time value -capacity 8");
	if(error != nil){
		sys->print("FAIL plot table command: %s\n",error);
		raise "fail:plot table";
	}
	commands := plot->run(p);
	reply := chan of string;
	commands <-= ref Plot->Plotmsg(
		"samples append 0 1  1 2  2 3",
		reply);
	error = <-reply;
	if(error != nil || p.rows("samples") != 3){
		sys->print("FAIL plot channel batch: %s, %d rows\n",
			error,p.rows("samples"));
		raise "fail:plot batch";
	}
	commands <-= ref Plot->Plotmsg("samples append 4",reply);
	error = <-reply;
	if(error == nil){
		sys->print("FAIL plot channel accepted an incomplete row\n");
		raise "fail:plot arity";
	}
	value := 0.0;
	(value, error) = p.value("samples",2,"value");
	if(error != nil || value != 3.0){
		sys->print("FAIL plot channel value: %s, %.17g\n",error,value);
		raise "fail:plot value";
	}
	sys->print("OK   plot channel batches and replies\n");
}

runone(c: Command, ctxt: ref Context, name: string,
		pidc, outcome: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	{
		c->init(ctxt, name :: nil);
		outcome <-= 0;
	} exception e {
	"*" =>
		sys->print("FAIL init %s: %s\n", name, e);
		outcome <-= 1;
	}
}

delay(done: chan of int, milliseconds: int)
{
	sys->sleep(milliseconds);
	done <-= 1;
}
