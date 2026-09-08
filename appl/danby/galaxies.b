implement Galaxies;

# danby/galaxies - the gravitational interaction of two galaxies
#
# The whole model is the script below: its bodies and their masses, its
# parameters and their ranges, where everything starts and the
# accelerations between them.  orblab(2) is a library this calls with
# that script - it owns the window, the integrator, the trails and the
# controls, and knows nothing about this model.

include "sys.m";
include "draw.m";
include "orblab.m";
	orblab: Orblab;

Galaxies: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SPEC: con
	"title Gravitational interaction between two galaxies\n" +
	"param galaxy_A_mass 2.0 0.2 6.0\n" +
	"param galaxy_B_mass 2.0 0.2 6.0\n" +
	"param separation 4.5 1.0 10.0\n" +
	"param approach_speed 0.25 0.0 1.0\n" +
	"param softening 0.12 0.02 0.6\n" +
	"param gravity 1.0 0.2 2.0\n" +
	"maxtime 35.0\n" +
	"body core_A galaxy_A_mass\n" +
	"body core_B galaxy_B_mass\n" +
	"body A1 0.08\n" +
	"body A2 0.08\n" +
	"body B1 0.08\n" +
	"body B2 0.08\n" +
	"state xA - separation over 2.0\n" +
	"state yA 0.0\n" +
	"state vxA approach_speed\n" +
	"state vyA 0.12\n" +
	"state xB separation over 2.0\n" +
	"state yB 0.0\n" +
	"state vxB - approach_speed\n" +
	"state vyB - 0.12\n" +
	"state xC - separation over 2.0 - 0.8\n" +
	"state yC 0.0\n" +
	"state vxC approach_speed\n" +
	"state vyC - 0.6\n" +
	"state xD - separation over 2.0 + 0.8\n" +
	"state yD 0.0\n" +
	"state vxD approach_speed\n" +
	"state vyD 0.6\n" +
	"state xE separation over 2.0 - 0.8\n" +
	"state yE 0.0\n" +
	"state vxE - approach_speed\n" +
	"state vyE - 0.6\n" +
	"state xF separation over 2.0 + 0.8\n" +
	"state yF 0.0\n" +
	"state vxF - approach_speed\n" +
	"state vyF 0.6\n" +
	# Newtonian gravity between every pair, softened so a close
	# approach stays finite.  6 bodies is 15 pairs, written out.
	"eq soft2 softening softening\n" +
	"eq dxAB xB - xA\n" +
	"eq dyAB yB - yA\n" +
	"eq rAB dxAB dxAB + dyAB dyAB + soft2\n" +
	"eq iAB 1.0 over { rAB sqrt { rAB } }\n" +
	"eq fxAB gravity dxAB iAB\n" +
	"eq fyAB gravity dyAB iAB\n" +
	"eq dxAC xC - xA\n" +
	"eq dyAC yC - yA\n" +
	"eq rAC dxAC dxAC + dyAC dyAC + soft2\n" +
	"eq iAC 1.0 over { rAC sqrt { rAC } }\n" +
	"eq fxAC gravity dxAC iAC\n" +
	"eq fyAC gravity dyAC iAC\n" +
	"eq dxAD xD - xA\n" +
	"eq dyAD yD - yA\n" +
	"eq rAD dxAD dxAD + dyAD dyAD + soft2\n" +
	"eq iAD 1.0 over { rAD sqrt { rAD } }\n" +
	"eq fxAD gravity dxAD iAD\n" +
	"eq fyAD gravity dyAD iAD\n" +
	"eq dxAE xE - xA\n" +
	"eq dyAE yE - yA\n" +
	"eq rAE dxAE dxAE + dyAE dyAE + soft2\n" +
	"eq iAE 1.0 over { rAE sqrt { rAE } }\n" +
	"eq fxAE gravity dxAE iAE\n" +
	"eq fyAE gravity dyAE iAE\n" +
	"eq dxAF xF - xA\n" +
	"eq dyAF yF - yA\n" +
	"eq rAF dxAF dxAF + dyAF dyAF + soft2\n" +
	"eq iAF 1.0 over { rAF sqrt { rAF } }\n" +
	"eq fxAF gravity dxAF iAF\n" +
	"eq fyAF gravity dyAF iAF\n" +
	"eq dxBC xC - xB\n" +
	"eq dyBC yC - yB\n" +
	"eq rBC dxBC dxBC + dyBC dyBC + soft2\n" +
	"eq iBC 1.0 over { rBC sqrt { rBC } }\n" +
	"eq fxBC gravity dxBC iBC\n" +
	"eq fyBC gravity dyBC iBC\n" +
	"eq dxBD xD - xB\n" +
	"eq dyBD yD - yB\n" +
	"eq rBD dxBD dxBD + dyBD dyBD + soft2\n" +
	"eq iBD 1.0 over { rBD sqrt { rBD } }\n" +
	"eq fxBD gravity dxBD iBD\n" +
	"eq fyBD gravity dyBD iBD\n" +
	"eq dxBE xE - xB\n" +
	"eq dyBE yE - yB\n" +
	"eq rBE dxBE dxBE + dyBE dyBE + soft2\n" +
	"eq iBE 1.0 over { rBE sqrt { rBE } }\n" +
	"eq fxBE gravity dxBE iBE\n" +
	"eq fyBE gravity dyBE iBE\n" +
	"eq dxBF xF - xB\n" +
	"eq dyBF yF - yB\n" +
	"eq rBF dxBF dxBF + dyBF dyBF + soft2\n" +
	"eq iBF 1.0 over { rBF sqrt { rBF } }\n" +
	"eq fxBF gravity dxBF iBF\n" +
	"eq fyBF gravity dyBF iBF\n" +
	"eq dxCD xD - xC\n" +
	"eq dyCD yD - yC\n" +
	"eq rCD dxCD dxCD + dyCD dyCD + soft2\n" +
	"eq iCD 1.0 over { rCD sqrt { rCD } }\n" +
	"eq fxCD gravity dxCD iCD\n" +
	"eq fyCD gravity dyCD iCD\n" +
	"eq dxCE xE - xC\n" +
	"eq dyCE yE - yC\n" +
	"eq rCE dxCE dxCE + dyCE dyCE + soft2\n" +
	"eq iCE 1.0 over { rCE sqrt { rCE } }\n" +
	"eq fxCE gravity dxCE iCE\n" +
	"eq fyCE gravity dyCE iCE\n" +
	"eq dxCF xF - xC\n" +
	"eq dyCF yF - yC\n" +
	"eq rCF dxCF dxCF + dyCF dyCF + soft2\n" +
	"eq iCF 1.0 over { rCF sqrt { rCF } }\n" +
	"eq fxCF gravity dxCF iCF\n" +
	"eq fyCF gravity dyCF iCF\n" +
	"eq dxDE xE - xD\n" +
	"eq dyDE yE - yD\n" +
	"eq rDE dxDE dxDE + dyDE dyDE + soft2\n" +
	"eq iDE 1.0 over { rDE sqrt { rDE } }\n" +
	"eq fxDE gravity dxDE iDE\n" +
	"eq fyDE gravity dyDE iDE\n" +
	"eq dxDF xF - xD\n" +
	"eq dyDF yF - yD\n" +
	"eq rDF dxDF dxDF + dyDF dyDF + soft2\n" +
	"eq iDF 1.0 over { rDF sqrt { rDF } }\n" +
	"eq fxDF gravity dxDF iDF\n" +
	"eq fyDF gravity dyDF iDF\n" +
	"eq dxEF xF - xE\n" +
	"eq dyEF yF - yE\n" +
	"eq rEF dxEF dxEF + dyEF dyEF + soft2\n" +
	"eq iEF 1.0 over { rEF sqrt { rEF } }\n" +
	"eq fxEF gravity dxEF iEF\n" +
	"eq fyEF gravity dyEF iEF\n" +
	"derivative xA vxA\n" +
	"derivative yA vyA\n" +
	"derivative vxA galaxy_B_mass fxAB + 0.08 fxAC + 0.08 fxAD + 0.08 fxAE + 0.08 fxAF\n" +
	"derivative vyA galaxy_B_mass fyAB + 0.08 fyAC + 0.08 fyAD + 0.08 fyAE + 0.08 fyAF\n" +
	"derivative xB vxB\n" +
	"derivative yB vyB\n" +
	"derivative vxB - galaxy_A_mass fxAB + 0.08 fxBC + 0.08 fxBD + 0.08 fxBE + 0.08 fxBF\n" +
	"derivative vyB - galaxy_A_mass fyAB + 0.08 fyBC + 0.08 fyBD + 0.08 fyBE + 0.08 fyBF\n" +
	"derivative xC vxC\n" +
	"derivative yC vyC\n" +
	"derivative vxC - galaxy_A_mass fxAC - galaxy_B_mass fxBC + 0.08 fxCD + 0.08 fxCE + 0.08 fxCF\n" +
	"derivative vyC - galaxy_A_mass fyAC - galaxy_B_mass fyBC + 0.08 fyCD + 0.08 fyCE + 0.08 fyCF\n" +
	"derivative xD vxD\n" +
	"derivative yD vyD\n" +
	"derivative vxD - galaxy_A_mass fxAD - galaxy_B_mass fxBD - 0.08 fxCD + 0.08 fxDE + 0.08 fxDF\n" +
	"derivative vyD - galaxy_A_mass fyAD - galaxy_B_mass fyBD - 0.08 fyCD + 0.08 fyDE + 0.08 fyDF\n" +
	"derivative xE vxE\n" +
	"derivative yE vyE\n" +
	"derivative vxE - galaxy_A_mass fxAE - galaxy_B_mass fxBE - 0.08 fxCE - 0.08 fxDE + 0.08 fxEF\n" +
	"derivative vyE - galaxy_A_mass fyAE - galaxy_B_mass fyBE - 0.08 fyCE - 0.08 fyDE + 0.08 fyEF\n" +
	"derivative xF vxF\n" +
	"derivative yF vyF\n" +
	"derivative vxF - galaxy_A_mass fxAF - galaxy_B_mass fxBF - 0.08 fxCF - 0.08 fxDF - 0.08 fxEF\n" +
	"derivative vyF - galaxy_A_mass fyAF - galaxy_B_mass fyBF - 0.08 fyCF - 0.08 fyDF - 0.08 fyEF\n" +
	"eq kinetic 0.5 galaxy_A_mass { vxA vxA + vyA vyA } + 0.5 galaxy_B_mass { vxB vxB + vyB vyB } + 0.5 0.08 { vxC vxC + vyC vyC } + 0.5 0.08 { vxD vxD + vyD vyD } + 0.5 0.08 { vxE vxE + vyE vyE } + 0.5 0.08 { vxF vxF + vyF vyF }\n" +
	"eq potAB - gravity galaxy_A_mass galaxy_B_mass over sqrt { dxAB dxAB + dyAB dyAB + soft2 }\n" +
	"eq potAC - gravity galaxy_A_mass 0.08 over sqrt { dxAC dxAC + dyAC dyAC + soft2 }\n" +
	"eq potAD - gravity galaxy_A_mass 0.08 over sqrt { dxAD dxAD + dyAD dyAD + soft2 }\n" +
	"eq potAE - gravity galaxy_A_mass 0.08 over sqrt { dxAE dxAE + dyAE dyAE + soft2 }\n" +
	"eq potAF - gravity galaxy_A_mass 0.08 over sqrt { dxAF dxAF + dyAF dyAF + soft2 }\n" +
	"eq potBC - gravity galaxy_B_mass 0.08 over sqrt { dxBC dxBC + dyBC dyBC + soft2 }\n" +
	"eq potBD - gravity galaxy_B_mass 0.08 over sqrt { dxBD dxBD + dyBD dyBD + soft2 }\n" +
	"eq potBE - gravity galaxy_B_mass 0.08 over sqrt { dxBE dxBE + dyBE dyBE + soft2 }\n" +
	"eq potBF - gravity galaxy_B_mass 0.08 over sqrt { dxBF dxBF + dyBF dyBF + soft2 }\n" +
	"eq potCD - gravity 0.08 0.08 over sqrt { dxCD dxCD + dyCD dyCD + soft2 }\n" +
	"eq potCE - gravity 0.08 0.08 over sqrt { dxCE dxCE + dyCE dyCE + soft2 }\n" +
	"eq potCF - gravity 0.08 0.08 over sqrt { dxCF dxCF + dyCF dyCF + soft2 }\n" +
	"eq potDE - gravity 0.08 0.08 over sqrt { dxDE dxDE + dyDE dyDE + soft2 }\n" +
	"eq potDF - gravity 0.08 0.08 over sqrt { dxDF dxDF + dyDF dyDF + soft2 }\n" +
	"eq potEF - gravity 0.08 0.08 over sqrt { dxEF dxEF + dyEF dyEF + soft2 }\n" +
	"\n" +
	"observable core_separation sqrt { { xB - xA } { xB - xA } + { yB - yA } { yB - yA } }\n" +
	"observable system_energy kinetic + potAB + potAC + potAD + potAE + potAF + potBC + potBD + potBE + potBF + potCD + potCE + potCF + potDE + potDF + potEF\n";

init(ctxt: ref Draw->Context, nil: list of string)
{
	orblab = load Orblab Orblab->PATH;
	if(orblab == nil)
		raise "fail:galaxies: cannot load orblab";
	if((e := orblab->run(ctxt, "galaxies", SPEC)) != nil)
		raise "fail:galaxies: "+e;
}
