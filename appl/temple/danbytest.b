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
	periodicvolterra: Twospecies;
	predatorfishing: Twospecies;
	logisticprey: Twospecies;
	logisticpredators: Twospecies;
	alternativepredation: Twospecies;
	maypredator: Twospecies;
	internalcompetition: Twospecies;
	cooperation: Twospecies;
	competition: Twospecies;
	ecologymodel: Twospecies;
include "danby/populationmodel.m";
	childcare: Populationmodel;
	manyspecies: Populationmodel;
	foodchainmodel: Populationmodel;
	violetsantsrodents: Populationmodel;
	parasite: Populationmodel;
	cannibalism: Populationmodel;
	changingenvironment: Populationmodel;
	lakepollution: Populationmodel;
	budworm: Populationmodel;
	heliumburning: Populationmodel;
	decomposition: Populationmodel;
	enzymekinetics: Populationmodel;
	enzymeapplication: Populationmodel;
	moreenzyme: Populationmodel;
	stillmoreenzyme: Populationmodel;
	brusselator: Populationmodel;
	oregonator: Populationmodel;
	reactorstability: Populationmodel;
	tankcontrol: Populationmodel;
	reservoir: Populationmodel;
	epidemicmodel: Populationmodel;
	vaccinationmodel: Populationmodel;
	migrationmodel: Populationmodel;
	diseasebirthdeath1: Populationmodel;
	diseasebirthdeath2: Populationmodel;
	crossinfection: Populationmodel;
	incubation: Populationmodel;
	seasonaldisease: Populationmodel;
	malaria: Populationmodel;
	gonorrhea: Populationmodel;
	hiv: Populationmodel;
	weightchange: Populationmodel;
	heartbeat: Populationmodel;
	lanchester: Populationmodel;
	fishingone: Populationmodel;
	productionexchange: Populationmodel;
	fishingtwo: Populationmodel;
	boommodel: Populationmodel;
	twocapital: Populationmodel;
include "danby/trajectory.m";
	spinningball: Trajectory;
	baseballpitch: Trajectory;
	knuckleball: Trajectory;
	flyball: Trajectory;
	softballpitch: Trajectory;
	golfdrive: Trajectory;
	badminton: Trajectory;
	tabletennis: Trajectory;
	basketball: Trajectory;
	discus: Trajectory;
	javelin: Trajectory;
	skijump: Trajectory;
	skylab: Trajectory;
	icbmrange: Trajectory;
	rocket2d: Trajectory;
	reentry: Trajectory;
include "danby/flight3d.m";
	soccerkick: Flight3d;
	cricketbowl: Flight3d;
	cricketswing: Flight3d;
	badfootball: Flight3d;
	icbmaccuracy: Flight3d;
include "danby/mechanism.m";
	running: Mechanism;
	diving: Mechanism;
	polevault: Mechanism;
	flightmodel: Mechanism;
	hovercraft: Mechanism;
	shipmotion: Mechanism;
	balloon: Mechanism;
	joggingcompanion: Mechanism;
	bungee: Mechanism;
	yoyo: Mechanism;
	amusementchaos: Mechanism;
	spacestationball: Mechanism;
	fireworks: Mechanism;
	rocketintro: Mechanism;
	multistagerocket: Mechanism;
	spaceyoyo: Mechanism;
	stretchyoyo: Mechanism;
	venushead: Mechanism;
	simplependulum: Mechanism;
	pendulumperiod: Mechanism;
	dampedpendulum: Mechanism;
	drypendulum: Mechanism;
	clockpendulum: Mechanism;
	windpendulum: Mechanism;
	loadedpendulum: Mechanism;
	synchronousmotor: Mechanism;
	gravitypendulum: Mechanism;
	magneticpendulum2d: Mechanism;
	swing1: Mechanism;
	swing2: Mechanism;
	varyingpendulum: Mechanism;
	swingingcenser: Mechanism;
	movingpivot: Mechanism;
	pegpendulum: Mechanism;
	slidingpendulum1: Mechanism;
	slidingpendulum2: Mechanism;
	atwoodpendulum: Mechanism;
	tablependulum: Mechanism;
	doublependulummodel: Mechanism;
	wheelpendulum: Mechanism;
	magneticpendulum3d: Mechanism;
	dumbbellsatellite: Mechanism;
	moonrotation: Mechanism;
	hyperionrotation: Mechanism;
	mercuryrotation: Mechanism;
	tidalrotation: Mechanism;
	nonlinearsprings: Mechanism;
	duffing: Mechanism;
	vanderpol: Mechanism;
	variationparameters: Mechanism;
	columnbuckling: Mechanism;
	catastrophemachine: Mechanism;
	attractingwires: Mechanism;
	violinbow: Mechanism;
	carrierlanding: Mechanism;
	springpivot: Mechanism;
	springpendulum: Mechanism;
	chaoticwheel: Mechanism;
	fireflies: Mechanism;
	pursuit: Mechanism;
	lowbombing: Mechanism;
	carbonmicrophone: Mechanism;
	rotatingring1: Mechanism;
	rotatingring2: Mechanism;
	compass: Mechanism;
	pistonflywheel: Mechanism;
	wattgovernor: Mechanism;
	dynamoreversal: Mechanism;
	twomagnet: Mechanism;
	bernoulli: Mechanism;
