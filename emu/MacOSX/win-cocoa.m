/*
 * Cocoa window backend for Inferno emu (MacOSX arm64 / modern macOS).
 * Softscreen is XBGR32; AppKit blits via CGImage.
 * UI runs on the process main thread (see main-cocoa.m).
 */
/* MacTypes.h (via Cocoa) also defines Point/Rect/nil — rename while importing. */
#define Point	MacPoint
#define Rect	MacRect
#import <Cocoa/Cocoa.h>
#undef Point
#undef Rect
#undef nil

#include "dat.h"
#include "fns.h"
#include <unistd.h>
#undef log2
#include <draw.h>
#define attachscreen	attachscreen_memdraw_proto
#include <memdraw.h>
#undef attachscreen
#include "cursor.h"
#include "keyboard.h"
#include "keycodes.h"

#define	Kup	Up
#define	Kleft	Left
#define	Kdown	Down
#define	Kright	Right
#define	Kalt	LAlt
#define	Kctl	LCtrl
#define	Kshift	LShift
#define	Kpgup	Pgup
#define	Kpgdown	Pgdown
#define	Khome	Home
#define	Kins	Ins
#define	Kend	End

enum {
	SnarfSize = 100*1024,
};

Memimage	*gscreen;

static int		readybit;
static Rendez		rend;
static int		triedscreen;
static int		dx, dy;
static NSWindow		*win;
static NSView		*view;
static NSCursor		*customcursor;
static int		mousebuttons;
static int		mouseX, mouseY;
static int		altPressed;
static int		button2, button3;
static char		snarf[3*SnarfSize+1];

static void
screenresize(int w, int h)
{
	Memimage *old, *next;
	int copyw, copyh, y;

	if(w < 1 || h < 1 || (w == dx && h == dy))
		return;
	next = allocmemimage(Rect(0, 0, w, h), XBGR32);
	if(next == nil)
		return;
	old = gscreen;
	/* Initialize newly exposed pixels to the WM grey background. */
	memset(next->data->bdata, 0x77, next->width * sizeof(u32) * h);
	if(old != nil){
		copyw = old->r.max.x - old->r.min.x;
		if(copyw > w) copyw = w;
		copyh = old->r.max.y - old->r.min.y;
		if(copyh > h) copyh = h;
		for(y = 0; y < copyh; y++)
			memmove(next->data->bdata + y * next->width * sizeof(u32),
				old->data->bdata + y * old->width * sizeof(u32),
				copyw * sizeof(u32));
	}
	gscreen = next;
	dx = w;
	dy = h;
	drawscreenresize(gscreen);
	if(view != nil)
		[view setNeedsDisplay:YES];
	/* Existing Draw images may still reference the old screen data while
	 * the window system processes its resize notification.  Retain it until
	 * process teardown rather than freeing it under those clients. */
}

static int
bytesperline1(Rectangle r)
{
	return ((r.max.x - r.min.x) + 7) / 8;
}

static int
isready(void *a)
{
	USED(a);
	return readybit;
}

static void
sendbuttons(int b, int x, int y)
{
	mousetrack(b, x, y, 0);
}

