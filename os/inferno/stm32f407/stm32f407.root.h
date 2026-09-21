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
int rootmaxq = 26;
Dirtab roottab[26] = {
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
	"echo.dis",	{14, 0, QTFILE},	 0,	0444,
	"cat.dis",	{15, 0, QTFILE},	 0,	0444,
	"ls.dis",	{16, 0, QTFILE},	 0,	0444,
	"bind.dis",	{17, 0, QTFILE},	 0,	0444,
	"arg.dis",	{18, 0, QTFILE},	 0,	0444,
	"bufio.dis",	{19, 0, QTFILE},	 0,	0444,
	"string.dis",	{20, 0, QTFILE},	 0,	0444,
	"readdir.dis",	{21, 0, QTFILE},	 0,	0444,
	"filepat.dis",	{22, 0, QTFILE},	 0,	0444,
	"daytime.dis",	{23, 0, QTFILE},	 0,	0444,
	"env.dis",	{24, 0, QTFILE},	 0,	0444,
	"std.dis",	{25, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[26] = {
	0,	 &roottab[1],	 10,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 &roottab[11],	 7,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 root10code,	 0,	 &root10len,
	3,	 &roottab[18],	 7,	nil,
	3,	 root12code,	 0,	 &root12len,
	3,	 &roottab[25],	 1,	nil,
	3,	 root22code,	 0,	 &root22len,
	3,	 root23code,	 0,	 &root23len,
	3,	 root24code,	 0,	 &root24len,
	3,	 root25code,	 0,	 &root25len,
	11,	 root15code,	 0,	 &root15len,
	11,	 root16code,	 0,	 &root16len,
	11,	 root17code,	 0,	 &root17len,
	11,	 root18code,	 0,	 &root18len,
	11,	 root19code,	 0,	 &root19len,
	11,	 root20code,	 0,	 &root20len,
	11,	 root21code,	 0,	 &root21len,
	13,	 root14code,	 0,	 &root14len,
};
