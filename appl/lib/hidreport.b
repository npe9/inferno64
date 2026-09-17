implement Hidreport;

#
# HID report descriptors.  See hidreport.m for why it is a library.
#
# A descriptor is a stream of items.  A short item is one prefix byte
# -- two bits of size, two of type, four of tag -- and 0, 1, 2 or 4
# bytes of data; a long item is 0xFE and a length, and nothing defines
# one, so it is stepped over.  Items are of three types: global ones
# set state that stays set, local ones set state that is cleared after
# every main item, and main items are the ones that actually put
# fields in a report.
#
# What this keeps is one Report per report id per kind, with a bit
# cursor: every main item lays its fields down at the cursor and
# advances it.  That is the whole of the layout, and it is why the
# cursor has to advance for constant fields too -- padding takes up
# room in the report whether or not anything reads it.
#

include "sys.m";
	sys: Sys;
include "hidreport.m";

#
# the global item state.  Push and Pop save and restore all of it,
# which is what makes it one adt rather than a set of variables.
#
Gstate: adt {
	page:	int;
	lmin:	int;
	lmax:	int;
	size:	int;
	count:	int;
	id:	int;
};

init()
{
	sys = load Sys Sys->PATH;
}

parse(d: array of byte): (list of ref Report, string)
{
	g := ref Gstate(0, 0, 0, 0, 0, 0);
	saved: list of ref Gstate;
	reports: list of ref Report;	# newest first; reversed at the end

	# local item state, cleared after every main item
	usages: list of int;		# newest first
	umin, umax, haveu: int;
	umin = umax = haveu = 0;

	# the application collection this is inside, and how deep
	app := 0;
	depth := 0;

	i := 0;
	while(i < len d){
		b := int d[i];
		i++;
		if(b == 16rfe){
			#
			# A long item.  Nothing in HID 1.11 defines one, so
			# there is nothing to do with it but step over it,
			# and a descriptor that ends inside one is broken.
			#
			if(i + 2 > len d)
				return done(reports, "a long item ran off the end");
			n := int d[i];
			i += 2 + n;
			if(i > len d)
				return done(reports, "a long item ran off the end");
			continue;
		}
		sz := b & 3;
		if(sz == 3)
			sz = 4;		# 3 means four bytes, not three
		typ := (b >> 2) & 3;
		tag := (b >> 4) & 16rf;
		if(i + sz > len d)
			return done(reports, "an item ran off the end of the descriptor");
		u := 0;
		for(k := sz - 1; k >= 0; k--)
			u = (u << 8) | int d[i + k];
		#
		# the same bytes read as a signed number, which is what
		# the logical minimum and maximum are.  A four byte item
		# is already two's complement in an int and needs no
		# widening; anything shorter does.
		#
		sv := u;
		if(sz > 0 && sz < 4 && (int d[i + sz - 1] & 16r80))
			sv = u - (1 << (8 * sz));
		i += sz;

		case typ {
		0 =>	# main
			case tag {
			8 =>	reports = lay(reports, g, usages, umin, umax, haveu, app, Input, u);
			9 =>	reports = lay(reports, g, usages, umin, umax, haveu, app, Output, u);
			11 =>	reports = lay(reports, g, usages, umin, umax, haveu, app, Feature, u);
			10 =>	# Collection
				#
				# an application collection says what the
				# thing is for.  Nested collections inside
				# it -- the physical one a mouse puts its
				# pointer in -- do not change that.
				#
				if(u == 1 && depth == 0){
					lu := 0;
					if(usages != nil)
						lu = firstu(usages);
					if(lu <= 16rffff)
						lu |= g.page << 16;
					app = lu;
				}
				depth++;
			12 =>	# End Collection
				depth--;
				if(depth <= 0){
					depth = 0;
					app = 0;
				}
			}
			usages = nil;
			umin = umax = haveu = 0;
		1 =>	# global
			case tag {
			0 =>	g.page = u;
			1 =>	g.lmin = sv;
			2 =>	g.lmax = sv;
			7 =>	g.size = u;
			8 =>	g.id = u;
			9 =>	g.count = u;
			10 =>	saved = ref Gstate(g.page, g.lmin, g.lmax,
						g.size, g.count, g.id) :: saved;
			11 =>
				if(saved == nil)
					return done(reports, "a Pop with nothing pushed");
				g = hd saved;
				saved = tl saved;
			}
		2 =>	# local
			case tag {
			0 =>	usages = u :: usages;
			1 =>	umin = u; haveu |= 1;
			2 =>	umax = u; haveu |= 2;
			}
		}
	}
	if(depth != 0)
		return done(reports, "the descriptor ends inside a collection");
	return done(reports, nil);
}