static int
convert_key(unsigned short key, unichar ch)
{
	switch(key) {
	case QZ_IBOOK_ENTER:
	case QZ_RETURN:
	case QZ_KP_ENTER:
		return '\n';
	case QZ_ESCAPE:
		return 27;
	case QZ_BACKSPACE:
		return '\b';
	case QZ_LALT:
	case QZ_RALT:
		return Kalt;
	case QZ_LCTRL:
	case QZ_RCTRL:
		return Kctl;
	case QZ_LSHIFT:
	case QZ_RSHIFT:
		return Kshift;
	case QZ_F1: return KF+1;
	case QZ_F2: return KF+2;
	case QZ_F3: return KF+3;
	case QZ_F4: return KF+4;
	case QZ_F5: return KF+5;
	case QZ_F6: return KF+6;
	case QZ_F7: return KF+7;
	case QZ_F8: return KF+8;
	case QZ_F9: return KF+9;
	case QZ_F10: return KF+10;
	case QZ_F11: return KF+11;
	case QZ_F12: return KF+12;
	case QZ_INSERT:
		return Kins;
	case QZ_DELETE:
		return 0x7F;
	case QZ_HOME:
		return Khome;
	case QZ_END:
		return Kend;
	case QZ_TAB:
		return '\t';
	case QZ_PAGEUP:
		return Kpgup;
	case QZ_PAGEDOWN:
		return Kpgdown;
	case QZ_UP:
		return Kup;
	case QZ_DOWN:
		return Kdown;
	case QZ_LEFT:
		return Kleft;
	case QZ_RIGHT:
		return Kright;
	case QZ_KP_PLUS:
		return '+';
	case QZ_KP_MINUS:
		return '-';
	case QZ_KP_MULTIPLY:
		return '*';
	case QZ_KP_DIVIDE:
		return '/';
	case QZ_KP_PERIOD:
		return '.';
	case QZ_KP0: return '0';
	case QZ_KP1: return '1';
	case QZ_KP2: return '2';
	case QZ_KP3: return '3';
	case QZ_KP4: return '4';
	case QZ_KP5: return '5';
	case QZ_KP6: return '6';
	case QZ_KP7: return '7';
	case QZ_KP8: return '8';
	case QZ_KP9: return '9';
	default:
		if(ch != 0 && ch < Spec)
			return (int)ch;
		return -1;
	}
}

@interface InfernoView : NSView
@end

@implementation InfernoView
- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)e
{
	(void)e;
	return YES;
}

- (BOOL)isOpaque
{
	return YES;
}

- (BOOL)wantsUpdateLayer
{
	return NO;
}

- (void)updateTrackingAreas
{
	NSTrackingAreaOptions opts;
	NSTrackingArea *ta;

	[super updateTrackingAreas];
	for(ta in [NSArray arrayWithArray:[self trackingAreas]])
		[self removeTrackingArea:ta];
	opts = NSTrackingMouseMoved
		| NSTrackingMouseEnteredAndExited
		| NSTrackingActiveInKeyWindow
		| NSTrackingInVisibleRect
		| NSTrackingEnabledDuringMouseDrag;
	ta = [[NSTrackingArea alloc] initWithRect:[self bounds]
		options:opts
		owner:self
		userInfo:nil];
	[self addTrackingArea:ta];
}

/*
 * Inferno resolution stays 1 pixel = 1 point.  Match the layer's scale to
 * the display so nearest-neighbor blit yields sharp Retina pixels (NxN
 * physical dots per Inferno pixel) instead of a soft window-server scale.
 */
- (void)viewDidChangeBackingProperties
{
	CGFloat s;

	[super viewDidChangeBackingProperties];
	s = [[self window] backingScaleFactor];
	if(s < 1.0)
		s = 1.0;
	if([self layer])
		[self layer].contentsScale = s;
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	if(!readybit || gscreen == nil || size.width < 1 || size.height < 1)
		return;
	screenresize((int)size.width, (int)size.height);
}

- (void)resetCursorRects
{
	[super resetCursorRects];
	if(customcursor)
		[self addCursorRect:[self bounds] cursor:customcursor];
}

- (BOOL)isFlipped
{
	/* Top-left origin like Inferno; NSBitmapImageRep rows match. */
	return YES;
}

