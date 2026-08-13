Cartpendulum: module
{
	PATH: con "/dis/danby/cartpendulum.dis";

	derivatives: fn(state, derivative: array of real, cartmass, bobmass,
		length, gravity, cartspring, cartdamping, hingedamping: real);
};
