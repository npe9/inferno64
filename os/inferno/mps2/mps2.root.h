extern unsigned char root16code[];
extern int root16len;
extern unsigned char root17code[];
extern int root17len;
extern unsigned char root18code[];
extern int root18len;
extern unsigned char root19code[];
extern int root19len;
extern unsigned char root20code[];
extern int root20len;
extern unsigned char root21code[];
extern int root21len;
extern unsigned char root22code[];
extern int root22len;
extern unsigned char root23code[];
extern int root23len;
extern unsigned char root24code[];
extern int root24len;
extern unsigned char root25code[];
extern int root25len;
extern unsigned char root26code[];
extern int root26len;
extern unsigned char root27code[];
extern int root27len;
extern unsigned char root28code[];
extern int root28len;
extern unsigned char root29code[];
extern int root29len;
extern unsigned char root30code[];
extern int root30len;
extern unsigned char root31code[];
extern int root31len;
extern unsigned char root32code[];
extern int root32len;
extern unsigned char root34code[];
extern int root34len;
extern unsigned char root35code[];
extern int root35len;
extern unsigned char root36code[];
extern int root36len;
extern unsigned char root37code[];
extern int root37len;
extern unsigned char root38code[];
extern int root38len;
extern unsigned char root39code[];
extern int root39len;
extern unsigned char root40code[];
extern int root40len;
extern unsigned char root42code[];
extern int root42len;
extern unsigned char root43code[];
extern int root43len;
extern unsigned char root44code[];
extern int root44len;
extern unsigned char root45code[];
extern int root45len;
extern unsigned char root46code[];
extern int root46len;
extern unsigned char root47code[];
extern int root47len;
extern unsigned char root48code[];
extern int root48len;
extern unsigned char root49code[];
extern int root49len;
extern unsigned char root50code[];
extern int root50len;
extern unsigned char root51code[];
extern int root51len;
extern unsigned char root52code[];
extern int root52len;
extern unsigned char root53code[];
extern int root53len;
extern unsigned char root54code[];
extern int root54len;
extern unsigned char root55code[];
extern int root55len;
extern unsigned char root56code[];
extern int root56len;
extern unsigned char root58code[];
extern int root58len;
extern unsigned char root59code[];
extern int root59len;
extern unsigned char root60code[];
extern int root60len;
extern unsigned char root62code[];
extern int root62len;
extern unsigned char root63code[];
extern int root63len;
extern unsigned char root64code[];
extern int root64len;
extern unsigned char root65code[];
extern int root65len;
extern unsigned char root66code[];
extern int root66len;
extern unsigned char root68code[];
extern int root68len;
extern unsigned char root69code[];
extern int root69len;
extern unsigned char root71code[];
extern int root71len;
extern unsigned char root72code[];
extern int root72len;
extern unsigned char root73code[];
extern int root73len;
extern unsigned char root74code[];
extern int root74len;
extern unsigned char root75code[];
extern int root75len;
extern unsigned char root76code[];
extern int root76len;
extern unsigned char root77code[];
extern int root77len;
extern unsigned char root78code[];
extern int root78len;
extern unsigned char root79code[];
extern int root79len;
extern unsigned char root80code[];
extern int root80len;
extern unsigned char root81code[];
extern int root81len;
extern unsigned char root82code[];
extern int root82len;
extern unsigned char root83code[];
extern int root83len;
extern unsigned char root84code[];
extern int root84len;
extern unsigned char root85code[];
extern int root85len;
extern unsigned char root86code[];
extern int root86len;
extern unsigned char root87code[];
extern int root87len;
extern unsigned char root88code[];
extern int root88len;
extern unsigned char root89code[];
extern int root89len;
extern unsigned char root90code[];
extern int root90len;
extern unsigned char root91code[];
extern int root91len;
extern unsigned char root92code[];
extern int root92len;
extern unsigned char root93code[];
extern int root93len;
extern unsigned char root95code[];
extern int root95len;
extern unsigned char root96code[];
extern int root96len;
extern unsigned char root97code[];
extern int root97len;
extern unsigned char root98code[];
extern int root98len;
extern unsigned char root99code[];
extern int root99len;
extern unsigned char root100code[];
extern int root100len;
int rootmaxq = 101;
Dirtab roottab[101] = {
	"",	{0, 0, QTDIR},	 0,	0555,
	"chan",	{1, 0, QTDIR},	 0,	0555,
	"dev",	{2, 0, QTDIR},	 0,	0555,
	"dis",	{3, 0, QTDIR},	 0,	0555,
	"env",	{4, 0, QTDIR},	 0,	0555,
	"fd",	{5, 0, QTDIR},	 0,	0555,
	"n",	{6, 0, QTDIR},	 0,	0555,
	"net",	{7, 0, QTDIR},	 0,	0555,
	"net.alt",	{8, 0, QTDIR},	 0,	0555,
	"nvfs",	{9, 0, QTDIR},	 0,	0555,
	"prog",	{10, 0, QTDIR},	 0,	0555,
	"tmp",	{11, 0, QTDIR},	 0,	0555,
	"proc",	{12, 0, QTDIR},	 0,	0555,
	"osinit.dis",	{13, 0, QTFILE},	 0,	0444,
	"keys",	{14, 0, QTDIR},	 0,	0555,
	"lib",	{15, 0, QTDIR},	 0,	0555,
	"svc",	{16, 0, QTDIR},	 0,	0555,
	"wm",	{17, 0, QTDIR},	 0,	0555,
	"init",	{18, 0, QTFILE},	 0,	0444,
	"shutdown",	{19, 0, QTFILE},	 0,	0444,
	"basename.dis",	{20, 0, QTFILE},	 0,	0444,
	"bind.dis",	{21, 0, QTFILE},	 0,	0444,
	"cat.dis",	{22, 0, QTFILE},	 0,	0444,
	"cd.dis",	{23, 0, QTFILE},	 0,	0444,
	"diskparts",	{24, 0, QTFILE},	 0,	0444,
	"echo.dis",	{25, 0, QTFILE},	 0,	0444,
	"fptest.dis",	{26, 0, QTFILE},	 0,	0444,
	"cvtchk.dis",	{27, 0, QTFILE},	 0,	0444,
	"modchk.dis",	{28, 0, QTFILE},	 0,	0444,
	"authchk.dis",	{29, 0, QTFILE},	 0,	0444,
	"aprs.dis",	{30, 0, QTFILE},	 0,	0444,
	"kisschk.dis",	{31, 0, QTFILE},	 0,	0444,
	"ax25chk.dis",	{32, 0, QTFILE},	 0,	0444,
	"ax25raw.dis",	{33, 0, QTFILE},	 0,	0444,
	"lorachk.dis",	{34, 0, QTFILE},	 0,	0444,
	"loraraw.dis",	{35, 0, QTFILE},	 0,	0444,
	"radiochk.dis",	{36, 0, QTFILE},	 0,	0444,
	"radiossl.dis",	{37, 0, QTFILE},	 0,	0444,
	"radiostyx.dis",	{38, 0, QTFILE},	 0,	0444,
	"pycubed",	{39, 0, QTDIR},	 0,	0555,
	"ftest.dis",	{40, 0, QTFILE},	 0,	0444,
	"grep.dis",	{41, 0, QTFILE},	 0,	0444,
	"ls.dis",	{42, 0, QTFILE},	 0,	0444,
	"mntgen.dis",	{43, 0, QTFILE},	 0,	0444,
	"mount.dis",	{44, 0, QTFILE},	 0,	0444,
	"memfs.dis",	{45, 0, QTFILE},	 0,	0444,
	"dossrv.dis",	{46, 0, QTFILE},	 0,	0444,
	"ns.dis",	{47, 0, QTFILE},	 0,	0444,
	"ps.dis",	{48, 0, QTFILE},	 0,	0444,
	"pwd.dis",	{49, 0, QTFILE},	 0,	0444,
	"read.dis",	{50, 0, QTFILE},	 0,	0444,
	"sh.dis",	{51, 0, QTFILE},	 0,	0444,
	"sh",	{52, 0, QTDIR},	 0,	0555,
	"unmount.dis",	{53, 0, QTFILE},	 0,	0444,
	"9660srv.dis",	{54, 0, QTFILE},	 0,	0444,
	"disk",	{55, 0, QTDIR},	 0,	0555,
	"ip",	{56, 0, QTDIR},	 0,	0555,
	"auth",	{57, 0, QTDIR},	 0,	0555,
	"arg.dis",	{58, 0, QTFILE},	 0,	0444,
	"auth.dis",	{59, 0, QTFILE},	 0,	0444,
	"bufio.dis",	{60, 0, QTFILE},	 0,	0444,
	"daytime.dis",	{61, 0, QTFILE},	 0,	0444,
	"dhcpclient.dis",	{62, 0, QTFILE},	 0,	0444,
	"dial.dis",	{63, 0, QTFILE},	 0,	0444,
	"disks.dis",	{64, 0, QTFILE},	 0,	0444,
	"env.dis",	{65, 0, QTFILE},	 0,	0444,
	"factotum.dis",	{66, 0, QTFILE},	 0,	0444,
	"filepat.dis",	{67, 0, QTFILE},	 0,	0444,
	"ip.dis",	{68, 0, QTFILE},	 0,	0444,
	"names.dis",	{69, 0, QTFILE},	 0,	0444,
	"nametree.dis",	{70, 0, QTFILE},	 0,	0444,
	"rand.dis",	{71, 0, QTFILE},	 0,	0444,
	"random.dis",	{72, 0, QTFILE},	 0,	0444,
	"readdir.dis",	{73, 0, QTFILE},	 0,	0444,
	"regex.dis",	{74, 0, QTFILE},	 0,	0444,
	"ssl.dis",	{75, 0, QTFILE},	 0,	0444,
	"string.dis",	{76, 0, QTFILE},	 0,	0444,
	"styx.dis",	{77, 0, QTFILE},	 0,	0444,
	"styxconv",	{78, 0, QTDIR},	 0,	0555,
	"styxpersist.dis",	{79, 0, QTFILE},	 0,	0444,
	"styxservers.dis",	{80, 0, QTFILE},	 0,	0444,
	"timers.dis",	{81, 0, QTFILE},	 0,	0444,
	"workdir.dis",	{82, 0, QTFILE},	 0,	0444,
	"ground",	{83, 0, QTFILE},	 0,	0444,
	"satellite",	{84, 0, QTFILE},	 0,	0444,
	"beepsat.dis",	{85, 0, QTFILE},	 0,	0444,
	"sat.dis",	{86, 0, QTFILE},	 0,	0444,
	"hw.dis",	{87, 0, QTFILE},	 0,	0444,
	"std.dis",	{88, 0, QTFILE},	 0,	0444,
	"fdisk.dis",	{89, 0, QTFILE},	 0,	0444,
	"kfs.dis",	{90, 0, QTFILE},	 0,	0444,
	"kfs64.dis",	{91, 0, QTFILE},	 0,	0444,
	"kfscmd.dis",	{92, 0, QTFILE},	 0,	0444,
	"prep.dis",	{93, 0, QTFILE},	 0,	0444,
	"calc.tab.dis",	{94, 0, QTFILE},	 0,	0444,
	"pedit.dis",	{95, 0, QTFILE},	 0,	0444,
	"dhcp.dis",	{96, 0, QTFILE},	 0,	0444,
	"ping.dis",	{97, 0, QTFILE},	 0,	0444,
	"factotum.dis",	{98, 0, QTFILE},	 0,	0444,
	"new2old.dis",	{99, 0, QTFILE},	 0,	0444,
	"ostyx.dis",	{100, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[101] = {
	0,	 &roottab[1],	 14,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[15],	 43,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 root16code,	 0,	 &root16len,
	0,	 &roottab[83],	 2,	nil,
	3,	 &roottab[58],	 25,	nil,
	3,	 nil,	 0,	 nil,
	3,	 nil,	 0,	 nil,
	3,	 root17code,	 0,	 &root17len,
	3,	 root18code,	 0,	 &root18len,
	3,	 root19code,	 0,	 &root19len,
	3,	 root20code,	 0,	 &root20len,
	3,	 root21code,	 0,	 &root21len,
	3,	 root22code,	 0,	 &root22len,
	3,	 root23code,	 0,	 &root23len,
	3,	 root24code,	 0,	 &root24len,
	3,	 root25code,	 0,	 &root25len,
	3,	 root26code,	 0,	 &root26len,
	3,	 root27code,	 0,	 &root27len,
	3,	 root28code,	 0,	 &root28len,
	3,	 root29code,	 0,	 &root29len,
	3,	 root30code,	 0,	 &root30len,
	3,	 root31code,	 0,	 &root31len,
	3,	 root32code,	 0,	 &root32len,
	3,	 root36code,	 0,	 &root36len,
	3,	 root37code,	 0,	 &root37len,
	3,	 root38code,	 0,	 &root38len,
	3,	 root39code,	 0,	 &root39len,
	3,	 root40code,	 0,	 &root40len,
	3,	 &roottab[85],	 3,	nil,
	3,	 root45code,	 0,	 &root45len,
	3,	 root46code,	 0,	 &root46len,
	3,	 root47code,	 0,	 &root47len,
	3,	 root48code,	 0,	 &root48len,
	3,	 root49code,	 0,	 &root49len,
	3,	 root50code,	 0,	 &root50len,
	3,	 root51code,	 0,	 &root51len,
	3,	 root52code,	 0,	 &root52len,
	3,	 root53code,	 0,	 &root53len,
	3,	 root54code,	 0,	 &root54len,
	3,	 root55code,	 0,	 &root55len,
	3,	 root56code,	 0,	 &root56len,
	3,	 &roottab[88],	 1,	nil,
	3,	 root59code,	 0,	 &root59len,
	3,	 root60code,	 0,	 &root60len,
	3,	 &roottab[89],	 7,	nil,
	3,	 &roottab[96],	 2,	nil,
	3,	 &roottab[98],	 1,	nil,
	15,	 root74code,	 0,	 &root74len,
	15,	 root75code,	 0,	 &root75len,
	15,	 root76code,	 0,	 &root76len,
	15,	 root77code,	 0,	 &root77len,
	15,	 root78code,	 0,	 &root78len,
	15,	 root79code,	 0,	 &root79len,
	15,	 root80code,	 0,	 &root80len,
	15,	 root81code,	 0,	 &root81len,
	15,	 root82code,	 0,	 &root82len,
	15,	 root83code,	 0,	 &root83len,
	15,	 root84code,	 0,	 &root84len,
	15,	 root85code,	 0,	 &root85len,
	15,	 root86code,	 0,	 &root86len,
	15,	 root87code,	 0,	 &root87len,
	15,	 root88code,	 0,	 &root88len,
	15,	 root89code,	 0,	 &root89len,
	15,	 root90code,	 0,	 &root90len,
	15,	 root91code,	 0,	 &root91len,
	15,	 root92code,	 0,	 &root92len,
	15,	 root93code,	 0,	 &root93len,
	15,	 &roottab[99],	 2,	nil,
	15,	 root97code,	 0,	 &root97len,
	15,	 root98code,	 0,	 &root98len,
	15,	 root99code,	 0,	 &root99len,
	15,	 root100code,	 0,	 &root100len,
	14,	 root34code,	 0,	 &root34len,
	14,	 root35code,	 0,	 &root35len,
	39,	 root42code,	 0,	 &root42len,
	39,	 root43code,	 0,	 &root43len,
	39,	 root44code,	 0,	 &root44len,
	52,	 root58code,	 0,	 &root58len,
	55,	 root62code,	 0,	 &root62len,
	55,	 root63code,	 0,	 &root63len,
	55,	 root64code,	 0,	 &root64len,
	55,	 root65code,	 0,	 &root65len,
	55,	 root66code,	 0,	 &root66len,
	55,	 root72code,	 0,	 &root72len,
	55,	 root73code,	 0,	 &root73len,
	56,	 root68code,	 0,	 &root68len,
	56,	 root69code,	 0,	 &root69len,
	57,	 root71code,	 0,	 &root71len,
	78,	 root95code,	 0,	 &root95len,
	78,	 root96code,	 0,	 &root96len,
};
