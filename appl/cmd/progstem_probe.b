implement Progstem_probe;
include "sys.m";
	sys: Sys;
Progstem_probe: module { init: fn(nil: ref Draw->Context, argv: list of string); };
include "draw.m";
init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	pid := sys->pctl(0, nil);
	base := "/prog/"+string pid;
	sys->print("argv0=%q\n", hd argv);
	for(names := list of {"text", "status", "heap", "stack"}; names != nil; names = tl names){
		p := base+"/"+hd names;
		(ok, dir) := sys->stat(p);
		if(ok < 0){
			sys->print("%s: missing\n", hd names);
			continue;
		}
		sys->print("%s: length=%bd type=%d mode=%uo\n", hd names, dir.length, dir.dtype, dir.mode);
		f := sys->open(p, Sys->OREAD);
		if(f == nil){
			sys->print("%s: open %r\n", hd names);
			continue;
		}
		buf := array[256] of byte;
		n := sys->read(f, buf, len buf);
		sys->print("%s: read %d: %q\n", hd names, n, string buf[0:n]);
	}
}
