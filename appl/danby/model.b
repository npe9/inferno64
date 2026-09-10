implement Model;

# danby/model - run a Danby model that is a text file
#
# A model in this collection is a script in two little languages -
# dynsys(2)'s equations and danbylab(2)'s picture - and for a long time
# every one of them was a Limbo module whose entire content was that
# script as a string constant, wrapped in forty lines of identical
# boilerplate.  The script is the model; the module was packaging.
#
# So the models are text files now, and this is the one command that
# runs them.  A spec file's first line is
#
#	#!/dis/danby/model.dis
#
# and the file is installed executable, so sh(1) runs `danby/duffing'
# by opening /dis/danby/duffing, seeing the header, and handing the path
# to this - see sh.b's own runexternal(), which falls back to that when
# there is no .dis of the name.  danby/NAME therefore still works
# exactly as it always did, and so does every man page and every
# launcher entry that says so.  danbylab(2)'s own parser skips lines
# beginning with #, so the header is a comment to the model and a
# hashpling to the shell, and neither has to know about the other.

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "danbylab.m";
	danbylab: Danbylab;

Model: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

usage()
{
	sys->fprint(sys->fildes(2), "usage: danby/model file\n");
	raise "fail:usage";
}

# The model's own name, for the man page danbylab opens from the Help
# menu: the basename of the spec, with no directory and no suffix.
namefor(path: string): string
{
	i := len path;
	while(i > 0 && path[i-1] != '/')
		i--;
	name := path[i:];
	for(j := 0; j < len name; j++)
		if(name[j] == '.')
			return name[0:j];
	return name;
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil){
		sys->fprint(sys->fildes(2), "danby/model: cannot load bufio: %r\n");
		raise "fail:load";
	}
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil){
		sys->fprint(sys->fildes(2), "danby/model: cannot load danbylab: %r\n");
		raise "fail:load";
	}
	argv = tl argv;
	if(argv == nil)
		usage();
	path := hd argv;
	iob := bufio->open(path, Bufio->OREAD);
	if(iob == nil){
		sys->fprint(sys->fildes(2), "danby/model: %s: %r\n", path);
		raise "fail:open";
	}
	spec := "";
	while((line := iob.gets('\n')) != nil)
		spec += line;
	iob.close();
	if(spec == nil){
		sys->fprint(sys->fildes(2), "danby/model: %s is empty\n", path);
		raise "fail:empty";
	}
	if((e := danbylab->run(ctxt, namefor(path), spec)) != nil){
		sys->fprint(sys->fildes(2), "danby/model: %s: %s\n", path, e);
		raise "fail:"+e;
	}
}
