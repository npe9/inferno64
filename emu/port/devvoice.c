/*
 * #V - speech, as a device.
 *
 *	bind -a '#V' /dev
 *	echo -n 'hɛlˈoʊ' > /dev/voice/phonemes
 *	cp /dev/voice/pcm /tmp/hello.pcm
 *
 * Why this is not the neural voice. say(1) speaks through ml(3) and a 60MB
 * VITS model, which sounds far better than anything here and cannot be the
 * basis of a screen reader for two reasons that are not going to change: it
 * needs eleven operators mlsoft.c does not implement, 258 convolutions among
 * them, so it does not run on native Inferno at all; and it costs upwards of a
 * second per utterance, when a system that reads out what you type has to
 * answer in the time it takes to press the next key.
 *
 * So this is a formant synthesizer: a few resonators driven by a buzz or a
 * hiss, which is how DECtalk and eSpeak do it and why they are still what
 * people actually read screens with. It is a few kilobytes of state, it runs
 * anywhere, it is faster than real time by a wide margin, and it stays
 * intelligible at the three-hundred-words-a-minute rates people actually use.
 * It does not sound natural and is not trying to.
 *
 * The two are not rivals. The model is for narration, where the words are
 * chosen in advance and quality is the whole point; this is for the screen,
 * where the words arrive unbidden and latency is.
 *
 * Text is not handled here. Turning English into phonemes needs a dictionary,
 * phon(2) has one, and Limbo is as native as C is on a machine that runs Dis
 * in the kernel. This takes the sounds and makes the sound.
 */

#include	"dat.h"
#include	"fns.h"
#include	"error.h"

/*
 * From libmath, which emu and every native configuration already link.
 * Declared here rather than pulled in through a host header because this is a
 * device: the tree compiles with implicit declarations only warned about, and
 * an implicitly declared exp() returns int, which would round every resonator
 * coefficient to a whole number and turn the speech into a buzz.
 */
extern double	__ieee754_exp(double);
extern double	cos(double);

enum {
	Qtopdir,		/* what "#V" itself is */
	Qvoicedir,		/* the "voice" under it, so a bind gives /dev/voice */
	Qctl,
	Qphonemes,
	Qpcm,
	Qscreen,

	Rate		= 16000,	/* samples per second */
	Maxsamples	= Rate * 30,	/* half a minute is plenty for one write */

	Defpitch	= 100,		/* Hz */
	Defspeed	= 100,		/* percent of the table's durations */
};

/*
 * A phoneme is a target: where the first three formants should be, whether the
 * source is voiced, and how long to take getting there. Everything between two
 * targets is interpolated, which is most of what makes formant speech sound
 * like speech rather than like a row of tones.
 *
 * The symbols are espeak's IPA - the same ones the voice model's
 * phoneme_id_map holds and the same ones phon(2) produces - so the two
 * synthesizers take identical input and a caller need not know which one it is
 * talking to. A symbol not in this table is skipped rather than refused: a
 * screen reader that stops dead on an unexpected diacritic is worse than one
 * that carries on without it.
 */
typedef struct Phone Phone;
struct Phone
{
	char	*sym;
	int	f1, f2, f3;	/* Hz */
	int	voiced;		/* 0 hiss, 1 buzz, 2 both */
	int	ms;		/* nominal duration */
	int	amp;		/* 0-100 */
};

