#!/usr/bin/env python3
"""Drive the rest of rio's window gestures on the microkernel.

osprey-check-rio.py settles that rio hears a button, that New and a
sweep make a window, and that a shell runs in it and reads what is typed
at it.  What it does not settle is the rest of what a window system
does: a second window, and moving, resizing and deleting one.  Each of
those is a menu item chosen by dragging inside the menu and then a
gesture at a window, and each ends in pixels on the screen QEMU scans
out - the window is somewhere else, or a different size, or gone.

The menu is chosen by arithmetic, not by guessing.  libdraw's
genmenuhit.c pops the menu with the last-hit item centred under the
pointer and lays the items out font->height+Vspacing apart, so item k is
(k - lasthit) * pitch below the pointer.  The first boot here measures
that pitch off the screen - the menu's border is DMedgreen and nothing
else on the screen is - and the second boot uses it.  menuhit remembers
the last item hit, so the offsets below are relative to the previous
choice, not to New.
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

Grey = (0x77, 0x77, 0x77)		# rio's background
White = (0xff, 0xff, 0xff)		# cols[BACK], what a window is filled with
Titlecol = (0x55, 0xaa, 0xaa)		# DGreygreen, the current window's border
Lighttitle = (0x9e, 0xee, 0xee)		# DPalegreygreen, a window that is not the current one
Menubord = (0x88, 0xcc, 0x88)		# DMedgreen, the menu's border and nothing else
Black = (0x00, 0x00, 0x00)		# what the arrow's opaque pixels are drawn in

# genmenuhit.c: Margin 4 outside the text, Vspacing 2 between lines
Margin, Vspacing, Nitem = 4, 2, 6	# New Resize Move Delete Hide Exit
New, Reshape, Move, Delete = 0, 1, 2, 3


def readppm(path):
    try:
        d = open(path, 'rb').read()
    except OSError:
        return None
    if not d.startswith(b'P6'):
        return None
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(d) and d[i:i+1].isspace():
            i += 1
        if d[i:i+1] == b'#':
            while i < len(d) and d[i:i+1] != b'\n':
                i += 1
            continue
        j = i
        while j < len(d) and not d[j:j+1].isspace():
            j += 1
        fields.append(int(d[i:j]))
        i = j
    i += 1
    w, h, _ = fields
    return w, h, d[i:i + w*h*3]


def boxof(pix, colour, w=1280):
    tri = bytes(colour)
    n = 0
    x0 = y0 = 1 << 30
    x1 = y1 = -1
    i = pix.find(tri)
    while i >= 0:
        if i % 3 == 0:
            n += 1
            q = i // 3
            x, y = q % w, q // w
            if x < x0: x0 = x
            if x > x1: x1 = x
            if y < y0: y0 = y
            if y > y1: y1 = y
        i = pix.find(tri, i+1)
    return n, (x0, y0, x1, y1)


def countin(pix, colour, box, w=1280):
    """How many pixels of this colour lie inside the box.  Counting
    inside a named rectangle rather than taking a bounding box is what
    tells two windows apart: both are filled with the same white."""
    tri = bytes(colour)
    x0, y0, x1, y1 = box
    n = 0
    i = pix.find(tri)
    while i >= 0:
        if i % 3 == 0:
            q = i // 3
            x, y = q % w, q // w
            if x0 <= x <= x1 and y0 <= y <= y1:
                n += 1
        i = pix.find(tri, i+1)
    return n


def arrowat(pix, pt):
    """The arrow's black pixels in the 16x16 sprite box whose top-left
    corner is the hotspot.  cursor.c draws the Plan 9 arrow with its
    hotspot at (-1,-1) from the sprite, and the sprite's black rows start
    one down and one right of that, so the black lies in exactly this
    box."""
    return countin(pix[2], Black, (pt[0], pt[1], pt[0]+15, pt[1]+15))


def inset(box, d):
    return (box[0]+d, box[1]+d, box[2]-d, box[3]-d)


def run(shot, inputspec, log, timeout='360'):
    argv = ['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
            '-l', log, '-t', timeout, '-u', 'the microkernel idles',
            '--shot', shot, '--input', inputspec]
    subprocess.run(argv, env=env, capture_output=True, text=True)
    try:
        t = open(log, errors='replace').read()
    except OSError:
        t = ''
    return t, readppm(shot)


def main():
    keep = '-k' in sys.argv[1:]
    r = subprocess.run(['mk', 'CONF=p9pair', '9p9pair'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9pair did not build'); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair'),
                            OSPREY_INI='ospreykey=this machine\'s secret\n*riodemo=1'),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    files = []
    def tmp(p, s='.ppm'):
        f = tempfile.mktemp(prefix='osprey-riowin-' + p, suffix=s)
        files.append(f)
        return f

    # First boot: open the menu, photograph it, then slide off it and let
    # go, which chooses nothing.  The menu's border is the measurement.
    mlog, mend = tmp('menu-', '.log'), tmp('menu-end-')
    mshot = tmp('menu-')
    mtext, _ = run(mend, 'm:260:-100,s:1.0,d:right,s:1.0,S:%s,m:400:0,s:0.5,'
                         'u:right,s:0.5' % mshot, mlog)
    mpix = readppm(mshot)
    epix = readppm(mend)
    nbord, mbox = boxof(mpix[2], Menubord) if mpix else (0, (0,0,0,0))
    mh = mbox[3] - mbox[1] + 1
    # menur is nitem*(height+Vspacing) tall inset by -Margin on each side
    pitch = (mh - 2*Margin) // Nitem
    ok_menu = mpix is not None and nbord > 200 and 12 <= pitch <= 40 \
        and (mh - 2*Margin) % Nitem == 0
    if not ok_menu:
        pitch = 18				# the default font: 16 high plus Vspacing

    def menu(item, last, x, y):
        """Press button 3 at (x,y) relative to where the pointer is, drag
        to item and let go.  Returns the ops and the new pointer."""
        dy = (item - last) * pitch
        s = 'm:%d:%d,s:0.8,d:right,s:0.5' % (x, y)
        if dy:
            s += ',m:0:%d,s:0.5' % dy
        s += ',u:right,s:0.8'
        return s, dy

    # Second boot: New and a sweep twice, then Move, Resize and Delete on
    # the second window.  The pointer starts in the middle of the screen.
    A = (400, 220, 680, 420)
    B = (760, 500, 1060, 700)
    Bmoved = (150, 500, 450, 700)
    Bsized = (700, 300, 1060, 560)
    shots = {k: tmp(k + '-') for k in ('a', 'b', 'm', 'r', 'd')}
    # where the input sequence leaves the pointer when each shot is taken
    Ptr = {'a': (680, 420), 'b': (1060, 700), 'm': (300, 600),
           'r': (1060, 560), 'd': (880, 430)}
    glog, gend = tmp('gest-', '.log'), tmp('gest-end-')

    ops = []
    m, _ = menu(New, New, 260, -200)		# pointer to (900,200)
    ops.append(m)
    # sweep A from (400,220) to (680,420)
    ops.append('m:-500:20,s:0.5,d:right,s:0.4,m:280:200,s:0.5,u:right,s:9.0')
    ops.append('S:' + shots['a'])
    m, _ = menu(New, New, 220, -270)		# pointer to (900,150)
    ops.append(m)
    # sweep B from (760,500) to (1060,700)
    ops.append('m:-140:350,s:0.5,d:right,s:0.4,m:300:200,s:0.5,u:right,s:9.0')
    ops.append('S:' + shots['b'])
    # Move: choose it, press inside B, drag by (120,40), let go
    m, dy = menu(Move, New, -810, -400)		# pointer to (250,300)
    ops.append(m)
    # press in the middle of B and drag it clear of where it was: the
    # criterion is that the box it came from is background again, so the
    # two places must not overlap
    ops.append('m:%d:%d,s:0.5,d:right,s:0.5,m:-610:0,s:0.5,u:right,s:2.0'
               % (910 - 250, 600 - (300 + dy)))
    ops.append('S:' + shots['m'])
    # Resize: choose it, point at B where it now is, then sweep the new
    # rectangle somewhere else again
    m, dy = menu(Reshape, Move, 250 - 300, 300 - 600)
    ops.append(m)
    ops.append('m:%d:%d,s:0.5,d:right,s:0.5,u:right,s:0.8'
               % (300 - 250, 600 - (300 + dy)))
    ops.append('m:%d:%d,s:0.5,d:right,s:0.5,m:360:260,s:0.5,u:right,s:4.0'
               % (700 - 300, 300 - 600))
    ops.append('S:' + shots['r'])
    # Delete: choose it, point at the window, let go
    m, dy = menu(Delete, Reshape, 250 - 1060, 600 - 560)
    ops.append(m)
    ops.append('m:%d:%d,s:0.5,d:right,s:0.5,u:right,s:4.0'
               % (880 - 250, 430 - (600 + dy)))
    ops.append('S:' + shots['d'])
    gtext, _ = run(gend, ','.join(ops), glog)
    pix = {k: readppm(v) for k, v in shots.items()}

    def white(k, box):
        return countin(pix[k][2], White, inset(box, 6)) if pix[k] else 0
    def grey(k, box):
        return countin(pix[k][2], Grey, inset(box, 6)) if pix[k] else 0
    def title(k, box):
        return countin(pix[k][2], Titlecol, inset(box, -4)) if pix[k] else 0
    def light(k, box):
        return countin(pix[k][2], Lighttitle, inset(box, -4)) if pix[k] else 0

    area = lambda b: (b[2]-b[0]-12) * (b[3]-b[1]-12)
    rcs = re.findall(r'buddy: exec /bin/rc for container (\d+)', gtext)

    arrows = {k: {j: (arrowat(pix[k], Ptr[j]) if pix[k] else -1) for j in Ptr}
              for k in Ptr}

    results = [
        ("a window is swept and the shot taken while the machine still runs: rio's cols[BACK] "
         "fills the rectangle the mouse was dragged over, inside a border of titlecol - this "
         "shot is taken part way through the input sequence, over QMP, not at the end of the "
         "boot, so the gestures after it are looked at on the same machine",
         pix['a'] is not None and white('a', A) > area(A) * 0.7 and title('a', A) > 500),
        ("and a second window is made beside it: both rectangles are filled, each counted "
         "inside its own box because the two are the same white, and the first is undisturbed "
         "by the second - and the borders say which is which, the new one in titlecol because "
         "it is the current window and the first now in lighttitlecol, which is rio having "
         "redrawn a border it had already drawn once",
         pix['b'] is not None and white('b', A) > area(A) * 0.7
         and white('b', B) > area(B) * 0.7 and title('b', B) > 500
         and light('b', A) > 500 and title('b', A) < 100),
        ("and each has a shell of its own: the buddy laid /bin/rc out twice, for two different "
         "containers - a window is not a drawing, it is a program with its own address space "
         "and its own descriptors",
         len(rcs) >= 2 and len(set(rcs)) >= 2),
        ("Move: the item two below New is chosen by dragging inside the menu, the second window "
         "is pressed and dragged, and it is somewhere else - the box it was in is rio's "
         "background again and the box it was dragged to is filled",
         pix['m'] is not None and white('m', Bmoved) > area(Bmoved) * 0.7
         and grey('m', B) > area(B) * 0.7 and white('m', A) > area(A) * 0.7),
        ("Resize: the item above Move is chosen, the window is pointed at and a new rectangle "
         "swept, and the window is that rectangle - a different size from the one it was swept "
         "at, not a moved copy of it",
         pix['r'] is not None and white('r', Bsized) > area(Bsized) * 0.7
         and (Bsized[2]-Bsized[0]) * (Bsized[3]-Bsized[1])
             != (B[2]-B[0]) * (B[3]-B[1])
         and grey('r', Bmoved) > area(Bmoved) * 0.8
         and white('r', A) > area(A) * 0.7),
        ("Delete: the item two below Resize is chosen and the window pointed at, and it is "
         "gone - where it was is rio's background, with none of its white left.  Both halves "
         "are asserted, the window there in the shot before and not there in this one: a "
         "criterion that only looked for background would pass on a rectangle that never held "
         "a window at all, which is exactly what it did when the gestures were failing.  The "
         "white that is left is the arrow's outline, 56 pixels of it, because the pointer is "
         "still where the window was pointed at",
         pix['d'] is not None and pix['r'] is not None
         and white('r', Bsized) > area(Bsized) * 0.7
         and grey('d', Bsized) > area(Bsized) * 0.8
         and white('d', Bsized) < 100),
        ("and deleting one window does not take the other with it: the first window is still "
         "filled and still bordered after the second is deleted - bordered in lighttitlecol, "
         "because deleting the current window leaves rio with no current window and not with "
         "the other one promoted, which is what rio does and not what would be assumed",
         pix['d'] is not None and white('d', A) > area(A) * 0.7
         and light('d', A) > 500 and title('d', A) < 100
         and len(re.findall(r'osprey proc: container \d+ pid \d+ /boot/rio: \w+', gtext)) >= 2),
        ("the menu is six items of the default font: its border is DMedgreen and nothing else "
         "on the screen is, so its height is measured off the screen, and the item pitch the "
         "gestures above are aimed with is that height less genmenuhit.c's two margins divided "
         "by the six items - measured, not assumed",
         ok_menu and pitch == 18),
        ("and the arrow is drawn where the pointer is and nowhere else: each of the five "
         "shots has the Plan 9 arrow's black pixels in the 16x16 sprite box at the point the "
         "mouse packets put the pointer at, and none of them has anything there at the four "
         "points the other shots' pointers were at - the arrow moved rather than accumulated.  "
         "It is the draw server that draws it, in its own container, out of a page of two "
         "numbers this personality writes because it is the one that owns the controller",
         all(pix[k] is not None for k in Ptr)
         and all(arrows[k][k] > 120 for k in Ptr)
         and all(arrows[k][j] < 20 for k in Ptr for j in Ptr if j != k)),
        ("and letting go outside the menu chooses nothing: the shot at the end of that boot has "
         "no menu on it and no window, so the menu measured above was closed by the gesture and "
         "not by the machine falling over",
         epix is not None and boxof(epix[2], Menubord)[0] == 0
         and boxof(epix[2], Titlecol)[0] == 0
         and 'rio: can\'t' not in mtext),
    ]

    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok: bad += 1
    for k in ('a', 'b', 'm', 'r', 'd'):
        print('arrow in shot %s: %s' % (k, ' '.join('%s@%s=%d' % (j, Ptr[j], arrows[k][j])
                                                    for j in ('a','b','m','r','d'))))
    print('the menu %r is %d high, pitch %d; /bin/rc for containers %s'
          % (mbox, mh, pitch, ' '.join(rcs)))
    for k, box in (('a', A), ('b', B), ('m', Bmoved), ('r', Bsized), ('d', Bsized)):
        if pix[k]:
            print('shot %s: %d white and %d grey in %r; A holds %d white, %d titlecol, '
                  '%d lighttitlecol'
                  % (k, white(k, box), grey(k, box), box, white(k, A), title(k, A), light(k, A)))
        else:
            print('shot %s: no screendump' % k)
    if keep or bad:
        for f in files: print('log %s' % f)
    else:
        for f in files:
            for g in (f, f + '.qmp'):
                try: os.unlink(g)
                except OSError: pass
    return 1 if bad else 0

sys.exit(main())
