implement Danbytest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "numerics.m";
	numerics: Numerics;
include "math.m";
	math: Math;
include "danby/chaosmap.m";
	chaosmap: Chaosmap;
include "danby/forcedpendulum.m";
	forcedpendulum: Forcedpendulum;
	Model: import forcedpendulum;
include "danby/lorenz.m";
	lorenz: Lorenz;
include "danby/twospecies.m";
include "danby/populationmodel.m";
	epidemicmodel: Populationmodel;
	vaccinationmodel: Populationmodel;
	heartbeat: Populationmodel;
	boommodel: Populationmodel;
include "danby/trajectory.m";
include "danby/flight3d.m";
	soccerkick: Flight3d;
	cricketbowl: Flight3d;
	cricketswing: Flight3d;
	badfootball: Flight3d;
	icbmaccuracy: Flight3d;
include "danby/mechanism.m";
include "danby/orbital.m";
include "danby/profile.m";
	starmodel: Profile;
	whitedwarf: Profile;

Danbytest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

pendulum: ref Model;
lorenzmodel: ref Lorenz->Model;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	numerics = load Numerics Numerics->PATH;
	math = load Math Math->PATH;
	chaosmap = load Chaosmap Chaosmap->PATH;
	forcedpendulum = load Forcedpendulum Forcedpendulum->PATH;
	lorenz = load Lorenz Lorenz->PATH;
	# ecology is the shared Twospecies viewer, so it deliberately does NOT
	# implement Twospecies (fb1504e0): a module that implements an interface
	# links its loads of that interface against its own function set.  Its
	# own Lotka-Volterra pair is written out in appl/danby/ecology.b and is
	# not reachable as a module, so there is nothing to check here.
	epidemicmodel = load Populationmodel "/dis/danby/epidemic.dis";
	vaccinationmodel = load Populationmodel "/dis/danby/vaccination.dis";
	heartbeat = load Populationmodel "/dis/danby/heartbeat.dis";
	boommodel = load Populationmodel "/dis/danby/boom.dis";
	soccerkick = load Flight3d "/dis/danby/soccerkick.dis";
	cricketbowl = load Flight3d "/dis/danby/cricketbowl.dis";
	cricketswing = load Flight3d "/dis/danby/cricketswing.dis";
	badfootball = load Flight3d "/dis/danby/badfootball.dis";
	icbmaccuracy = load Flight3d "/dis/danby/icbmaccuracy.dis";
	# slidingpendulum1 is now a mechlab(2) script rather than a Mechanism
	# module - mechlabtest(1) checks it, including the momentum law that
	# used to be checked here.
	# aerobraking is no longer an Orbital plugin: d4f6aaf2 made it a
	# standalone command with its own equations, so there is nothing here
	# to load as one.  This line loaded /dis/danby/plugin/aerobraking.dis,
	# which that commit stopped building - the test has been dead since.
	starmodel = load Profile "/dis/danby/starmodel.dis";
	whitedwarf = load Profile "/dis/danby/whitedwarf.dis";
	if(
			numerics == nil || math == nil || chaosmap == nil ||
			forcedpendulum == nil || lorenz == nil || epidemicmodel == nil ||
			vaccinationmodel == nil || heartbeat == nil || boommodel == nil ||
			soccerkick == nil || cricketbowl == nil || cricketswing == nil ||
			badfootball == nil || icbmaccuracy == nil || starmodel == nil ||
			whitedwarf == nil)
		raise "fail:danbytest: missing module";
	testmap();
	testpendulum();
	testlorenz();
	testpopulations();
	sys->print("OK   Danby model modules\n");
}

testpopulations()
{
	# childcare's own metadata and empty-population checks moved to
	# poplabtest(1) with the model.
	# lakepollution's steady state moved to poplabtest(1).
	testepidemics();
	testvitaldisease();
	testextendedepidemics();
	testhealthmodels();
	testcompetitioneconomics();
	testtrajectory();
}

testtrajectory()
{
	# every vacuum and kinematics check for this family moved to
	# trajlabtest(1) with the models.
	checkvacuumflight3d(soccerkick,"soccer kick");
	checkvacuumflight3d(cricketbowl,"cricket bowl");
	checkvacuumflight3d(cricketswing,"cricket swing");
	checkvacuumflight3d(badfootball,"bad football");
	checkflight3dfinite(icbmaccuracy,"ICBM accuracy");
	checkprofile(starmodel,"stellar model");
	checkprofile(whitedwarf,"white dwarf");
	# running's and diving's own property checks moved to mechlabtest(1)
	# with the models themselves.
}

