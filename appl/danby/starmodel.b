implement Profile;

include "math.m";
	math: Math;
include "danby/profile.m";

new(): ref Model
{
	math = load Math Math->PATH;
	return ref Model(array[] of {1.0,1.0,1.5,1.0,0.002,10.0});
}

title(): string
{
	return "An approximate model for a star";
}

parameterlabels(): array of string
{
	return array[] of {"central density", "central pressure", "polytropic index", "gravity", "start radius", "radius limit"};
}

parameterminima(): array of real
{
	return array[] of {0.1,0.1,0.5,0.1,0.0001,2.0};
}

parametermaxima(): array of real
{
	return array[] of {5.0,5.0,4.0,3.0,0.02,30.0};
}

fieldlabels(): array of string
{
	return array[] of {"density", "enclosed mass"};
}

profile(model: ref Model, samples: int): array of real
{
	p := model.parameter;
	result := array[3*samples] of real;
	r := p[4];
	dr := p[5]/real(samples-1);
	density := p[0];
	mass := 4.1887902*r*r*r*density;
	for(i := 0; i < samples; i++){
		result[3*i] = r;
		result[3*i+1] = density/p[0];
		result[3*i+2] = mass;
		pressure := p[1]*math->pow(density/p[0],1.0+1.0/p[2]);
		densityderivative := -p[3]*mass*density/
			(r*r*(1.0+1.0/p[2])*pressure/density+1.0e-8);
		massderivative := 4.0*Math->Pi*r*r*density;
		density += dr*densityderivative;
		mass += dr*massderivative;
		if(density < 0.0)
			density = 0.0;
		r += dr;
	}
	maximum := result[3*(samples-1)+2];
	if(maximum > 0.0)
		for(i = 0; i < samples; i++)
			result[3*i+2] /= maximum;
	return result;
}
