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

mods := array[] of {
	"asciiorgan", "battlelines", "bigguns", "blackdiamond", "bombergolf",
	"bounce", "box", "budget", "cartesian", "castlefrankenstein",
	"chardemo", "circletrace", "collision", "digits", "doodle",
	"population", "ecology", "periodicvolterra", "predatorfishing",
	"logisticprey", "logisticpredators", "alternativepredation", "maypredator",
	"internalcompetition", "cooperation",
	"childcare",
	"manyspecies",
	"violetsantsrodents", "parasite", "cannibalism",
	"changingenvironment", "lakepollution", "budworm",
	"epidemic", "tennis", "orbit", "modeling", "stability",
	"chaosintro", "chaosdynamics", "chaos", "chaosmap",
	"diseasebirthdeath1", "diseasebirthdeath2",
	"crossinfection", "incubation", "seasonaldisease", "malaria",
	"gonorrhea", "hiv", "weightchange",
	"heartbeat",
	"lanchester", "fishingone",
	"productionexchange", "fishingtwo", "twocapital",
	"spinningball",
	"baseballpitch", "knuckleball", "flyball", "softballpitch", "golfdrive",
	"soccerkick", "cricketbowl", "cricketswing",
	"badminton", "tabletennis", "basketball", "badfootball", "discus", "javelin",
	"skijump",
	"running", "diving", "polevault",
	"flight", "hovercraft", "shipmotion", "balloon",
	"joggingcompanion", "bungee", "yoyo", "amusementchaos", "spacestationball",
	"fireworks",
	"threebody", "moontrip", "lagrange1", "lagrange2",
	"skylab", "icbmrange", "icbmaccuracy", "aerobraking",
	"rocketintro", "multistagerocket",
	"rocket2d", "lowthrust", "reentry", "spaceyoyo", "stretchyoyo",
	"cometcatch", "jupiterboost", "grandtour",
	"perihelion", "poyntingrobertson", "galaxies", "venushead",
	"heliumburning", "starmodel", "whitedwarf",
	"simplependulum", "pendulumperiod", "dampedpendulum", "drypendulum",
	"clockpendulum", "windpendulum", "loadedpendulum", "synchronousmotor",
	"gravitypendulum", "magneticpendulum2d", "swing1", "swing2",
	"varyingpendulum", "swingingcenser", "movingpivot", "pegpendulum",
	"slidingpendulum1", "slidingpendulum2", "atwoodpendulum", "tablependulum",
	"doublependulum", "wheelpendulum", "magneticpendulum3d", "dumbbellsatellite",
	"moonrotation", "hyperionrotation", "mercuryrotation", "tidalrotation",
	"nonlinearsprings", "duffing", "vanderpol", "variationparameters",
	"columnbuckling", "catastrophemachine", "attractingwires", "violinbow",
	"carrierlanding", "springpivot", "springpendulum", "chaoticwheel",
	"decomposition", "enzymekinetics", "enzymeapplication", "moreenzyme", "stillmoreenzyme",
	"brusselator", "oregonator", "reactorstability", "tankcontrol", "reservoir",
	"fireflies", "pursuit", "lowbombing", "carbonmicrophone",
	"rotatingring1", "rotatingring2", "compass", "pistonflywheel",
	"wattgovernor", "dynamoreversal", "twomagnet", "bernoulli",
	"euler", "truncation", "methodorder", "eulerorder", "heun", "rungekutta", "stepsize", "rkf45",
	"odesystems", "rkf45scalar", "rkf45system", "solverdebug", "solverrun",
	"meaning", "instructions", "solutions", "existence", "chapter1assignments",
	"harvest", "competition", "foodchain", "forcedpendulum", "migration", "methods", "sirs", "vaccination",
	"strains", "drug", "price", "firms", "boom", "arms",
	"danbytest", "dungen", "elephantwalk", "flapbat", "flattops", "fonted",
	"god", "grmodels", "halogen", "hanoi", "keepaway",
	"life", "lines", "logic", "massspring", "maze", "numericstest",
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
	for(i := 0; i < len mods; i++){
		if(!wanted(mods[i],argv))
			continue;
		total++;
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
