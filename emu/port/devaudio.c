#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"audio.h"

Dirtab audiotab[] =
{
	".",		{Qdir, 0, QTDIR},	0,	0555,
	"audio",	{Qaudio},	0,	0666,
	"audioctl",	{Qaudioctl},	0,	0666,
	"audiodec",	{Qaudiodec},	0,	0666,
};

/*
 * Coded-audio decode, as a filter: write one coded sample, read back the PCM
 * it turns into. A filter rather than another way to play, because that is
 * what composes - the caller can send the PCM to /dev/audio, mix it, write it
 * to a file, or measure it - and because a sink cannot be tested without
 * listening to it.
 *
 * The split is the same one draw(3) makes for video: quicktime(2) finds the
 * coded samples in Limbo, and only the bytes of one sample cross into the
 * kernel, where the platform decoder is the part that cannot be done anywhere
 * else. Nil hooks mean no decoder, which is an error to the caller rather
 * than silence.
 */
void*	(*audiodecopen)(char *codec, int rate, int chans, uchar *extra, int nextra);
int	(*audiodecsample)(void *dec, uchar *in, int nin, uchar *out, int nout);
void	(*audiodecclose)(void *dec);

static void	*audiodec;		/* one decoder, like the one audio device */
static uchar	*audiodecbuf;		/* PCM waiting to be read */
static int	audiodeclen;
static int	audiodecoff;

enum { Audiodecmax = 256*1024 };	/* a decoded sample is far smaller */

static void
audioinit(void)
{
	audio_file_init();
}

static Chan*
audioattach(char *spec)
{
	return devattach('A', spec);
}

static Walkqid*
audiowalk(Chan *c, Chan *nc, char **name, int nname)
{
	return devwalk(c, nc, name, nname, audiotab, nelem(audiotab), devgen);
}

static int
audiostat(Chan *c, uchar *db, int n)
{
	return devstat(c, db, n, audiotab, nelem(audiotab), devgen);
}

static Chan*
audioopen(Chan *c, int omode)
{
	c = devopen(c, omode, audiotab, nelem(audiotab), devgen);
	if(waserror()){
		c->flag &= ~COPEN;
		nexterror();
	}
	switch(c->qid.path) {
	case Qdir:
	case Qaudioctl:
	case Qaudiodec:		/* a filter: it opens no hardware */
		break;
	case Qaudio:
		audio_file_open(c, c->mode);
		break;
	default:
		error(Egreg);
	}
	poperror();
	return c;
}

static void
audioclose(Chan *c)
{
	if((c->flag & COPEN) == 0)
		return;

	switch(c->qid.path) {
	case Qdir:
	case Qaudioctl:
	case Qaudiodec:
		break;
	case Qaudio:
		audio_file_close(c);
		break;
	default:
		error(Egreg);
	}
}

static int ctlsummary(char*, int, Audio_t*);

static long
audioread(Chan *c, void *va, long count, vlong offset)
{
	char *buf;
	int n;

	if(c->qid.type & QTDIR)
		return devdirread(c, va, count, audiotab, nelem(audiotab), devgen);
	switch(c->qid.path) {
	case Qaudio:
		return audio_file_read(c, va, count, offset);
	case Qaudiodec:
		if(audiodecbuf == nil || audiodecoff >= audiodeclen)
			return 0;
		n = audiodeclen - audiodecoff;
		if(n > count)
			n = count;
		memmove(va, audiodecbuf + audiodecoff, n);
		audiodecoff += n;
		return n;
	case Qaudioctl:
		buf = smalloc(READSTR);
		if(waserror()){
			free(buf);
			nexterror();
		}
		n = ctlsummary(buf, READSTR, getaudiodev());
		count = readstr(offset, va, n, buf);
		poperror();
		free(buf);
		return count;
	}
	return 0;
}

static long
audiowrite(Chan *c, void *va, long count, vlong offset)
{
	switch(c->qid.path) {
	case Qaudiodec:
		if(audiodec == nil)
			error("no decoder: write \"decoder\" to audioctl first");
		if(audiodecbuf == nil){
			audiodecbuf = malloc(Audiodecmax);
			if(audiodecbuf == nil)
				error(Enomem);
		}
		audiodeclen = audiodecsample(audiodec, va, count, audiodecbuf, Audiodecmax);
		audiodecoff = 0;
		if(audiodeclen < 0){
			audiodeclen = 0;
			error(up->env->errstr);
		}
		return count;
	case Qaudio:
		return audio_file_write(c, va, count, offset);
	case Qaudioctl:
		return audio_ctl_write(c, va, count, offset);
	}
	return 0;
}

static int sval(char*, unsigned long*, ulong, ulong);
static int str2val(svp_t*, char*, ulong*);
static char* val2str(svp_t*, ulong);

