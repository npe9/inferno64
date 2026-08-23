extern unsigned char root12code[];
extern int root12len;
int rootmaxq = 13;
Dirtab roottab[13] = {
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
	"osinit.dis",	{12, 0, QTFILE},	 0,	0444,
};
Rootdata rootdata[13] = {
	0,	 &roottab[1],	 12,	nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 nil,	 0,	 nil,
	0,	 root12code,	 0,	 &root12len,
};
