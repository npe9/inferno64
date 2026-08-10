#include "lib9.h"
#include "draw.h"
#include "tk.h"

#define RGB(R,G,B) ((R<<24)|(G<<16)|(B<<8)|(0xff))

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
	-1,
};

void
tksetenvcolours(TkEnv *env)
{
	Coltab *c;

	c = &coltab[0];
	while(c->c != -1) {
		env->colors[c->c] = tkrgbashade(c->rgba, c->shade);
		env->set |= (1<<c->c);
		c++;
	}
}
