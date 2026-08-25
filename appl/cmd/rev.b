implement Rev;

#
#	rev: reverse the characters of each line.
#	Not part of this tree until now; the classic use is sorting on the
#	end of a word rather than its start - see sort(1) and man/1/rev.
#

include "sys.m"; sys: Sys;
include "bufio.m"; bufio: Bufio; Iobuf: import bufio;
include "draw.m";

Rev: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	args = tl args;

	if(args == nil)
		args = "-" :: nil;

	stdout := bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	if(stdout == nil){
		sys->fprint(sys->fildes(2), "rev: cannot open stdout: %r\n");
		raise "fail:bufio";
	}

	for(; args != nil; args = tl args){
		file := hd args;
		fd: ref Sys->FD;
		if(file == "-")
			fd = sys->fildes(0);
		else{
			fd = sys->open(file, Sys->OREAD);
			if(fd == nil){
				sys->fprint(sys->fildes(2), "rev: cannot open %s: %r\n", file);
				raise "fail:bad open";
			}
		}
		rev(fd, stdout);
	}
	stdout.flush();
}

rev(fd: ref Sys->FD, stdout: ref Iobuf)
{
	bio := bufio->fopen(fd, Bufio->OREAD);
	if(bio == nil){
		sys->fprint(sys->fildes(2), "rev: cannot open bufio: %r\n");
		raise "fail:bufio";
	}

	line: string;
	while((line = bio.gets('\n')) != nil){
		nl := 0;
		if(len line > 0 && line[len line - 1] == '\n'){
			nl = 1;
			line = line[0:len line - 1];
		}
		r := "";
		for(i := len line - 1; i >= 0; i--)
			r[len r] = line[i];
		if(nl)
			r[len r] = '\n';
		stdout.puts(r);
	}
}
