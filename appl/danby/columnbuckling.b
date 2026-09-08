implement Columnbuckling;

# danby/columnbuckling - dynamic buckling of a column
#
# The whole model is the script below: its parameters and their ranges,
# its state and the equations that move it, the points that draw it and
# the two quantities it plots.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator and the controls, and
# knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Columnbuckling: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family mechanism\n" +
	"title Dynamic buckling of a column\n" +
	"param mass 1.0 0.1 5.0\n" +
	"param compressive_load 1.3 -2.0 5.0\n" +
	"param post_buckling 1.0 0.05 5.0\n" +
	"param damping 0.12 0.0 2.0\n" +
	"param initial_offset 0.08 -1.0 1.0\n" +
	"maxtime 30.0\n" +
	"state x initial_offset\n" +
	"state v 0.0\n" +
	"derivative x v\n" +
	"derivative v { compressive_load x - post_buckling x x x - damping v } over mass\n" +
	"point foot 0.0 , - 1.5\n" +
	"point lower { 0.65 x } , - 0.5\n" +
	"point upper x , 0.5\n" +
	"point head 0.0 , 1.5\n" +
	"point base_left - 0.5 , - 1.5\n" +
	"point base_right 0.5 , - 1.5\n" +
	"link foot lower\n" +
	"link lower upper\n" +
	"link upper head\n" +
	"link base_left base_right\n" +
	"observable lateral_deflection x\n" +
	"observable velocity v\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:columnbuckling: cannot load danbylab";
	if((e := danbylab->run(ctxt, "columnbuckling", SPEC)) != nil)
		raise "fail:columnbuckling: "+e;
}