checkprofile(profilemodule: Profile, name: string)
{
	model := profilemodule->new();
	labels := profilemodule->parameterlabels();
	minima := profilemodule->parameterminima();
	maxima := profilemodule->parametermaxima();
	if(len labels != len model.parameter || len minima != len model.parameter ||
			len maxima != len model.parameter)
		fail(name+" parameter metadata",real len labels,real len model.parameter);
	data := profilemodule->profile(model,64);
	if(len data != 192)
		fail(name+" profile size",real len data,192.0);
	previousradius := -1.0;
	for(i := 0; i < 64; i++){
		radius := data[3*i];
		first := data[3*i+1];
		second := data[3*i+2];
		if(radius <= previousradius)
			fail(name+" increasing radius",radius,previousradius);
		if(first != first || second != second || first < 0.0 || second < 0.0)
			fail(name+" finite nonnegative profile",first,second);
		previousradius = radius;
	}
	if(len profilemodule->fieldlabels() != 2)
		fail(name+" field metadata",real len profilemodule->fieldlabels(),2.0);
}


checkmechanism(mechanism: Mechanism, name: string)
{
	model := mechanism->new();
	labels := mechanism->parameterlabels();
	minima := mechanism->parameterminima();
	maxima := mechanism->parametermaxima();
	if(len labels != len model.parameter || len minima != len model.parameter ||
			len maxima != len model.parameter)
		fail(name+" parameter metadata",real len labels,real len model.parameter);
	for(i := 0; i < len minima; i++)
		if(minima[i] >= maxima[i])
			fail(name+" parameter range",minima[i],maxima[i]);
	state := mechanism->initialstate(model);
	derivative := array[len state] of real;
	mechanism->evaluate(model,0.0,state,derivative);
	for(i = 0; i < len derivative; i++)
		if(derivative[i] != derivative[i])
			fail(name+" finite derivative",derivative[i],0.0);
	points := mechanism->geometry(model,state);
	links := mechanism->links();
	if(len points == 0 || len points%2 != 0 || len links%2 != 0)
		fail(name+" geometry",real len points,2.0);
	for(i = 0; i < len links; i++)
		if(links[i] < 0 || links[i] >= len points/2)
			fail(name+" link index",real links[i],real(len points/2-1));
	observations := mechanism->observables(model,state);
	if(len observations != 2 || len mechanism->observablelabels() != 2)
		fail(name+" observables",real len observations,2.0);
	if(mechanism->maxtime(model) <= 0.0)
		fail(name+" observation time",mechanism->maxtime(model),1.0);
}

checkvacuumflight3d(flight: Flight3d, name: string)
{
	model := flight->new();
	labels := flight->parameterlabels();
	minima := flight->parameterminima();
	ranges := flight->parameterranges();
	if(len model.parameter != 6 || len labels != 6 || len minima != 6 ||
			len ranges != 6)
		fail(name+" metadata",real len model.parameter,6.0);
	for(i := 0; i < len minima; i++)
		if(minima[i] >= ranges[i])
			fail(name+" parameter range",minima[i],ranges[i]);
	model.parameter[3] = 0.0;
	model.parameter[4] = 0.0;
	state := flight->initialstate(model);
	if(len state != 6)
		fail(name+" state size",real len state,6.0);
	derivative := array[] of {0.0,0.0,0.0,0.0,0.0,0.0};
	flight->evaluate(model,0.0,state,derivative);
	check(name+" kinematics x",derivative[0],state[3],0.0);
	check(name+" kinematics y",derivative[1],state[4],0.0);
	check(name+" kinematics z",derivative[2],state[5],0.0);
	check(name+" vacuum downrange acceleration",derivative[3],0.0,1.0e-13);
	check(name+" vacuum lateral acceleration",derivative[4],0.0,1.0e-13);
	check(name+" vacuum vertical acceleration",derivative[5],
		-model.parameter[5],1.0e-13);
	if(flight->maxtime(model) <= 0.0)
		fail(name+" observation time",flight->maxtime(model),1.0);
}

