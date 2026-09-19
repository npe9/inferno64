implement Hget;

#
# Fetch a URL over plain HTTP, with request headers the caller chooses.
#
# webgrab(1) already fetches a URL; what it cannot do is send a header,
# and a cloud provider's metadata service answers nothing without one.
# This is the thin command wrapper over httpclient(2) that makes that
# reachable from a shell and from a test.
#
include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "httpclient.m";
	http: Httpclient;
	Hdr, Resp: import http;

Hget: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	arg := load Arg Arg->PATH;
	http = load Httpclient Httpclient->PATH;
	if(http == nil)
		fail(sys->sprint("cannot load %s: %r", Httpclient->PATH));
	if((err := http->init()) != nil)
		fail(err);

	hdrs: list of Hdr;
	showhdrs := 0;
	addr := "";
	arg->init(argv);
	arg->setusage("hget [-v] [-A addr] [-h 'name: value']... url");
	while((o := arg->opt()) != 0)
		case o {
		'h' =>	s := arg->earg();
			for(i := 0; i < len s; i++)
				if(s[i] == ':'){
					nm := s[0:i];
					v := s[i+1:];
					while(len v > 0 && v[0] == ' ')
						v = v[1:];
					hdrs = Hdr(nm, v) :: hdrs;
					break;
				}
		'A' =>	addr = arg->earg();
		'v' =>	showhdrs = 1;
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(len argv != 1)
		arg->usage();

	(r, e) := http->requestat("GET", hd argv, addr, hdrs, nil);
	if(e != nil)
		fail(e);
	if(showhdrs){
		sys->print("%d %s\n", r.code, r.reason);
		for(l := r.hdrs; l != nil; l = tl l){
			h := hd l;
			sys->print("%s: %s\n", h.name, h.val);
		}
		sys->print("\n");
	}
	if(r.code != 200)
		fail(sys->sprint("http %d %s", r.code, r.reason));
	if(len r.body > 0)
		sys->write(sys->fildes(1), r.body, len r.body);
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "hget: %s\n", s);
	raise "fail:" + s;
}
