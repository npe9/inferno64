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
extern unsigned char root37code[];
extern int root37len;
extern unsigned char root38code[];
extern int root38len;
extern unsigned char root39code[];
extern int root39len;
extern unsigned char root41code[];
extern int root41len;
extern unsigned char root42code[];
extern int root42len;
extern unsigned char root43code[];
extern int root43len;
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
extern unsigned char root51code[];
extern int root51len;
extern unsigned char root52code[];
extern int root52len;
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
extern unsigned char root74code[];
extern int root74len;
extern unsigned char root75code[];
extern int root75len;
extern unsigned char root76code[];
extern int root76len;
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
extern unsigned char root85code[];
extern int root85len;
int rootmaxq = 86;
Dirtab roottab[86] = {
	"",	{0, 0, QTDIR},	 0,	0555,
	"chan",	{1, 0, QTDIR},	 0,	0555,
	"dev",	{2, 0, QTDIR},	 0,	0555,
	"dis",	{3, 0, QTDIR},	 0,	0555,
	"env",	{4, 0, QTDIR},	 0,	0555,
	"fd",	{5, 0, QTDIR},	 0,	0555,
	"forth",	{6, 0, QTDIR},	 0,	0555,
	"n",	{7, 0, QTDIR},	 0,	0555,
	"net",	{8, 0, QTDIR},	 0,	0555,
	"net.alt",	{9, 0, QTDIR},	 0,	0555,
	"nvfs",	{10, 0, QTDIR},	 0,	0555,
	"prog",	{11, 0, QTDIR},	 0,	0555,
	"tmp",	{12, 0, QTDIR},	 0,	0555,
	"proc",	{13, 0, QTDIR},	 0,	0555,
	"osinit.dis",	{14, 0, QTFILE},	 0,	0444,
	"init.f",	{15, 0, QTFILE},	 0,	0444,
	"lib",	{16, 0, QTDIR},	 0,	0555,
	"svc",	{17, 0, QTDIR},	 0,	0555,
	"wm",	{18, 0, QTDIR},	 0,	0555,
	"init",	{19, 0, QTFILE},	 0,	0444,
	"shutdown",	{20, 0, QTFILE},	 0,	0444,
	"basename.dis",	{21, 0, QTFILE},	 0,	0444,
	"bind.dis",	{22, 0, QTFILE},	 0,	0444,
	"cat.dis",	{23, 0, QTFILE},	 0,	0444,
	"cd.dis",	{24, 0, QTFILE},	 0,	0444,
	"diskparts",	{25, 0, QTFILE},	 0,	0444,
	"echo.dis",	{26, 0, QTFILE},	 0,	0444,
	"ftest.dis",	{27, 0, QTFILE},	 0,	0444,
	"grep.dis",	{28, 0, QTFILE},	 0,	0444,
	"ls.dis",	{29, 0, QTFILE},	 0,	0444,
	"mntgen.dis",	{30, 0, QTFILE},	 0,	0444,
	"mount.dis",	{31, 0, QTFILE},	 0,	0444,
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
	"usb",	{43, 0, QTDIR},	 0,	0555,
	"cat.f",	{44, 0, QTFILE},	 0,	0444,
	"helpers.f",	{45, 0, QTFILE},	 0,	0444,
	"ns.f",	{46, 0, QTFILE},	 0,	0444,
	"arg.dis",	{47, 0, QTFILE},	 0,	0444,
	"auth.dis",	{48, 0, QTFILE},	 0,	0444,
	"bufio.dis",	{49, 0, QTFILE},	 0,	0444,
	"daytime.dis",	{50, 0, QTFILE},	 0,	0444,
	"dhcpclient.dis",	{51, 0, QTFILE},	 0,	0444,
	"dial.dis",	{52, 0, QTFILE},	 0,	0444,
	"disks.dis",	{53, 0, QTFILE},	 0,	0444,
	"env.dis",	{54, 0, QTFILE},	 0,	0444,
	"factotum.dis",	{55, 0, QTFILE},	 0,	0444,
	"filepat.dis",	{56, 0, QTFILE},	 0,	0444,
	"ip.dis",	{57, 0, QTFILE},	 0,	0444,
	"names.dis",	{58, 0, QTFILE},	 0,	0444,
	"nametree.dis",	{59, 0, QTFILE},	 0,	0444,
	"rand.dis",	{60, 0, QTFILE},	 0,	0444,
	"random.dis",	{61, 0, QTFILE},	 0,	0444,
	"readdir.dis",	{62, 0, QTFILE},	 0,	0444,
	"regex.dis",	{63, 0, QTFILE},	 0,	0444,
	"ssl.dis",	{64, 0, QTFILE},	 0,	0444,
	"string.dis",	{65, 0, QTFILE},	 0,	0444,
	"styx.dis",	{66, 0, QTFILE},	 0,	0444,
	"styxconv",	{67, 0, QTDIR},	 0,	0555,
	"styxpersist.dis",	{68, 0, QTFILE},	 0,	0444,
	"styxservers.dis",	{69, 0, QTFILE},	 0,	0444,
	"timers.dis",	{70, 0, QTFILE},	 0,	0444,
	"workdir.dis",	{71, 0, QTFILE},	 0,	0444,
	"std.dis",	{72, 0, QTFILE},	 0,	0444,
	"fdisk.dis",	{73, 0, QTFILE},	 0,	0444,
	"kfs.dis",	{74, 0, QTFILE},	 0,	0444,
	"kfs64.dis",	{75, 0, QTFILE},	 0,	0444,
	"kfscmd.dis",	{76, 0, QTFILE},	 0,	0444,
	"prep.dis",	{77, 0, QTFILE},	 0,	0444,
	"calc.tab.dis",	{78, 0, QTFILE},	 0,	0444,
	"pedit.dis",	{79, 0, QTFILE},	 0,	0444,
	"dhcp.dis",	{80, 0, QTFILE},	 0,	0444,
	"ping.dis",	{81, 0, QTFILE},	 0,	0444,
	"factotum.dis",	{82, 0, QTFILE},	 0,	0444,
	"new2old.dis",	{83, 0, QTFILE},	 0,	0444,
	"ostyx.dis",	{84, 0, QTFILE},	 0,	0444,
	"usbd.dis",	{85, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[86] = {
	0,	 &roottab[1],	 15,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[16],	 28,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[44],	 3,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 root17code,	 0,	 &root17len,
	0,	 root18code,	 0,	 &root18len,
	3,	 &roottab[47],	 25,	nil,
	3,	 nil,	 0,	 nil,
	3,	 nil,	 0,	 nil,
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
	3,	 root37code,	 0,	 &root37len,
	3,	 root38code,	 0,	 &root38len,
	3,	 root39code,	 0,	 &root39len,
	3,	 &roottab[72],	 1,	nil,
	3,	 root42code,	 0,	 &root42len,
	3,	 root43code,	 0,	 &root43len,
	3,	 &roottab[73],	 7,	nil,
	3,	 &roottab[80],	 2,	nil,
	3,	 &roottab[82],	 1,	nil,
	3,	 &roottab[85],	 1,	nil,
	6,	 root19code,	 0,	 &root19len,
	6,	 root20code,	 0,	 &root20len,
	6,	 root21code,	 0,	 &root21len,
	16,	 root57code,	 0,	 &root57len,
	16,	 root58code,	 0,	 &root58len,
	16,	 root59code,	 0,	 &root59len,
	16,	 root60code,	 0,	 &root60len,
	16,	 root61code,	 0,	 &root61len,
	16,	 root62code,	 0,	 &root62len,
	16,	 root63code,	 0,	 &root63len,
	16,	 root64code,	 0,	 &root64len,
	16,	 root65code,	 0,	 &root65len,
	16,	 root66code,	 0,	 &root66len,
	16,	 root67code,	 0,	 &root67len,
	16,	 root68code,	 0,	 &root68len,
	16,	 root69code,	 0,	 &root69len,
	16,	 root70code,	 0,	 &root70len,
	16,	 root71code,	 0,	 &root71len,
	16,	 root72code,	 0,	 &root72len,
	16,	 root73code,	 0,	 &root73len,
	16,	 root74code,	 0,	 &root74len,
	16,	 root75code,	 0,	 &root75len,
	16,	 root76code,	 0,	 &root76len,
	16,	 &roottab[83],	 2,	nil,
	16,	 root80code,	 0,	 &root80len,
	16,	 root81code,	 0,	 &root81len,
	16,	 root82code,	 0,	 &root82len,
	16,	 root83code,	 0,	 &root83len,
	37,	 root41code,	 0,	 &root41len,
	40,	 root45code,	 0,	 &root45len,
	40,	 root46code,	 0,	 &root46len,
	40,	 root47code,	 0,	 &root47len,
	40,	 root48code,	 0,	 &root48len,
	40,	 root49code,	 0,	 &root49len,
	40,	 root55code,	 0,	 &root55len,
	40,	 root56code,	 0,	 &root56len,
	41,	 root51code,	 0,	 &root51len,
	41,	 root52code,	 0,	 &root52len,
	42,	 root54code,	 0,	 &root54len,
	67,	 root78code,	 0,	 &root78len,
	67,	 root79code,	 0,	 &root79len,
	43,	 root85code,	 0,	 &root85len,
};