#
# the one way out.  Reports and fields are both built head first, so
# both are turned round here -- and here rather than at each return, so
# that a descriptor that failed half way through hands back what was
# understood in the same order as one that did not.
#
done(reports: list of ref Report, e: string): (list of ref Report, string)
{
	rl := rev(reports);
	for(l := rl; l != nil; l = tl l)
		(hd l).fields = revf((hd l).fields);
	return (rl, e);
}

#
# one main item's worth of fields.  reports is passed by value and the
# list itself is never changed here -- getrep() is what adds to it --
# so this returns the list it ends up with.
#
lay(reports: list of ref Report, g: ref Gstate, usages: list of int,
	umin, umax, haveu, app, kind, flags: int): list of ref Report
{
	(rl, r) := getrep(reports, g.id, kind, app);
	off := r.bits;
	if(g.size > 0 && g.count > 0)
		r.bits += g.size * g.count;
	#
	# Padding still takes up room and is what the cursor above has
	# already accounted for; there is nothing in it to read, so it
	# is not made a field.
	#
	if(g.size <= 0 || g.count <= 0 || (flags & Fconst))
		return rl;

	#
	# Fields are prepended here and every report's list is turned
	# round at the end of parse(), because a Limbo list grows at the
	# head and what a caller wants is descriptor order.
	#
	if((flags & Fvar) && (haveu != 3 || usages != nil)){
		#
		# A variable field with its usages named one by one:
		# each item is its own field, and a count longer than
		# the list repeats the last usage, which is what a
		# descriptor means by giving fewer.
		#
		ul := rev0(usages);
		lu := 0;
		for(n := 0; n < g.count; n++){
			us := lu;
			if(ul != nil){
				us = hd ul;
				ul = tl ul;
				lu = us;
			}
			pg := g.page;
			if(us > 16rffff){		# a usage carrying its own page
				pg = (us >> 16) & 16rffff;
				us &= 16rffff;
			}
			r.fields = ref Field(pg, us, us, us, g.lmin, g.lmax,
				off + n * g.size, g.size, 1, flags) :: r.fields;
		}
	} else {
		#
		# Either an array -- the value selects a usage out of
		# the range -- or a variable run given as a range, which
		# is how the eight keyboard modifier bits are written.
		# Both stay one field: what the caller wants is the run.
		#
		us := 0;
		lo := umin;
		hi := umax;
		if(haveu != 3){
			if(usages != nil){
				us = firstu(usages);
				lo = hi = us;
			} else
				lo = hi = 0;
		}
		r.fields = ref Field(g.page, us, lo, hi, g.lmin, g.lmax,
			off, g.size, g.count, flags) :: r.fields;
	}
	return rl;
}

#
# the report with that id and kind, made if it is not there yet.  A
# report is created the first time the descriptor puts something in
# it, so the order they come back in is the order they were declared.
#
getrep(reports: list of ref Report, id, kind, app: int): (list of ref Report, ref Report)
{
	for(l := reports; l != nil; l = tl l){
		r := hd l;
		if(r.id == id && r.kind == kind){
			# a report may be opened before its application
			# collection has been seen; take it when it is
			if(r.app == 0)
				r.app = app;
			return (reports, r);
		}
	}
	nr := ref Report(id, kind, 0, app, nil);
	return (nr :: reports, nr);
}

report(rl: list of ref Report, id, kind: int): ref Report
{
	for(; rl != nil; rl = tl rl)
		if((hd rl).id == id && (hd rl).kind == kind)
			return hd rl;
	return nil;
}

Report.find(r: self ref Report, page, usage: int): ref Field
{
	for(l := r.fields; l != nil; l = tl l){
		f := hd l;
		if(f.page != page)
			continue;
		if(f.usage == usage)
			return f;
		if(f.usage == 0 && f.umin <= usage && usage <= f.umax)
			return f;
	}
	return nil;
}