- (void)drawRect:(NSRect)dirty
{
	NSBitmapImageRep *rep;
	unsigned char *planes[5];

	(void)dirty;
	if(gscreen == nil || gscreen->data == nil || gscreen->data->bdata == nil)
		return;

	/*
	 * Do not take drawqlock here: flushmemscreen may run with the lock
	 * held and dispatch_async onto this thread — locking would deadlock.
	 *
	 * Build a fresh bitmap each paint so AppKit cannot cache a stale
	 * frame of the softscreen (menus/clicks otherwise look dead).
	 */
	memset(planes, 0, sizeof planes);
	planes[0] = gscreen->data->bdata;
	rep = [[NSBitmapImageRep alloc]
		initWithBitmapDataPlanes:planes
		pixelsWide:dx
		pixelsHigh:dy
		bitsPerSample:8
		samplesPerPixel:3
		hasAlpha:NO
		isPlanar:NO
		colorSpaceName:NSDeviceRGBColorSpace
		bytesPerRow:dx * 4
		bitsPerPixel:32];
	/* Scale softscreen into the current content view (window may resize). */
	[rep drawInRect:[self bounds]
		fromRect:NSMakeRect(0, 0, dx, dy)
		operation:NSCompositingOperationCopy
		fraction:1.0
		respectFlipped:YES
		hints:@{ NSImageHintInterpolation: @(NSImageInterpolationNone) }];
}

- (void)keyDown:(NSEvent *)e
{
	int key;
	NSUInteger mods;
	NSString *chars;
	unichar ch;

	mods = [e modifierFlags];
	/* Cmd+Q etc. handled by the menu; swallow other Cmd chords */
	if(mods & NSEventModifierFlagCommand)
		return;

	chars = [e characters];
	ch = [chars length] > 0 ? [chars characterAtIndex:0] : 0;
	key = convert_key([e keyCode], ch);
	if(key != -1)
		gkbdputc(gkbdq, key);
}

- (void)flagsChanged:(NSEvent *)e
{
	NSUInteger mods = [e modifierFlags];

	switch(mods & (NSEventModifierFlagOption | NSEventModifierFlagCommand)) {
	case NSEventModifierFlagOption | NSEventModifierFlagCommand:
		altPressed = 1;
		if(mousebuttons & (1|2|4)) {
			mousebuttons |= 2|4;
			button2 = button3 = 1;
			sendbuttons(mousebuttons, mouseX, mouseY);
		}
		break;
	case NSEventModifierFlagOption:
		altPressed = 1;
		if(mousebuttons & (1|4)) {
			mousebuttons |= 2;
			button2 = 1;
			sendbuttons(mousebuttons, mouseX, mouseY);
		}
		break;
	case NSEventModifierFlagCommand:
		if(mousebuttons & (1|2)) {
			mousebuttons |= 4;
			button3 = 1;
			sendbuttons(mousebuttons, mouseX, mouseY);
		} else
			gkbdputc(gkbdq, Latin);
		break;
	default:
		if(button2 || button3) {
			if(button2) {
				mousebuttons &= ~2;
				button2 = 0;
				altPressed = 0;
			}
			if(button3) {
				mousebuttons &= ~4;
				button3 = 0;
			}
			sendbuttons(mousebuttons, mouseX, mouseY);
		}
		if(altPressed) {
			gkbdputc(gkbdq, Kalt);
			altPressed = 0;
		}
		break;
	}
}

- (void)mousePosFromEvent:(NSEvent *)e
{
	NSPoint p = [self convertPoint:[e locationInWindow] fromView:nil];
	NSRect b = [self bounds];
	/* Map view coords → softscreen; isFlipped matches Inferno. */
	if(b.size.width > 0 && b.size.height > 0) {
		mouseX = (int)(p.x * dx / b.size.width);
		mouseY = (int)(p.y * dy / b.size.height);
	} else {
		mouseX = (int)p.x;
		mouseY = (int)p.y;
	}
	if(mouseX < 0) mouseX = 0;
	if(mouseY < 0) mouseY = 0;
	if(mouseX >= dx) mouseX = dx-1;
	if(mouseY >= dy) mouseY = dy-1;
}

