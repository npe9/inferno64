implement Wmsmoke;

# Minimal wm client: connect, !reshape, prove image + /chan/wmrect.
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Image, Wmcontext: import draw;
include "wmlib.m";
	wmlib: Wmlib;

Wmsmoke: module
{
	init:	fn(ctxt: ref Draw->Context, nil: list of string);
};

# childminder blocks forwarding join's "rect" on ctl; drain so reshape can proceed.
drain(wm: ref Wmcontext, ready: chan of int)
{
	first := 1;
	for(;;)
		alt{
		<-wm.ctl =>
			if(first){
				first = 0;
				ready <-= 1;
			}
		<-wm.ptr =>
			;
		<-wm.kbd =>
			;
		}
}

init(ctxt: ref Draw->Context, nil: list of string)
{
	wm: ref Wmcontext;
	img: ref Image;
	fd: ref Sys->FD;
	buf: array of byte;
	n: int;
	err: string;
	ready: chan of int;

	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmlib = load Wmlib Wmlib->PATH;
	if(draw == nil || wmlib == nil){
		sys->print("WMWM-FAIL load: %r\n");
		exit;
	}
	if(ctxt == nil || ctxt.wm == nil){
		sys->print("WMWM-FAIL no wm context\n");
		exit;
	}

	wmlib->init();
	{
		wm = wmlib->connect(ctxt);
		ready = chan of int;
		spawn drain(wm, ready);
		<-ready;
		# exact placement inside 640x480 ramfb.
		(nil, img, err) = wmlib->wmctl(wm,
			"!reshape . -1 40 40 240 180 exact");
	} exception e {
	"*" =>
		sys->print("WMWM-FAIL exception: %s\n", e);
		exit;
	}
	if(err != nil){
		sys->print("WMWM-FAIL reshape: %s\n", err);
		exit;
	}
	if(img == nil){
		sys->print("WMWM-FAIL image\n");
		exit;
	}

	fd = sys->open("/chan/wmrect", Sys->OREAD);
	if(fd == nil){
		sys->print("WMWM-FAIL wmrect: %r\n");
		exit;
	}
	buf = array[128] of byte;
	n = sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0){
		sys->print("WMWM-FAIL wmrect read: %r\n");
		exit;
	}

	sys->print("WMWM-OK\n");
	for(;;)
		sys->sleep(1000);
}
