implement Fonted;

# TempleOS Demo/Graphics/FontEd.HC — 8x8 system font editor.
# The 16x16 selector renders all 256 glyphs live from the editable
# bitmaps, seeded from the authentic system font (Kernel/FontStd.HC
# sys_font_std).  LMB sets a pixel, RMB clears one (Bts/Btr), and
# painting continues while a button is dragged.  Arrow keys move the
# selection; typing any printable character jumps to its glyph.
# Ctrl-A saves, Esc saves then exits, Del exits without saving.
# GAP: <CTRL-ALT-f> aux-font toggle is TempleOS-systemic (it swaps the
#      live console font); the original banner is shown but the toggle
#      has no Inferno equivalent.
# GAP: FESave's DocWrite prompt and Shift-Esc are not portable as-is:
#      saving always writes /tmp/temple-font.hex; abort-without-save is
#      Del (or closing the window).

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Font, Point, Rect: import draw;

include "keyboard.m";

include "tk.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

Fonted: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

FW: con 8;
FH: con 8;
CELL: con 10;	# selector cell: 8x8 glyph pixels + 1px border
BIG: con 24;	# blow-up editor block size
GRIDX: con 8;
GRIDY: con 40;
BIGX: con 300;
BIGY: con 40;

win: ref Window;
display: ref Display;
yellow, blue, white: ref Image;
font: ref Font;
glyphs: array of big;
cells: array of ref Image;	# cached white-on-blue selector cells
cur := 0;
blink := 0;
prevbtn := 0;