checktrajectoryfinite(trajectory: Trajectory, name: string)
{
	model := trajectory->new();
	state := trajectory->initialstate(model);
	if(len state != 4)
		fail(name+" state size",real len state,4.0);
	derivative := array[len state] of real;
	trajectory->evaluate(model,0.0,state,derivative);
	for(i := 0; i < len derivative; i++)
		if(derivative[i] != derivative[i])
			fail(name+" finite derivative",derivative[i],0.0);
	check(name+" kinematics x",derivative[0],state[2],0.0);
	check(name+" kinematics y",derivative[1],state[3],0.0);
}

checkflight3dfinite(flight: Flight3d, name: string)
{
	model := flight->new();
	state := flight->initialstate(model);
	if(len state != 6)
		fail(name+" state size",real len state,6.0);
	derivative := array[len state] of real;
	flight->evaluate(model,0.0,state,derivative);
	for(i := 0; i < len derivative; i++)
		if(derivative[i] != derivative[i])
			fail(name+" finite derivative",derivative[i],0.0);
	check(name+" kinematics x",derivative[0],state[3],0.0);
	check(name+" kinematics y",derivative[1],state[4],0.0);
	check(name+" kinematics z",derivative[2],state[5],0.0);
}

checkvacuumtrajectory(trajectory: Trajectory, name: string)
{
	model := trajectory->new();
	labels := trajectory->parameterlabels();
	ranges := trajectory->parameterranges();
	if(len model.parameter != 6 || len labels != 6 || len ranges != 6)
		fail(name+" metadata",real len model.parameter,6.0);
	model.parameter[2] = 0.0;
	model.parameter[3] = 0.0;
	model.parameter[4] = 0.0;
	state := trajectory->initialstate(model);
	if(len state != 4)
		fail(name+" state size",real len state,4.0);
	derivative := array[] of {0.0,0.0,0.0,0.0};
	trajectory->evaluate(model,0.0,state,derivative);
	check(name+" kinematics x",derivative[0],state[2],0.0);
	check(name+" kinematics y",derivative[1],state[3],0.0);
	check(name+" vacuum horizontal acceleration",derivative[2],0.0,1.0e-13);
	check(name+" vacuum vertical acceleration",derivative[3],
		-model.parameter[5],1.0e-13);
	if(trajectory->maxtime(model) <= 0.0)
		fail(name+" observation time",trajectory->maxtime(model),1.0);
}

testcompetitioneconomics()
{
	# lanchester's invariant, fishingone's bionomic equilibrium and
	# productionexchange's transfer balance moved to poplabtest(1) with
	# the models.
	checkpopulationmodule(boommodel,"Goodwin cycle",2);
	state := array[] of {0.9,0.7};
	derivative := array[] of {0.0,0.0};
	goodwin := boommodel->new();
	p := goodwin.parameter;
	state[0] = p[2]/p[3];
	state[1] = p[0]/p[1];
	boommodel->evaluate(goodwin,0.0,state,derivative);
	check("Goodwin wage equilibrium",derivative[0],0.0,1.0e-14);
	check("Goodwin employment equilibrium",derivative[1],0.0,1.0e-14);
}

testhealthmodels()
{
	checkpopulationmetadata(heartbeat,"heartbeat",2);
	# gonorrhea's and weightchange's own checks moved to poplabtest(1).
	beat := heartbeat->new();
	x := beat.parameter[2];
	state2 := array[] of {x,beat.parameter[1]*x-x*x*x};
	derivative2 := array[] of {0.0,0.0};
	heartbeat->evaluate(beat,0.0,state2,derivative2);
	check("heartbeat equilibrium fast",derivative2[0],0.0,1.0e-12);
	check("heartbeat equilibrium slow",derivative2[1],0.0,1.0e-12);
}

testextendedepidemics()
{
	# incubation's, malaria's and seasonaldisease's conservation laws
	# moved to poplabtest(1) with the models.
}

testvitaldisease()
{
	# migration's conservation law moved to poplabtest(1).
	# the two vital-dynamics balances moved to poplabtest(1).
}

checkpopulationmetadata(modelmodule: Populationmodel, name: string, nstate: int)
{
	model := modelmodule->new();
	if(len model.initial != nstate || len modelmodule->statelabels() != nstate)
		fail(name+" state metadata",real len model.initial,real nstate);
	state := array[nstate] of real;
	derivative := array[nstate] of real;
	for(i := 0; i < nstate; i++){
		state[i] = model.initial[i];
		derivative[i] = 0.0;
	}
	modelmodule->evaluate(model,0.0,state,derivative);
	for(i = 0; i < nstate; i++)
		if(derivative[i] != derivative[i])
			fail(name+" finite derivative",derivative[i],0.0);
}

