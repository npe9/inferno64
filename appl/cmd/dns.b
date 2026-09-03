implement Command;

# dns(1) - resolve a hostname over DNS-over-HTTPS (doh(2)), printing
# its addresses. Because it resolves over this tree's own TLS through
# a resolver reached by literal IP, it works with no /net/cs and no
# host resolver - the first thing in this tree that can turn a name
# into an address by itself.
#
#   dns name ...          A (IPv4) records
#   dns -6 name ...       AAAA (IPv6) records
#   dns -s ip -u url name resolve through a different DoH provider

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "keyring.m";
include "security.m";
include "tls12.m";
include "doh.m";
	doh: DOH;
	Resolver: import doh;

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	doh = load DOH DOH->PATH;
	if(arg == nil || doh == nil){
		sys->fprint(stderr, "dns: cannot load support modules: %r\n");
		raise "fail:load";
	}
	if((e := doh->init()) != nil){
		sys->fprint(stderr, "dns: %s\n", e);
		raise "fail:init";
	}

	qtype := DOH->Ta;
	url := "";
	ip := "";
	arg->init(argv);
	arg->setusage("dns [-6] [-s resolver-ip] [-u resolver-url] name ...");
	while((o := arg->opt()) != 0)
		case o {
		'6' =>	qtype = DOH->Taaaa;
		's' =>	ip = arg->earg();
		'u' =>	url = arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();

	r := doh->gdns();
	if(ip != "")
		r.ip = ip;
	if(url != "")
		r.url = url;

	status := 0;
	for(; argv != nil; argv = tl argv){
		name := hd argv;
		(addrs, err) := doh->resolvetype(r, name, qtype);
		if(err != nil){
			sys->fprint(stderr, "dns: %s: %s\n", name, err);
			status = 1;
			continue;
		}
		for(; addrs != nil; addrs = tl addrs)
			sys->print("%s\t%s\n", name, hd addrs);
	}
	if(status)
		raise "fail:resolve";
}