include "danby/orbital.m";
	threebody: Orbital;
	moontrip: Orbital;
	lagrange1: Orbital;
	lagrange2: Orbital;
	aerobraking: Orbital;
	lowthrust: Orbital;
	cometcatch: Orbital;
	jupiterboost: Orbital;
	grandtour: Orbital;
	perihelion: Orbital;
	poyntingrobertson: Orbital;
	galaxies: Orbital;
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
	periodicvolterra = load Twospecies "/dis/danby/periodicvolterra.dis";
	predatorfishing = load Twospecies "/dis/danby/predatorfishing.dis";
	logisticprey = load Twospecies "/dis/danby/logisticprey.dis";
	logisticpredators = load Twospecies "/dis/danby/logisticpredators.dis";
	alternativepredation = load Twospecies "/dis/danby/alternativepredation.dis";
	maypredator = load Twospecies "/dis/danby/maypredator.dis";
	internalcompetition = load Twospecies "/dis/danby/internalcompetition.dis";
	cooperation = load Twospecies "/dis/danby/cooperation.dis";
	competition = load Twospecies "/dis/danby/competition.dis";
	ecologymodel = load Twospecies "/dis/danby/ecology.dis";
	childcare = load Populationmodel "/dis/danby/childcare.dis";
	manyspecies = load Populationmodel "/dis/danby/manyspecies.dis";
	foodchainmodel = load Populationmodel "/dis/danby/foodchain.dis";
	violetsantsrodents = load Populationmodel "/dis/danby/violetsantsrodents.dis";
	parasite = load Populationmodel "/dis/danby/parasite.dis";
	cannibalism = load Populationmodel "/dis/danby/cannibalism.dis";
	changingenvironment = load Populationmodel "/dis/danby/changingenvironment.dis";
	lakepollution = load Populationmodel "/dis/danby/lakepollution.dis";
	budworm = load Populationmodel "/dis/danby/budworm.dis";
	heliumburning = load Populationmodel "/dis/danby/heliumburning.dis";
	decomposition = load Populationmodel "/dis/danby/decomposition.dis";
	enzymekinetics = load Populationmodel "/dis/danby/enzymekinetics.dis";
	enzymeapplication = load Populationmodel "/dis/danby/enzymeapplication.dis";
	moreenzyme = load Populationmodel "/dis/danby/moreenzyme.dis";
	stillmoreenzyme = load Populationmodel "/dis/danby/stillmoreenzyme.dis";
	brusselator = load Populationmodel "/dis/danby/brusselator.dis";
	oregonator = load Populationmodel "/dis/danby/oregonator.dis";
	reactorstability = load Populationmodel "/dis/danby/reactorstability.dis";
	tankcontrol = load Populationmodel "/dis/danby/tankcontrol.dis";
	reservoir = load Populationmodel "/dis/danby/reservoir.dis";
	epidemicmodel = load Populationmodel "/dis/danby/epidemic.dis";
	vaccinationmodel = load Populationmodel "/dis/danby/vaccination.dis";
	migrationmodel = load Populationmodel "/dis/danby/migration.dis";
	diseasebirthdeath1 = load Populationmodel "/dis/danby/diseasebirthdeath1.dis";
	diseasebirthdeath2 = load Populationmodel "/dis/danby/diseasebirthdeath2.dis";
	crossinfection = load Populationmodel "/dis/danby/crossinfection.dis";
	incubation = load Populationmodel "/dis/danby/incubation.dis";
	seasonaldisease = load Populationmodel "/dis/danby/seasonaldisease.dis";
	malaria = load Populationmodel "/dis/danby/malaria.dis";
	gonorrhea = load Populationmodel "/dis/danby/gonorrhea.dis";
	hiv = load Populationmodel "/dis/danby/hiv.dis";
	weightchange = load Populationmodel "/dis/danby/weightchange.dis";
	heartbeat = load Populationmodel "/dis/danby/heartbeat.dis";
	lanchester = load Populationmodel "/dis/danby/lanchester.dis";
	fishingone = load Populationmodel "/dis/danby/fishingone.dis";
	productionexchange = load Populationmodel "/dis/danby/productionexchange.dis";
	fishingtwo = load Populationmodel "/dis/danby/fishingtwo.dis";
	boommodel = load Populationmodel "/dis/danby/boom.dis";
	twocapital = load Populationmodel "/dis/danby/twocapital.dis";
	spinningball = load Trajectory "/dis/danby/spinningball.dis";
	baseballpitch = load Trajectory "/dis/danby/baseballpitch.dis";
	knuckleball = load Trajectory "/dis/danby/knuckleball.dis";
	flyball = load Trajectory "/dis/danby/flyball.dis";
	softballpitch = load Trajectory "/dis/danby/softballpitch.dis";
	golfdrive = load Trajectory "/dis/danby/golfdrive.dis";
	badminton = load Trajectory "/dis/danby/badminton.dis";
	tabletennis = load Trajectory "/dis/danby/tabletennis.dis";
	basketball = load Trajectory "/dis/danby/basketball.dis";
	discus = load Trajectory "/dis/danby/discus.dis";
	javelin = load Trajectory "/dis/danby/javelin.dis";
	skijump = load Trajectory "/dis/danby/skijump.dis";
	skylab = load Trajectory "/dis/danby/skylab.dis";
	icbmrange = load Trajectory "/dis/danby/icbmrange.dis";
	rocket2d = load Trajectory "/dis/danby/rocket2d.dis";
	reentry = load Trajectory "/dis/danby/reentry.dis";
	soccerkick = load Flight3d "/dis/danby/soccerkick.dis";
	cricketbowl = load Flight3d "/dis/danby/cricketbowl.dis";
	cricketswing = load Flight3d "/dis/danby/cricketswing.dis";
	badfootball = load Flight3d "/dis/danby/badfootball.dis";
	icbmaccuracy = load Flight3d "/dis/danby/icbmaccuracy.dis";
	running = load Mechanism "/dis/danby/running.dis";
	diving = load Mechanism "/dis/danby/diving.dis";
	polevault = load Mechanism "/dis/danby/polevault.dis";
	flightmodel = load Mechanism "/dis/danby/flight.dis";
	hovercraft = load Mechanism "/dis/danby/hovercraft.dis";
	shipmotion = load Mechanism "/dis/danby/shipmotion.dis";
	balloon = load Mechanism "/dis/danby/balloon.dis";
	joggingcompanion = load Mechanism "/dis/danby/joggingcompanion.dis";
	bungee = load Mechanism "/dis/danby/bungee.dis";
	yoyo = load Mechanism "/dis/danby/yoyo.dis";
	amusementchaos = load Mechanism "/dis/danby/amusementchaos.dis";
	spacestationball = load Mechanism "/dis/danby/spacestationball.dis";
	fireworks = load Mechanism "/dis/danby/fireworks.dis";
	rocketintro = load Mechanism "/dis/danby/rocketintro.dis";
	multistagerocket = load Mechanism "/dis/danby/multistagerocket.dis";
	spaceyoyo = load Mechanism "/dis/danby/spaceyoyo.dis";
	stretchyoyo = load Mechanism "/dis/danby/stretchyoyo.dis";
	venushead = load Mechanism "/dis/danby/venushead.dis";
	simplependulum = load Mechanism "/dis/danby/simplependulum.dis";
	pendulumperiod = load Mechanism "/dis/danby/pendulumperiod.dis";
	dampedpendulum = load Mechanism "/dis/danby/dampedpendulum.dis";
	drypendulum = load Mechanism "/dis/danby/drypendulum.dis";
	clockpendulum = load Mechanism "/dis/danby/clockpendulum.dis";
	windpendulum = load Mechanism "/dis/danby/windpendulum.dis";
	loadedpendulum = load Mechanism "/dis/danby/loadedpendulum.dis";
	synchronousmotor = load Mechanism "/dis/danby/synchronousmotor.dis";
	gravitypendulum = load Mechanism "/dis/danby/gravitypendulum.dis";
	magneticpendulum2d = load Mechanism "/dis/danby/magneticpendulum2d.dis";
	swing1 = load Mechanism "/dis/danby/swing1.dis";
	swing2 = load Mechanism "/dis/danby/swing2.dis";
	varyingpendulum = load Mechanism "/dis/danby/varyingpendulum.dis";
	swingingcenser = load Mechanism "/dis/danby/swingingcenser.dis";
	movingpivot = load Mechanism "/dis/danby/movingpivot.dis";
	pegpendulum = load Mechanism "/dis/danby/pegpendulum.dis";
	slidingpendulum1 = load Mechanism "/dis/danby/slidingpendulum1.dis";
	slidingpendulum2 = load Mechanism "/dis/danby/slidingpendulum2.dis";
	atwoodpendulum = load Mechanism "/dis/danby/atwoodpendulum.dis";
	tablependulum = load Mechanism "/dis/danby/tablependulum.dis";
	doublependulummodel = load Mechanism "/dis/danby/doublependulum.dis";
	wheelpendulum = load Mechanism "/dis/danby/wheelpendulum.dis";
	magneticpendulum3d = load Mechanism "/dis/danby/magneticpendulum3d.dis";
	dumbbellsatellite = load Mechanism "/dis/danby/dumbbellsatellite.dis";
	moonrotation = load Mechanism "/dis/danby/moonrotation.dis";
	hyperionrotation = load Mechanism "/dis/danby/hyperionrotation.dis";
	mercuryrotation = load Mechanism "/dis/danby/mercuryrotation.dis";
	tidalrotation = load Mechanism "/dis/danby/tidalrotation.dis";
	nonlinearsprings = load Mechanism "/dis/danby/nonlinearsprings.dis";
	duffing = load Mechanism "/dis/danby/duffing.dis";
	vanderpol = load Mechanism "/dis/danby/vanderpol.dis";
	variationparameters = load Mechanism "/dis/danby/variationparameters.dis";
	columnbuckling = load Mechanism "/dis/danby/columnbuckling.dis";
	catastrophemachine = load Mechanism "/dis/danby/catastrophemachine.dis";
	attractingwires = load Mechanism "/dis/danby/attractingwires.dis";
	violinbow = load Mechanism "/dis/danby/violinbow.dis";
	carrierlanding = load Mechanism "/dis/danby/carrierlanding.dis";
	springpivot = load Mechanism "/dis/danby/springpivot.dis";
	springpendulum = load Mechanism "/dis/danby/springpendulum.dis";
	chaoticwheel = load Mechanism "/dis/danby/chaoticwheel.dis";
	fireflies = load Mechanism "/dis/danby/fireflies.dis";
	pursuit = load Mechanism "/dis/danby/pursuit.dis";
	lowbombing = load Mechanism "/dis/danby/lowbombing.dis";
	carbonmicrophone = load Mechanism "/dis/danby/carbonmicrophone.dis";
	rotatingring1 = load Mechanism "/dis/danby/rotatingring1.dis";
	rotatingring2 = load Mechanism "/dis/danby/rotatingring2.dis";
	compass = load Mechanism "/dis/danby/compass.dis";
	pistonflywheel = load Mechanism "/dis/danby/pistonflywheel.dis";
	wattgovernor = load Mechanism "/dis/danby/wattgovernor.dis";
	dynamoreversal = load Mechanism "/dis/danby/dynamoreversal.dis";
	twomagnet = load Mechanism "/dis/danby/twomagnet.dis";
	bernoulli = load Mechanism "/dis/danby/bernoulli.dis";
	threebody = load Orbital "/dis/danby/threebody.dis";
	moontrip = load Orbital "/dis/danby/moontrip.dis";
	lagrange1 = load Orbital "/dis/danby/lagrange1.dis";
	lagrange2 = load Orbital "/dis/danby/lagrange2.dis";
	aerobraking = load Orbital "/dis/danby/aerobraking.dis";
	lowthrust = load Orbital "/dis/danby/lowthrust.dis";
	cometcatch = load Orbital "/dis/danby/cometcatch.dis";
	jupiterboost = load Orbital "/dis/danby/jupiterboost.dis";
	grandtour = load Orbital "/dis/danby/grandtour.dis";
	perihelion = load Orbital "/dis/danby/perihelion.dis";
	poyntingrobertson = load Orbital "/dis/danby/poyntingrobertson.dis";
	galaxies = load Orbital "/dis/danby/galaxies.dis";
	starmodel = load Profile "/dis/danby/starmodel.dis";
	whitedwarf = load Profile "/dis/danby/whitedwarf.dis";
	if(numerics == nil || math == nil || chaosmap == nil ||
			forcedpendulum == nil || lorenz == nil ||
			periodicvolterra == nil || predatorfishing == nil ||
			logisticprey == nil || logisticpredators == nil ||
			alternativepredation == nil || maypredator == nil ||
			internalcompetition == nil || cooperation == nil ||
			competition == nil || ecologymodel == nil || childcare == nil ||
			manyspecies == nil || foodchainmodel == nil ||
			violetsantsrodents == nil || parasite == nil ||
			cannibalism == nil || changingenvironment == nil ||
			lakepollution == nil || budworm == nil || heliumburning == nil ||
			decomposition == nil || enzymekinetics == nil || enzymeapplication == nil ||
			moreenzyme == nil || stillmoreenzyme == nil || brusselator == nil ||
			oregonator == nil || reactorstability == nil || tankcontrol == nil ||
			reservoir == nil ||
			epidemicmodel == nil || vaccinationmodel == nil ||
			migrationmodel == nil || diseasebirthdeath1 == nil ||
			diseasebirthdeath2 == nil || crossinfection == nil ||
			incubation == nil || seasonaldisease == nil || malaria == nil ||
			gonorrhea == nil || hiv == nil || weightchange == nil || heartbeat == nil ||
			lanchester == nil || fishingone == nil ||
			productionexchange == nil || fishingtwo == nil ||
			boommodel == nil || twocapital == nil || spinningball == nil ||
			baseballpitch == nil || knuckleball == nil || flyball == nil ||
			softballpitch == nil || golfdrive == nil || soccerkick == nil ||
			cricketbowl == nil || cricketswing == nil || badminton == nil ||
			tabletennis == nil || basketball == nil || badfootball == nil ||
			discus == nil || javelin == nil || skijump == nil || skylab == nil ||
			icbmrange == nil || icbmaccuracy == nil || aerobraking == nil ||
			rocket2d == nil || reentry == nil || lowthrust == nil ||
			running == nil || diving == nil || polevault == nil ||
			flightmodel == nil || hovercraft == nil || shipmotion == nil ||
			balloon == nil || joggingcompanion == nil || bungee == nil ||
			yoyo == nil || amusementchaos == nil || spacestationball == nil ||
			fireworks == nil || rocketintro == nil || multistagerocket == nil ||
			spaceyoyo == nil || stretchyoyo == nil ||
			threebody == nil || moontrip == nil ||
			lagrange1 == nil || lagrange2 == nil || cometcatch == nil ||
			jupiterboost == nil || grandtour == nil || perihelion == nil ||
			poyntingrobertson == nil || galaxies == nil || venushead == nil ||
			starmodel == nil || whitedwarf == nil || simplependulum == nil ||
			pendulumperiod == nil || dampedpendulum == nil || drypendulum == nil ||
			clockpendulum == nil || windpendulum == nil || loadedpendulum == nil ||
			synchronousmotor == nil || gravitypendulum == nil ||
			magneticpendulum2d == nil || swing1 == nil || swing2 == nil ||
			varyingpendulum == nil || swingingcenser == nil ||
			movingpivot == nil || pegpendulum == nil ||
			slidingpendulum1 == nil || slidingpendulum2 == nil ||
			atwoodpendulum == nil || tablependulum == nil ||
			doublependulummodel == nil || wheelpendulum == nil ||
			magneticpendulum3d == nil || dumbbellsatellite == nil ||
			moonrotation == nil || hyperionrotation == nil ||
			mercuryrotation == nil || tidalrotation == nil ||
			nonlinearsprings == nil || duffing == nil || vanderpol == nil ||
			variationparameters == nil || columnbuckling == nil ||
			catastrophemachine == nil || attractingwires == nil || violinbow == nil ||
			carrierlanding == nil || springpivot == nil || springpendulum == nil ||
			chaoticwheel == nil || fireflies == nil || pursuit == nil ||
			lowbombing == nil || carbonmicrophone == nil || rotatingring1 == nil ||
			rotatingring2 == nil || compass == nil || pistonflywheel == nil ||
			wattgovernor == nil || dynamoreversal == nil || twomagnet == nil ||
			bernoulli == nil)
		raise "fail:danbytest: missing module";
	testmap();
	testpendulum();
	testlorenz();
	testtwospecies();
	testpopulations();
	sys->print("OK   Danby model modules\n");
}