# Kernel/FontStd.HC sys_font_std: byte 0 is the top row, LSB is the
# leftmost pixel — same U64 layout the original's Bt/Bts/Btr use.
sysfont := array[] of {
	big 16r0000000000000000, big 16r0000000000000000, big 16r000000FF00000000, big 16r000000FF00FF0000,
	big 16r1818181818181818, big 16r6C6C6C6C6C6C6C6C, big 16r181818F800000000, big 16r6C6C6CEC0CFC0000,
	big 16r1818181F00000000, big 16r6C6C6C6F607F0000, big 16r000000F818181818, big 16r000000FC0CEC6C6C,
	big 16r0000001F18181818, big 16r0000007F606F6C6C, big 16r0000000000000000, big 16r0000000000000000,
	big 16r0000000000000000, big 16r0000000000000000, big 16r0000000000000000, big 16r0000000000000000,
	big 16r0000000000000000, big 16r0000000000000000, big 16r0000000000000000, big 16r0000000000000000,
	big 16r0000000000000000, big 16r0000000000000000, big 16r0000000000000000, big 16r0000000000000000,
	big 16r0000000000000000, big 16r0000000000000000, big 16r0000000000000000, big 16r0008000000000000,
	big 16r0000000000000000, big 16r00180018183C3C18, big 16r0000000000363636, big 16r006C6CFE6CFE6C6C,
	big 16r00187ED07C16FC30, big 16r0060660C18306606, big 16r00DC66B61C36361C, big 16r0000000000181818,
	big 16r0030180C0C0C1830, big 16r000C18303030180C, big 16r0000187E3C7E1800, big 16r000018187E181800,
	big 16r0C18180000000000, big 16r000000007E000000, big 16r0018180000000000, big 16r0000060C18306000,
	big 16r003C666E7E76663C, big 16r007E181818181C18, big 16r007E0C183060663C, big 16r003C66603860663C,
	big 16r0030307E363C3830, big 16r003C6660603E067E, big 16r003C66663E060C38, big 16r000C0C0C1830607E,
	big 16r003C66663C66663C, big 16r001C30607C66663C, big 16r0018180018180000, big 16r0C18180018180000,
	big 16r0030180C060C1830, big 16r0000007E007E0000, big 16r000C18306030180C, big 16r001800181830663C,
	big 16r003C06765676663C, big 16r006666667E66663C, big 16r003E66663E66663E, big 16r003C66060606663C,
	big 16r001E36666666361E, big 16r007E06063E06067E, big 16r000606063E06067E, big 16r003C66667606663C,
	big 16r006666667E666666, big 16r007E18181818187E, big 16r001C36303030307C, big 16r0066361E0E1E3666,
	big 16r007E060606060606, big 16r00C6C6D6D6FEEEC6, big 16r006666767E6E6666, big 16r003C66666666663C,
	big 16r000606063E66663E, big 16r006C36566666663C, big 16r006666363E66663E, big 16r003C66603C06663C,
	big 16r001818181818187E, big 16r003C666666666666, big 16r00183C6666666666, big 16r00C6EEFED6D6C6C6,
	big 16r0066663C183C6666, big 16r001818183C666666, big 16r007E060C1830607E, big 16r003E06060606063E,
	big 16r00006030180C0600, big 16r007C60606060607C, big 16r000000000000663C, big 16rFFFF000000000000,
	big 16r000000000030180C, big 16r007C667C603C0000, big 16r003E6666663E0606, big 16r003C6606663C0000,
	big 16r007C6666667C6060, big 16r003C067E663C0000, big 16r000C0C0C3E0C0C38, big 16r3C607C66667C0000,
	big 16r00666666663E0606, big 16r003C1818181C0018, big 16r0E181818181C0018, big 16r0066361E36660606,
	big 16r003C18181818181C, big 16r00C6D6D6FE6C0000, big 16r00666666663E0000, big 16r003C6666663C0000,
	big 16r06063E66663E0000, big 16rE0607C66667C0000, big 16r000606066E360000, big 16r003E603C067C0000,
	big 16r00380C0C0C3E0C0C, big 16r007C666666660000, big 16r00183C6666660000, big 16r006CFED6D6C60000,
	big 16r00663C183C660000, big 16r3C607C6666660000, big 16r007E0C18307E0000, big 16r003018180E181830,
	big 16r0018181818181818, big 16r000C18187018180C, big 16r000000000062D68C, big 16rFFFFFFFFFFFFFFFF,
	big 16r1E30181E3303331E, big 16r007E333333003300, big 16r001E033F331E0038, big 16r00FC667C603CC37E,
	big 16r007E333E301E0033, big 16r007E333E301E0007, big 16r007E333E301E0C0C, big 16r3C603E03033E0000,
	big 16r003C067E663CC37E, big 16r001E033F331E0033, big 16r001E033F331E0007, big 16r001E0C0C0C0E0033,
	big 16r003C1818181C633E, big 16r001E0C0C0C0E0007, big 16r00333F33331E0C33, big 16r00333F331E000C0C,
	big 16r003F061E063F0038, big 16r00FE33FE30FE0000, big 16r007333337F33367C, big 16r001E33331E00331E,
	big 16r001E33331E003300, big 16r001E33331E000700, big 16r007E33333300331E, big 16r007E333333000700,
	big 16r1F303F3333003300, big 16r001C3E63633E1C63, big 16r001E333333330033, big 16r18187E03037E1818,
	big 16r003F67060F26361C, big 16r000C3F0C3F1E3333, big 16r70337B332F1B1B0F, big 16r0E1B18187E18D870,
	big 16r007E333E301E0038, big 16r001E0C0C0C0E001C, big 16r001E33331E003800, big 16r007E333333003800,
	big 16r003333331F001F00, big 16r00333B3F3733003F, big 16r00007E007C36363C, big 16r00007E003C66663C,
	big 16r001E3303060C000C, big 16r000003033F000000, big 16r000030303F000000, big 16rF81973C67C1B3363,
	big 16rC0F9F3E6CF1B3363, big 16r183C3C1818001800, big 16r0000CC663366CC00, big 16r00003366CC663300,
	big 16r1144114411441144, big 16r55AA55AA55AA55AA, big 16rEEBBEEBBEEBBEEBB, big 16r1818181818181818,
	big 16r1818181F18181818, big 16r1818181F181F1818, big 16r6C6C6C6F6C6C6C6C, big 16r6C6C6C7F00000000,
	big 16r1818181F181F0000, big 16r6C6C6C6F606F6C6C, big 16r6C6C6C6C6C6C6C6C, big 16r6C6C6C6F607F0000,
	big 16r0000007F606F6C6C, big 16r0000007F6C6C6C6C, big 16r0000001F181F1818, big 16r1818181F00000000,
	big 16r000000F818181818, big 16r000000FF18181818, big 16r181818FF00000000, big 16r181818F818181818,
	big 16r000000FF00000000, big 16r181818FF18181818, big 16r181818F818F81818, big 16r6C6C6CEC6C6C6C6C,
	big 16r000000FC0CEC6C6C, big 16r6C6C6CEC0CFC0000, big 16r000000FF00EF6C6C, big 16r6C6C6CEF00FF0000,
	big 16r6C6C6CEC0CEC6C6C, big 16r000000FF00FF0000, big 16r6C6C6CEF00EF6C6C, big 16r000000FF00FF1818,
	big 16r000000FF6C6C6C6C, big 16r181818FF00FF0000, big 16r6C6C6CFF00000000, big 16r000000FC6C6C6C6C,
	big 16r000000F818F81818, big 16r181818F818F80000, big 16r6C6C6CFC00000000, big 16r6C6C6CEF6C6C6C6C,
	big 16r181818FF00FF1818, big 16r0000001F18181818, big 16r181818F800000000, big 16rFFFFFFFFFFFFFFFF,
	big 16rFFFFFFFF00000000, big 16r0F0F0F0F0F0F0F0F, big 16rF0F0F0F0F0F0F0F0, big 16r00000000FFFFFFFF,
	big 16r006E3B133B6E0000, big 16r03031F331F331E00, big 16r0003030303637F00, big 16r0036363636367F00,
	big 16r007F660C180C667F, big 16r001E3333337E0000, big 16r03063E6666666600, big 16r00181818183B6E00,
	big 16r3F0C1E33331E0C3F, big 16r001C36637F63361C, big 16r007736366363361C, big 16r001E33333E180C38,
	big 16r00007EDBDB7E0000, big 16r03067EDBDB7E3060, big 16r003C06033F03063C, big 16r003333333333331E,
	big 16r00003F003F003F00, big 16r003F000C0C3F0C0C, big 16r003F00060C180C06, big 16r003F00180C060C18,
	big 16r1818181818D8D870, big 16r0E1B1B1818181818, big 16r000C0C003F000C0C, big 16r0000394E00394E00,
	big 16r000000001C36361C, big 16r0000001818000000, big 16r0000001800000000, big 16r383C3637303030F0,
	big 16r000000363636361E, big 16r0000003E061C301E, big 16r00003C3C3C3C0000, big 16rFFFFFFFFFFFFFFFF
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	win = wmclient->window(ctxt, "TempleOS FontEd", Wmclient->Appl);
	d := win.display;
	display = d;
	# exact TempleOS palette: YELLOW, BLUE, WHITE
	yellow = d.color(int 16rFFFF55FF);
	blue = d.color(int 16r0000AAFF);
	white = d.color(int 16rFFFFFFFF);
	font = Font.open(d, "/fonts/temple/temple.font");
	glyphs = array[256] of big;
	glyphs[0:] = sysfont;
	cells = array[256] of ref Image;
	win.reshape(Rect((0, 0), (520, 420)));
	win.onscreen("place");
	win.startinput("kbd" :: "ptr" :: nil);
	redraw();
	blinkch := chan of int;
	spawn blinker(blinkch);
	for(;;) alt{
	ctl := <-win.ctl or
	ctl = <-win.ctxt.ctl =>
		win.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();
	p := <-win.ctxt.ptr =>
		win.pointer(*p);
		ptr(p);
	k := <-win.ctxt.kbd =>
		key(k);
	<-blinkch =>
		# system Blink: the selected cell alternates
		# BLUE-on-YELLOW / YELLOW-on-BLUE about 1Hz
		blink = !blink;
		redraw();
	}
}

