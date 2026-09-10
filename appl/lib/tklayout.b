implement Tklayout;

#
# Check a Tk layout by asking Tk what each widget needed and what it got.
#
# The failure a bigger font causes is not a mis-sized widget - libtk sizes
# widgets from their font, and tkofftest(1) asserts that - but a window
# whose pixels were counted out around the old size and no longer holds
# its own contents.  What that looks like from outside is text with its
# end cut off, and it is invisible to any check that looks at one widget
# at a time.
#
# Three ways to see it were tried, and only the third works here:
#
#   - Siblings overlapping.  This Tk has only pack and grid, no place, so
#     two packed widgets are given disjoint space by construction.  The
#     check is kept because a canvas window could still do it, but it has
#     never been seen to fire.
#   - A widget outside the pane.  It cannot happen: Tk clips a widget to
#     the room available, so a label needing 502 pixels in a 200-pixel
#     window reports itself as 200 wide.  A checker built on this would
#     have passed everything, always.
#   - Actual against required.  Tk->Required is *not* clipped - the same
#     label reports 502 - so the difference between the two is exactly the
#     text that was cut off, per widget, by name.  That is this module.
#
# Only widgets a geometry manager has count.  One created and never
# packed still reports its border as a rectangle, and programs here do
# create such widgets deliberately - see laidout() below.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Rect, Point: import draw;
include "tk.m";
	tk: Tk;
include "tklayout.m";

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
}

Problem.text(p: self ref Problem): string
{
	case p.kind {
	Clipped =>
		return sys->sprint("%s got %dx%d but needs %dx%d", p.a,
			p.ra.dx(), p.ra.dy(), p.rb.dx(), p.rb.dy());
	Overlap =>
		return sys->sprint("%s %s overlaps %s %s",
			p.a, rs(p.ra), p.b, rs(p.rb));
	}
	return "";
}

rs(r: Rect): string
{
	return sys->sprint("(%d,%d)-(%d,%d)", r.min.x, r.min.y, r.max.x, r.max.y);
}

children(top: ref Tk->Toplevel, path: string): list of string
{
	s := tk->cmd(top, "winfo children " + path);
	if(len s > 0 && s[0] == '!')
		return nil;
	l: list of string;
	for(ls := sys->tokenize(s, " \t\n").t1; ls != nil; ls = tl ls)
		l = hd ls :: l;
	return rev(l);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

walk(top: ref Tk->Toplevel, path: string): list of string
{
	r: list of string;
	for(l := children(top, path); l != nil; l = tl l){
		c := hd l;
		r = c :: r;
		for(d := walk(top, c); d != nil; d = tl d)
			r = hd d :: r;
	}
	return rev(r);
}

# Whether this widget is somewhere that can show it.  One created and
# never packed still reports a rectangle - its own border - so without
# this every measuring dummy and unposted menu looks like a widget
# squeezed to nothing.  wm/toolbar has one of each: a
# `button .b -text {XXX}` that exists only to be asked how tall a button
# would be, and the menu it posts on demand.
# The widget this one is laid out inside, or "" if none has it.
master(top: ref Tk->Toplevel, path: string): string
{
	s := tk->cmd(top, "winfo master " + path);
	if(len s > 0 && s[0] == '!')
		return "";
	return s;
}

laidout(top: ref Tk->Toplevel, path: string): int
{
	s := tk->cmd(top, "winfo manager " + path);
	if(len s > 0 && s[0] == '!')
		return 1;	# an older libtk: assume it counts
	if(s == "")
		return 0;

	# Having a manager is not enough.  A widget packed inside a container
	# that is not itself showing anything - wm/unibrowse packs the
	# contents of three drop-down panels that are only posted on demand -
	# reports a manager, and a rectangle the size of its own border.  It
	# is not being clipped; there is simply nowhere it is being drawn.
	#
	# So walk up the masters and require every one of them to have a
	# content area.  Deliberately not applied to the widget itself: a
	# widget squeezed until its own content is nothing is exactly the
	# failure this module exists to report - wm/task's .b.kill got 2x41
	# where it needed 50x39 - and testing it here would throw away the
	# most legible case.
	for(m := master(top, path); m != "" && m != "."; m = master(top, m)){
		r := tk->rect(top, m, 0);
		if(r.dx() <= 0 || r.dy() <= 0)
			return 0;
	}
	return 1;
}

check(top: ref Tk->Toplevel, root: string): list of ref Problem
{
	probs: list of ref Problem;

	for(wl := walk(top, root); wl != nil; wl = tl wl){
		w := hd wl;
		if(!laidout(top, w))
			continue;
		got := tk->rect(top, w, Tk->Border);
		if(got.dx() <= 0 || got.dy() <= 0)
			continue;
		need := tk->rect(top, w, Tk->Required);
		if(need.dx() > got.dx() || need.dy() > got.dy())
			probs = ref Problem(Clipped, w, "", got, need) :: probs;
	}

	# Compare only widgets laid out inside the same master.  Not the same
	# parent by path: `pack .b .l1 -in .f`, which appl/wm/about.b does,
	# leaves both named under the root and lays them out inside .f, so
	# grouping by name reports the frame as overlapping its own contents.
	# Widgets under different masters may also legitimately share pixels
	# - a menu over the window it drops from.
	all := walk(top, root);
	for(ml := root :: all; ml != nil; ml = tl ml){
		m := hd ml;
		kids: list of string;
		for(kl := all; kl != nil; kl = tl kl)
			if(master(top, hd kl) == m)
				kids = hd kl :: kids;
		for(a := kids; a != nil; a = tl a){
			if(!laidout(top, hd a))
				continue;
			ra := tk->rect(top, hd a, Tk->Border);
			if(ra.dx() <= 0 || ra.dy() <= 0)
				continue;
			for(b := tl a; b != nil; b = tl b){
				if(!laidout(top, hd b))
					continue;
				rb := tk->rect(top, hd b, Tk->Border);
				if(rb.dx() <= 0 || rb.dy() <= 0)
					continue;
				(o, nonempty) := ra.clip(rb);
				if(nonempty && o.dx() > 0 && o.dy() > 0)
					probs = ref Problem(Overlap,
						hd a, hd b, ra, rb) :: probs;
			}
		}
	}

	return probs;
}
