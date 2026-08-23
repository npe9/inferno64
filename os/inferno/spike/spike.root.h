extern unsigned char root10code[];
extern int root10len;
int rootmaxq = 11;
Dirtab roottab[11] = {
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
	"osinit.dis",	{10, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[11] = {
	0,	 &roottab[1],	 10,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 root10code,	 0,	 &root10len,
};
