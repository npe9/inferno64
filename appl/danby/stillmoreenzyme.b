implement Stillmoreenzyme;

# danby/stillmoreenzyme - cooperative two-site enzyme kinetics
#
# The whole model is the script below: its parameters and their ranges,
# its populations and the equations that move them.  danbylab(2) is a
# library this calls with that script - it owns the window, the
# integrator and the controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Stillmoreenzyme: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family population\n" +
	"title Cooperative two-site enzyme kinetics\n" +
	"param first_binding 1.8 0.0 8.0\n" +
	"param first_release 0.5 0.0 4.0\n" +
	"param second_binding 1.5 0.0 8.0\n" +
	"param second_release 0.4 0.0 4.0\n" +
	"param catalysis 0.8 0.0 4.0\n" +
	"maxtime 100.0\n" +
	"state substrate 2.0\n" +
	"state enzyme 0.35\n" +
	"state one_bound 0.0\n" +
	"state two_bound 0.0\n" +
	"state product 0.0\n" +
	"eq cS { substrate + abs { substrate } } over 2.0\n" +
	"eq cE { enzyme + abs { enzyme } } over 2.0\n" +
	"eq c1 { one_bound + abs { one_bound } } over 2.0\n" +
	"eq c2 { two_bound + abs { two_bound } } over 2.0\n" +
	"eq f1 first_binding cS cE\n" +
	"eq r1 first_release c1\n" +
	"eq f2 second_binding cS c1\n" +
	"eq r2 second_release c2\n" +
	"eq cat catalysis c2\n" +
	"derivative substrate - f1 + r1 - f2 + r2\n" +
	"derivative enzyme - f1 + r1 + cat\n" +
	"derivative one_bound f1 - r1 - f2 + r2\n" +
	"derivative two_bound f2 - r2 - cat\n" +
	"derivative product 2.0 cat\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:stillmoreenzyme: cannot load danbylab";
	if((e := danbylab->run(ctxt, "stillmoreenzyme", SPEC)) != nil)
		raise "fail:stillmoreenzyme: "+e;
}
