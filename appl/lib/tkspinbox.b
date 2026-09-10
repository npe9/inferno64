implement Tkspinbox;

#
# A spinbox - a number with an up and a down beside it - out of the
# widgets libtk already has.  This Tk is 8.0-era and has no spinbox; the
# expensive half of that gap wants C, and this is the cheap half, a frame
# holding an entry and two buttons.
#
# THE VALUE LIVES IN AN ENTRY, and that is not a detail of appearance.
# An entry is a control with a state, so libtk already announces it to
# voice(3) when the keyboard arrives at it - tkannouncestate() has a case
# for TKentry - and a person who tabs onto this hears the number without
# this module knowing that speech exists.  It is the same trade the
# notebook makes by building its tabs from radiobuttons, and the reason
# to prefer a composition over a drawing: a picture of a number would
# have been silent.
#
# What the entry does NOT do by itself is say the number changed when a
# button moved it, because nothing typed into it.  event() says so, and
# that is the only line in here that mentions speech.
#
# The buttons report on a channel rather than acting directly.  A Tk
# command is a string and cannot add one to a number, so the arithmetic
# has to happen in Limbo, which means an application has to pump it - it
# selects on the channel new() returns and hands what arrives to event().
# The alternative, a process per spinbox reading its own channel, would
# put a second writer on the same toplevel as the application, and libtk
# is not the place to find out what that does.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "tk.m";
	tk: Tk;
include "keyboard.m";
include "tkspinbox.m";

init()
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
}

new(top: ref Tk->Toplevel, path: string, lo, hi, step, start: int): (ref Spinbox, chan of string)
{
	if(tk == nil || top == nil)
		return (nil, nil);
	if(hi < lo)
		(lo, hi) = (hi, lo);
	if(step <= 0)
		step = 1;

	sb := ref Spinbox(top, path, lo, hi, step);
	c := chan of string;
	name := "sbc" + sanitise(path);
	tk->namechan(top, c, name);

	tk->cmd(top, "frame " + path);
	# Wide enough for the longest number it can hold, so the field does
	# not resize under the person as they spin it.
	w := len string lo;
	if((n := len string hi) > w)
		w = n;
	tk->cmd(top, sys->sprint("entry %s.e -width %d", path, w + 1));
	# tk->quote() and not a bare ' - in this Tk a ' quotes to the END of
	# the line, so an unquoted label swallows the rest of the command.
	tk->cmd(top, sys->sprint("button %s.up -text %s -command {send %s up}",
		path, tk->quote("+"), name));
	tk->cmd(top, sys->sprint("button %s.down -text %s -command {send %s down}",
		path, tk->quote("-"), name));
	# The arrow keys, on the entry, so the widget can be used by someone
	# who is not holding a mouse.  Without these a person on the keyboard
	# could type a number in but not step it, which is the one thing a
	# spinbox is for - and it is the same person the announcements above
	# are for.
	tk->cmd(top, sys->sprint("bind %s.e <Key-%c> {send %s up}",
		path, Keyboard->Up, name));
	tk->cmd(top, sys->sprint("bind %s.e <Key-%c> {send %s down}",
		path, Keyboard->Down, name));
	tk->cmd(top, "pack " + path + ".e -side left");
	tk->cmd(top, "pack " + path + ".up -side left");
	tk->cmd(top, "pack " + path + ".down -side left");

	sb.set(start);
	return (sb, c);
}

# a widget path is not a channel name
sanitise(s: string): string
{
	o := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '.')
			o[len o] = '_';
		else
			o[len o] = s[i];
	return o;
}

Spinbox.value(sb: self ref Spinbox): int
{
	if(sb.top == nil)
		return sb.lo;
	s := tk->cmd(sb.top, sb.path + ".e get");
	# tk->cmd reports an error by returning a string starting '!', which
	# is not the same as returning nil - see the convention in tk(2).
	if(s == nil || s[0] == '!')
		return sb.lo;
	return clamp(sb, num(s, sb.lo));
}

Spinbox.set(sb: self ref Spinbox, v: int)
{
	if(sb.top == nil)
		return;
	v = clamp(sb, v);
	tk->cmd(sb.top, sb.path + ".e delete 0 end");
	tk->cmd(sb.top, sys->sprint("%s.e insert 0 %d", sb.path, v));
	tk->cmd(sb.top, "update");
}

Spinbox.event(sb: self ref Spinbox, s: string): int
{
	v := sb.value();
	case s {
	"up" =>		v += sb.step;
	"down" =>	v -= sb.step;
	* =>		return v;
	}
	was := sb.value();
	sb.set(v);
	now := sb.value();
	# Only when it actually moved.  At either end of the range a press
	# does nothing, and saying the same number again every time someone
	# leans on the button is worse than silence.
	if(now != was)
		say(now);
	return now;
}

# Tell voice(3) the number changed.  Nothing typed into the entry, so
# libtk has no reason to know, and a person spinning this by ear would
# otherwise hear the arrival announcement and then nothing at all - which
# is exactly how choicebutton(9) was broken before it was noticed.
voicefd: ref Sys->FD;

say(v: int)
{
	# No voice device is the ordinary case rather than an error: the
	# announcement is an extra and a spinbox works without it.  But the
	# open is retried whenever it is not open, and NOT remembered as
	# having failed - #V can be bound into the namespace at any moment,
	# and a version of this that cached the failure went silent for the
	# life of the program because the first press happened to come
	# first.  A press is a person's action, so an open() per press is
	# not a cost worth caching against.
	if(voicefd == nil)
		voicefd = sys->open("/dev/voice/screen", Sys->OWRITE);
	if(voicefd != nil)
		sys->fprint(voicefd, "%d", v);
}

clamp(sb: ref Spinbox, v: int): int
{
	if(v < sb.lo)
		return sb.lo;
	if(v > sb.hi)
		return sb.hi;
	return v;
}

# a number, or def if the person typed something that is not one
num(s: string, def: int): int
{
	i := 0;
	neg := 0;
	if(i < len s && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	if(i >= len s)
		return def;
	v := 0;
	for(; i < len s; i++){
		if(s[i] < '0' || s[i] > '9')
			return def;
		v = v*10 + (s[i] - '0');
	}
	if(neg)
		return -v;
	return v;
}
