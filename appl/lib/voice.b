implement Voice;

#
# A voice model, held open. See voice(2).
#
include "sys.m";
	sys: Sys;
	sprint: import sys;
include "math.m";
	math: Math;
include "bufio.m";
	bufio: Bufio;
include "json.m";
	json: JSON;
	JValue: import json;
include "voice.m";

init(): string
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	if(math == nil || bufio == nil || json == nil)
		return sprint("load: %r");
	json->init(bufio);
	return nil;
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

open(model, units: string): (ref Speaker, string)
{
	if(sys == nil)
		return (nil, "voice->init has not been called");
	if(model == nil)
		model = MODEL;
	if(units == nil)
		units = "cpu";

	if(sys->bind("#N", "/dev", Sys->MAFTER) < 0)
		return (nil, sprint("bind #N: %r"));
	ctl := sys->open("/dev/ml/clone", Sys->ORDWR);
	if(ctl == nil)
		return (nil, sprint("/dev/ml/clone: %r"));
	nb := array[32] of byte;
	n := sys->read(ctl, nb, len nb);
	if(n <= 0)
		return (nil, sprint("read clone: %r"));
	# a numeric read comes back padded, as everything in Plan 9 does
	dir := "/dev/ml/" + trim(string nb[0:n]);

	if(sys->fprint(ctl, "units %s", units) < 0)
		return (nil, sprint("units: %r"));

	# The model crosses as bytes, in pieces; the device appends until ctl
	# says load. Sixty megabytes of it, which is the whole reason a Speaker
	# is worth keeping rather than making one per utterance.
	mf := sys->open(model, Sys->OREAD);
	if(mf == nil)
		return (nil, sprint("%s: %r", model));
	mfd := sys->open(dir + "/model", Sys->OWRITE);
	if(mfd == nil)
		return (nil, sprint("open model: %r"));
	buf := array[1024*1024] of byte;
	total := 0;
	while((n = sys->read(mf, buf, len buf)) > 0){
		if(sys->write(mfd, buf[0:n], n) != n)
			return (nil, sprint("write model: %r"));
		total += n;
	}
	mfd = nil;
	mf = nil;
	if(total == 0)
		return (nil, model + " is empty");
	if(sys->fprint(ctl, "load") < 0)
		return (nil, sprint("load: %r"));

	s := ref Speaker(dir, ctl, RATE, nil, nil);
	if((e := symbols(s, model)) != nil)
		return (nil, e);
	return (s, nil);
}

#
# The voice's own symbol table, out of the .json beside it. Read once: it is a
# hundred and fifty entries and re-reading it per utterance was most of what
# made a second utterance as expensive as the first.
#
symbols(s: ref Speaker, model: string): string
{
	cfg := model + ".json";
	b := bufio->open(cfg, Bufio->OREAD);
	if(b == nil)
		return sprint("%s: %r", cfg);
	(v, err) := json->readjson(b);
	if(v == nil)
		return sprint("%s: %s", cfg, err);
	m := v.get("phoneme_id_map");
	if(m == nil)
		return cfg + " has no phoneme_id_map";

	pick mm := m {
	Object =>
		n := 0;
		for(l := mm.mem; l != nil; l = tl l)
			n++;
		s.sym = array[n] of string;
		s.id = array[n] of int;
		k := 0;
		for(l = mm.mem; l != nil; l = tl l){
			(nm, val) := hd l;
			if(val == nil)
				continue;
			pick a := val {
			Array =>
				if(len a.a == 0)
					continue;
				pick n0 := a.a[0] {
				Int =>	s.id[k] = int n0.value;
				Real =>	s.id[k] = int n0.value;
				* =>	continue;
				}
			* =>
				continue;
			}
			s.sym[k] = nm;
			k++;
		}
		s.sym = s.sym[0:k];
		s.id = s.id[0:k];
	* =>
		return cfg + "'s phoneme_id_map is not an object";
	}
	if(len s.sym == 0)
		return cfg + " has an empty phoneme_id_map";
	return nil;
}

Speaker.lookup(s: self ref Speaker, sym: string): int
{
	for(i := 0; i < len s.sym; i++)
		if(s.sym[i] == sym)
			return s.id[i];
	return -1;
}

