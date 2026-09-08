implement Threebody;

# danby/threebody - the motion of three bodies
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  danbylab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "danbylab.m";
	danbylab: Danbylab;

Threebody: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"family orbit\n" +
	"title The motion of three bodies\n" +
	"param mass_A 1.0 0.1 3.0\n" +
	"param mass_B 1.0 0.1 3.0\n" +
	"param mass_C 0.5 0.1 3.0\n" +
	"param gravity 1.0 0.1 3.0\n" +
	"param softening 0.015 0.001 0.1\n" +
	"param perturbation 0.03 -0.2 0.2\n" +
	"maxtime 30.0\n" +
	"body A mass_A\n" +
	"body B mass_B\n" +
	"body C mass_C\n" +
	"state xa - 0.5\n" +
	"state ya - 0.288675\n" +
	"state vxa sqrt { gravity { mass_A + mass_B + mass_C } } 0.288675\n" +
	"state vya - sqrt { gravity { mass_A + mass_B + mass_C } } 0.5\n" +
	"state xb 0.5\n" +
	"state yb - 0.288675\n" +
	"state vxb sqrt { gravity { mass_A + mass_B + mass_C } } 0.288675\n" +
	"state vyb sqrt { gravity { mass_A + mass_B + mass_C } } 0.5 + perturbation\n" +
	"state xc 0.0\n" +
	"state yc 0.57735\n" +
	"state vxc - sqrt { gravity { mass_A + mass_B + mass_C } } 0.57735\n" +
	"state vyc 0.0\n" +
	# Newtonian gravity between every pair, softened so that a close
	# approach stays finite.  Three bodies is three pairs, written out.
	"eq soft2 softening softening\n" +
	"eq dxab xb - xa\n" +
	"eq dyab yb - ya\n" +
	"eq rab dxab dxab + dyab dyab + soft2\n" +
	"eq iab 1.0 over { rab sqrt { rab } }\n" +
	"eq fxab gravity dxab iab\n" +
	"eq fyab gravity dyab iab\n" +
	"eq dxac xc - xa\n" +
	"eq dyac yc - ya\n" +
	"eq rac dxac dxac + dyac dyac + soft2\n" +
	"eq iac 1.0 over { rac sqrt { rac } }\n" +
	"eq fxac gravity dxac iac\n" +
	"eq fyac gravity dyac iac\n" +
	"eq dxbc xc - xb\n" +
	"eq dybc yc - yb\n" +
	"eq rbc dxbc dxbc + dybc dybc + soft2\n" +
	"eq ibc 1.0 over { rbc sqrt { rbc } }\n" +
	"eq fxbc gravity dxbc ibc\n" +
	"eq fybc gravity dybc ibc\n" +
	"derivative xa vxa\n" +
	"derivative ya vya\n" +
	"derivative vxa mass_B fxab + mass_C fxac\n" +
	"derivative vya mass_B fyab + mass_C fyac\n" +
	"derivative xb vxb\n" +
	"derivative yb vyb\n" +
	"derivative vxb - mass_A fxab + mass_C fxbc\n" +
	"derivative vyb - mass_A fyab + mass_C fybc\n" +
	"derivative xc vxc\n" +
	"derivative yc vyc\n" +
	"derivative vxc - mass_A fxac - mass_B fxbc\n" +
	"derivative vyc - mass_A fyac - mass_B fybc\n" +
	"eq kinetic 0.5 mass_A { vxa vxa + vya vya } + 0.5 mass_B { vxb vxb + vyb vyb } + 0.5 mass_C { vxc vxc + vyc vyc }\n" +
	"eq pab - gravity mass_A mass_B over sqrt { dxab dxab + dyab dyab + soft2 }\n" +
	"eq pac - gravity mass_A mass_C over sqrt { dxac dxac + dyac dyac + soft2 }\n" +
	"eq pbc - gravity mass_B mass_C over sqrt { dxbc dxbc + dybc dybc + soft2 }\n" +
	"observable energy kinetic + pab + pac + pbc\n" +
	"observable angular_momentum mass_A { xa vya - ya vxa } + mass_B { xb vyb - yb vxb } + mass_C { xc vyc - yc vxc }\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	danbylab = load Danbylab Danbylab->PATH;
	if(danbylab == nil)
		raise "fail:threebody: cannot load danbylab";
	if((e := danbylab->run(ctxt, "threebody", SPEC)) != nil)
		raise "fail:threebody: "+e;
}
