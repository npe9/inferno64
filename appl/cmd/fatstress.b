implement Fatstress;

#
# Hammer a FAT filesystem through dossrv and check what comes back.
#
# The Pi damaged the card it boots from, and every round of that hunt
# found one more thing: a rename that kept the low half of a start
# cluster, a FAT32 root that could not grow, a rename onto an existing
# name that removed the source first.  Each was found by a board, one
# boot at a time.  This is the same work done in seconds and on
# purpose, and its verdict is not only "the files read back": the
# script that runs it fscks the image afterwards with a tool that
# shares none of this code's opinions.
#
# usage: fatstress [-n rounds] [-f files] [-s maxk] dir
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Fatstress: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;
dir := "";
nfail := 0;

fail(s: string)
{
	sys->fprint(stderr, "FATSTRESS-FAIL %s\n", s);
	nfail++;
}

# a file's contents are a function of its name and length, so a file
# that comes back holding another file's bytes is caught, not just one
# that comes back short
fill(b: array of byte, name: string, off: int)
{
	seed := 1;
	for(i := 0; i < len name; i++)
		seed = seed*31 + int name[i];
	for(i = 0; i < len b; i++)
		b[i] = byte ((seed + off + i*7) & 16rff);
}

write(name: string, key: string, n: int): int
{
	path := dir + "/" + name;
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){
		fail(sys->sprint("create %s: %r", path));
		return -1;
	}
	b := array[4096] of byte;
	off := 0;
	while(off < n){
		m := len b;
		if(off + m > n)
			m = n - off;
		fill(b[0:m], key, off);
		if(sys->write(fd, b[0:m], m) != m){
			fail(sys->sprint("write %s at %d: %r", path, off));
			return -1;
		}
		off += m;
	}
	return 0;
}

check(name: string, key: string, n: int): int
{
	path := dir + "/" + name;
	(ok, d) := sys->stat(path);
	if(ok < 0){
		fail(sys->sprint("stat %s: %r", path));
		return -1;
	}
	if(int d.length != n){
		fail(sys->sprint("%s is %bd bytes, wrote %d", path, d.length, n));
		return -1;
	}
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		fail(sys->sprint("open %s: %r", path));
		return -1;
	}
	b := array[4096] of byte;
	w := array[4096] of byte;
	off := 0;
	while(off < n){
		m := len b;
		if(off + m > n)
			m = n - off;
		if(sys->read(fd, b[0:m], m) != m){
			fail(sys->sprint("read %s at %d: %r", path, off));
			return -1;
		}
		fill(w[0:m], key, off);
		for(i := 0; i < m; i++)
			if(b[i] != w[i]){
				fail(sys->sprint("%s differs at %d", path, off+i));
				return -1;
			}
		off += m;
	}
	return 0;
}

rename(name, newname: string): int
{
	path := dir + "/" + name;
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return -1;
	d.name = newname;
	r := -1;
	{
		r = sys->wstat(path, d);
	} exception {
	"*" =>
		return -1;
	}
	return r;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil){
		sys->fprint(stderr, "fatstress: cannot load %s: %r\n", Arg->PATH);
		raise "fail:load";
	}
	rounds := 4;
	files := 12;
	maxk := 200;
	arg->init(argv);
	arg->setusage("fatstress [-n rounds] [-f files] [-s maxk] dir");
	while((c := arg->opt()) != 0)
		case c {
		'n' =>	rounds = int arg->earg();
		'f' =>	files = int arg->earg();
		's' =>	maxk = int arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	dir = hd argv;

	# Long names and short ones, because they take different numbers
	# of directory entries and only the long ones can straddle a
	# sector.  Sizes from nothing to a few hundred kilobytes, because
	# a file of no clusters, a file of one and a file of many are
	# three different paths through the allocator.
	sizes := array[] of {0, 1, 511, 512, 513, 4095, 4096, 8193};
	for(r := 0; r < rounds; r++){
		names: list of (string, string, int);
		for(i := 0; i < files; i++){
			name := sys->sprint("stress-%d-%d.dat", r, i);
			if(i % 3 == 0)
				name = sys->sprint("S%d%d.D", r, i);	# 8.3
			n := sizes[(r*files+i) % len sizes];
			if(i % 5 == 4)
				n = ((r*7+i) % maxk) * 1024;
			if(write(name, name, n) < 0)
				continue;
			if(check(name, name, n) < 0)
				continue;
			names = (name, name, n) :: names;
		}

		# rename every one of them, and check it still reads back:
		# a rename that loses half a start cluster shows here and
		# nowhere else
		# the contents follow the file, not the name: what is
		# checked after a rename is that the bytes written under
		# the old name are still there under the new one
		nl: list of (string, string, int);
		for(l := names; l != nil; l = tl l){
			(name, key, n) := hd l;
			newname := "r-" + name;
			if(rename(name, newname) < 0){
				fail(sys->sprint("rename %s: %r", name));
				continue;
			}
			if(check(newname, key, n) < 0)
				continue;
			nl = (newname, key, n) :: nl;
		}

		# a rename onto a name that exists must be refused, and must
		# leave both files as they were
		if(nl != nil && tl nl != nil){
			(a, ka, na) := hd nl;
			(b, kb, nb) := hd tl nl;
			if(rename(a, b) >= 0)
				fail(sys->sprint("rename %s onto %s was allowed", a, b));
			else {
				check(a, ka, na);
				check(b, kb, nb);
			}
		}

		# remove half of them, then write new ones, so the next
		# round allocates clusters that were just freed
		keep: list of (string, string, int);
		i = 0;
		for(l = nl; l != nil; l = tl l){
			(name, key, n) := hd l;
			if(i++ % 2 == 0){
				if(sys->remove(dir + "/" + name) < 0)
					fail(sys->sprint("remove %s: %r", name));
			} else
				keep = (name, key, n) :: keep;
		}
		# and everything kept must still be intact after all that
		for(l = keep; l != nil; l = tl l){
			(name, key, n) := hd l;
			check(name, key, n);
		}
		for(l = keep; l != nil; l = tl l){
			(name, nil, nil) := hd l;
			sys->remove(dir + "/" + name);
		}
		sys->print("fatstress: round %d done\n", r);
	}
	if(nfail > 0){
		sys->print("FATSTRESS-FAIL %d failures\n", nfail);
		raise "fail:stress";
	}
	sys->print("FATSTRESS-OK %d rounds, %d files each\n", rounds, files);
}
