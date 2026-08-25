implement Paste;

#
#	paste: merge corresponding lines of several files, tab-separated.
#	Not part of this tree until now; the classic use is putting two
#	parallel derived files - a word list and the same list shifted one
#	line - back into pairs on one line each. See man/1/paste.
#
#	Scope: no -d (alternate delimiters) or -s (serial, one file at a
#	time) - neither is needed to merge parallel files line by line,
#	which is the one thing this was built for.
#

include "sys.m"; sys: Sys;
include "bufio.m"; bufio: Bufio; Iobuf: import bufio;
include "draw.m";

Paste: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	args = tl args;

	if(args == nil){
		sys->fprint(sys->fildes(2), "usage: paste file ...\n");
		raise "fail:usage";
	}

	n := len args;
	ios := array[n] of ref Iobuf;
	i := 0;
	for(a := args; a != nil; a = tl a){
		file := hd a;
		fd: ref Sys->FD;
		if(file == "-")
			fd = sys->fildes(0);
		else{
			fd = sys->open(file, Sys->OREAD);
			if(fd == nil){
				sys->fprint(sys->fildes(2), "paste: cannot open %s: %r\n", file);
				raise "fail:bad open";
			}
		}
		ios[i] = bufio->fopen(fd, Bufio->OREAD);
		i++;
	}

	stdout := bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	if(stdout == nil){
		sys->fprint(sys->fildes(2), "paste: cannot open stdout: %r\n");
		raise "fail:bufio";
	}

	for(;;){
		out := "";
		any := 0;
		for(j := 0; j < n; j++){
			field := "";
			if(ios[j] != nil){
				l := ios[j].gets('\n');
				if(l == nil)
					ios[j] = nil;
				else{
					any = 1;
					if(len l > 0 && l[len l - 1] == '\n')
						l = l[0:len l - 1];
					field = l;
				}
			}
			if(j > 0)
				out = out + "\t";
			out = out + field;
		}
		if(!any)
			break;
		out = out + "\n";
		stdout.puts(out);
	}
	stdout.flush();
}
