implement Hidboot;

#
# The HID boot protocol.  See hidboot.m for why it is a library.
#

include "sys.m";
	sys: Sys;
include "hidboot.m";

#
# Usage codes 4 to 56, unshifted and shifted.  This is the US layout,
# which is what the boot protocol assumes: a device that speaks it
# reports positions, and what a position means is the host's business.
#
# Fifty three codes and so fifty three characters in each row.  One of
# them is Escape, code 41, which is not a printable character; the
# rows these were lifted from carry it as a literal byte, where it is
# invisible in the source and easy to drop when the line is copied by
# hand -- which is what happened while this library was being written.
# It is built in here instead, so that what sits between the newline
# and the backspace can be seen.
#
Esc:	con 16r1b;

keys:	array of string;

init()
{
	sys = load Sys Sys->PATH;
	esc := " ";
	esc[0] = Esc;
	keys = array[] of {
		"abcdefghijklmnopqrstuvwxyz1234567890\n" + esc + "\b\t -=[]\\#;'`,./",
		"ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()\n" + esc + "\b\t _+{}|~:\"~<>?",
	};
}

keysym(k, mod: int): string
{
	shift := (mod & 16r22) != 0;
	ctl := (mod & 16r11) != 0;
	if(k >= 4 && k <= 56){
		c := keys[shift][k-4];
		if(ctl && c >= 'a' && c <= 'z')
			c -= 'a' - 1;
		if(ctl && c >= 'A' && c <= 'Z')
			c -= 'A' - 1;
		return sys->sprint("%c", c);
	}
	if(k == 76)
		return sys->sprint("%c", 16r7f);	# delete forward
	return nil;		# caps lock, function and arrow keys: not mapped yet
}

#
# The six key slots of a boot report.  Zero is an empty slot; 1 is the
# code a keyboard sends in every slot when more keys are down than it
# can report, and it is not a key.
#
keysof(rep: array of byte): array of int
{
	a := array[6] of int;
	n := 0;
	for(i := 2; i < 8 && i < len rep; i++){
		k := int rep[i];
		if(k == 0 || k == 1)
			continue;
		a[n++] = k;
	}
	return a[0:n];
}

held(ks: array of int, k: int): int
{
	for(i := 0; i < len ks; i++)
		if(ks[i] == k)
			return 1;
	return 0;
}

mouse(rep: array of byte): (int, int, int)
{
	if(len rep < 3)
		return (0, 0, 0);
	hb := int rep[0];
	# HID: bit 0 left, bit 1 right, bit 2 middle; devpointer: 1, 4, 2
	b := (hb & 1) | ((hb & 2) << 1) | ((hb & 4) >> 1);
	return (sext(int rep[1]), sext(int rep[2]), b);
}

sext(v: int): int
{
	if(v & 16r80)
		return v - 256;
	return v;
}