blinker(c: chan of int)
{
	for(;;){
		sys->sleep(500);
		c <-= 1;
	}
}

key(k: int)
{
	case k {
	Keyboard->Esc =>
		savehex();	# original CH_ESC: save, then exit
		exit;
	Keyboard->Del =>
		exit;		# abort without saving (original Shift-Esc)
	1 =>	# Ctrl-A: SaveAs (original CH_CTRLA)
		savehex();
	Keyboard->Left =>
		cur = (cur + 255) & 255;
		redraw();
	Keyboard->Right =>
		cur = (cur + 1) & 255;
		redraw();
	Keyboard->Up =>
		cur = (cur + 240) & 255;
		redraw();
	Keyboard->Down =>
		cur = (cur + 16) & 255;
		redraw();
	* =>
		if(k >= 32 && k < 127){
			# original default: typing a character selects it
			cur = k;
			redraw();
		}
	}
}

ptr(p: ref Draw->Pointer)
{
	b := p.buttons;
	newly := b & ~prevbtn;
	prevbtn = b;
	img := win.image;
	if(img == nil)
		return;
	x := p.xy.x - img.r.min.x;
	y := p.xy.y - img.r.min.y;
	if(newly & 5){
		# L or R button press in the 16x16 selector picks a glyph
		gx := (x - GRIDX) / CELL;
		gy := (y - GRIDY) / CELL;
		if(x >= GRIDX && gx < 16 && y >= GRIDY && gy < 16){
			cur = gy*16 + gx;
			redraw();
			return;
		}
	}
	if(b & 5){
		# LMB sets a bit (Bts), RMB clears it (Btr); MSG_MS_MOVE
		# with a button held paints continuously
		bx := (x - BIGX) / BIG;
		by := (y - BIGY) / BIG;
		if(x >= BIGX && bx < FW && y >= BIGY && by < FH){
			k := by*FW + bx;
			old := glyphs[cur];
			if(b & 1)
				glyphs[cur] |= big 1 << k;
			if(b & 4)
				glyphs[cur] &= ~(big 1 << k);
			if(glyphs[cur] != old){
				cells[cur] = nil;
				redraw();
			}
		}
	}
}