- (void)mouseButtonsFromEvent:(NSEvent *)e down:(BOOL)down
{
	NSUInteger mods = [e modifierFlags];
	NSInteger button = [e buttonNumber];
	int bit;

	if(button == 0) {
		if(mods & NSEventModifierFlagOption)
			bit = 2;
		else if(mods & NSEventModifierFlagCommand)
			bit = 4;
		else
			bit = 1;
	} else if(button == 2)
		bit = 2;
	else if(button == 1)
		bit = 4;
	else
		bit = 1;

	if(down)
		mousebuttons |= bit;
	else
		mousebuttons &= ~bit;

	if(down && [e clickCount] > 1)
		mousebuttons |= 1<<8;
	else
		mousebuttons &= ~(1<<8);
}

- (void)mouseDown:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	[self mouseButtonsFromEvent:e down:YES];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)mouseUp:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	[self mouseButtonsFromEvent:e down:NO];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)rightMouseDown:(NSEvent *)e	{ [self mouseDown:e]; }
- (void)rightMouseUp:(NSEvent *)e	{ [self mouseUp:e]; }
- (void)otherMouseDown:(NSEvent *)e	{ [self mouseDown:e]; }
- (void)otherMouseUp:(NSEvent *)e	{ [self mouseUp:e]; }

- (void)mouseDragged:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)rightMouseDragged:(NSEvent *)e	{ [self mouseDragged:e]; }
- (void)otherMouseDragged:(NSEvent *)e	{ [self mouseDragged:e]; }

- (void)mouseMoved:(NSEvent *)e
{
	[self mousePosFromEvent:e];
	sendbuttons(mousebuttons, mouseX, mouseY);
}

- (void)scrollWheel:(NSEvent *)e
{
	CGFloat dyw = [e scrollingDeltaY];

	[self mousePosFromEvent:e];
	if(dyw == 0)
		return;
	sendbuttons(dyw > 0 ? 8 : 16, mouseX, mouseY);
	sendbuttons(mousebuttons, mouseX, mouseY);
}
@end

@interface InfernoAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation InfernoAppDelegate
- (void)windowDidResize:(NSNotification *)note
{
	NSRect r;
	(void)note;
	if(view == nil)
		return;
	if(!readybit)
		return;
	r = [view bounds];
	screenresize((int)r.size.width, (int)r.size.height);
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	(void)sender;
	return NO;	/* Inferno may still be running headless */
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
	(void)sender;
	win = nil;
	view = nil;
	/* AppKit thread: cleanexit avoids touching nil up, restores tty. */
	cleanexit(0);
	return NSTerminateNow;
}

- (void)windowWillClose:(NSNotification *)note
{
	(void)note;
	win = nil;
	view = nil;
	/*
	 * Do not call cleanexit/_exit on the AppKit thread while emu
	 * worker threads may hold locks — that can beachball instead of
	 * quitting.  Detach and exit from another thread.
	 */
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		cleanexit(0);
	});
}
@end

static void
setupmenu(void)
{
	NSMenu *menubar, *appmenu, *viewmenu;
	NSMenuItem *appitem, *viewitem, *quit, *fs;

	menubar = [[NSMenu alloc] init];
	appitem = [[NSMenuItem alloc] init];
	[menubar addItem:appitem];

	viewitem = [[NSMenuItem alloc] init];
	[menubar addItem:viewitem];
	[NSApp setMainMenu:menubar];

	appmenu = [[NSMenu alloc] init];
	quit = [[NSMenuItem alloc] initWithTitle:@"Quit Inferno"
		action:@selector(terminate:)
		keyEquivalent:@"q"];
	[appmenu addItem:quit];
	[appitem setSubmenu:appmenu];

	viewmenu = [[NSMenu alloc] initWithTitle:@"View"];
	fs = [[NSMenuItem alloc] initWithTitle:@"Enter Full Screen"
		action:@selector(toggleFullScreen:)
		keyEquivalent:@"f"];
	[fs setKeyEquivalentModifierMask:
		NSEventModifierFlagControl | NSEventModifierFlagCommand];
	[viewmenu addItem:fs];
	[viewitem setSubmenu:viewmenu];
}