static Phone phtab[] =
{
	/* vowels */
	{"i",	270, 2290, 3010,	1,  90, 70},
	{"ɪ",	390, 1990, 2550,	1,  70, 70},
	{"e",	530, 1840, 2480,	1,  90, 70},
	{"ɛ",	530, 1840, 2480,	1,  70, 70},
	{"æ",	660, 1720, 2410,	1,  90, 70},
	{"ɑ",	730, 1090, 2440,	1, 100, 70},
	{"ɒ",	570,  840, 2410,	1,  90, 70},
	{"ɔ",	570,  840, 2410,	1,  90, 70},
	{"o",	490,  910, 2460,	1,  90, 70},
	{"ʊ",	440, 1020, 2240,	1,  70, 70},
	{"u",	300,  870, 2240,	1,  90, 70},
	{"ʌ",	640, 1190, 2390,	1,  70, 70},
	{"ə",	500, 1500, 2500,	1,  50, 55},
	{"ɐ",	600, 1400, 2500,	1,  50, 60},
	{"ɜ",	490, 1350, 1690,	1,  90, 70},
	{"ɚ",	490, 1350, 1690,	1,  70, 65},
	{"ᵻ",	400, 1900, 2550,	1,  50, 60},
	{"a",	730, 1090, 2440,	1,  90, 70},

	/* approximants and nasals */
	{"ɹ",	310, 1060, 1380,	1,  60, 65},
	{"l",	360, 1300, 2700,	1,  60, 65},
	{"w",	290,  610, 2150,	1,  55, 65},
	{"j",	260, 2070, 3020,	1,  55, 65},
	{"m",	280,  900, 2200,	1,  65, 55},
	{"n",	280, 1700, 2600,	1,  65, 55},
	{"ŋ",	280, 2300, 2750,	1,  65, 55},

	/* fricatives */
	{"f",	400, 1100, 2200,	0,  75, 35},
	{"v",	400, 1100, 2200,	2,  55, 45},
	{"θ",	400, 1400, 2400,	0,  75, 30},
	{"ð",	400, 1400, 2400,	2,  55, 45},
	{"s",	400, 1400, 2600,	0,  85, 45},
	{"z",	400, 1400, 2600,	2,  65, 50},
	{"ʃ",	400, 1800, 2400,	0,  90, 50},
	{"ʒ",	400, 1800, 2400,	2,  65, 50},
	{"h",	500, 1500, 2500,	0,  55, 25},

	/* stops */
	{"p",	400, 1100, 2200,	0,  35, 30},
	{"b",	300,  900, 2100,	2,  30, 40},
	{"t",	400, 1600, 2600,	0,  35, 30},
	{"d",	300, 1600, 2600,	2,  30, 40},
	{"k",	400, 1900, 2400,	0,  40, 30},
	{"ɡ",	300, 1700, 2300,	2,  30, 40},
	{"g",	300, 1700, 2300,	2,  30, 40},
	{"ɾ",	300, 1600, 2600,	2,  20, 45},
	{"ʔ",	400, 1400, 2400,	0,  25,  0},
};

/*
 * A two-pole resonator. y = a*x + b*y' + c*y''; the coefficients put a pole
 * pair at the wanted frequency with the wanted bandwidth. Three in cascade is
 * a vocal tract, near enough.
 */
typedef struct Reson Reson;
struct Reson
{
	double	a, b, c;
	double	p1, p2;
};

static void
setreson(Reson *r, double f, double bw)
{
	double x, th;

	x = __ieee754_exp(-3.14159265358979 * bw / Rate);
	th = 2.0 * 3.14159265358979 * f / Rate;
	r->c = -x * x;
	r->b = 2.0 * x * cos(th);
	r->a = 1.0 - r->b - r->c;
}

static double
reson(Reson *r, double x)
{
	double y;

	y = r->a * x + r->b * r->p1 + r->c * r->p2;
	r->p2 = r->p1;
	r->p1 = y;
	return y;
}

typedef struct Voice Voice;
struct Voice
{
	QLock	l;

	int	pitch;		/* Hz */
	int	speed;		/* percent */

	short	*pcm;		/* the last utterance */
	int	npcm;
	int	apcm;
};

static Voice voice;

/*
 * What the interface has to say about itself.
 *
 * Anything in the system that knows a person's attention has moved - libtk
 * when the keyboard focus changes, and in principle anything else - calls
 * voiceannounce(). A reader blocks on /dev/voice/screen and speaks whatever
 * comes out, so the screen reader is `speak /dev/voice/screen &` and not a
 * program that has to understand widgets.
 *
 * The hook lives here rather than in libtk because this file is linked into
 * every configuration that has the device, and libtk is not: emu-g has a voice
 * and no Tk at all. libtk holds the reference, and only where it is linked.
 *
 * A full ring drops the OLDEST entry. A screen reader is telling you where you
 * are now; a backlog of places you used to be is worse than useless, because
 * you have to sit through it to find out.
 */
enum {
	Nannounce	= 16,
	Announcemax	= 256,

	Anoff,			/* say nothing */
	Anfocus,		/* where the keyboard is - the default */
	Anall,			/* and what appears on the screen */
};

static int anlevel = Anfocus;

static struct {
	Lock	lk;
	Rendez	r;
	char	msg[Nannounce][Announcemax];
	int	kind[Nannounce];
	int	rd;
	int	wr;
	int	n;
} screen;

/* with the lock held */
static void
queue(int kind, char *what)
{
	if(screen.n == Nannounce){
		screen.rd = (screen.rd + 1) % Nannounce;
		screen.n--;
	}
	strncpy(screen.msg[screen.wr], what, Announcemax-1);
	screen.msg[screen.wr][Announcemax-1] = '\0';
	screen.kind[screen.wr] = kind;
	screen.wr = (screen.wr + 1) % Nannounce;
	screen.n++;
}

