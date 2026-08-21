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

	Namedrect: adt {
		name: string;
		r: Draw->Rect;
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
		rects: list of ref Namedrect;

		# Declarative panel layout, the same idea as a Tk geometry manager
		# applied to plot views instead of widgets: describe the split you
		# want, not the pixel arithmetic. Recomputed from p.image.r each
		# call, same as everything else here - cheap, and correct across
		# a live window resize with no extra bookkeeping.
		#   content margin l t r b     - "content" = image rect, shrunk
		#   rect name x0 y0 x1 y1      - a named rect from literal bounds
		#   split source x|y name w [name w...] gutter g
		#                              - splits a named rect along an axis
		#                                into named rects proportional to
		#                                w, separated by g pixels
		#   view name x0 y0 x1 y1      - as before, literal bounds
		#   view name rect             - a view taking a named rect's
		#                                bounds directly
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