static void
createwindow(void)
{
	NSRect rect;
	NSUInteger style;
	static InfernoAppDelegate *delegate;

	if(win != nil)
		return;

	if(delegate == nil) {
		delegate = [[InfernoAppDelegate alloc] init];
		[NSApp setDelegate:delegate];
	}
	setupmenu();

	style = NSWindowStyleMaskTitled
		| NSWindowStyleMaskClosable
		| NSWindowStyleMaskMiniaturizable
		| NSWindowStyleMaskResizable;
	rect = NSMakeRect(30, 60, dx, dy);
	win = [[NSWindow alloc] initWithContentRect:rect
		styleMask:style
		backing:NSBackingStoreBuffered
		defer:NO];
	[win setTitle:@"Inferno"];
	[win setAcceptsMouseMovedEvents:YES];
	[win setReleasedWhenClosed:NO];
	[win setDelegate:(id)delegate];
	/* Softscreen size is fixed; constrain the content aspect to it. */
	[win setContentMinSize:NSMakeSize(dx/2, dy/2)];
	[win setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];

	view = [[InfernoView alloc] initWithFrame:NSMakeRect(0, 0, dx, dy)];
	[view setWantsLayer:YES];
	[win setContentView:view];
	[win makeFirstResponder:view];
	[win setContentSize:NSMakeSize(dx, dy)];
	[view viewDidChangeBackingProperties];
	[win center];
	[win makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];
}

void
screeninit(void)
{
	dx = Xsize;
	dy = Ysize;
	if(dx <= 0)
		dx = 1024;
	if(dy <= 0)
		dy = 768;

	gscreen = allocmemimage(Rect(0, 0, dx, dy), XBGR32);
	if(gscreen == nil)
		sysfatal("allocmemimage: %r");

	/* Window must be created on the AppKit main thread */
	dispatch_sync(dispatch_get_main_queue(), ^{
		createwindow();
		readybit = 1;
		Wakeup(&rend);
	});
	Sleep(&rend, isready, nil);
}

void
flushmemscreen(Rectangle r)
{
	if(r.max.x < r.min.x || r.max.y < r.min.y)
		return;
	if(view == nil)
		return;

	/*
	 * Always mark the whole view dirty.  Partial rects are easy to get
	 * wrong with flipped coordinates / Retina, and the softscreen blit
	 * is cheap at 640x480.
	 */
	dispatch_async(dispatch_get_main_queue(), ^{
		[view setNeedsDisplay:YES];
	});
}

uchar*
attachscreen(Rectangle *r, ulong *chan, int *depth, int *width, int *softscreen)
{
	if(!triedscreen) {
		triedscreen = 1;
		screeninit();
	}
	*r = gscreen->r;
	*chan = gscreen->chan;
	*depth = gscreen->depth;
	*width = gscreen->width;
	*softscreen = 1;
	return gscreen->data->bdata;
}

void
getcolor(ulong i, ulong *r, ulong *g, ulong *b)
{
	*r = *g = *b = i;
}

void
setcolor(ulong index, ulong r, ulong g, ulong b)
{
	USED(index); USED(r); USED(g); USED(b);
}

char*
clipread(void)
{
	__block char *q = nil;

	dispatch_sync(dispatch_get_main_queue(), ^{
		NSString *s;
		char *p;
		NSUInteger n;

		@autoreleasepool {
			s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
			if(s == nil)
				return;
			n = [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
			if(n >= sizeof snarf)
				n = sizeof snarf - 1;
			memcpy(snarf, [s UTF8String], n);
			snarf[n] = 0;
			for(p = snarf; *p; p++)
				if(*p == '\r')
					*p = '\n';
			q = strdup(snarf);
		}
	});
	return q;
}

int
clipwrite(char *buf)
{
	__block int ok = 0;

	if(buf == nil)
		return 0;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSString *s;

		@autoreleasepool {
			s = [NSString stringWithUTF8String:buf];
			if(s == nil)
				return;
			[[NSPasteboard generalPasteboard] clearContents];
			ok = [[NSPasteboard generalPasteboard] setString:s forType:NSPasteboardTypeString] ? 1 : 0;
		}
	});
	return ok;
}

