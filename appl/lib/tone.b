implement Tone;

include "sys.m";
	sys: Sys;

include "math.m";
	math: Math;

include "tone.m";

Audio:		con "/dev/audio";
Audioctl:	con "/dev/audioctl";

afd:	ref Sys->FD;
ctlfd:	ref Sys->FD;
stopch:	chan of int;
playing := 0;
twopi:	real;

init(): string
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	if(math == nil)
		return "cannot load Math";
	twopi = 2.0 * Math->Pi;
	ctlfd = sys->open(Audioctl, Sys->OWRITE);
	if(ctlfd == nil)
		return sys->sprint("open %s: %r", Audioctl);
	if(sys->fprint(ctlfd, "rate %d\nchans 2\nbits 16\nenc pcm\n", Tone->Rate) < 0)
		return sys->sprint("audioctl: %r");
	afd = sys->open(Audio, Sys->OWRITE);
	if(afd == nil)
		return sys->sprint("open %s: %r", Audio);
	stopch = chan of int;
	return nil;
}

ensure(): int
{
	if(afd != nil)
		return 0;
	e := init();
	if(e != nil){
		if(sys == nil)
			sys = load Sys Sys->PATH;
		sys->fprint(sys->fildes(2), "tone: %s\n", e);
		return -1;
	}
	return 0;
}

snd(freq: int)
{
	if(ensure() < 0)
		return;
	stop();
	if(freq <= 0)
		return;
	playing = 1;
	spawn toneproc(freq, 0);
}

beep(freq, duration_ms: int)
{
	if(ensure() < 0)
		return;
	stop();
	if(freq <= 0 || duration_ms <= 0)
		return;
	playing = 1;
	spawn toneproc(freq, duration_ms);
}

stop()
{
	if(ensure() < 0)
		return;
	if(playing){
		alt{
		stopch <-= 1 =>
			;
		* =>
			;
		}
		playing = 0;
	}
}

toneproc(freq: int, duration_ms: int)
{
	chunkms := 20;
	nsmax := Tone->Rate * chunkms / 1000;
	buf := array[nsmax * 4] of byte;
	phase := 0.0;
	dphase := twopi * real freq / real Tone->Rate;
	amp := 0.25;
	left := duration_ms;
	forever := duration_ms <= 0;

	for(;;){
		alt{
		<-stopch =>
			z := array[nsmax * 4] of { * => byte 0 };
			sys->write(afd, z, len z);
			playing = 0;
			exit;
		* =>
			;
		}
		ns := nsmax;
		if(!forever){
			if(left <= 0)
				break;
			if(left < chunkms)
				ns = Tone->Rate * left / 1000;
			left -= chunkms;
		}
		fill(buf, ns, phase, dphase, amp);
		phase += dphase * real ns;
		while(phase > twopi)
			phase -= twopi;
		if(sys->write(afd, buf, ns * 4) != ns * 4)
			break;
	}
	playing = 0;
}

fill(buf: array of byte, ns: int, phase, dphase, amp: real)
{
	for(i := 0; i < ns; i++){
		s := math->sin(phase);
		phase += dphase;
		v := int(s * amp * 32767.0);
		if(v > 32767)
			v = 32767;
		if(v < -32768)
			v = -32768;
		lo := byte(v);
		hi := byte(v >> 8);
		o := i * 4;
		buf[o] = lo;
		buf[o+1] = hi;
		buf[o+2] = lo;
		buf[o+3] = hi;
	}
}

# Write a tone synchronously (used by play).
tonewrite(freq: int, duration_ms: int)
{
	if(freq <= 0 || duration_ms <= 0){
		sys->sleep(duration_ms);
		return;
	}
	ns := Tone->Rate * duration_ms / 1000;
	if(ns <= 0)
		return;
	# write in chunks to avoid huge buffers
	chunk := Tone->Rate / 10;	# 100ms
	phase := 0.0;
	dphase := twopi * real freq / real Tone->Rate;
	amp := 0.25;
	buf := array[chunk * 4] of byte;
	left := ns;
	while(left > 0){
		n := chunk;
		if(n > left)
			n = left;
		fill(buf, n, phase, dphase, amp);
		phase += dphase * real n;
		while(phase > twopi)
			phase -= twopi;
		if(sys->write(afd, buf, n * 4) != n * 4)
			return;
		left -= n;
	}
}

play(score: string): string
{
	if(ensure() < 0)
		return "audio not open";
	stop();

	octave := 4;
	dur_ms := 500;	# quarter @ ~120bpm
	i := 0;
	n := len score;
	while(i < n){
		c := score[i++];
		case c {
		'0' to '9' =>
			octave = c - '0';
		'w' =>
			dur_ms = 2000;
		'h' =>
			dur_ms = 1000;
		'q' =>
			dur_ms = 500;
		'e' =>
			dur_ms = 250;
		's' =>
			dur_ms = 125;
		't' =>
			dur_ms = 62;
		'.' =>
			dur_ms = dur_ms * 3 / 2;
		'R' or 'r' =>
			sys->sleep(dur_ms);
		'A' to 'G' =>
			semi := 0;
			case c {
			'C' => semi = 0;
			'D' => semi = 2;
			'E' => semi = 4;
			'F' => semi = 5;
			'G' => semi = 7;
			'A' => semi = 9;
			'B' => semi = 11;
			}
			acc := 0;
			if(i < n){
				if(score[i] == '#'){
					acc = 1;
					i++;
				}else if(score[i] == 'b'){
					acc = -1;
					i++;
				}
			}
			f := 440.0 * math->pow(2.0, real((octave+1)*12 + semi + acc - 69) / 12.0);
			tonewrite(int f, dur_ms);
		' ' or '\t' or '\n' =>
			;
		* =>
			;
		}
	}
	return nil;
}