testpopulations()
{
	model := childcare->new();
	if(len model.initial != 3 || len childcare->statelabels() != 3)
		fail("child-care state metadata",real len model.initial,3.0);
	state := array[] of {0.0,0.0,0.0};
	derivative := array[] of {0.0,0.0,0.0};
	childcare->evaluate(model,0.0,state,derivative);
	for(i := 0; i < len derivative; i++)
		check("child-care empty boundary",derivative[i],0.0,0.0);
	for(i = 0; i < len state; i++)
		state[i] = model.initial[i];
	childcare->evaluate(model,0.0,state,derivative);
	for(i = 0; i < len derivative; i++)
		if(derivative[i] != derivative[i])
			fail("child-care finite derivative",derivative[i],0.0);
	checkpopulationmodule(manyspecies,"many species",3);
	checkpopulationmodule(foodchainmodel,"food chain",3);
	checkpopulationmodule(violetsantsrodents,"violets ants rodents",3);
	checkpopulationmodule(parasite,"parasite",2);
	checkpopulationmodule(cannibalism,"cannibalism",2);
	checkpopulationmodule(changingenvironment,"changing environment",1);
	checkpopulationmodule(budworm,"budworm",1);
	checkpopulationmodule(heliumburning,"helium burning",4);
	checkpopulationmodule(decomposition,"molecular decomposition",3);
	checkpopulationmodule(enzymekinetics,"enzyme kinetics",4);
	checkpopulationmodule(enzymeapplication,"competitive inhibition",6);
	checkpopulationmodule(moreenzyme,"reversible enzyme",4);
	checkpopulationmodule(stillmoreenzyme,"cooperative enzyme",5);
	checkpopulationmetadata(brusselator,"Brusselator",2);
	checkpopulationmodule(oregonator,"Oregonator",3);
	checkpopulationmetadata(reactorstability,"reactor stability",2);
	checkpopulationmetadata(tankcontrol,"tank control",4);
	checkpopulationmetadata(reservoir,"reservoir system",3);
	testlakepollution();
	testepidemics();
	testvitaldisease();
	testextendedepidemics();
	testhealthmodels();
	testcompetitioneconomics();
	testtrajectory();
}