/*
 * Throw away queued output, keeping anything the person's own actions
 * produced. Called when the focus moves, because that IS a person acting: they
 * have stopped caring about whatever was scrolling past, and making them sit
 * through it before hearing where they now are is the single most tiring thing
 * a screen reader does.
 */
static void
dropoutput(void)
{
	int i, j, n;

	j = screen.rd;
	n = 0;
	for(i = 0; i < screen.n; i++){
		int k = (screen.rd + i) % Nannounce;
		if(screen.kind[k] == Anall)
			continue;
		if(j != k){
			memmove(screen.msg[j], screen.msg[k], Announcemax);
			screen.kind[j] = screen.kind[k];
		}
		j = (j + 1) % Nannounce;
		n++;
	}
	screen.wr = j;
	screen.n = n;
}

void
voiceannounce(char *what)
{
	if(anlevel == Anoff || what == nil || *what == '\0')
		return;
	lock(&screen.lk);
	dropoutput();
	queue(Anfocus, what);
	unlock(&screen.lk);
	Wakeup(&screen.r);
}

static int
announced(void *a)
{
	USED(a);
	return screen.n > 0;
}

/*
 * Text appearing on the screen, as opposed to the keyboard moving.
 *
 * It is off unless asked for, because it is a different order of chattiness:
 * focus changes when a person does something, and output arrives whenever the
 * machine feels like it.
 *
 * Whole lines only. A shell window inserts the characters you type one at a
 * time through the same path the output takes, so announcing every insert
 * would read back each letter as you pressed it and then read the line again
 * when it echoed. Holding the fragments until a newline turns both into one
 * sensible utterance, and it keeps libtk from having to know any of this.
 */
static struct {
	Lock	lk;
	char	buf[Announcemax];
	int	n;
} pending;

void
voiceannouncetext(char *what)
{
	char line[Announcemax];
	int i, got;

	if(anlevel < Anall || what == nil)
		return;
	for(; *what != '\0'; what++){
		got = 0;
		lock(&pending.lk);
		if(*what == '\n' || pending.n >= Announcemax-1){
			memmove(line, pending.buf, pending.n);
			line[pending.n] = '\0';
			pending.n = 0;
			got = 1;
		}
		if(*what != '\n')
			pending.buf[pending.n++] = *what;
		unlock(&pending.lk);
		if(got){
			/* a line of nothing but spaces is not worth saying */
			for(i = 0; line[i] == ' ' || line[i] == '\t'; i++)
				;
			if(line[i] != '\0'){
				lock(&screen.lk);
				queue(Anall, line);
				unlock(&screen.lk);
				Wakeup(&screen.r);
			}
		}
	}
}

static ulong rngstate = 1;

static double
noise(void)
{
	rngstate = rngstate * 1103515245 + 12345;
	return (double)((rngstate >> 16) & 0x7fff) / 16384.0 - 1.0;
}

static Phone*
lookup(char *sym, int n)
{
	int i;

	for(i = 0; i < nelem(phtab); i++)
		if(strncmp(phtab[i].sym, sym, n) == 0 && phtab[i].sym[n] == '\0')
			return &phtab[i];
	return nil;
}

/*
 * How many bytes the symbol at s occupies. The table is UTF-8 and so is the
 * input; comparing byte by byte would split ð down the middle and match
 * nothing at all.
 */
static int
symlen(char *s)
{
	uchar c;

	c = (uchar)*s;
	if(c < 0x80)
		return 1;
	if((c & 0xe0) == 0xc0)
		return 2;
	if((c & 0xf0) == 0xe0)
		return 3;
	if((c & 0xf8) == 0xf0)
		return 4;
	return 1;
}

static int
grow(Voice *v, int need)
{
	short *p;
	int n;

	if(v->npcm + need <= v->apcm)
		return 0;
	n = v->apcm? v->apcm * 2: Rate;
	while(n < v->npcm + need)
		n *= 2;
	if(n > Maxsamples)
		n = Maxsamples;
	if(v->npcm + need > n)
		return -1;
	p = realloc(v->pcm, n * sizeof(short));
	if(p == nil)
		return -1;
	v->pcm = p;
	v->apcm = n;
	return 0;
}

/*
 * One phoneme, with the formants sliding from wherever the last one left them.
 * The slide is the whole difference between speech and a row of tones.
 */
