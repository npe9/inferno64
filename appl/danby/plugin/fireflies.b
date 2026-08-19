implement Mechanism;

include "math.m";
	math: Math;
include "danby/mechanism.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,0.18,0.8,0.1});
}

title(): string
{
	return "Synchronizing fireflies";
}

parameterlabels(): array of string
{
	return array[] of {"mean frequency", "frequency spread", "coupling", "initial spread"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.0,0.0,0.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,2.0,5.0,6.28};
}

initialstate(model: ref Model): array of real
{
	s := model.parameter[3];
	return array[] of {0.0,0.23*s,0.61*s,0.91*s};
}

maxtime(nil: ref Model): real
{
	return 45.0;
}

Model.rhs(model: self ref Model, nil: real, state, derivative: array of real)
{
	p := model.parameter;
	for(i := 0; i < len state; i++){
		coupling := 0.0;
		for(j := 0; j < len state; j++)
			coupling += math->sin(state[j]-state[i]);
		offset := p[1]*(real(i)-1.5)/1.5;
		derivative[i] = p[0]+offset+p[2]*coupling/real len state;
	}
}

evaluate(model: ref Model, t: real, state, derivative: array of real)
{
	model.rhs(t,state,derivative);
}

geometry(nil: ref Model, state: array of real): array of real
{
	points := array[2*len state] of real;
	for(i := 0; i < len state; i++){
		angle := 2.0*Math->Pi*real(i)/real len state;
		pulse := 0.8+0.25*math->cos(state[i]);
		points[2*i] = pulse*math->cos(angle);
		points[2*i+1] = pulse*math->sin(angle);
	}
	return points;
}

links(): array of int
{
	return array[] of {0,1,1,2,2,3,3,0};
}

observablelabels(): array of string
{
	return array[] of {"coherence", "mean flash"};
}

observables(nil: ref Model, state: array of real): array of real
{
	c := 0.0;
	s := 0.0;
	for(i := 0; i < len state; i++){
		c += math->cos(state[i]);
		s += math->sin(state[i]);
	}
	coherence := math->sqrt(c*c+s*s)/real len state;
	return array[] of {coherence,c/real len state};
}
