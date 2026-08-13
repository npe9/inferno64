Plot: module
{
	PATH: con "/dis/lib/plot.dis";

	Table: adt {
		names: array of string;
		cols: array of array of real;
		capacity, head, n: int;
	};

	Scale: adt {
		lo, hi: real;
		plo, phi: int;
		map: fn(s: self ref Scale, value: real): int;
		invert: fn(s: self ref Scale, pixel: int): real;
	};

	View: adt {
		name: string;
		r: Draw->Rect;
		x, y: ref Scale;
		xlabel, ylabel: string;
		xgrid, ygrid: int;
	};

	Namedtable: adt {
		name: string;
		table: ref Table;
	};

	Namedimage: adt {
		name: string;
		image: ref Draw->Image;
	};

	Layer: adt {
		geometry, view, table: string;
		x, y, dx, dy: string;
		colour: string;
		width, radius: int;
	};

	Plotmsg: adt {
		command: string;
		reply: chan of string;
	};

	Plotter: adt {
		image: ref Draw->Image;
		font: ref Draw->Font;
		views: list of ref View;
		tables: list of ref Namedtable;
		colours: list of ref Namedimage;
		layers: list of ref Layer;

		cmd: fn(p: self ref Plotter, command: string): string;
		rows: fn(p: self ref Plotter, name: string): int;
		value: fn(p: self ref Plotter, name: string, row: int,
			column: string): (real, string);
		draw: fn(p: self ref Plotter);
		invert: fn(p: self ref Plotter, view: string,
			point: Draw->Point): (real, real, string);
	};

	new: fn(image: ref Draw->Image, font: ref Draw->Font): ref Plotter;
	run: fn(plotter: ref Plotter): chan of ref Plotmsg;
};
