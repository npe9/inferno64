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
extern unsigned char root33code[];
extern int root33len;
extern unsigned char root34code[];
extern int root34len;
extern unsigned char root35code[];
extern int root35len;
extern unsigned char root36code[];
extern int root36len;
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
extern unsigned char root48code[];
extern int root48len;
extern unsigned char root49code[];
extern int root49len;
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
extern unsigned char root57code[];
extern int root57len;
extern unsigned char root58code[];
extern int root58len;
extern unsigned char root59code[];
extern int root59len;
extern unsigned char root60code[];
extern int root60len;
extern unsigned char root61code[];
extern int root61len;
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
extern unsigned char root67code[];
extern int root67len;
extern unsigned char root68code[];
extern int root68len;
extern unsigned char root69code[];
extern int root69len;
extern unsigned char root70code[];
extern int root70len;
extern unsigned char root71code[];
extern int root71len;
extern unsigned char root72code[];
extern int root72len;
extern unsigned char root73code[];
extern int root73len;
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
int rootmaxq = 81;
Dirtab roottab[81] = {
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
	"lib",	{14, 0, QTDIR},	 0,	0555,
	"svc",	{15, 0, QTDIR},	 0,	0555,
	"wm",	{16, 0, QTDIR},	 0,	0555,
	"init",	{17, 0, QTFILE},	 0,	0444,
	"shutdown",	{18, 0, QTFILE},	 0,	0444,
	"basename.dis",	{19, 0, QTFILE},	 0,	0444,
	"bind.dis",	{20, 0, QTFILE},	 0,	0444,
	"cat.dis",	{21, 0, QTFILE},	 0,	0444,
	"cd.dis",	{22, 0, QTFILE},	 0,	0444,
	"diskparts",	{23, 0, QTFILE},	 0,	0444,
	"echo.dis",	{24, 0, QTFILE},	 0,	0444,
	"ftest.dis",	{25, 0, QTFILE},	 0,	0444,
	"grep.dis",	{26, 0, QTFILE},	 0,	0444,
	"ls.dis",	{27, 0, QTFILE},	 0,	0444,
	"mntgen.dis",	{28, 0, QTFILE},	 0,	0444,
	"mount.dis",	{29, 0, QTFILE},	 0,	0444,
	"memfs.dis",	{30, 0, QTFILE},	 0,	0444,
	"dossrv.dis",	{31, 0, QTFILE},	 0,	0444,
	"ns.dis",	{32, 0, QTFILE},	 0,	0444,
	"ps.dis",	{33, 0, QTFILE},	 0,	0444,
	"pwd.dis",	{34, 0, QTFILE},	 0,	0444,
	"read.dis",	{35, 0, QTFILE},	 0,	0444,
	"sh.dis",	{36, 0, QTFILE},	 0,	0444,
	"sh",	{37, 0, QTDIR},	 0,	0555,
	"unmount.dis",	{38, 0, QTFILE},	 0,	0444,
	"9660srv.dis",	{39, 0, QTFILE},	 0,	0444,
	"disk",	{40, 0, QTDIR},	 0,	0555,
	"ip",	{41, 0, QTDIR},	 0,	0555,
	"auth",	{42, 0, QTDIR},	 0,	0555,
	"arg.dis",	{43, 0, QTFILE},	 0,	0444,
	"auth.dis",	{44, 0, QTFILE},	 0,	0444,
	"bufio.dis",	{45, 0, QTFILE},	 0,	0444,
	"daytime.dis",	{46, 0, QTFILE},	 0,	0444,
	"dhcpclient.dis",	{47, 0, QTFILE},	 0,	0444,
	"dial.dis",	{48, 0, QTFILE},	 0,	0444,
	"disks.dis",	{49, 0, QTFILE},	 0,	0444,
	"env.dis",	{50, 0, QTFILE},	 0,	0444,
	"factotum.dis",	{51, 0, QTFILE},	 0,	0444,
	"filepat.dis",	{52, 0, QTFILE},	 0,	0444,
	"ip.dis",	{53, 0, QTFILE},	 0,	0444,
	"names.dis",	{54, 0, QTFILE},	 0,	0444,
	"nametree.dis",	{55, 0, QTFILE},	 0,	0444,
	"rand.dis",	{56, 0, QTFILE},	 0,	0444,
	"random.dis",	{57, 0, QTFILE},	 0,	0444,
	"readdir.dis",	{58, 0, QTFILE},	 0,	0444,
	"regex.dis",	{59, 0, QTFILE},	 0,	0444,
	"ssl.dis",	{60, 0, QTFILE},	 0,	0444,
	"string.dis",	{61, 0, QTFILE},	 0,	0444,
	"styx.dis",	{62, 0, QTFILE},	 0,	0444,
	"styxconv",	{63, 0, QTDIR},	 0,	0555,
	"styxpersist.dis",	{64, 0, QTFILE},	 0,	0444,
	"styxservers.dis",	{65, 0, QTFILE},	 0,	0444,
	"timers.dis",	{66, 0, QTFILE},	 0,	0444,
	"workdir.dis",	{67, 0, QTFILE},	 0,	0444,
	"std.dis",	{68, 0, QTFILE},	 0,	0444,
	"fdisk.dis",	{69, 0, QTFILE},	 0,	0444,
	"kfs.dis",	{70, 0, QTFILE},	 0,	0444,
	"kfs64.dis",	{71, 0, QTFILE},	 0,	0444,
	"kfscmd.dis",	{72, 0, QTFILE},	 0,	0444,
	"prep.dis",	{73, 0, QTFILE},	 0,	0444,
	"calc.tab.dis",	{74, 0, QTFILE},	 0,	0444,
	"pedit.dis",	{75, 0, QTFILE},	 0,	0444,
	"dhcp.dis",	{76, 0, QTFILE},	 0,	0444,
	"ping.dis",	{77, 0, QTFILE},	 0,	0444,
	"factotum.dis",	{78, 0, QTFILE},	 0,	0444,
	"new2old.dis",	{79, 0, QTFILE},	 0,	0444,
	"ostyx.dis",	{80, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[81] = {
	0,	 &roottab[1],	 13,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[14],	 29,	nil,
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
	3,	 &roottab[43],	 25,	nil,
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
	3,	 root33code,	 0,	 &root33len,
	3,	 root34code,	 0,	 &root34len,
	3,	 root35code,	 0,	 &root35len,
	3,	 root36code,	 0,	 &root36len,
	3,	 &roottab[68],	 1,	nil,
	3,	 root39code,	 0,	 &root39len,
	3,	 root40code,	 0,	 &root40len,
	3,	 &roottab[69],	 7,	nil,
	3,	 &roottab[76],	 2,	nil,
	3,	 &roottab[78],	 1,	nil,
	14,	 root54code,	 0,	 &root54len,
	14,	 root55code,	 0,	 &root55len,
	14,	 root56code,	 0,	 &root56len,
	14,	 root57code,	 0,	 &root57len,
	14,	 root58code,	 0,	 &root58len,
	14,	 root59code,	 0,	 &root59len,
	14,	 root60code,	 0,	 &root60len,
	14,	 root61code,	 0,	 &root61len,
	14,	 root62code,	 0,	 &root62len,
	14,	 root63code,	 0,	 &root63len,
	14,	 root64code,	 0,	 &root64len,
	14,	 root65code,	 0,	 &root65len,
	14,	 root66code,	 0,	 &root66len,
	14,	 root67code,	 0,	 &root67len,
	14,	 root68code,	 0,	 &root68len,
	14,	 root69code,	 0,	 &root69len,
	14,	 root70code,	 0,	 &root70len,
	14,	 root71code,	 0,	 &root71len,
	14,	 root72code,	 0,	 &root72len,
	14,	 root73code,	 0,	 &root73len,
	14,	 &roottab[79],	 2,	nil,
	14,	 root77code,	 0,	 &root77len,
	14,	 root78code,	 0,	 &root78len,
	14,	 root79code,	 0,	 &root79len,
	14,	 root80code,	 0,	 &root80len,
	37,	 root38code,	 0,	 &root38len,
	40,	 root42code,	 0,	 &root42len,
	40,	 root43code,	 0,	 &root43len,
	40,	 root44code,	 0,	 &root44len,
	40,	 root45code,	 0,	 &root45len,
	40,	 root46code,	 0,	 &root46len,
	40,	 root52code,	 0,	 &root52len,
	40,	 root53code,	 0,	 &root53len,
	41,	 root48code,	 0,	 &root48len,
	41,	 root49code,	 0,	 &root49len,
	42,	 root51code,	 0,	 &root51len,
	63,	 root75code,	 0,	 &root75len,
	63,	 root76code,	 0,	 &root76len,
};