testtrajectory()
{
	ball := spinningball->new();
	ball.parameter[2] = 0.0;
	ball.parameter[3] = 0.0;
	ball.parameter[4] = 0.0;
	state := spinningball->initialstate(ball);
	derivative := array[] of {0.0,0.0,0.0,0.0};
	spinningball->evaluate(ball,0.0,state,derivative);
	check("ball kinematics x",derivative[0],state[2],0.0);
	check("ball kinematics y",derivative[1],state[3],0.0);
	check("ball vacuum horizontal acceleration",derivative[2],0.0,0.0);
	check("ball vacuum vertical acceleration",derivative[3],
		-ball.parameter[5],0.0);
	check("ball launch speed",
		math->sqrt(state[2]*state[2]+state[3]*state[3]),
		ball.parameter[0],1.0e-12);
	checkvacuumtrajectory(baseballpitch,"baseball pitch");
	checkvacuumtrajectory(knuckleball,"knuckleball");
	checkvacuumtrajectory(flyball,"fly ball");
	checkvacuumtrajectory(softballpitch,"softball pitch");
	checkvacuumtrajectory(golfdrive,"golf drive");
	checkvacuumflight3d(soccerkick,"soccer kick");
	checkvacuumflight3d(cricketbowl,"cricket bowl");
	checkvacuumflight3d(cricketswing,"cricket swing");
	checkvacuumtrajectory(badminton,"badminton");
	checkvacuumtrajectory(tabletennis,"table tennis");
	checkvacuumtrajectory(basketball,"basketball");
	checkvacuumflight3d(badfootball,"bad football");
	checkvacuumtrajectory(discus,"discus");
	checkvacuumtrajectory(javelin,"javelin");
	checkvacuumtrajectory(skijump,"ski jump");
	checktrajectoryfinite(skylab,"Skylab");
	checktrajectoryfinite(icbmrange,"ICBM range");
	checktrajectoryfinite(rocket2d,"two-dimensional rocket");
	checktrajectoryfinite(reentry,"re-entry");
	checkflight3dfinite(icbmaccuracy,"ICBM accuracy");
	checkmechanism(running,"running");
	checkmechanism(diving,"diving");
	checkmechanism(polevault,"pole vault");
	checkmechanism(flightmodel,"flight");
	checkmechanism(hovercraft,"hovercraft");
	checkmechanism(shipmotion,"ship motion");
	checkmechanism(balloon,"balloon");
	checkmechanism(joggingcompanion,"jogging companion");
	checkmechanism(bungee,"bungee");
	checkmechanism(yoyo,"yo-yo");
	checkmechanism(amusementchaos,"amusement chaos");
	checkmechanism(spacestationball,"space-station ball");
	checkmechanism(fireworks,"fireworks");
	checkmechanism(rocketintro,"rocket introduction");
	checkmechanism(multistagerocket,"multi-stage rocket");
	checkmechanism(spaceyoyo,"space yo-yo");
	checkmechanism(stretchyoyo,"stretch yo-yo");
	checkmechanism(venushead,"Venus ray geometry");
	checkmechanism(simplependulum,"simple pendulum");
	checkmechanism(pendulumperiod,"pendulum period");
	checkmechanism(dampedpendulum,"damped pendulum");
	checkmechanism(drypendulum,"dry-friction pendulum");
	checkmechanism(clockpendulum,"clock pendulum");
	checkmechanism(windpendulum,"wind pendulum");
	checkmechanism(loadedpendulum,"loaded pendulum");
	checkmechanism(synchronousmotor,"synchronous motor");
	checkmechanism(gravitypendulum,"gravity pendulum");
	checkmechanism(magneticpendulum2d,"magnetic pendulum 2d");
	checkmechanism(swing1,"child swing 1");
	checkmechanism(swing2,"child swing 2");
	checkmechanism(varyingpendulum,"varying-length pendulum");
	checkmechanism(swingingcenser,"swinging censer");
	checkmechanism(movingpivot,"moving-pivot pendulum");
	checkmechanism(pegpendulum,"peg pendulum");
	checkmechanism(slidingpendulum1,"sliding pendulum 1");
	checkmechanism(slidingpendulum2,"sliding pendulum 2");
	checkmechanism(atwoodpendulum,"swinging Atwood machine");
	checkmechanism(tablependulum,"table-coupled pendulum");
	checkmechanism(doublependulummodel,"double pendulum");
	checkmechanism(wheelpendulum,"wheel pendulum");
	checkmechanism(magneticpendulum3d,"magnetic pendulum 3d");
	checkmechanism(dumbbellsatellite,"dumbbell satellite");
	checkmechanism(moonrotation,"Moon rotation");
	checkmechanism(hyperionrotation,"Hyperion rotation");
	checkmechanism(mercuryrotation,"Mercury rotation");
	checkmechanism(tidalrotation,"tidal spin capture");
	checkmechanism(nonlinearsprings,"nonlinear springs");
	checkmechanism(duffing,"Duffing oscillator");
	checkmechanism(vanderpol,"Van der Pol oscillator");
	checkmechanism(variationparameters,"variation of parameters");
	checkmechanism(columnbuckling,"column buckling");
	checkmechanism(catastrophemachine,"catastrophe machine");
	checkmechanism(attractingwires,"attracting wires");
	checkmechanism(violinbow,"violin bow");
	checkmechanism(carrierlanding,"carrier landing");
	checkmechanism(springpivot,"spring pivot");
	checkmechanism(springpendulum,"spring pendulum");
	checkmechanism(chaoticwheel,"chaotic driven wheel");
	checkmechanism(fireflies,"fireflies");
	checkmechanism(pursuit,"pursuit curves");
	checkmechanism(lowbombing,"low-level bombing");
	checkmechanism(carbonmicrophone,"carbon microphone");
	checkmechanism(rotatingring1,"rotating ring 1");
	checkmechanism(rotatingring2,"rotating ring 2");
	checkmechanism(compass,"oscillating compass");
	checkmechanism(pistonflywheel,"piston and flywheel");
	checkmechanism(wattgovernor,"Watt governor");
	checkmechanism(dynamoreversal,"reversal dynamo");
	checkmechanism(twomagnet,"two-magnet toy");
	checkmechanism(bernoulli,"Bernoulli problem");
	checkorbital(threebody,"three body");
	checkorbital(moontrip,"Moon trip");
	checkorbital(lagrange1,"Lagrange 1");
	checkorbital(lagrange2,"Lagrange 2");
	checkorbital(aerobraking,"aerobraking");
	checkorbital(lowthrust,"low thrust");
	checkorbital(cometcatch,"comet catch");
	checkorbital(jupiterboost,"Jupiter boost");
	checkorbital(grandtour,"grand tour");
	checkorbital(perihelion,"perihelion");
	checkorbital(poyntingrobertson,"Poynting-Robertson");
	checkorbital(galaxies,"galaxies");
	checkprofile(starmodel,"stellar model");
	checkprofile(whitedwarf,"white dwarf");
	runner := running->new();
	runnerstate := running->initialstate(runner);
	runnerderivative := array[len runnerstate] of real;
	running->evaluate(runner,0.0,runnerstate,runnerderivative);
	check("running distance rate",runnerderivative[3],runnerstate[0],0.0);
	diver := diving->new();
	diverstate := diving->initialstate(diver);
	check("diving launch speed",
		math->sqrt(diverstate[2]*diverstate[2]+diverstate[3]*diverstate[3]),
		diver.parameter[0],1.0e-12);
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

checkorbital(orbital: Orbital, name: string)
{
	model := orbital->new();
	labels := orbital->parameterlabels();
	minima := orbital->parameterminima();
	maxima := orbital->parametermaxima();
	if(len labels != len model.parameter || len minima != len model.parameter ||
			len maxima != len model.parameter)
		fail(name+" parameter metadata",real len labels,real len model.parameter);
	if(len orbital->bodylabels() != len model.mass)
		fail(name+" body metadata",real len orbital->bodylabels(),real len model.mass);
	state := orbital->initialstate(model);
	if(len state != 4*len model.mass)
		fail(name+" state size",real len state,real(4*len model.mass));
	derivative := array[len state] of real;
	orbital->evaluate(model,0.0,state,derivative);
	for(i := 0; i < len derivative; i++)
		if(derivative[i] != derivative[i])
			fail(name+" finite derivative",derivative[i],0.0);
	pxrate := 0.0;
	pyrate := 0.0;
	for(i = 0; i < len model.mass; i++){
		pxrate += model.mass[i]*derivative[4*i+2];
		pyrate += model.mass[i]*derivative[4*i+3];
	}
	check(name+" internal force x",pxrate,0.0,1.0e-11);
	check(name+" internal force y",pyrate,0.0,1.0e-11);
	if(len orbital->observables(model,state) != 2 ||
			len orbital->observablelabels() != 2)
		fail(name+" observables",real len orbital->observables(model,state),2.0);
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
	checkpopulationmetadata(lanchester,"Lanchester",2);
	checkpopulationmodule(fishingone,"one-species fishing",2);
	combat := lanchester->new();
	state := array[] of {0.9,0.7};
	derivative := array[] of {0.0,0.0};
	lanchester->evaluate(combat,0.0,state,derivative);
	invariantderivative := 2.0*combat.parameter[1]*state[0]*derivative[0]
		-2.0*combat.parameter[0]*state[1]*derivative[1];
	check("Lanchester square-law invariant",invariantderivative,0.0,1.0e-14);
	fishery := fishingone->new();
	p := fishery.parameter;
	stock := p[4]/(p[3]*p[2]);
	effort := p[0]*(1.0-stock/p[1])/p[2];
	state[0] = stock;
	state[1] = effort;
	fishingone->evaluate(fishery,0.0,state,derivative);
	check("fishery stock equilibrium",derivative[0],0.0,1.0e-12);
	check("fishery effort equilibrium",derivative[1],0.0,1.0e-12);
	checkpopulationmetadata(productionexchange,"production exchange",2);
	checkpopulationmodule(fishingtwo,"two-species fishing",3);
	checkpopulationmodule(boommodel,"Goodwin cycle",2);
	checkpopulationmodule(twocapital,"two-capital growth",2);
	exchange := productionexchange->new();
	state[0] = 0.8;
	state[1] = 0.3;
	productionexchange->evaluate(exchange,0.0,state,derivative);
	p = exchange.parameter;
	expectedtotal := p[0]+p[2]-p[1]*state[0]-p[3]*state[1];
	check("exchange conserves transferred goods",derivative[0]+derivative[1],
		expectedtotal,1.0e-14);
	goodwin := boommodel->new();
	p = goodwin.parameter;
	state[0] = p[2]/p[3];
	state[1] = p[0]/p[1];
	boommodel->evaluate(goodwin,0.0,state,derivative);
	check("Goodwin wage equilibrium",derivative[0],0.0,1.0e-14);
	check("Goodwin employment equilibrium",derivative[1],0.0,1.0e-14);
}

testhealthmodels()
{
	checkpopulationmodule(gonorrhea,"gonorrhea",4);
	checkpopulationmodule(hiv,"HIV",3);
	checkpopulationmetadata(weightchange,"weight change",1);
	checkpopulationmetadata(heartbeat,"heartbeat",2);
	state4 := array[] of {0.8,0.2,0.7,0.3};
	derivative4 := array[] of {0.0,0.0,0.0,0.0};
	gonorrheamodel := gonorrhea->new();
	gonorrhea->evaluate(gonorrheamodel,0.0,state4,derivative4);
	check("gonorrhea women conservation",derivative4[0]+derivative4[1],
		0.0,1.0e-14);
	check("gonorrhea men conservation",derivative4[2]+derivative4[3],
		0.0,1.0e-14);
	weight := weightchange->new();
	state1 := array[] of {0.0};
	derivative1 := array[] of {0.0};
	weightchange->evaluate(weight,0.0,state1,derivative1);
	check("weight zero-mass energy balance",derivative1[0],
		weight.parameter[0]/weight.parameter[3],1.0e-14);
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
	checkpopulationmodule(crossinfection,"cross infection",4);
	checkpopulationmodule(incubation,"incubation",4);
	checkpopulationmodule(seasonaldisease,"seasonal disease",3);
	checkpopulationmodule(malaria,"malaria",4);
	state4 := array[] of {0.8,0.1,0.7,0.2};
	derivative4 := array[] of {0.0,0.0,0.0,0.0};
	seir := incubation->new();
	incubation->evaluate(seir,0.0,state4,derivative4);
	check("SEIR conservation",
		derivative4[0]+derivative4[1]+derivative4[2]+derivative4[3],
		0.0,1.0e-14);
	vector := malaria->new();
	malaria->evaluate(vector,0.0,state4,derivative4);
	check("malaria human conservation",derivative4[0]+derivative4[1],
		0.0,1.0e-14);
	check("malaria mosquito conservation",derivative4[2]+derivative4[3],
		0.0,1.0e-14);
	seasonal := seasonaldisease->new();
	state3 := array[] of {0.8,0.15,0.05};
	derivative3 := array[] of {0.0,0.0,0.0};
	seasonaldisease->evaluate(seasonal,0.0,state3,derivative3);
	check("seasonal SIR conservation",
		derivative3[0]+derivative3[1]+derivative3[2],0.0,1.0e-14);
}

testvitaldisease()
{
	checkpopulationmetadata(migrationmodel,"disease migration",3);
	checkpopulationmetadata(diseasebirthdeath1,"disease vital model 1",3);
	checkpopulationmodule(diseasebirthdeath2,"disease vital model 2",3);
	state := array[] of {0.8,0.15,0.05};
	derivative := array[] of {0.0,0.0,0.0};
	migration := migrationmodel->new();
	migrationmodel->evaluate(migration,0.0,state,derivative);
	check("migration fraction conservation",
		derivative[0]+derivative[1]+derivative[2],0.0,1.0e-14);
	balanced := diseasebirthdeath1->new();
	diseasebirthdeath1->evaluate(balanced,0.0,state,derivative);
	check("balanced vital population conservation",
		derivative[0]+derivative[1]+derivative[2],0.0,1.0e-14);
	unbalanced := diseasebirthdeath2->new();
	diseasebirthdeath2->evaluate(unbalanced,0.0,state,derivative);
	p := unbalanced.parameter;
	expected := (p[2]-p[3])-p[4]*state[1];
	check("independent vital population balance",
		derivative[0]+derivative[1]+derivative[2],expected,1.0e-14);
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

testlakepollution()
{
	model := lakepollution->new();
	p := model.parameter;
	equilibrium := (p[0]/p[1])/(p[2]/p[1]+p[3]);
	state := array[] of {equilibrium};
	derivative := array[] of {0.0};
	lakepollution->evaluate(model,0.0,state,derivative);
	check("lake pollution mass balance",derivative[0],0.0,1.0e-12);
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

testtwospecies()
{
	seasonal := periodicvolterra->new();
	(prey,predators) := periodicvolterra->fixedpoint(seasonal);
	state := array[] of {prey,predators};
	derivative := array[2] of real;
	periodicvolterra->evaluate(seasonal,0.0,state,derivative);
	if(derivative[0] == 0.0)
		fail("periodic birthrate varies at t=0",derivative[0],1.0);
	period := 2.0*3.14159265358979323846/seasonal.parameter[5];
	periodicvolterra->evaluate(seasonal,period/4.0,state,derivative);
	check("periodic mean equilibrium prey",derivative[0],0.0,1.0e-12);
	check("periodic mean equilibrium predator",derivative[1],0.0,1.0e-12);

	fished := predatorfishing->new();
	(prey,predators) = predatorfishing->fixedpoint(fished);
	state[0] = prey;
	state[1] = predators;
	predatorfishing->evaluate(fished,0.0,state,derivative);
	check("fishing equilibrium prey",derivative[0],0.0,1.0e-12);
	check("fishing equilibrium predator",derivative[1],0.0,1.0e-12);

	checktwospecies(logisticprey,"logistic prey");
	checktwospecies(logisticpredators,"logistic predators");
	checktwospecies(alternativepredation,"alternative predation");
	checktwospecies(maypredator,"May predator-prey");
	checktwospecies(internalcompetition,"internal competition");
	checktwospecies(cooperation,"cooperation");
	checktwospecies(competition,"competition");
	checktwospecies(ecologymodel,"Volterra ecology");

	may := maypredator->new();
	state[0] = 0.0;
	state[1] = 0.5;
	maypredator->evaluate(may,0.0,state,derivative);
	check("May zero-prey boundary",derivative[1],
		-may.parameter[4]*state[1],1.0e-12);
}

checktwospecies(modelmodule: Twospecies, name: string)
{
	model := modelmodule->new();
	(x,y) := modelmodule->fixedpoint(model);
	if(x <= 0.0 || y <= 0.0)
		fail(name+" positive equilibrium",x+y,1.0);
	state := array[] of {x,y};
	derivative := array[2] of real;
	modelmodule->evaluate(model,0.0,state,derivative);
	check(name+" equilibrium x",derivative[0],0.0,1.0e-10);
	check(name+" equilibrium y",derivative[1],0.0,1.0e-10);
}

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
