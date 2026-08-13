Scorestore: module
{
	PATH: con "/dis/lib/scorestore.dis";

	loadint: fn(name: string, dflt: int): int;
	loadreal: fn(name: string, dflt: real): real;
	saveint: fn(name: string, value: int): int;
	savereal: fn(name: string, value: real): int;
};
