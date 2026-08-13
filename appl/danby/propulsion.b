implement Propulsion;

include "danby/propulsion.m";

mass(drymass, propellant, flow, time: real): real
{
	remaining := propellant-flow*time;
	if(remaining < 0.0)
		remaining = 0.0;
	return drymass+remaining;
}

thrustacceleration(thrust, drymass, propellant, flow, time: real): real
{
	if(time >= burntime(propellant,flow))
		return 0.0;
	return thrust/mass(drymass,propellant,flow,time);
}

burntime(propellant, flow: real): real
{
	if(flow <= 0.0)
		return 0.0;
	return propellant/flow;
}
