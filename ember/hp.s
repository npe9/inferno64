#0
	load	0(mp),$0,88(fp)
	frame	$1,96(fp)
	movp	8(mp),64(96(fp))
	lea	80(fp),32(96(fp))
	mcall	96(fp),$0,88(fp)
	ret	
	entry	0, 2
	desc	$0,24,"e0"
	desc	$1,72,"0080"
	desc	$2,104,"00d0"
	var	@mp,24
	string	@mp+0,"$Sys"
	string	@mp+8,"hello, inferno\n"
	module	Hp
	link	2,0,0x4244b354,"init"
	ldts	@ldt,1
	word	@ldt+0,1
	ext	@ldt+8,0xac849033,"print"
	source	"/tmp/hp.b"
