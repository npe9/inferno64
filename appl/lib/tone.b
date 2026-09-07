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

# Every snd(), beep() and stop() bumps this, and a running toneproc exits
# as soon as it sees a number that is not its own.
#
# stop() used to be the only way to end one, through a NON-BLOCKING send
# on an unbuffered stopch - and a toneproc spends nearly all its time
# blocked in the write to /dev/audio, not at that receive, so the message
# was usually dropped and the old process ran on for ever.  bombergolf
# calls snd() with a fresh random frequency on every frame of an
# explosion, so it leaked about sixty processes a second: 624 of them in
# twelve seconds, 14MB of the main pool, and then the emulator ran out.
# Found with /dev/memleak, which named newproc, newprog, addprog,
# newstack and kproc all with the same count.
generation := 0;
twopi:	real;

# --- the synth ---
#
# A voice is a harmonic series and an envelope.  The series is summed
# once into a single-cycle wavetable when the voice is chosen, so
# rendering a note is a table lookup and a linear interpolation per
# sample rather than one sin() per harmonic per sample: at 22050Hz with
# six harmonics and four parts that is the difference between 530,000
# sin() calls a second and none.
#
# The envelope is why this stops sounding like a beeper.  A PC speaker
# note is a rectangle in time - full amplitude the instant it starts,
# nothing the instant it ends, which is the click you hear between the
# notes of every TempleOS tune.  Here every note ramps up over its
# attack, falls to its sustain level over its decay, holds, and ramps
# down over its release.

Ntable:	con 2048;		# one cycle, power of two

Voicedef: adt {
	name:		string;
	harm:		array of real;	# amplitude of harmonic 1, 2, 3, ...
	attack:		int;		# ms
	decay:		int;		# ms
	sustain:	real;		# 0..1 of peak
	release:	int;		# ms
	vibhz:		real;		# 0 for none
	vibdepth:	real;		# semitone fraction
};

voicetab := array[] of {
	# the old behaviour, kept so a caller can ask for it back
	Voicedef("sine", array[] of {1.0}, 4, 0, 1.0, 6, 0.0, 0.0),
	# drawbars: odd and even together, a slow tremolo
	Voicedef("organ", array[] of {1.0, 0.5, 0.35, 0.0, 0.22, 0.0, 0.12},
		12, 40, 0.85, 60, 5.5, 0.004),
	# a sawtooth-ish series, bowed: slow in, long out
	Voicedef("string", array[] of {1.0, 0.5, 0.33, 0.25, 0.2, 0.16, 0.14, 0.12},
		90, 120, 0.7, 260, 5.0, 0.010),
	# square-ish odd harmonics, short and hard
	Voicedef("reed", array[] of {1.0, 0.0, 0.33, 0.0, 0.2, 0.0, 0.14, 0.0, 0.11},
		8, 90, 0.6, 90, 0.0, 0.0),
	# inharmonic-sounding partials with no sustain at all
	Voicedef("bell", array[] of {1.0, 0.0, 0.6, 0.0, 0.0, 0.4, 0.0, 0.0, 0.25},
		2, 900, 0.0, 300, 0.0, 0.0),
	# a plucked string: instant on, decays away
	Voicedef("pluck", array[] of {1.0, 0.7, 0.45, 0.3, 0.2, 0.14, 0.1},
		2, 420, 0.08, 160, 0.0, 0.0),
	# the flute end: almost a sine, breathy attack
	Voicedef("flute", array[] of {1.0, 0.08, 0.16, 0.02, 0.05},
		70, 60, 0.9, 120, 6.0, 0.006),
};

voice := 1;			# organ
table: array of real;		# one cycle of the current voice
quarterms := 500;		# tempo, ms per quarter note

# init does NOT open the audio device.  Opening /dev/audio costs about
# 150ms on a hosted emu - CoreAudio setup, on this host - and forty
# programs in this tree called init() from their own init() before
# putting a window up, so every one of them was a sixth of a second
# slower to appear whether or not it ever made a sound.  bigguns spent
# 153ms of its 214ms startup here.
#
# What is left is what a caller actually wants from init(): "is the tone
# library usable".  opendevice() does the real work, from ensure(), on
# the first note.
init(): string
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	if(math == nil)
		return "cannot load Math";
	twopi = 2.0 * Math->Pi;
	stopch = chan[1] of int;	# buffered: a stop is never dropped
	opened = 0;
	buildtable();
	return nil;
}

buildtable()
{
	v := voicetab[voice];
	table = array[Ntable+1] of real;
	peak := 0.0;
	for(i := 0; i < Ntable; i++){
		a := twopi * real i / real Ntable;
		x := 0.0;
		for(h := 0; h < len v.harm; h++)
			if(v.harm[h] != 0.0)
				x += v.harm[h] * math->sin(a * real (h+1));
		table[i] = x;
		if(x > peak)
			peak = x;
		if(-x > peak)
			peak = -x;
	}
	if(peak <= 0.0)
		peak = 1.0;
	for(i = 0; i < Ntable; i++)
		table[i] /= peak;
	table[Ntable] = table[0];	# so interpolation needs no wrap test
}