void
setpointer(int x, int y)
{
	__block NSPoint sp;
	CGPoint cgp;
	CGFloat screenh;

	if(win == nil || view == nil || dx <= 0 || dy <= 0)
		return;
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSRect b = [view bounds];
		NSPoint vp, wp;

		/* Inverse of mousePosFromEvent: softscreen → view. */
		vp = NSMakePoint((x + 0.5) * b.size.width / dx,
			(y + 0.5) * b.size.height / dy);
		wp = [view convertPoint:vp toView:nil];
		sp = [win convertPointToScreen:wp];
	});
	screenh = CGDisplayBounds(CGMainDisplayID()).size.height;
	cgp.x = sp.x;
	cgp.y = screenh - sp.y;
	CGWarpMouseCursorPosition(cgp);
}

void
drawcursor(Drawcursor *c)
{
	int h, bpl, w;
	uchar *bc, *bs;
	Rectangle ir;

	if(c == nil || c->data == nil){
		dispatch_async(dispatch_get_main_queue(), ^{
			customcursor = nil;
			if(view)
				[[view window] invalidateCursorRectsForView:view];
			[[NSCursor arrowCursor] set];
		});
		return;
	}

	ir.min.x = c->minx;
	ir.min.y = c->miny;
	ir.max.x = c->maxx;
	ir.max.y = c->maxy;
	bpl = bytesperline1(ir);
	h = (c->maxy - c->miny) / 2;
	if(h <= 0 || bpl <= 0)
		return;
	w = c->maxx - c->minx;
	if(w > 64)
		w = 64;
	if(h > 64)
		h = 64;

	bc = c->data;
	bs = c->data + h * bpl;

	/* Build RGBA: mask=set|clr, color from set (fg black / bg white), like X11. */
	dispatch_sync(dispatch_get_main_queue(), ^{
		NSBitmapImageRep *rep;
		NSImage *img;
		NSCursor *nc;
		uchar *px;
		int ii, jj, b, mbit;
		int hotx, hoty;

		rep = [[NSBitmapImageRep alloc]
			initWithBitmapDataPlanes:nil
			pixelsWide:w
			pixelsHigh:h
			bitsPerSample:8
			samplesPerPixel:4
			hasAlpha:YES
			isPlanar:NO
			colorSpaceName:NSCalibratedRGBColorSpace
			bytesPerRow:w * 4
			bitsPerPixel:32];
		if(rep == nil)
			return;
		px = [rep bitmapData];
		memset(px, 0, (size_t)w * h * 4);
		for(ii = 0; ii < h; ii++){
			for(jj = 0; jj < w; jj++){
				b = jj / 8;
				mbit = 0x80 >> (jj & 7);
				if(b >= bpl)
					break;
				if((bs[ii*bpl + b] | bc[ii*bpl + b]) & mbit){
					uchar *p = px + (ii * w + jj) * 4;
					if(bs[ii*bpl + b] & mbit)
						p[0] = p[1] = p[2] = 0;	/* black */
					else
						p[0] = p[1] = p[2] = 255;	/* white */
					p[3] = 255;
				}
			}
		}
		img = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
		[img addRepresentation:rep];
		hotx = -c->hotx;
		hoty = -c->hoty;
		if(hotx < 0) hotx = 0;
		if(hoty < 0) hoty = 0;
		if(hotx >= w) hotx = w - 1;
		if(hoty >= h) hoty = h - 1;
		nc = [[NSCursor alloc] initWithImage:img hotSpot:NSMakePoint(hotx, hoty)];
		customcursor = nc;
		[nc set];
		if(view)
			[[view window] invalidateCursorRectsForView:view];
	});
}
