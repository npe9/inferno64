Chaosmap: module
{
	PATH: con "/dis/danby/plugin/chaosmap.dis";

	step: fn(parameter, value: real): real;
	derivative: fn(parameter, value: real): real;
	lyapunov: fn(parameter, initial: real, discard, count: int): real;
};