static int
hexval(int c)
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static void
audiodecctl(Cmdbuf *cb)
{
	uchar *ex;
	int nex, i, hi, lo, l, rate, chans;

	if(audiodecopen == nil)
		error("no audio decoder on this platform");
	if(audiodec != nil){
		audiodecclose(audiodec);
		audiodec = nil;
	}
	rate = atoi(cb->f[2]);
	chans = atoi(cb->f[3]);
	if(rate <= 0 || chans <= 0)
		error("decoder needs a positive rate and channel count");

	nex = 0;
	ex = nil;
	if(cb->nf >= 5){
		l = strlen(cb->f[4]);
		if(l & 1)
			error("setup data must be an even number of hex digits");
		nex = l/2;
		ex = malloc(nex);
		if(ex == nil)
			error(Enomem);
		if(waserror()){
			free(ex);
			nexterror();
		}
		for(i = 0; i < nex; i++){
			hi = hexval(cb->f[4][2*i]);
			lo = hexval(cb->f[4][2*i+1]);
			if(hi < 0 || lo < 0)
				error("bad hex in setup data");
			ex[i] = (hi<<4) | lo;
		}
		poperror();
	}
	audiodec = audiodecopen(cb->f[1], rate, chans, ex, nex);
	free(ex);
	if(audiodec == nil)
		error(up->env->errstr);
	audiodeclen = 0;
	audiodecoff = 0;
}

int
audioparse(char* args, int len, Audio_t *t)
{
	int i, n;
	ulong v;
	Cmdbuf *cb;
	ulong tf;
	Audio_t info = *t;

	cb = parsecmd(args, len);
	if(waserror()){
		free(cb);
		return 0;
	}

	/*
	 * decoder <codec> <rate> <chans> <hex setup>
	 *
	 * Handled before the ordinary parameters because it is not one of
	 * them: it configures the audiodec filter rather than the device's own
	 * format, and its setup data is hex for the same reason draw(3)'s is -
	 * this is a text control file and a parameter set is tens of bytes.
	 */
	if(cb->nf >= 4 && strcmp(cb->f[0], "decoder") == 0){
		audiodecctl(cb);
		poperror();
		free(cb);
		return 1;
	}
	if(cb->nf == 1 && strcmp(cb->f[0], "nodecoder") == 0){
		if(audiodec != nil && audiodecclose != nil)
			audiodecclose(audiodec);
		audiodec = nil;
		poperror();
		free(cb);
		return 1;
	}

	tf = 0;
	n = cb->nf;
	for(i = 0; i < cb->nf-1; i++) {
		if(strcmp(cb->f[i], "in") == 0){
			tf |= AUDIO_IN_FLAG;
			continue;
		}
		if(strcmp(cb->f[i], "out") == 0) {
			tf |= AUDIO_OUT_FLAG;
			continue;
		}
		if(tf == 0)
			tf = AUDIO_IN_FLAG | AUDIO_OUT_FLAG;
		if(strcmp(cb->f[i], "bits") == 0) {
			if(!str2val(audio_bits_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_BITS_FLAG | AUDIO_MOD_FLAG;
				info.in.bits = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_BITS_FLAG | AUDIO_MOD_FLAG;
				info.out.bits = v;
			}
		} else if(strcmp(cb->f[i], "buf") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_BUF_FLAG | AUDIO_MOD_FLAG;
				info.in.buf = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_BUF_FLAG | AUDIO_MOD_FLAG;
				info.out.buf = v;
			}
		} else if(strcmp(cb->f[i], "chans") == 0) {
			if(!str2val(audio_chan_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_CHAN_FLAG | AUDIO_MOD_FLAG;
				info.in.chan = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_CHAN_FLAG | AUDIO_MOD_FLAG;
				info.out.chan = v;
			}
		} else if(strcmp(cb->f[i], "indev") == 0) {
			if(!str2val(audio_indev_tbl, cb->f[i+1], &v))
				break;
			i++;
			info.in.flags |= AUDIO_DEV_FLAG | AUDIO_MOD_FLAG;
			info.in.dev = v;
		} else if(strcmp(cb->f[i], "outdev") == 0) {
			if(!str2val(audio_outdev_tbl, cb->f[i+1], &v))
				break;
			i++;
			info.out.flags |= AUDIO_DEV_FLAG | AUDIO_MOD_FLAG;
			info.out.dev = v;
		} else if(strcmp(cb->f[i], "enc") == 0) {
			if(!str2val(audio_enc_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_ENC_FLAG | AUDIO_MOD_FLAG;
				info.in.enc = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_ENC_FLAG | AUDIO_MOD_FLAG;
				info.out.enc = v;
			}
		} else if(strcmp(cb->f[i], "rate") == 0) {
			if(!str2val(audio_rate_tbl, cb->f[i+1], &v))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_RATE_FLAG | AUDIO_MOD_FLAG;
				info.in.rate = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_RATE_FLAG | AUDIO_MOD_FLAG;
				info.out.rate = v;
			}
		} else if(strcmp(cb->f[i], "vol") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_VOL_FLAG | AUDIO_MOD_FLAG;
				info.in.left = v;
				info.in.right = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_VOL_FLAG | AUDIO_MOD_FLAG;
				info.out.left = v;
				info.out.right = v;
			}
		} else if(strcmp(cb->f[i], "left") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_LEFT_FLAG | AUDIO_MOD_FLAG;
				info.in.left = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_LEFT_FLAG | AUDIO_MOD_FLAG;
				info.out.left = v;
			}
		} else if(strcmp(cb->f[i], "right") == 0) {
			if(!sval(cb->f[i+1], &v, Audio_Max_Val, Audio_Min_Val))
				break;
			i++;
			if(tf & AUDIO_IN_FLAG) {
				info.in.flags |= AUDIO_RIGHT_FLAG | AUDIO_MOD_FLAG;
				info.in.right = v;
			}
			if(tf & AUDIO_OUT_FLAG) {
				info.out.flags |= AUDIO_RIGHT_FLAG | AUDIO_MOD_FLAG;
				info.out.right = v;
			}
		}else
			break;
	}
	poperror();
	free(cb);

	if(i < n)
		return 0;

	*t = info;	/* set information back */
	return 1;
}