#
# HID packs a report least significant bit first, and a field may
# start and end anywhere: a three bit field can sit across a byte
# boundary and often does.  So this is bit by bit rather than a shift
# of a byte.
#
Field.val(f: self ref Field, rep: array of byte, n: int): int
{
	if(n < 0 || n >= f.count || f.size <= 0 || f.size > 32)
		return 0;
	o := f.off + n * f.size;
	v := 0;
	for(i := 0; i < f.size; i++){
		b := o + i;
		if((b >> 3) >= len rep)
			break;
		if(int rep[b >> 3] & (1 << (b & 7)))
			v |= 1 << i;
	}
	# signed only when the descriptor said the range goes below zero
	if(f.lmin < 0 && f.size < 32 && (v & (1 << (f.size - 1))))
		v -= 1 << f.size;
	return v;
}

#
# A keyboard is an array of key codes on the keyboard page: the report
# says which keys are down by naming them, not by a bit each.  A
# device with only the modifier bits and no array is a set of
# modifiers and not a keyboard.
#
kbd(r: ref Report): int
{
	if(r == nil)
		return 0;
	for(l := r.fields; l != nil; l = tl l){
		f := hd l;
		if(f.page == Pkeyboard && !(f.flags & Fvar))
			return 1;
	}
	return 0;
}

keys(r: ref Report, rep: array of byte): (int, array of int)
{
	if(r == nil)
		return (0, array[0] of int);
	mod := 0;
	nk := 0;
	ka := array[16] of int;
	for(l := r.fields; l != nil; l = tl l){
		f := hd l;
		if(f.page != Pkeyboard)
			continue;
		if(f.flags & Fvar){
			#
			# the modifiers, assembled into the byte the boot
			# protocol puts them in: bit 0 is Left Control,
			# usage E0, and so on up to E7
			#
			for(n := 0; n < f.count; n++){
				us := f.usage;
				if(us == 0)
					us = f.umin + n;
				if(us < 16re0 || us > 16re7)
					continue;
				if(f.val(rep, n))
					mod |= 1 << (us - 16re0);
			}
			continue;
		}
		for(n := 0; n < f.count && nk < len ka; n++){
			k := f.val(rep, n);
			# 0 is an empty slot and 1 is the code a keyboard
			# sends when more keys are down than it can report
			if(k > 1)
				ka[nk++] = k;
		}
	}
	return (mod, ka[0:nk]);
}

ptr(r: ref Report): int
{
	if(r == nil)
		return 0;
	return r.find(Pgeneric, Ux) != nil && r.find(Pgeneric, Uy) != nil;
}

mouse(r: ref Report, rep: array of byte): (int, int, int, int)
{
	if(r == nil)
		return (0, 0, 0, 0);
	dx := axis(r, rep, Ux);
	dy := axis(r, rep, Uy);
	w := axis(r, rep, Uwheel);
	hb := 0;
	for(l := r.fields; l != nil; l = tl l){
		f := hd l;
		if(f.page != Pbutton)
			continue;
		for(n := 0; n < f.count; n++){
			us := f.usage;
			if(us == 0)
				us = f.umin + n;
			# button 1 is the leftmost, and 0 is no button
			if(us >= 1 && us <= 8 && f.val(rep, n))
				hb |= 1 << (us - 1);
		}
	}
	# HID: bit 0 left, bit 1 right, bit 2 middle; devpointer: 1, 4, 2
	b := (hb & 1) | ((hb & 2) << 1) | ((hb & 4) >> 1);
	return (dx, dy, b, w);
}

axis(r: ref Report, rep: array of byte, usage: int): int
{
	f := r.find(Pgeneric, usage);
	if(f == nil)
		return 0;
	n := 0;
	if(f.usage == 0)
		n = usage - f.umin;
	return f.val(rep, n);
}

#
# the first usage the descriptor declared.  The list is built head
# first, so walking to its end is what gives it.
#
firstu(l: list of int): int
{
	v := 0;
	for(; l != nil; l = tl l)
		v = hd l;
	return v;
}

rev(l: list of ref Report): list of ref Report
{
	r: list of ref Report;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

revf(l: list of ref Field): list of ref Field
{
	r: list of ref Field;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

rev0(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
