implement Command;

#
# Tests voice(3), the speech device.
#
# Nothing here can hear, so this does not claim the speech is intelligible. It
# claims three things that can be established from the samples themselves:
#
#	writing phonemes produces sound and an unknown symbol does not stop it;
#	"speed" changes how long an utterance takes, in the direction and by
#	roughly the amount it says;
#	"pitch" changes the rate the voice source repeats at, which is measured
#	by autocorrelation rather than believed.
#
# The pitch check is the one worth having. Everything else about this device
# could be right while the source ran at a fixed rate, and the result would
# still be speech-shaped noise of the correct length - it would just always be
# the same voice. Correlating the waveform against itself at the period the
# pitch implies is what distinguishes those.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Rate:	con 16000;

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

ctl:	ref Sys->FD;

cmd(s: string)
{
	if(sys->fprint(ctl, "%s", s) < 0)
		bad(sprint("%s: %r", s));
}

# write phonemes, read back the samples
utter(ph: string): array of int
{
	fd := sys->open("/dev/voice/phonemes", Sys->OWRITE);
	if(fd == nil){
		bad(sprint("open phonemes: %r"));
		return nil;
	}
	b := array of byte ph;
	if(sys->write(fd, b, len b) != len b){
		bad(sprint("write phonemes: %r"));
		return nil;
	}
	fd = nil;

	pfd := sys->open("/dev/voice/pcm", Sys->OREAD);
	if(pfd == nil){
		bad(sprint("open pcm: %r"));
		return nil;
	}
	raw := array[4*1024*1024] of byte;
	n := sys->readn(pfd, raw, len raw);
	if(n <= 0)
		return nil;
	v := array[n/2] of int;
	for(i := 0; i < len v; i++){
		s := (int raw[2*i+1] << 8) | int raw[2*i];
		if(s >= 16r8000)
			s -= 16r10000;		# signed 16-bit, little-endian
		v[i] = s;
	}
	return v;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	if(sys->bind("#V", "/dev", Sys->MAFTER) < 0){
		print("voicetest: bind #V: %r\n");
		raise "fail:no device";
	}
	ctl = sys->open("/dev/voice/ctl", Sys->ORDWR);
	if(ctl == nil){
		print("voicetest: open ctl: %r\n");
		raise "fail:no device";
	}

	makes();
	speed();
	pitch();
	announce();

	if(fail)
		raise "fail:test";
	print("PASS\n");
}

#
# It makes a sound at all, and an unknown symbol is skipped rather than fatal.
#
makes()
{
	cmd("pitch 100");
	cmd("speed 100");
	v := utter("hɛlˈoʊ");
	if(len v == 0){
		bad("phonemes produced no samples");
		return;
	}
	# not merely nonzero: silence would also be "samples"
	e := 0;
	for(i := 0; i < len v; i++)
		if(v[i] > 1000 || v[i] < -1000)
			e++;
	if(e * 10 < len v)
		bad(sprint("only %d of %d samples carry any signal", e, len v));

	# a symbol the table does not have must not stop the rest
	w := utter("hɛlˈoʊ☃");
	if(len w == 0)
		bad("an unknown symbol silenced the whole utterance");
}

#
# Speed. Twice the speed is half the samples, near enough - the device works in
# whole samples per phoneme so it will not be exact.
#
speed()
{
	cmd("pitch 100");
	cmd("speed 100");
	slow := utter("ˈɑːˈɑːˈɑː");
	cmd("speed 200");
	fast := utter("ˈɑːˈɑːˈɑː");
	cmd("speed 100");

	if(len slow == 0 || len fast == 0){
		bad("no samples to compare speeds with");
		return;
	}
	want := len slow / 2;
	d := len fast - want;
	if(d < 0)
		d = -d;
	if(d > want / 10)
		bad(sprint("speed 200 gave %d samples, expected about %d (from %d)",
			len fast, want, len slow));
}

#
# Pitch, by correlating the waveform against itself.
#
# A voiced source repeating every P samples makes a waveform that resembles
# itself P samples later. At 16000 Hz, 100 Hz is 160 samples and 200 Hz is 80.
# So the test is not "does the number in ctl change" - it is whether the sound
# actually repeats at the period the number implies.
#
pitch()
{
	cmd("speed 100");
	cmd("pitch 100");
	lo := utter("ˈɑːˈɑːˈɑː");
	cmd("pitch 200");
	hi := utter("ˈɑːˈɑːˈɑː");
	cmd("pitch 100");

	if(len lo < 2000 || len hi < 2000){
		bad("not enough samples to measure pitch");
		return;
	}
	l160 := corr(lo, 160);
	l80 := corr(lo, 80);
	h160 := corr(hi, 160);
	h80 := corr(hi, 80);

	# at 100Hz it should look more like itself at 160 than at 80
	if(l160 <= l80)
		bad(sprint("pitch 100: correlation at 160 samples %g not above that at 80 %g",
			l160, l80));
	# at 200Hz, 80 samples is one period and 160 is two, so both are high;
	# what must change is that 80 is now at least as good as 160
	if(h80 < h160)
		bad(sprint("pitch 200: correlation at 80 samples %g below that at 160 %g",
			h80, h160));
	if(!fail)
		print("  pitch 100 correlates %g at 160 and %g at 80; pitch 200, %g and %g\n",
			l160, l80, h160, h80);
}

# normalised autocorrelation at one lag, over the middle of the waveform
corr(v: array of int, lag: int): real
{
	n := len v / 2;
	if(n + lag > len v)
		n = len v - lag;
	off := (len v - n - lag) / 2;
	num := 0.0;
	da := 0.0;
	db := 0.0;
	for(i := 0; i < n; i++){
		a := real v[off+i];
		b := real v[off+i+lag];
		num += a * b;
		da += a * a;
		db += b * b;
	}
	if(da == 0.0 || db == 0.0)
		return 0.0;
	return num / sqrt(da * db);
}

sqrt(x: real): real
{
	if(x <= 0.0)
		return 0.0;
	g := x;
	for(i := 0; i < 40; i++)
		g = 0.5 * (g + x / g);
	return g;
}

#
# The announce levels are accepted and reported back. What each one actually
# lets through is checked under wm by hand, not here: it needs a window system
# and a focus to move.
#
announce()
{
	for(l := list of {"off", "all", "focus"}; l != nil; l = tl l){
		cmd("announce " + hd l);
		if(reported() != hd l)
			bad(sprint("announce %s reported back as %#q", hd l, reported()));
	}
	# and something that is not a level must be refused
	if(sys->fprint(ctl, "announce sideways") >= 0)
		bad("ctl accepted an announce level that does not exist");
}

reported(): string
{
	fd := sys->open("/dev/voice/ctl", Sys->OREAD);
	if(fd == nil)
		return sprint("open ctl: %r");
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return sprint("read ctl: %r");
	s := string b[0:n];
	for(i := 0; i < len s; i++){
		if(i != 0 && s[i-1] != '\n')
			continue;
		if(i+9 <= len s && s[i:i+9] == "announce "){
			j := i+9;
			while(j < len s && s[j] != '\n')
				j++;
			return s[i+9:j];
		}
	}
	return "";
}