voicenames(): list of string
{
	l: list of string;
	for(i := len voicetab - 1; i >= 0; i--)
		l = voicetab[i].name :: l;
	return l;
}

setvoice(name: string): string
{
	if(math == nil && init() != nil)
		return "cannot load Math";
	for(i := 0; i < len voicetab; i++)
		if(voicetab[i].name == name){
			voice = i;
			buildtable();
			return nil;
		}
	known := "";
	for(i = 0; i < len voicetab; i++){
		if(i > 0)
			known += " ";
		known += voicetab[i].name;
	}
	return "no voice "+name+"; have "+known;
}

settempo(quarter_ms: int)
{
	if(quarter_ms > 0)
		quarterms = quarter_ms;
}

# wave: the current voice's cycle at a phase in turns (0..1), linearly
# interpolated between table entries.
# math->floor, not "int": Limbo's int-of-a-real ROUNDS to nearest, so
# int(0.9999*2048) is 2048 and the interpolation reads table[2049].  That
# is an array bounds error the first time a note's phase passes the last
# table entry, which is within a millisecond of the first note.
wave(turns: real): real
{
	turns -= math->floor(turns);
	x := turns * real Ntable;
	i := int math->floor(x);
	if(i >= Ntable)
		i = Ntable-1;
	f := x - real i;
	return table[i] + f*(table[i+1]-table[i]);
}

# envelope: 0..1 for a note that started at age 0 and lasts dur ms.  The
# release is taken out of the note's own length, so notes in a score
# separate instead of running into one another.
envelope(age, dur: int): real
{
	v := voicetab[voice];
	if(age < 0 || age > dur)
		return 0.0;
	rel := v.release;
	if(rel > dur/2)
		rel = dur/2;
	if(age > dur-rel){
		e := sustainat(dur-rel);
		if(rel <= 0)
			return 0.0;
		return e * real(dur-age) / real rel;
	}
	return sustainat(age);
}

sustainat(age: int): real
{
	v := voicetab[voice];
	if(age < v.attack){
		if(v.attack <= 0)
			return 1.0;
		return real age / real v.attack;
	}
	if(age < v.attack+v.decay){
		if(v.decay <= 0)
			return v.sustain;
		f := real(age-v.attack) / real v.decay;
		return 1.0 + (v.sustain-1.0)*f;
	}
	return v.sustain;
}

opened := 0;		# 1 = device open, -1 = tried and failed

opendevice(): string
{
	ctlfd = sys->open(Audioctl, Sys->OWRITE);
	if(ctlfd == nil)
		return sys->sprint("open %s: %r", Audioctl);
	if(sys->fprint(ctlfd, "rate %d\nchans 2\nbits 16\nenc pcm\n", Tone->Rate) < 0)
		return sys->sprint("audioctl: %r");
	afd = sys->open(Audio, Sys->OWRITE);
	if(afd == nil)
		return sys->sprint("open %s: %r", Audio);
	return nil;
}

ensure(): int
{
	if(afd != nil)
		return 0;
	if(opened < 0)
		return -1;	# reported once already; do not say it again
	if(sys == nil){
		e := init();
		if(e != nil){
			opened = -1;
			return -1;
		}
	}
	e := opendevice();
	if(e != nil){
		opened = -1;
		sys->fprint(sys->fildes(2), "tone: %s\n", e);
		return -1;
	}
	opened = 1;
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
	spawn toneproc(freq, 0, generation);
}

beep(freq, duration_ms: int)
{
	if(ensure() < 0)
		return;
	stop();
	if(freq <= 0 || duration_ms <= 0)
		return;
	playing = 1;
	spawn toneproc(freq, duration_ms, generation);
}

stop()
{
	if(ensure() < 0)
		return;
	generation++;
	if(playing){
		alt{
		stopch <-= 1 =>
			;
		* =>
			;	# buffer already holds one, which is enough
		}
		playing = 0;
	}
}

toneproc(freq: int, duration_ms: int, mygen: int)
{
	chunkms := 20;
	nsmax := Tone->Rate * chunkms / 1000;
	buf := array[nsmax * 4] of byte;
	turns := 0.0;
	dturns := real freq / real Tone->Rate;
	age := 0;
	left := duration_ms;
	forever := duration_ms <= 0;

	for(;;){
		if(mygen != generation)
			exit;		# superseded, whether or not the
					# stop message reached us
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
		fill(buf, ns, turns, dturns, age, duration_ms);
		turns += dturns * real ns;
		turns -= math->floor(turns);
		age += ns*1000/Tone->Rate;
		if(sys->write(afd, buf, ns * 4) != ns * 4)
			break;
	}
	playing = 0;
}