static void
emit(Voice *v, Phone *p, double *cf, double *phase, Reson *r1, Reson *r2, Reson *r3)
{
	int i, n;
	double t, f1, f2, f3, src, y, amp, step;

	n = p->ms * Rate / 1000;
	if(v->speed > 0)
		n = n * 100 / v->speed;
	if(n <= 0 || grow(v, n) < 0)
		return;

	amp = p->amp / 100.0;
	step = (double)v->pitch / Rate;
	for(i = 0; i < n; i++){
		t = (double)i / (double)n;
		f1 = cf[0] + (p->f1 - cf[0]) * t;
		f2 = cf[1] + (p->f2 - cf[1]) * t;
		f3 = cf[2] + (p->f3 - cf[2]) * t;
		setreson(r1, f1, 60.0);
		setreson(r2, f2, 90.0);
		setreson(r3, f3, 150.0);

		src = 0.0;
		if(p->voiced != 0){
			/*
			 * A sawtooth rather than an impulse train. An impulse
			 * one sample wide at 100Hz puts almost no energy
			 * anywhere, and the result is inaudible however the
			 * formants are set.
			 */
			*phase += step;
			if(*phase >= 1.0)
				*phase -= 1.0;
			src += 2.0 * (*phase) - 1.0;
		}
		if(p->voiced != 1)
			src += 0.3 * noise();

		y = reson(r3, reson(r2, reson(r1, src))) * amp;
		if(y > 1.0)
			y = 1.0;
		if(y < -1.0)
			y = -1.0;
		v->pcm[v->npcm++] = (short)(y * 24000.0);
	}
	cf[0] = p->f1;
	cf[1] = p->f2;
	cf[2] = p->f3;
}

static void
silence(Voice *v, int ms)
{
	int i, n;

	n = ms * Rate / 1000;
	if(v->speed > 0)
		n = n * 100 / v->speed;
	if(n <= 0 || grow(v, n) < 0)
		return;
	for(i = 0; i < n; i++)
		v->pcm[v->npcm++] = 0;
}

static void
synth(Voice *v, char *s, int n)
{
	Reson r1, r2, r3;
	Phone *p;
	double cf[3], phase;
	char *e;
	int k;

	v->npcm = 0;
	memset(&r1, 0, sizeof r1);
	memset(&r2, 0, sizeof r2);
	memset(&r3, 0, sizeof r3);
	cf[0] = 500.0;
	cf[1] = 1500.0;
	cf[2] = 2500.0;
	phase = 0.0;

	e = s + n;
	while(s < e){
		if(*s == ' ' || *s == '\t' || *s == '\n'){
			silence(v, 60);
			s++;
			continue;
		}
		k = symlen(s);
		if(s + k > e)
			break;
		p = lookup(s, k);
		if(p != nil)
			emit(v, p, cf, &phase, &r1, &r2, &r3);
		s += k;
	}
}

/*
 * Two levels, so that `bind -a '#V' /dev` gives /dev/voice/ctl rather than
 * scattering ctl, phonemes and pcm straight into /dev, where a name as common
 * as "ctl" would collide with every other device's idea of one. devml(3) is
 * arranged the same way and for the same reason.
 */
static int
voicegen(Chan *c, char *name, Dirtab *tab, int ntab, int s, Dir *dp)
{
	Qid q;
	static char *files[] = { "ctl", "phonemes", "pcm", "screen" };
	static int ftype[] = { Qctl, Qphonemes, Qpcm, Qscreen };
	static int fperm[] = { 0666, 0222, 0444, 0444 };

	USED(name); USED(tab); USED(ntab);
	q.vers = 0;

	if(s == DEVDOTDOT){
		switch((ulong)c->qid.path){
		case Qtopdir:
		case Qvoicedir:
			mkqid(&q, Qtopdir, 0, QTDIR);
			devdir(c, q, "#V", 0, eve, DMDIR|0555, dp);
			break;
		default:
			mkqid(&q, Qvoicedir, 0, QTDIR);
			devdir(c, q, "voice", 0, eve, DMDIR|0555, dp);
			break;
		}
		return 1;
	}

	if((ulong)c->qid.path == Qtopdir){
		if(s != 0)
			return -1;
		mkqid(&q, Qvoicedir, 0, QTDIR);
		devdir(c, q, "voice", 0, eve, DMDIR|0555, dp);
		return 1;
	}

	/*
	 * The file qids belong to this level too, and must fall through to
	 * here. devstat looks an entry up by asking gen to enumerate using the
	 * FILE's own chan, so a case that matched only the directory answers a
	 * read of /dev/voice and then fails every stat of what is inside it -
	 * which is exactly what `cp /dev/voice/pcm` hit.
	 */
	if(s < 0 || s >= nelem(files))
		return -1;
	mkqid(&q, ftype[s], 0, QTFILE);
	devdir(c, q, files[s], 0, eve, fperm[s], dp);
	return 1;
}

