extern unsigned char root13code[];
extern int root13len;
extern unsigned char root14code[];
extern int root14len;
extern unsigned char root15code[];
extern int root15len;
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
int rootmaxq = 45;
Dirtab roottab[45] = {
	"",	{0, 0, QTDIR},	 0,	0555,
	"chan",	{1, 0, QTDIR},	 0,	0555,
	"dev",	{2, 0, QTDIR},	 0,	0555,
	"dis",	{3, 0, QTDIR},	 0,	0555,
	"env",	{4, 0, QTDIR},	 0,	0555,
	"fd",	{5, 0, QTDIR},	 0,	0555,
	"n",	{6, 0, QTDIR},	 0,	0555,
	"net",	{7, 0, QTDIR},	 0,	0555,
	"prog",	{8, 0, QTDIR},	 0,	0555,
	"tmp",	{9, 0, QTDIR},	 0,	0555,
	"proc",	{10, 0, QTDIR},	 0,	0555,
	"osinit.dis",	{11, 0, QTFILE},	 0,	0444,
	"lib",	{12, 0, QTDIR},	 0,	0555,
	"sh",	{13, 0, QTDIR},	 0,	0555,
	"basename.dis",	{14, 0, QTFILE},	 0,	0444,
	"bind.dis",	{15, 0, QTFILE},	 0,	0444,
	"cat.dis",	{16, 0, QTFILE},	 0,	0444,
	"cd.dis",	{17, 0, QTFILE},	 0,	0444,
	"date.dis",	{18, 0, QTFILE},	 0,	0444,
	"echo.dis",	{19, 0, QTFILE},	 0,	0444,
	"fptest.dis",	{20, 0, QTFILE},	 0,	0444,
	"grep.dis",	{21, 0, QTFILE},	 0,	0444,
	"ls.dis",	{22, 0, QTFILE},	 0,	0444,
	"memfs.dis",	{23, 0, QTFILE},	 0,	0444,
	"mntgen.dis",	{24, 0, QTFILE},	 0,	0444,
	"mount.dis",	{25, 0, QTFILE},	 0,	0444,
	"ns.dis",	{26, 0, QTFILE},	 0,	0444,
	"ps.dis",	{27, 0, QTFILE},	 0,	0444,
	"pwd.dis",	{28, 0, QTFILE},	 0,	0444,
	"read.dis",	{29, 0, QTFILE},	 0,	0444,
	"sh.dis",	{30, 0, QTFILE},	 0,	0444,
	"unmount.dis",	{31, 0, QTFILE},	 0,	0444,
	"arg.dis",	{32, 0, QTFILE},	 0,	0444,
	"bufio.dis",	{33, 0, QTFILE},	 0,	0444,
	"daytime.dis",	{34, 0, QTFILE},	 0,	0444,
	"env.dis",	{35, 0, QTFILE},	 0,	0444,
	"filepat.dis",	{36, 0, QTFILE},	 0,	0444,
	"names.dis",	{37, 0, QTFILE},	 0,	0444,
	"nametree.dis",	{38, 0, QTFILE},	 0,	0444,
	"readdir.dis",	{39, 0, QTFILE},	 0,	0444,
	"string.dis",	{40, 0, QTFILE},	 0,	0444,
	"styx.dis",	{41, 0, QTFILE},	 0,	0444,
	"styxservers.dis",	{42, 0, QTFILE},	 0,	0444,
	"workdir.dis",	{43, 0, QTFILE},	 0,	0444,
	"std.dis",	{44, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[45] = {
	0,	 &roottab[1],	 11,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[12],	 20,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 root13code,	 0,	 &root13len,
	3,	 &roottab[32],	 12,	nil,
	3,	 &roottab[44],	 1,	nil,
	3,	 root14code,	 0,	 &root14len,
	3,	 root15code,	 0,	 &root15len,
	3,	 root16code,	 0,	 &root16len,
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
	3,	 root32code,	 0,	 &root32len,
	12,	 root33code,	 0,	 &root33len,
	12,	 root34code,	 0,	 &root34len,
	12,	 root35code,	 0,	 &root35len,
	12,	 root36code,	 0,	 &root36len,
	12,	 root37code,	 0,	 &root37len,
	12,	 root38code,	 0,	 &root38len,
	12,	 root39code,	 0,	 &root39len,
	12,	 root40code,	 0,	 &root40len,
	12,	 root41code,	 0,	 &root41len,
	12,	 root42code,	 0,	 &root42len,
	12,	 root43code,	 0,	 &root43len,
	12,	 root44code,	 0,	 &root44len,
	13,	 root31code,	 0,	 &root31len,
};
