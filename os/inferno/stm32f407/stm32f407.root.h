extern unsigned char root10code[];
extern int root10len;
extern unsigned char root12code[];
extern int root12len;
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
extern unsigned char root57code[];
extern int root57len;
extern unsigned char root58code[];
extern int root58len;
extern unsigned char root59code[];
extern int root59len;
int rootmaxq = 60;
Dirtab roottab[60] = {
	"",	{0, 0, QTDIR},	 0,	0555,
	"chan",	{1, 0, QTDIR},	 0,	0555,
	"dev",	{2, 0, QTDIR},	 0,	0555,
	"dis",	{3, 0, QTDIR},	 0,	0555,
	"env",	{4, 0, QTDIR},	 0,	0555,
	"fd",	{5, 0, QTDIR},	 0,	0555,
	"n",	{6, 0, QTDIR},	 0,	0555,
	"prog",	{7, 0, QTDIR},	 0,	0555,
	"tmp",	{8, 0, QTDIR},	 0,	0555,
	"proc",	{9, 0, QTDIR},	 0,	0555,
	"osinit.dis",	{10, 0, QTFILE},	 0,	0444,
	"lib",	{11, 0, QTDIR},	 0,	0555,
	"sh.dis",	{12, 0, QTFILE},	 0,	0444,
	"sh",	{13, 0, QTDIR},	 0,	0555,
	"lil.dis",	{14, 0, QTFILE},	 0,	0444,
	"echo.dis",	{15, 0, QTFILE},	 0,	0444,
	"radiocal.dis",	{16, 0, QTFILE},	 0,	0444,
	"ax25raw.dis",	{17, 0, QTFILE},	 0,	0444,
	"ax25chk.dis",	{18, 0, QTFILE},	 0,	0444,
	"export.dis",	{19, 0, QTFILE},	 0,	0444,
	"sed.dis",	{20, 0, QTFILE},	 0,	0444,
	"ed.dis",	{21, 0, QTFILE},	 0,	0444,
	"cat.dis",	{22, 0, QTFILE},	 0,	0444,
	"dd.dis",	{23, 0, QTFILE},	 0,	0444,
	"ls.dis",	{24, 0, QTFILE},	 0,	0444,
	"bind.dis",	{25, 0, QTFILE},	 0,	0444,
	"pwd.dis",	{26, 0, QTFILE},	 0,	0444,
	"cd.dis",	{27, 0, QTFILE},	 0,	0444,
	"grep.dis",	{28, 0, QTFILE},	 0,	0444,
	"wc.dis",	{29, 0, QTFILE},	 0,	0444,
	"date.dis",	{30, 0, QTFILE},	 0,	0444,
	"sleep.dis",	{31, 0, QTFILE},	 0,	0444,
	"ps.dis",	{32, 0, QTFILE},	 0,	0444,
	"basename.dis",	{33, 0, QTFILE},	 0,	0444,
	"cleanname.dis",	{34, 0, QTFILE},	 0,	0444,
	"sort.dis",	{35, 0, QTFILE},	 0,	0444,
	"uniq.dis",	{36, 0, QTFILE},	 0,	0444,
	"tee.dis",	{37, 0, QTFILE},	 0,	0444,
	"tr.dis",	{38, 0, QTFILE},	 0,	0444,
	"test.dis",	{39, 0, QTFILE},	 0,	0444,
	"time.dis",	{40, 0, QTFILE},	 0,	0444,
	"kill.dis",	{41, 0, QTFILE},	 0,	0444,
	"read.dis",	{42, 0, QTFILE},	 0,	0444,
	"env.dis",	{43, 0, QTFILE},	 0,	0444,
	"md5sum.dis",	{44, 0, QTFILE},	 0,	0444,
	"strings.dis",	{45, 0, QTFILE},	 0,	0444,
	"xd.dis",	{46, 0, QTFILE},	 0,	0444,
	"seq.dis",	{47, 0, QTFILE},	 0,	0444,
	"arg.dis",	{48, 0, QTFILE},	 0,	0444,
	"bufio.dis",	{49, 0, QTFILE},	 0,	0444,
	"daytime.dis",	{50, 0, QTFILE},	 0,	0444,
	"env.dis",	{51, 0, QTFILE},	 0,	0444,
	"filepat.dis",	{52, 0, QTFILE},	 0,	0444,
	"names.dis",	{53, 0, QTFILE},	 0,	0444,
	"rand.dis",	{54, 0, QTFILE},	 0,	0444,
	"readdir.dis",	{55, 0, QTFILE},	 0,	0444,
	"regex.dis",	{56, 0, QTFILE},	 0,	0444,
	"string.dis",	{57, 0, QTFILE},	 0,	0444,
	"workdir.dis",	{58, 0, QTFILE},	 0,	0444,
	"std.dis",	{59, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[60] = {
	0,	 &roottab[1],	 10,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[11],	 37,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 root10code,	 0,	 &root10len,
	3,	 &roottab[48],	 11,	nil,
	3,	 root12code,	 0,	 &root12len,
	3,	 &roottab[59],	 1,	nil,
	3,	 root15code,	 0,	 &root15len,
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
	3,	 root40code,	 0,	 &root40len,
	3,	 root41code,	 0,	 &root41len,
	3,	 root42code,	 0,	 &root42len,
	3,	 root43code,	 0,	 &root43len,
	3,	 root44code,	 0,	 &root44len,
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
	3,	 root57code,	 0,	 &root57len,
	3,	 root58code,	 0,	 &root58len,
	3,	 root59code,	 0,	 &root59len,
	11,	 root16code,	 0,	 &root16len,
	11,	 root17code,	 0,	 &root17len,
	11,	 root18code,	 0,	 &root18len,
	11,	 root19code,	 0,	 &root19len,
	11,	 root20code,	 0,	 &root20len,
	11,	 root21code,	 0,	 &root21len,
	11,	 root22code,	 0,	 &root22len,
	11,	 root23code,	 0,	 &root23len,
	11,	 root24code,	 0,	 &root24len,
	11,	 root25code,	 0,	 &root25len,
	11,	 root26code,	 0,	 &root26len,
	13,	 root14code,	 0,	 &root14len,
};