# fill: one chunk of a single steady note, for snd() and beep().  amp is
# the envelope value at each sample, so even a held note fades in rather
# than clicking on.
fill(buf: array of byte, ns: int, turns, dturns: real, age, dur: int)
{
	for(i := 0; i < ns; i++){
		e := 1.0;
		if(dur > 0)
			e = envelope(age + i*1000/Tone->Rate, dur);
		else
			e = sustainat(age + i*1000/Tone->Rate);
		v := int(wave(turns) * e * 0.25 * 32767.0);
		turns += dturns;
		if(v > 32767)
			v = 32767;
		if(v < -32768)
			v = -32768;
		lo := byte v;
		hi := byte (v >> 8);
		o := i * 4;
		buf[o] = lo;
		buf[o+1] = hi;
		buf[o+2] = lo;
		buf[o+3] = hi;
	}
}

# --- score rendering ---

Ev: adt {
	start:	int;		# ms from the start of the piece
	dur:	int;
	freq:	real;		# 0 for a rest
};

# parsepart: one score into absolute-time events.  Same syntax as before -
# digits set the octave, w/h/q/e/s/t set the duration, '.' dots it, A-G
# with an optional #/b are notes and R is a rest - with the durations now
# scaled by the tempo rather than fixed at 120bpm.
parsepart(score: string): array of Ev
{
	evs := array[len score + 1] of Ev;
	n := 0;
	octave := 4;
	dur := quarterms;
	at := 0;
	i := 0;
	m := len score;
	while(i < m){
		c := score[i++];
		case c {
		'0' to '9' =>
			octave = c - '0';
		'w' => dur = quarterms*4;
		'h' => dur = quarterms*2;
		'q' => dur = quarterms;
		'e' => dur = quarterms/2;
		's' => dur = quarterms/4;
		't' => dur = quarterms/8;
		'.' => dur = dur*3/2;
		'R' or 'r' =>
			at += dur;
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
			if(i < m){
				if(score[i] == '#'){
					acc = 1;
					i++;
				}else if(score[i] == 'b'){
					acc = -1;
					i++;
				}
			}
			f := 440.0 * math->pow(2.0,
				real((octave+1)*12 + semi + acc - 69) / 12.0);
			evs[n++] = Ev(at, dur, f);
			at += dur;
		* =>
			;
		}
	}
	return evs[0:n];
}

# render: mix every event of every part and write the result.  This is
# what a square wave cannot do: two notes at the same instant.
render(parts: array of array of Ev): string
{
	total := 0;
	nev := 0;
	for(p := 0; p < len parts; p++){
		nev += len parts[p];
		for(i := 0; i < len parts[p]; i++){
			e := parts[p][i].start + parts[p][i].dur;
			if(e > total)
				total = e;
		}
	}
	if(nev == 0 || total <= 0)
		return nil;

	# one flat event list, with a phase per note
	ev := array[nev] of Ev;
	k := 0;
	for(p = 0; p < len parts; p++)
		for(i := 0; i < len parts[p]; i++)
			ev[k++] = parts[p][i];
	turns := array[nev] of real;
	vibturns := array[nev] of real;
	for(i = 0; i < nev; i++){
		turns[i] = 0.0;
		vibturns[i] = 0.0;
	}

	v := voicetab[voice];
	scale := 0.7;
	if(len parts > 1)
		scale = 0.7 / math->sqrt(real len parts);

	chunk := Tone->Rate / 20;		# 50ms
	buf := array[chunk*4] of byte;
	nstotal := Tone->Rate * total / 1000 + Tone->Rate/10;
	done := 0;
	while(done < nstotal){
		ns := chunk;
		if(ns > nstotal-done)
			ns = nstotal-done;
		for(j := 0; j < ns; j++){
			ms := (done+j)*1000/Tone->Rate;
			x := 0.0;
			for(i = 0; i < nev; i++){
				age := ms - ev[i].start;
				if(age < 0 || age > ev[i].dur)
					continue;
				e := envelope(age, ev[i].dur);
				if(e <= 0.0)
					continue;
				f := ev[i].freq;
				if(v.vibhz > 0.0){
					f *= 1.0 + v.vibdepth*wave(vibturns[i]);
					vibturns[i] += v.vibhz / real Tone->Rate;
				}
				x += e * wave(turns[i]);
				turns[i] += f / real Tone->Rate;
			}
			w := int(x * scale * 32767.0);
			if(w > 32767)
				w = 32767;
			if(w < -32768)
				w = -32768;
			lo := byte w;
			hi := byte (w >> 8);
			o := j*4;
			buf[o] = lo;
			buf[o+1] = hi;
			buf[o+2] = lo;
			buf[o+3] = hi;
		}
		if(sys->write(afd, buf, ns*4) != ns*4)
			return "audio write failed";
		done += ns;
	}
	return nil;
}

play(score: string): string
{
	return playparts(array[] of {score});
}

playparts(parts: array of string): string
{
	if(ensure() < 0)
		return "audio not open";
	stop();
	if(len parts == 0)
		return nil;
	evs := array[len parts] of array of Ev;
	for(i := 0; i < len parts; i++)
		evs[i] = parsepart(parts[i]);
	return render(evs);
}

