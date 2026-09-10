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
extern unsigned char root41code[];
extern int root41len;
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
extern unsigned char root57code[];
extern int root57len;
extern unsigned char root59code[];
extern int root59len;
extern unsigned char root60code[];
extern int root60len;
int rootmaxq = 61;
Dirtab roottab[61] = {
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
	"echo.dis",	{23, 0, QTFILE},	 0,	0444,
	"grep.dis",	{24, 0, QTFILE},	 0,	0444,
	"ls.dis",	{25, 0, QTFILE},	 0,	0444,
	"mntgen.dis",	{26, 0, QTFILE},	 0,	0444,
	"mount.dis",	{27, 0, QTFILE},	 0,	0444,
	"ns.dis",	{28, 0, QTFILE},	 0,	0444,
	"ps.dis",	{29, 0, QTFILE},	 0,	0444,
	"pwd.dis",	{30, 0, QTFILE},	 0,	0444,
	"read.dis",	{31, 0, QTFILE},	 0,	0444,
	"sh.dis",	{32, 0, QTFILE},	 0,	0444,
	"sh",	{33, 0, QTDIR},	 0,	0555,
	"unmount.dis",	{34, 0, QTFILE},	 0,	0444,
	"ip",	{35, 0, QTDIR},	 0,	0555,
	"arg.dis",	{36, 0, QTFILE},	 0,	0444,
	"bufio.dis",	{37, 0, QTFILE},	 0,	0444,
	"daytime.dis",	{38, 0, QTFILE},	 0,	0444,
	"env.dis",	{39, 0, QTFILE},	 0,	0444,
	"filepat.dis",	{40, 0, QTFILE},	 0,	0444,
	"names.dis",	{41, 0, QTFILE},	 0,	0444,
	"nametree.dis",	{42, 0, QTFILE},	 0,	0444,
	"readdir.dis",	{43, 0, QTFILE},	 0,	0444,
	"regex.dis",	{44, 0, QTFILE},	 0,	0444,
	"string.dis",	{45, 0, QTFILE},	 0,	0444,
	"styx.dis",	{46, 0, QTFILE},	 0,	0444,
	"styxconv",	{47, 0, QTDIR},	 0,	0555,
	"styxservers.dis",	{48, 0, QTFILE},	 0,	0444,
	"workdir.dis",	{49, 0, QTFILE},	 0,	0444,
	"dial.dis",	{50, 0, QTFILE},	 0,	0444,
	"dhcpclient.dis",	{51, 0, QTFILE},	 0,	0444,
	"ip.dis",	{52, 0, QTFILE},	 0,	0444,
	"rand.dis",	{53, 0, QTFILE},	 0,	0444,
	"random.dis",	{54, 0, QTFILE},	 0,	0444,
	"timers.dis",	{55, 0, QTFILE},	 0,	0444,
	"std.dis",	{56, 0, QTFILE},	 0,	0444,
	"new2old.dis",	{57, 0, QTFILE},	 0,	0444,
	"ostyx.dis",	{58, 0, QTFILE},	 0,	0444,
	"dhcp.dis",	{59, 0, QTFILE},	 0,	0444,
	"ping.dis",	{60, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[61] = {
	0,	 &roottab[1],	 13,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[14],	 22,	nil,
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
	3,	 &roottab[36],	 20,	nil,
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
	3,	 &roottab[56],	 1,	nil,
	3,	 root35code,	 0,	 &root35len,
	3,	 &roottab[59],	 2,	nil,
	14,	 root36code,	 0,	 &root36len,
	14,	 root37code,	 0,	 &root37len,
	14,	 root38code,	 0,	 &root38len,
	14,	 root39code,	 0,	 &root39len,
	14,	 root40code,	 0,	 &root40len,
	14,	 root41code,	 0,	 &root41len,
	14,	 root42code,	 0,	 &root42len,
	14,	 root43code,	 0,	 &root43len,
	14,	 root44code,	 0,	 &root44len,
	14,	 root45code,	 0,	 &root45len,
	14,	 root46code,	 0,	 &root46len,
	14,	 &roottab[57],	 2,	nil,
	14,	 root50code,	 0,	 &root50len,
	14,	 root51code,	 0,	 &root51len,
	14,	 root52code,	 0,	 &root52len,
	14,	 root53code,	 0,	 &root53len,
	14,	 root54code,	 0,	 &root54len,
	14,	 root55code,	 0,	 &root55len,
	14,	 root56code,	 0,	 &root56len,
	14,	 root57code,	 0,	 &root57len,
	33,	 root34code,	 0,	 &root34len,
	47,	 root48code,	 0,	 &root48len,
	47,	 root49code,	 0,	 &root49len,
	35,	 root59code,	 0,	 &root59len,
	35,	 root60code,	 0,	 &root60len,
};
