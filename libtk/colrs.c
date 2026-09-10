#include "lib9.h"
#include "draw.h"
#include "tk.h"

/*
 * The casts are load-bearing.  R<<24 as a plain int is negative whenever
 * R is 0x80 or more, and widening that to a 64-bit ulong sign-extends it
 * - so the table held 0xfffffffff5f0d8ff where it meant 0xf5f0d8ff.
 * tkrgbavals() masks the red byte now and would cope either way, but a
 * colour constant should be the number it looks like.
 */
#define RGB(R,G,B) ((((ulong)(R)&0xff)<<24)|(((ulong)(G)&0xff)<<16)|(((ulong)(B)&0xff)<<8)|0xffUL)

enum
{
	/* Soft Plan9 Paper body (#F5F0D8). */
	tkBackR		= 0xf5,		/* Background base color */
	tkBackG 	= 0xf0,
	tkBackB 	= 0xd8,

	/* Soft chrome for active/hover widgets (#D4D0C4). */
	tkActiveR	= 0xd4,
	tkActiveG	= 0xd0,
	tkActiveB	= 0xc4,

	/* Soft accent (#3D6A9A) */
	tkSelectR	= 0x3d,		/* Check box selected color */
	tkSelectG	= 0x6a,
	tkSelectB	= 0x9a,

	/* Soft blue selection wash (lightened accent) */
	tkSelectbgndR	= 0xb8,
	tkSelectbgndG	= 0xcc,
	tkSelectbgndB	= 0xe0,

	tkForeR		= 0x2a,		/* Soft near-black text */
	tkForeG		= 0x2a,
	tkForeB		= 0x22,

	tkMuteR		= 0x8a,		/* Muted cool slate / disabled */
	tkMuteG		= 0x90,
	tkMuteB		= 0x98
};

typedef struct Coltab Coltab;
struct Coltab {
	int	c;
	ulong rgba;
	int shade;
};

static Coltab coltab[] =
{
	TkCbackgnd,
		RGB(tkBackR, tkBackG, tkBackB),
		TkSameshade,
	TkCbackgndlght,
		RGB(tkBackR, tkBackG, tkBackB),
		TkLightshade,
	TkCbackgnddark,
		RGB(tkBackR, tkBackG, tkBackB),
		TkDarkshade,
	TkCactivebgnd,
		RGB(tkActiveR, tkActiveG, tkActiveB),
		TkSameshade,
	TkCactivebgndlght,
		RGB(tkActiveR, tkActiveG, tkActiveB),
		TkLightshade,
	TkCactivebgnddark,
		RGB(tkActiveR, tkActiveG, tkActiveB),
		TkDarkshade,
	TkCactivefgnd,
		RGB(tkForeR, tkForeG, tkForeB),
		TkSameshade,
	TkCforegnd,
		RGB(tkForeR, tkForeG, tkForeB),
		TkSameshade,
	TkCselect,
		RGB(tkSelectR, tkSelectG, tkSelectB),
		TkSameshade,
	TkCselectbgnd,
		RGB(tkSelectbgndR, tkSelectbgndG, tkSelectbgndB),
		TkSameshade,
	TkCselectbgndlght,
		RGB(tkSelectbgndR, tkSelectbgndG, tkSelectbgndB),
		TkLightshade,
	TkCselectbgnddark,
		RGB(tkSelectbgndR, tkSelectbgndG, tkSelectbgndB),
		TkDarkshade,
	TkCselectfgnd,
		RGB(tkForeR, tkForeG, tkForeB),
		TkSameshade,
	TkCdisablefgnd,
		RGB(tkMuteR, tkMuteG, tkMuteB),
		TkSameshade,
	TkChighlightfgnd,
		RGB(tkSelectR, tkSelectG, tkSelectB),
		TkSameshade,
	TkCtransparent,
		DTransparent,
		TkSameshade,
	TkCfield,
		RGB(tkBackR, tkBackG, tkBackB),
		TkSameshade,
	-1,
};

/*
 * The flat style's own palette.  Not a recolouring of the one above: the
 * point is that a window drawn now has LEVELS - a page, fields sitting
 * above it, controls filled rather than outlined - and the classic table
 * cannot express that, because its background serves as page and field
 * and button all at once.  Everything separated by a hairline on one
 * colour is what makes the old look read as a wireframe.
 *
 * One accent, used for what is chosen and for the focus ring, and
 * nothing else coloured.
 */
enum
{
	fBackR = 0xf0, fBackG = 0xf0, fBackB = 0xed,	/* the page */
	fFieldR = 0xff, fFieldG = 0xff, fFieldB = 0xfd,	/* a level above it */
	fActiveR = 0xe2, fActiveG = 0xe2, fActiveB = 0xde,	/* hover */
	fAccentR = 0x3d, fAccentG = 0x6a, fAccentB = 0x9a,
	fWashR = 0xd7, fWashG = 0xe3, fWashB = 0xf1,	/* selection */
	fInkR = 0x1f, fInkG = 0x23, fInkB = 0x28,
	fMuteR = 0x7a, fMuteG = 0x7f, fMuteB = 0x87
};

static Coltab flatcoltab[] =
{
	TkCbackgnd,	RGB(fBackR, fBackG, fBackB),	TkSameshade,
	TkCbackgndlght,	RGB(fBackR, fBackG, fBackB),	TkLightshade,
	TkCbackgnddark,	RGB(fBackR, fBackG, fBackB),	TkDarkshade,
	TkCactivebgnd,	RGB(fActiveR, fActiveG, fActiveB),	TkSameshade,
	TkCactivebgndlght, RGB(fActiveR, fActiveG, fActiveB),	TkLightshade,
	TkCactivebgnddark, RGB(fActiveR, fActiveG, fActiveB),	TkDarkshade,
	TkCactivefgnd,	RGB(fInkR, fInkG, fInkB),	TkSameshade,
	TkCforegnd,	RGB(fInkR, fInkG, fInkB),	TkSameshade,
	TkCselect,	RGB(fAccentR, fAccentG, fAccentB),	TkSameshade,
	TkCselectbgnd,	RGB(fWashR, fWashG, fWashB),	TkSameshade,
	TkCselectbgndlght, RGB(fWashR, fWashG, fWashB),	TkLightshade,
	TkCselectbgnddark, RGB(fWashR, fWashG, fWashB),	TkDarkshade,
	TkCselectfgnd,	RGB(fInkR, fInkG, fInkB),	TkSameshade,
	TkCdisablefgnd,	RGB(fMuteR, fMuteG, fMuteB),	TkSameshade,
	TkChighlightfgnd, RGB(fAccentR, fAccentG, fAccentB),	TkSameshade,
	TkCtransparent,	DTransparent,			TkSameshade,
	TkCfield,	RGB(fFieldR, fFieldG, fFieldB),	TkSameshade,
	-1,
};

void
tksetenvcolours(TkEnv *env, int style)
{
	Coltab *c;

	c = style == TkSflat ? &flatcoltab[0] : &coltab[0];
	while(c->c != -1) {
		env->colors[c->c] = tkrgbashade(c->rgba, c->shade);
		env->set |= (1<<c->c);
		c++;
	}
}
