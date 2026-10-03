/*
 * The x86 backends' registers (pc64/vmx.c, pc64/svm.c), and the
 * platform's view of them (vmplat.c and the devices under it).
 */
enum {
	VRax, VRbx, VRcx, VRdx, VRsi, VRdi, VRbp, VRsp,
	VR8, VR9, VR10, VR11, VR12, VR13, VR14, VR15,
	VRip, VRflags,
	VCr0, VCr2, VCr3, VCr4, VEfer,
	VCs, VCsbase, VCslimit, VCsattr,
	VDs, VDsbase, VDslimit, VDsattr,
	VEs, VEsbase, VEslimit, VEsattr,
	VFs, VFsbase, VFslimit, VFsattr,
	VGs, VGsbase, VGslimit, VGsattr,
	VSs, VSsbase, VSslimit, VSsattr,
	VTr, VTrbase, VTrlimit, VTrattr,
	VLdtr, VLdtrbase, VLdtrlimit, VLdtrattr,
	VGdtrbase, VGdtrlimit, VIdtrbase, VIdtrlimit,
	VNreg,
};

extern char *vm86regname[VNreg];