#
# What a VITS voice wants: the phoneme numbers, how many there are, and the
# three scales that decide how it is spoken. The arrangement - begin, then
# every symbol followed by the pad, then end - is identical for every
# utterance, so it lives here rather than in every caller.
#
Speaker.speak(s: self ref Speaker, phonemes: string): (array of real, string)
{
	if(phonemes == nil)
		return (nil, "nothing to say");

	ids := array[2 + 2*len phonemes + 1] of int;
	n := 0;
	ids[n++] = 1;			# begin
	ids[n++] = 0;			# pad
	for(i := 0; i < len phonemes; i++){
		k := s.lookup(phonemes[i:i+1]);
		if(k < 0)
			return (nil, sprint("the voice has no symbol %s", phonemes[i:i+1]));
		ids[n++] = k;
		ids[n++] = 0;
	}
	ids[n++] = 2;			# end
	return s.feedids(ids[0:n]);
}

Speaker.feedids(s: self ref Speaker, ids: array of int): (array of real, string)
{
	if((e := feed(s, "input", "1 " + string len ids, puti64(ids))) != nil)
		return (nil, e);
	if((e = feed(s, "input_lengths", "1", puti64(array[] of {len ids}))) != nil)
		return (nil, e);
	if((e = feed(s, "scales", nil, putf32(array[] of {0.667, 1.0, 0.8}))) != nil)
		return (nil, e);
	if(sys->fprint(s.ctl, "run") < 0)
		return (nil, sprint("run: %r"));

	ofd := sys->open(s.dir + "/out", Sys->OREAD);
	if(ofd == nil)
		return (nil, sprint("open out: %r"));
	ob := array[4*1024*1024] of byte;
	m := sys->readn(ofd, ob, len ob);
	if(m <= 0)
		return (nil, sprint("read out: %r"));
	return (getf32(ob[0:m]), nil);
}

feed(s: ref Speaker, name, shape: string, data: array of byte): string
{
	if(sys->fprint(s.ctl, "feed %s", name) < 0)
		return sprint("feed %s: %r", name);
	if(shape != nil && sys->fprint(s.ctl, "shape %s", shape) < 0)
		return sprint("shape %s: %r", shape);
	fd := sys->open(s.dir + "/in", Sys->OWRITE);
	if(fd == nil)
		return sprint("open in: %r");
	if(sys->write(fd, data, len data) != len data)
		return sprint("write %s: %r", name);
	return nil;
}

#
# ml(3)'s wire is big-endian whatever the host is.
#
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

pcmbytes(pcm: array of real): array of byte
{
	w := array[2*len pcm] of byte;
	for(i := 0; i < len pcm; i++){
		v := int (pcm[i] * 32767.0);
		if(v > 32767)
			v = 32767;
		if(v < -32768)
			v = -32768;
		w[2*i] = byte v;
		w[2*i+1] = byte (v >> 8);
	}
	return w;
}

play(pcm: array of real, rate: int, out: string): string
{
	if(out == nil)
		out = "/dev/audio";

	#
	# The device infers nothing from what is written to it - it starts at
	# 8000 Hz and two channels - so samples in any other shape are heard as
	# though they were that, with no error, because nothing about the write
	# is wrong. See audio(3).
	#
	if(out == "/dev/audio"){
		cfd := sys->open("/dev/audioctl", Sys->OWRITE);
		if(cfd == nil)
			return sprint("open /dev/audioctl: %r");
		if(sys->fprint(cfd, "rate %d", rate) < 0 ||
		   sys->fprint(cfd, "chans 1") < 0 ||
		   sys->fprint(cfd, "bits 16") < 0)
			return sprint("set the audio format: %r");
	}

	w := pcmbytes(pcm);
	af := sys->create(out, Sys->OWRITE, 8r666);
	if(af == nil)
		af = sys->open(out, Sys->OWRITE);
	if(af == nil)
		return sprint("%s: %r", out);
	if(sys->write(af, w, len w) != len w)
		return sprint("write %s: %r", out);
	#
	# Dropping the last reference closes it, and closing /dev/audio is what
	# waits for the sound to finish - a write only queues it. So this
	# returns when it has been heard, which is what makes a writer's pacing
	# come out right.
	#
	af = nil;
	return nil;
}
