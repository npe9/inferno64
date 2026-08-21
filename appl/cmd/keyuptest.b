implement Command;

include "sys.m";
	sys: Sys;
	print: import sys;
include "draw.m";
	draw: Draw;
	Display: import draw;
include "tk.m";
	tk: Tk;

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# From include/keyboard.h: Spec=0xe000, Keyup=Spec|0x800,
# German=Spec|0xf00, Grave/Acute/Circumflex = German|1/2/3.
Spec:		con 16re000;
Keyup:		con Spec|16r800;
German:		con Spec|16rf00;
Grave:		con German|16r1;
Acute:		con German|16r2;
Circumflex:	con German|16r3;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;

	# Allocate our own Display rather than needing a wm-supplied
	# Draw->Context, so this runs standalone. Tk_keyboard() - the
	# function under test - doesn't care how the toplevel was made.
	disp := draw->Display.allocate(nil);
	if(disp == nil){
		print("FAIL: cannot allocate display: %r (run under emu-cocoa)\n");
		return;
	}
	top := tk->toplevel(disp, "");
	if(top == nil){
		print("FAIL: could not make toplevel\n");
		return;
	}
	tk->cmd(top, "entry .e -width 200");
	tk->cmd(top, "pack .e");
	tk->cmd(top, "focus .e");
	tk->cmd(top, "update");

	ok := 1;

	# --- Test 1: exactly what the Cocoa backend sends when a user
	# types "abc" - a press AND a matching release for every key.
	# The bug inserted the release code as literal text, so this is
	# the precise reproduction of the original user report. ---
	tk->cmd(top, ".e delete 0 end");
	s := "abc";
	for(i := 0; i < len s; i++){
		tk->keyboard(top, s[i]);		# keyDown:
		tk->keyboard(top, Keyup|s[i]);		# keyUp:
	}
	tk->cmd(top, "update");
	got := tk->cmd(top, ".e get");
	print("typed \"abc\" with releases -> %q (want \"abc\", len %d want 3)\n", got, len got);
	if(got != "abc"){
		print("FAIL: key-release events are still being inserted as text\n");
		ok = 0;
		for(j := 0; j < len got; j++)
			print("      char %d = 16r%x\n", j, got[j]);
	}

	# --- Test 2: presses alone must still work (guard against the fix
	# swallowing real input). ---
	tk->cmd(top, ".e delete 0 end");
	for(i = 0; i < len s; i++)
		tk->keyboard(top, s[i]);
	tk->cmd(top, "update");
	got = tk->cmd(top, ".e get");
	print("presses only -> %q (want \"abc\")\n", got);
	if(got != "abc"){
		print("FAIL: ordinary key presses no longer insert correctly\n");
		ok = 0;
	}

	# --- Test 3: the dead-key collision the fix explicitly guards.
	# German/Grave/Acute/Circumflex numerically satisfy the Keyup mask
	# (0xef00 & 0xf800 == 0xe800), so a naive fix would swallow them.
	# They must still reach the widget. ---
	deadnames := array[] of {"Grave", "Acute", "Circumflex", "German"};
	deads := array[] of {Grave, Acute, Circumflex, German};
	for(i = 0; i < len deads; i++){
		tk->cmd(top, ".e delete 0 end");
		tk->keyboard(top, deads[i]);
		tk->cmd(top, "update");
		got = tk->cmd(top, ".e get");
		print("dead key %s (16r%x) -> len %d %s\n",
			deadnames[i], deads[i], len got, verdict(len got == 1));
		if(len got != 1){
			print("FAIL: %s was swallowed by the Keyup mask\n", deadnames[i]);
			ok = 0;
		}
	}

	# --- Test 4: a non-dead-key release really is dropped, not merely
	# rendered invisibly - check a few different keys. ---
	tk->cmd(top, ".e delete 0 end");
	for(i = 0; i < 5; i++)
		tk->keyboard(top, Keyup|('a'+i));
	tk->cmd(top, "update");
	got = tk->cmd(top, ".e get");
	print("5 releases alone -> len %d (want 0)\n", len got);
	if(len got != 0){
		print("FAIL: releases still reaching the widget\n");
		ok = 0;
	}

	if(ok)
		print("PASS\n");
	else
		print("SOME CHECKS FAILED\n");
}

verdict(good: int): string
{
	if(good)
		return "delivered";
	return "SWALLOWED";
}