static Chan*
voiceattach(char *spec)
{
	return devattach('V', spec);
}

static Walkqid*
voicewalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, nil, 0, voicegen);
}

static int
voicestat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, nil, 0, voicegen);
}

static Chan*
voiceopen(Chan *c, int omode)
{
	return devopen(c, omode, nil, 0, voicegen);
}

static void
voiceclose(Chan *c)
{
	USED(c);
}

static long
voiceread(Chan *c, void *va, long n, vlong off)
{
	char buf[128];
	long rv;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, n, nil, 0, voicegen);

	switch((ulong)c->qid.path){
	case Qctl:
		snprint(buf, sizeof buf,
			"rate %d\npitch %d\nspeed %d\nsamples %d\nannounce %s\n",
			Rate, voice.pitch, voice.speed, voice.npcm,
			anlevel == Anoff? "off": anlevel == Anfocus? "focus": "all");
		return readstr(off, va, n, buf);

	case Qpcm:
		qlock(&voice.l);
		if(voice.pcm == nil || off >= (vlong)voice.npcm * 2){
			qunlock(&voice.l);
			return 0;
		}
		rv = (vlong)voice.npcm * 2 - off;
		if(rv > n)
			rv = n;
		memmove(va, (uchar*)voice.pcm + off, rv);
		qunlock(&voice.l);
		return rv;

	case Qscreen:
		/*
		 * One announcement per read, and it blocks until there is one.
		 * That is what lets the screen reader be `speak
		 * /dev/voice/screen`: a program that reads lines from a file,
		 * with no idea it is a device.
		 */
		Sleep(&screen.r, announced, nil);
		lock(&screen.lk);
		if(screen.n == 0){
			unlock(&screen.lk);
			return 0;
		}
		rv = strlen(screen.msg[screen.rd]);
		if(rv > n - 1)
			rv = n - 1;
		memmove(va, screen.msg[screen.rd], rv);
		((char*)va)[rv++] = '\n';
		screen.rd = (screen.rd + 1) % Nannounce;
		screen.n--;
		unlock(&screen.lk);
		return rv;
	}
	error(Ebadarg);
	return 0;
}

static long
voicewrite(Chan *c, void *va, long n, vlong off)
{
	Cmdbuf *cb;
	char *s;
	int v;

	USED(off);
	switch((ulong)c->qid.path){
	case Qctl:
		cb = parsecmd(va, n);
		if(waserror()){
			free(cb);
			nexterror();
		}
		if(cb->nf < 1)
			error(Ebadarg);
		if(strcmp(cb->f[0], "pitch") == 0 && cb->nf == 2){
			v = atoi(cb->f[1]);
			if(v < 40 || v > 400)
				error("pitch is 40 to 400 Hz");
			voice.pitch = v;
		}else if(strcmp(cb->f[0], "announce") == 0 && cb->nf == 2){
			if(strcmp(cb->f[1], "off") == 0)
				anlevel = Anoff;
			else if(strcmp(cb->f[1], "focus") == 0)
				anlevel = Anfocus;
			else if(strcmp(cb->f[1], "all") == 0)
				anlevel = Anall;
			else
				error("announce is off, focus or all");
		}else if(strcmp(cb->f[0], "speed") == 0 && cb->nf == 2){
			v = atoi(cb->f[1]);
			if(v < 20 || v > 800)
				error("speed is 20 to 800 percent");
			voice.speed = v;
		}else
			error(Ebadarg);
		poperror();
		free(cb);
		return n;

	case Qphonemes:
		if(n <= 0)
			return 0;
		s = malloc(n + 1);
		if(s == nil)
			error(Enomem);
		memmove(s, va, n);
		s[n] = '\0';
		qlock(&voice.l);
		if(waserror()){
			qunlock(&voice.l);
			free(s);
			nexterror();
		}
		synth(&voice, s, n);
		poperror();
		qunlock(&voice.l);
		free(s);
		return n;
	}
	error(Ebadarg);
	return 0;
}

static void
voiceinit(void)
{
	voice.pitch = Defpitch;
	voice.speed = Defspeed;
}

Dev voicedevtab = {
	'V',
	"voice",

#ifndef EMU
	devreset,
#endif
	voiceinit,
#ifndef EMU
	devshutdown,
#endif
	voiceattach,
	voicewalk,
	voicestat,
	voiceopen,
	devcreate,
	voiceclose,
	voiceread,
	devbread,
	voicewrite,
	devbwrite,
	devremove,
	devwstat,
};