static char*
audioparam(char* p, char* e, char* name, int val, svp_t* tbl)
{
	char *s;
	svp_t *sv;

	if((s = val2str(tbl, val)) != nil){
		p = seprint(p, e, "%s %s", name, s);	/* current setting */
		for(sv = tbl; sv->s != nil; sv++)
			if(sv->v != val)
				p = seprint(p, e, " %s", sv->s);	/* other possible values */
		p = seprint(p, e, "\n");
	}else
		p = seprint(p, e, "%s unknown\n", name);
	return p;
}

static char*
audioioparam(char* p, char* e, char* name, int ival, int oval, svp_t* tbl)
{
	if(ival == oval)
		return audioparam(p, e, name, ival, tbl);
	p = audioparam(seprint(p, e, "in "), e, name, ival, tbl);
	p = audioparam(seprint(p, e, "out "), e, name, oval, tbl);
	return p;
}

static int
ctlsummary(char *buf, int bsize, Audio_t *adev)
{
	Audio_d *in, *out;
	char	*p, *e;

	in = &adev->in;
	out = &adev->out;

	p = buf;
	e = p + bsize;

	p = audioparam(p, e, "indev", in->dev, audio_indev_tbl);
	p = audioparam(p, e, "outdev", out->dev, audio_outdev_tbl);
	p = audioioparam(p, e, "enc", in->enc, out->enc, audio_enc_tbl);
	p = audioioparam(p, e, "rate", in->rate, out->rate, audio_rate_tbl);
	p = audioioparam(p, e, "bits", in->bits, out->bits, audio_bits_tbl);	/* this one is silly */
	p = audioioparam(p, e, "chans", in->chan, out->chan, audio_chan_tbl);
	/* TO DO: minimise in/out left/right where possible */
	if(in->left != in->right){
		p = seprint(p, e, "in left %d 0 100\n", in->left);
		p = seprint(p, e, "in right %d 0 100\n", in->right);
	}else
		p = seprint(p, e, "in %d 0 100\n", in->right);
	if(out->left != out->right){
		p = seprint(p, e, "out left %d 0 100\n", out->left);
		p = seprint(p, e, "out right %d 0 100\n", out->right);
	}else
		p = seprint(p, e, "out %d 0 100\n", out->right);
	p = seprint(p, e, "in buf %d %d %d\n", in->buf, Audio_Min_Val, Audio_Max_Val);
	p = seprint(p, e, "out buf %d %d %d\n", out->buf, Audio_Min_Val, Audio_Max_Val);

	return p-buf;
}

void
audio_info_init(Audio_t *t)
{
	t->in = Default_Audio_Format;
	t->in.dev = Default_Audio_Input;
	t->out = Default_Audio_Format;
	t->out.dev = Default_Audio_Output;
}

static int
str2val(svp_t* t, char* s, ulong *v)
{
	if(t == nil || s == nil)
		return 0;
	for(; t->s != nil; t++) {
		if(strncmp(t->s, s, strlen(t->s)) == 0) {
			*v = t->v;
			return 1;
		}
	}
	return 0;
}

static char*
val2str(svp_t* t, ulong v)
{
	if(t == nil)
		return nil;
	for(; t->s != nil; t++)
		if(t->v == v)
			return t->s;
	return nil;
}

static int 
sval(char* buf, ulong* v, ulong max, ulong min)
{
	unsigned long val = strtoul(buf, 0, 10);

	if(val > max || val < min)
		return 0;
	*v = val;
	return 1;
}

Dev audiodevtab = {
        'A',
        "audio",

        audioinit,
        audioattach,
        audiowalk,
        audiostat,
        audioopen,
        devcreate,
        audioclose,
        audioread,
        devbread,
        audiowrite,
        devbwrite,
        devremove,
        devwstat
};

