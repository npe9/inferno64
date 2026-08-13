implement Numericstest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "numerics.m";
	numerics: Numerics;
	Tolerance: import numerics;

Numericstest: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

testwork: ref Numerics->Workspace;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	numerics = load Numerics Numerics->PATH;
	if(numerics == nil)
		raise "fail:numericstest: cannot load numerics";
	w := numerics->workspace(1);
	testwork = w;
	y := array[] of {1.0};
	numerics->euler(w,exponential,0.0,0.1,y);
	check("Euler",y[0],1.1,1.0e-12);
	y[0] = 1.0;
	numerics->heun(w,exponential,0.0,0.1,y);
	check("Heun",y[0],1.105,1.0e-12);
	y[0] = 1.0;
	tolerance := Tolerance(1.0e-10,1.0e-10,1.0e-8,0.25);
	result := numerics->adaptive(w,exponential,tolerance,
		0.0,1.0,0.1,y);
	check("RKF45 time",result.t,1.0,0.0);
	check("RKF45 value",y[0],2.718281828459045,1.0e-8);
	eulercoarse := fixederror(0,0.1);
	eulerfine := fixederror(0,0.05);
	heuncoarse := fixederror(1,0.1);
	heunfine := fixederror(1,0.05);
	rkcoarse := fixederror(2,0.1);
	rkfine := fixederror(2,0.05);
	checkorder("Euler order",eulercoarse,eulerfine,2.0,0.25);
	checkorder("Heun order",heuncoarse,heunfine,4.0,0.35);
	checkorder("RK4 order",rkcoarse,rkfine,16.0,2.0);
	sys->print("OK   numerics Euler, Heun, and adaptive RKF45\n");
}

fixederror(method: int, h: real): real
{
	y := array[] of {1.0};
	t := 0.0;
	while(t < 1.0){
		step := h;
		if(t+step > 1.0)
			step = 1.0-t;
		case method {
		0 => numerics->euler(testwork,exponential,t,step,y);
		1 => numerics->heun(testwork,exponential,t,step,y);
		2 => numerics->rk4(testwork,exponential,t,step,y);
		}
		t += step;
	}
	error := y[0]-2.718281828459045;
	if(error < 0.0)
		error = -error;
	return error;
}

checkorder(name: string, coarse, fine, expected, tolerance: real)
{
	ratio := coarse/fine;
	check(name,ratio,expected,tolerance);
}

exponential(nil: real, y, derivative: array of real)
{
	derivative[0] = y[0];
}

check(name: string, got, expected, tolerance: real)
{
	error := got-expected;
	if(error < 0.0)
		error = -error;
	if(error > tolerance){
		sys->print("FAIL numerics %s: got %.17g expected %.17g\n",
			name,got,expected);
		raise "fail:numericstest: " + name;
	}
}
