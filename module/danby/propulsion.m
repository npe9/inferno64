Propulsion: module
{
	PATH: con "/dis/danby/propulsion.dis";

	mass: fn(drymass, propellant, flow, time: real): real;
	thrustacceleration: fn(thrust, drymass, propellant, flow, time: real): real;
	burntime: fn(propellant, flow: real): real;
};
