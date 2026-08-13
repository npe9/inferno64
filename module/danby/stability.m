Stability: module
{
	PATH: con "/dis/danby/stability.dis";

	Model: adt {
		growth: real;

		rhs: fn(model: self ref Model, t: real,
			state, derivative: array of real);
		linear: fn(model: self ref Model, t: real,
			state, derivative: array of real);
	};

	new: fn(growth: real): ref Model;
};
