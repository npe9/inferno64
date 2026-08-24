implement Command;

#
# Speak, through ml(3).
#
# The voice is a VITS model - phoneme numbers in, a waveform out, with no
# vocoder or formant synthesis in between. That is the whole reason for
# putting it behind ml(3) rather than building a synthesizer: the interesting
# part is a trained network, and the device already runs those.
#
# It takes phoneme ids rather than text. Turning text into phonemes is a
# different job with a different failure mode - English spelling - and doing
# it badly here would make a working synthesizer look broken. A front end
# belongs on top of this, not inside it.
#
#	say 1 0 20 0 59 0 24 0 120 0 27 0 100 0 2
#
# The model this was written against wants its ids interleaved with the pad
# symbol and wrapped in begin and end, which is the sequence above: it says
# "hello".
#
include "sys.m";
	sys: Sys;
	print, sprint, fprint: import sys;
include "draw.m";
include "math.m";
	math: Math;
include "arg.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Voice:	con "/lib/ml/voices/en_US-lessac-low.onnx";
Rate:	con 16000;		# what this voice was trained at

ctl:	ref Sys->FD;
dir:	string;

fatal(s: string)
{
	fprint(sys->fildes(2), "say: %s\n", s);
	raise "fail:error";
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

cmd(s: string)
{
	if(sys->fprint(ctl, "%s", s) < 0)
		fatal(sprint("%s: %r", s));
}

# i64 across ml(3)'s big-endian wire
puti64(v: array of int): array of byte
{
	b := array[8*len v] of byte;
	for(i := 0; i < len v; i++){
		x := big v[i];
		for(j := 0; j < 8; j++)
			b[8*i+j] = byte int ((x >> ((7-j)*8)) & big 16rff);
	}
	return b;
}

putf32(v: array of real): array of byte
{
	b := array[4*len v] of byte;
	for(i := 0; i < len v; i++){
		u := math->realbits32(v[i]);
		b[4*i] = byte (u>>24); b[4*i+1] = byte (u>>16);
		b[4*i+2] = byte (u>>8); b[4*i+3] = byte u;
	}
	return b;
}

getf32(b: array of byte): array of real
{
	v := array[len b/4] of real;
	for(i := 0; i < len v; i++)
		v[i] = math->bits32real((int b[4*i]<<24) | (int b[4*i+1]<<16) |
			(int b[4*i+2]<<8) | int b[4*i+3]);
	return v;
}

feed(name: string, shape: string, data: array of byte)
{
	cmd("feed " + name);
	if(shape != nil)
		cmd("shape " + shape);
	fd := sys->open(dir + "/in", Sys->OWRITE);
	if(fd == nil)
		fatal(sprint("open in: %r"));
	if(sys->write(fd, data, len data) != len data)
		fatal(sprint("write %s: %r", name));
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	arg := load Arg Arg->PATH;
	if(math == nil || arg == nil)
		fatal(sprint("load: %r"));

	voice := Voice;
	out := "/dev/audio";
	showinfo := 0;
	arg->init(argv);
	arg->setusage("say [-v voice] [-o file] [-i] id...");
	while((o := arg->opt()) != 0)
		case o {
		'v' =>	voice = arg->earg();
		'o' =>	out = arg->earg();
		'i' =>	showinfo++;
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(argv == nil)
		arg->usage();
	ids := array[len argv] of int;
	for(i := 0; argv != nil; (i, argv) = (i+1, tl argv))
		ids[i] = int hd argv;

	if(sys->bind("#N", "/dev", Sys->MAFTER) < 0)
		fatal(sprint("bind #N: %r"));
	ctl = sys->open("/dev/ml/clone", Sys->ORDWR);
	if(ctl == nil)
		fatal(sprint("open clone: %r"));
	nb := array[32] of byte;
	n := sys->read(ctl, nb, len nb);
	if(n <= 0)
		fatal(sprint("read clone: %r"));
	# a numeric read comes back padded, as everything in Plan 9 does
	dir = "/dev/ml/" + trim(string nb[0:n]);

	# The model, whole. It is sixty megabytes, so it goes in pieces; the
	# device appends until ctl says load.
	mf := sys->open(voice, Sys->OREAD);
	if(mf == nil)
		fatal(sprint("%s: %r", voice));
	mfd := sys->open(dir + "/model", Sys->OWRITE);
	if(mfd == nil)
		fatal(sprint("open model: %r"));
	buf := array[1024*1024] of byte;
	total := 0;
	while((n = sys->read(mf, buf, len buf)) > 0){
		if(sys->write(mfd, buf[0:n], n) != n)
			fatal(sprint("write model: %r"));
		total += n;
	}
	mfd = nil;
	cmd("load");

	if(showinfo){
		ifd := sys->open(dir + "/info", Sys->OREAD);
		ib := array[8192] of byte;
		if(ifd != nil && (n = sys->read(ifd, ib, len ib)) > 0)
			print("%s", string ib[0:n]);
	}

	# What a VITS voice wants: the phonemes, how many there are, and the
	# three scales that decide how it is spoken.
	feed("input", "1 " + string len ids, puti64(ids));
	feed("input_lengths", "1", puti64(array[] of {len ids}));
	feed("scales", nil, putf32(array[] of {0.667, 1.0, 0.8}));

	cmd("run");

	ofd := sys->open(dir + "/out", Sys->OREAD);
	if(ofd == nil)
		fatal(sprint("open out: %r"));
	ob := array[4*1024*1024] of byte;
	n = sys->readn(ofd, ob, len ob);
	if(n <= 0)
		fatal(sprint("read out: %r"));
	pcm := getf32(ob[0:n]);
	print("say: %d samples, %g seconds at %d Hz\n",
		len pcm, real len pcm / real Rate, Rate);

	# /dev/audio takes signed 16-bit, little-endian, and this voice is
	# 16kHz mono. The samples come back between -1 and 1.
	w := array[2*len pcm] of byte;
	for(i = 0; i < len pcm; i++){
		s := int (pcm[i] * 32767.0);
		if(s > 32767)
			s = 32767;
		if(s < -32768)
			s = -32768;
		w[2*i] = byte s;
		w[2*i+1] = byte (s >> 8);
	}
	af := sys->create(out, Sys->OWRITE, 8r666);
	if(af == nil)
		af = sys->open(out, Sys->OWRITE);
	if(af == nil)
		fatal(sprint("%s: %r", out));
	if(sys->write(af, w, len w) != len w)
		fatal(sprint("write %s: %r", out));
}
