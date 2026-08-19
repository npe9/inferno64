Forcedpendulum: module
{
	PATH: con "/dis/danby/plugin/forcedpendulum.dis";

	Model: adt {
		damping, drive, frequency: real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
		energy: fn(model: self ref Model, state: array of real): real;
	};

	new: fn(damping, drive, frequency: real): ref Model;
};
