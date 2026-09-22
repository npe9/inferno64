implement Cat;

include "sys.m";
	sys: Sys;

include "draw.m";

# Bufsize: 8192 where a Dis word is eight bytes, 512 where it is four.
# See module/w4/bufsize.m and module/w8/bufsize.m.
include "bufsize.m";

Cat: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

stdout: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stdout = sys->fildes(1);
	args = tl args;
	if(args == nil)
		args = "-" :: nil;
	for(; args != nil; args = tl args){
		file := hd args;
		if(file != "-"){
			fd := sys->open(file, Sys->OREAD);
			if(fd == nil){
				sys->fprint(sys->fildes(2), "cat: cannot open %s: %r\n", file);
				raise "fail:bad open";
			}
			cat(fd, file);
		}else
			cat(sys->fildes(0), "<stdin>");
	}
}

cat(fd: ref Sys->FD, file: string)
{
	buf := array[Bufsize] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		if(sys->write(stdout, buf, n) < n) {
			sys->fprint(sys->fildes(2), "cat: write error: %r\n");
			raise "fail:write error";
		}
	if(n < 0) {
		sys->fprint(sys->fildes(2), "cat: error reading %s: %r\n", file);
		raise "fail:read error";
	}
}