testepidemics()
{
	checkpopulationmodule(epidemicmodel,"SIR epidemic",3);
	checkpopulationmodule(vaccinationmodel,"vaccination",4);
	model := epidemicmodel->new();
	state := array[] of {0.8,0.15,0.05};
	derivative := array[] of {0.0,0.0,0.0};
	epidemicmodel->evaluate(model,0.0,state,derivative);
	check("SIR population conservation",
		derivative[0]+derivative[1]+derivative[2],0.0,1.0e-14);
	vaccine := vaccinationmodel->new();
	statev := array[] of {0.7,0.1,0.05,0.15};
	derivativev := array[] of {0.0,0.0,0.0,0.0};
	vaccinationmodel->evaluate(vaccine,0.0,statev,derivativev);
	check("vaccination population conservation",
		derivativev[0]+derivativev[1]+derivativev[2]+derivativev[3],
		0.0,1.0e-14);
}

checkpopulationmodule(modelmodule: Populationmodel, name: string, nstate: int)
{
	model := modelmodule->new();
	if(len model.initial != nstate || len modelmodule->statelabels() != nstate)
		fail(name+" state metadata",real len model.initial,real nstate);
	state := array[nstate] of real;
	derivative := array[nstate] of real;
	for(i := 0; i < nstate; i++){
		state[i] = 0.0;
		derivative[i] = 0.0;
	}
	modelmodule->evaluate(model,0.0,state,derivative);
	for(i = 0; i < nstate; i++)
		check(name+" empty boundary",derivative[i],0.0,0.0);
	for(i = 0; i < nstate; i++)
		state[i] = model.initial[i];
	modelmodule->evaluate(model,0.0,state,derivative);
	for(i = 0; i < nstate; i++)
		if(derivative[i] != derivative[i])
			fail(name+" finite derivative",derivative[i],0.0);
}

# every two-species check moved to ecolabtest(1) with the models.


testlorenz()
{
	lorenzmodel = lorenz->new(10.0,28.0,8.0/3.0);
	state := array[] of {0.0,0.0,0.0};
	derivative := array[3] of real;
	lorenz->evaluate(lorenzmodel,0.0,state,derivative);
	check("Lorenz origin dx",derivative[0],0.0,0.0);
	check("Lorenz origin dy",derivative[1],0.0,0.0);
	check("Lorenz origin dz",derivative[2],0.0,0.0);
	x := math->sqrt(lorenzmodel.beta*(lorenzmodel.rho-1.0));
	state[0] = x;
	state[1] = x;
	state[2] = lorenzmodel.rho-1.0;
	lorenz->evaluate(lorenzmodel,0.0,state,derivative);
	check("Lorenz equilibrium dx",derivative[0],0.0,1.0e-12);
	check("Lorenz equilibrium dy",derivative[1],0.0,1.0e-12);
	check("Lorenz equilibrium dz",derivative[2],0.0,1.0e-12);
}

testmap()
{
	fixedpoint := chaosmap->step(2.0,0.5);
	check("logistic fixed point",fixedpoint,0.5,1.0e-14);
	periodic := chaosmap->lyapunov(3.2,0.217,500,2000);
	if(periodic >= 0.0)
		fail("periodic Lyapunov",periodic,-1.0);
	chaotic := chaosmap->lyapunov(4.0,0.217,500,10000);
	check("r=4 Lyapunov",chaotic,0.6931471805599453,0.02);
}

testpendulum()
{
	pendulum = forcedpendulum->new(0.0,0.0,1.0);
	state := array[] of {1.2,0.0};
	work := numerics->workspace(len state);
	before := pendulum.energy(state);
	t := 0.0;
	for(i := 0; i < 20000; i++){
		numerics->rk4(work,pendulumrhs,t,0.001,state);
		t += 0.001;
	}
	after := pendulum.energy(state);
	check("unforced pendulum energy",after,before,2.0e-11);
}

pendulumrhs(t: real, state, derivative: array of real)
{
	pendulum.rhs(t,state,derivative);
}

check(name: string, got, expected, tolerance: real)
{
	error := got-expected;
	if(error < 0.0)
		error = -error;
	if(error > tolerance)
		fail(name,got,expected);
}

fail(name: string, got, expected: real)
{
	sys->print("FAIL %s: got %.17g expected %.17g\n",
		name,got,expected);
	raise "fail:danbytest: " + name;
}
