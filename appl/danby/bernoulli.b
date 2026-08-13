implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,9.81,3.141592653589793,0.02});
}

title(): string
{
	return "Bernoulli's brachistochrone problem";
}

parameterlabels(): array of string
{
	return array[] of {"cycloid scale", "gravity", "end parameter", "start parameter"};
}

parameterminima(): array of real
{
	return array[] of {0.2,0.1,1.0,0.001};
}

parametermaxima(): array of real
{
	return array[] of {4.0,20.0,6.0,0.5};
}

initialstate(model: ref Model): array of real
{
	return array[] of {model.parameter[3],0.0,0.0};
}

maxtime(nil: ref Model): real
{
	return 8.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	endx := p[0]*(p[2]-math->sin(p[2]));
	endy := p[0]*(1.0-math->cos(p[2]));
	length := math->sqrt(endx*endx+endy*endy);
	derivative[0] = math->sqrt(p[1]/p[0]);
	derivative[1] = state[2];
	derivative[2] = p[1]*endy/length;
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	theta := state[0];
	if(theta > p[2])
		theta = p[2];
	cx := p[0]*(theta-math->sin(theta));
	cy := -p[0]*(1.0-math->cos(theta));
	endx := p[0]*(p[2]-math->sin(p[2]));
	endy := -p[0]*(1.0-math->cos(p[2]));
	length := math->sqrt(endx*endx+endy*endy);
	fraction := state[1]/length;
	if(fraction > 1.0)
		fraction = 1.0;
	sx := fraction*endx;
	sy := fraction*endy;
	return array[] of {0.0,0.0,endx,endy,cx,cy,sx,sy};
}

links(): array of int
{
	return array[] of {0,1};
}

observablelabels(): array of string
{
	return array[] of {"cycloid progress", "straight progress"};
}

observables(model: ref Model, state: array of real): array of real
{
	p := model.parameter;
	cycloidprogress := state[0]/p[2];
	endx := p[0]*(p[2]-math->sin(p[2]));
	endy := p[0]*(1.0-math->cos(p[2]));
	length := math->sqrt(endx*endx+endy*endy);
	return array[] of {cycloidprogress,state[1]/length};
}