# render one selector cell: 8x8 glyph pixels, 1px per bit, inside a
# CELLxCELL block — the original draws these as real TextChar cells
mkcell(ch: int, bg, fg: ref Image): ref Image
{
	img := display.newimage(Rect((0, 0), (CELL, CELL)), Draw->RGB24, 0, Draw->Black);
	if(img == nil)
		return nil;
	img.draw(img.r, bg, nil, Point(0, 0));
	g := glyphs[ch];
	for(k := 0; k < FW*FH; k++)
		if(((g >> k) & big 1) != big 0)
			img.draw(Rect((1 + k%FW, 1 + k/FW), (2 + k%FW, 2 + k/FW)),
				fg, nil, Point(0, 0));
	return img;
}

redraw()
{
	img := win.image;
	if(img == nil)
		return;
	img.draw(img.r, blue, nil, Point(0, 0));
	o := img.r.min;
	if(font != nil)
		img.text(Point(o.x + GRIDX, o.y + 24), yellow, Point(0, 0), font,
			"Press <CTRL-ALT-f> to Toggle Aux Font.");
	for(i := 0; i < 16; i++)
		for(j := 0; j < 16; j++){
			ch := i*16 + j;
			p := Point(o.x + GRIDX + j*CELL, o.y + GRIDY + i*CELL);
			c: ref Image;
			if(ch == cur){
				if(blink)
					c = mkcell(ch, blue, yellow);
				else
					c = mkcell(ch, yellow, blue);
			}else{
				if(cells[ch] == nil)
					cells[ch] = mkcell(ch, blue, white);
				c = cells[ch];
			}
			if(c != nil)
				img.draw(c.r.addpt(p), c, nil, c.r.min);
		}
	for(k := 0; k < FW*FH; k++){
		c := blue;
		if(((glyphs[cur] >> k) & big 1) != big 0)
			c = yellow;
		x := o.x + BIGX + (k%FW)*BIG;
		y := o.y + BIGY + (k/FW)*BIG;
		img.draw(Rect((x, y), (x + BIG - 1, y + BIG - 1)), c, nil, Point(0, 0));
	}
	win.settitle(sys->sprint("FontEd ch=%d 0x%02X · LMB set RMB clear · arrows move · Ctrl-A save · Esc save+exit · Del abort", cur, cur));
	img.flush(Draw->Flushnow);
}

hex64(v: big): string
{
	hexd := "0123456789ABCDEF";
	s := "";
	for(i := 15; i >= 0; i--)
		s[len s] = hexd[int (v >> (4*i)) & 15];
	return s;
}

savehex()
{
	# FESave format: each glyph is ONE U64, "0x%016X," — row 0 in the
	# low byte, LSB leftmost — with //<char> comments for doc-safe
	# characters ('$' escaped as $$): paste-ready for Kernel/FontStd.HC
	path := "/tmp/temple-font.hex";
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "fonted: %s: %r\n", path);
		return;
	}
	for(ch := 0; ch < 256; ch++){
		s := "0x" + hex64(glyphs[ch]) + ",";
		if(ch == '$')
			s += "//$$";
		else if(ch > 32 && ch < 127)
			s += sys->sprint("//%c", ch);
		sys->fprint(fd, "%s\n", s);
	}
	win.settitle("FontEd saved " + path);
}
