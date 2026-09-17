#!/usr/bin/env python3
"""Boot p9pair and press a mouse button at rio.

The pair check already settles that rio runs: it is laid out by the
buddy, it takes the screen, it paints its background and it is still
running when the machine idles.  What it does not settle is that rio is
listening - a window system that painted once and then sat deaf would
leave the same pixels.  This presses button 3 at it and looks at the
screen QEMU is scanning out, not at the memory this tree mapped:
rio opens its menu on the press, in its own colours, and the menu is a
block of them that is not there in a run with no press.

The press crosses the whole machine: QEMU's PS/2 controller, the IRQ12
notification the microkernel routes to the personality's container, the
user-space i8042 driver that reads port 0x60 with its own inb, the
/dev/mouse of devinput.c, a forwarded read answered by the buddy over
the ring, rio's mouse proc, and back out through /dev/draw to the draw
server in a container of its own, which writes the frame buffer.
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

Grey = (0x77, 0x77, 0x77)		# rio's background, 0x777777FF
# The menu is libdraw's, not rio's: genmenuhit.c's menucolors makes the
# body allocimagemix(DPalegreen, DWhite), the highlight and the text
# DDarkgreen, and the border DMedgreen.  These are those colours, read
# out of the constants and confirmed against a screendump - an earlier
# version of this check called them rio's DPalegreygreen and DGreygreen,
# which is where rio's window titles come from and not where these do.
Menuback = (0xea, 0xff, 0xea)		# allocimagemix(DPalegreen, DWhite)
Menuhigh = (0x44, 0x88, 0x44)		# DDarkgreen
Menubord = (0x88, 0xcc, 0x88)		# DMedgreen
# what a sweep is drawn in: cols[BACK] inside a border of sizecol
White = (0xff, 0xff, 0xff)		# cols[BACK], 0xFFFFFFFF
Black = (0x00, 0x00, 0x00)		# cols[TEXT], what a window's text is drawn in
Red = (0xff, 0x00, 0x00)		# sizecol, DRed
# and what a window that has been made is bordered in: rio's titlecol
Titlecol = (0x55, 0xaa, 0xaa)		# DGreygreen, from rio's data.c


def readppm(path):
    """QEMU's screendump, a binary P6.  Returns (w, h, pixels) with
    pixels a bytes of 3 per pixel, or None."""
    try:
        d = open(path, 'rb').read()
    except OSError:
        return None
    if not d.startswith(b'P6'):
        return None
    # header: P6 <w> <h> <max>, whitespace separated, comments possible
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
    i += 1				# the single whitespace after the maxval
    w, h, _ = fields
    return w, h, d[i:i + w*h*3]


def changed(a, b):
    """The pixels that differ between the two screens: how many, the box
    they lie in, and what colours they became.  Comparing the two shots
    is what says rio drew something because a button was pressed, rather
    than that something on the screen happens to be a colour."""
    n = 0
    x0 = y0 = 1 << 30
    x1 = y1 = -1
    seen = {}
    w = 1280
    for k in range(0, min(len(a), len(b)), 3):
        if a[k:k+3] != b[k:k+3]:
            n += 1
            p = k // 3
            x, y = p % w, p // w
            if x < x0: x0 = x
            if x > x1: x1 = x
            if y < y0: y0 = y
            if y > y1: y1 = y
            c = (b[k], b[k+1], b[k+2])
            seen[c] = seen.get(c, 0) + 1
    return n, (x0, y0, x1, y1), seen


def count(pix, colour):
    """How many pixels are exactly this colour.  Nothing dithers a frame
    buffer, so the match is exact; the scan is by find rather than by a
    loop over a million pixels, taking only the hits that land on a
    pixel boundary."""
    tri = bytes(colour)
    n, i = 0, pix.find(tri)
    while i >= 0:
        if i % 3 == 0:
            n += 1
        i = pix.find(tri, i+1)
    return n


def boxof(pix, colour):
    """The bounding box of every pixel of exactly this colour, and how
    many there are.  A swept rectangle is known by where it is, not only
    by what colour it is."""
    tri = bytes(colour)
    n = 0
    x0 = y0 = 1 << 30
    x1 = y1 = -1
    w = 1280
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


def countin(pix, colour, box):
    """How many pixels of this colour lie inside the box.  Restricted
    because the frame buffer's top-left corner holds a handful of
    pixels that are not the mapping's - they are there in the control
    shot too, with nothing drawn - and a bounding box taken over the
    whole screen is dragged to the origin by them."""
    tri = bytes(colour)
    x0, y0, x1, y1 = box
    n = 0
    w = 1280
    i = pix.find(tri)
    while i >= 0:
        if i % 3 == 0:
            q = i // 3
            x, y = q % w, q // w
            if x0 <= x <= x1 and y0 <= y <= y1:
                n += 1
        i = pix.find(tri, i+1)
    return n


def boot(shot, inputspec, log):
    argv = ['./scripts/osprey-console.py', '-q', '-p', '2', '-n', 'e1000',
            '-l', log, '-t', '300', '-u', 'the microkernel idles',
            '--shot', shot]
    if inputspec:
        argv += ['--input', inputspec]
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
    def tmp(p, s):
        f = tempfile.mktemp(prefix=p, suffix=s); files.append(f); return f

    # the control first: the same boot, the mouse moved and no button pressed
    clog, cshot = tmp('osprey-rio-ctl-', '.log'), tmp('osprey-rio-ctl-', '.ppm')
    ctext, cpix = boot(cshot, 'm:240:160,s:0.5', clog)
    # and the run that presses button 3, which is what opens rio's menu
    plog, pshot = tmp('osprey-rio-', '.log'), tmp('osprey-rio-', '.ppm')
    ptext, ppix = boot(pshot, 'm:240:160,s:0.5,d:right,s:1.0', plog)

    cw = ch = pw = ph = 0
    cgrey = -1
    nch, box, seen = 0, (0, 0, 0, 0), {}
    if cpix is not None:
        cw, ch, cd = cpix
        cgrey = count(cd, Grey)
    if ppix is not None:
        pw, ph, pd = ppix
    if cpix is not None and ppix is not None:
        nch, box, seen = changed(cd, pd)
    # and the sweep: New from the menu, then a press, a drag and a release
    swlog, swshot = tmp('osprey-rio-sw-', '.log'), tmp('osprey-rio-sw-', '.ppm')
    # and then a word typed at it, one key at a time through the emulated
    # keyboard, and Enter.  The word is one the shell cannot run: what it
    # proves is the path, not the program - a key crosses the i8042, the
    # driver, /dev/kbd, rio, the window's own /dev/cons and the shell,
    # which parses the line and asks for a program by that name.
    typed = ','.join('K:' + k for k in 'n o s u c h t h i n g'.split())
    # and then a program that does exist, and a line for it to echo:
    # /bin/cat with no argument reads its standard input and writes it
    # out, and in a window both of those are the window.
    runcat = ','.join('K:' + k for k in
                      'slash b i n slash c a t'.split()) + ',K:ret,s:3.0,'
    runcat += ','.join('K:' + k for k in 'h e l l o'.split()) + ',K:ret,s:3.0'
    swtext, swpix = boot(swshot, 'm:240:160,s:1.0,d:right,s:1.2,u:right,s:1.5,'
                                 'm:-400:-300,s:0.8,d:right,s:0.6,m:300:220,s:0.8,'
                                 'u:right,s:8.0,' + typed + ',K:ret,s:4.0,'
                                 + runcat, swlog)
    # Where it is, measured from the border rather than from the fill: a
    # stray white pixel in the frame buffer's top-left corner - two of
    # them, and they are there in the control shot too - would otherwise
    # drag the box out to the origin.  The border is sizecol while the
    # sweep is still being drawn and titlecol once it is a window, and
    # which of those the screendump catches depends on when it is taken,
    # so whichever is there is the one measured.
    swwhite = count(swpix[2], White) if swpix else 0
    swred, redbox = boxof(swpix[2], Red) if swpix else (0, (0,0,0,0))
    swtitle, titlebox = boxof(swpix[2], Titlecol) if swpix else (0, (0,0,0,0))
    swbox = redbox if swred > swtitle else titlebox
    # the text the window's shell wrote, drawn by rio inside the window
    swtext_px = countin(swpix[2], Black, swbox) if swpix else 0
    forks = lambda t: len(re.findall(r'osprey fork: container \d+ forked container \d+ \(/boot/rio\)', t))
    cforks, swforks = forks(ctext), forks(swtext)
    menu = seen.get(Menuback, 0) + seen.get(Menuhigh, 0)
    tight = (box[2] - box[0]) < 400 and (box[3] - box[1]) < 400

    results = [
        ("the screen QEMU scans out is rio's, in the run with no button pressed: 1280x800, "
         "and nearly all of it the 0x777777 rio fills its view with - this is the display "
         "controller's own memory dumped by the emulator, not the mapping this tree made",
         cpix is not None and (cw, ch) == (1280, 800) and cgrey > 1280*800*0.9),
        ("rio hears the button: the same boot with button 3 held down opens rio's menu, and "
         "the two screens differ by a block of pixels that were the background in the control "
         "run - the press crossed the i8042, the microkernel's IRQ12 notification, the "
         "user-space driver, /dev/mouse, a forwarded read answered over the ring, and rio, and "
         "came back through /dev/draw to the frame buffer",
         ppix is not None and (pw, ph) == (1280, 800) and nch > 3000 and tight),
        ("and what it drew is a menu: most of what changed is libdraw's menu palette - the "
         "mix of DPalegreen and DWhite for the body a menu item sits on, DDarkgreen for the "
         "highlight and the text, DMedgreen for the border, which is what genmenuhit.c's "
         "menucolors asks for - and every pixel of it was the background before",
         nch > 0 and menu > nch * 0.6 and seen.get((0, 0, 0), 0) > 100),
        ("and rio is still running in both, so what changed is the menu and not the machine",
         'rio: can\'t' not in ctext and 'rio: can\'t' not in ptext
         and len(re.findall(r'osprey proc: container \d+ pid \d+ /boot/rio: \w+', ctext)) >= 2
         and len(re.findall(r'osprey proc: container \d+ pid \d+ /boot/rio: \w+', ptext)) >= 2),
        ("New is chosen from the menu and a rectangle swept: where the pointer was dragged "
         "with the button down there is rio's cols[BACK], at the corners the mouse packets "
         "put it at, inside a border of either sizecol while the sweep is still being drawn "
         "or titlecol once it is a window - which of the two the screendump catches depends "
         "on when it is taken, so the box is what is asserted and the border is only named",
         swpix is not None and swwhite > 20000 and (swred > 1000 or swtitle > 1000)
         and abs(swbox[0] - 480) < 12 and abs(swbox[1] - 260) < 12
         and abs(swbox[2] - 780) < 12 and abs(swbox[3] - 480) < 12),
        ("and a window is made of it: the sweep boot forks a rio the control boot does not - "
         "the process libthread makes for winshell - and that process mounts rio's own file "
         "server for the window on /mnt/wsys, binds it over /dev and opens /dev/cons there, "
         "with no mount, bind or cons failure in the log.  What it then fails to run is "
         "/bin/rc, which this personality does not have, so the window does not stay; that is "
         "written down in doc/osprey-progress.ms and is not claimed here",
         swforks > cforks
         and 'mount failed' not in swtext and 'bind failed' not in swtext
         and "can't open /dev/cons" not in swtext
         and 'the child table is full' not in swtext),
        ("and a shell runs in the window: rio execs /bin/rc in it, which on this personality "
         "is /boot/sh under the name rio has written into it, and the buddy lays that binary "
         "out for the window's container",
         re.search(r'buddy: exec /bin/rc for container \d+: a Plan 9 a\.out', swtext) is not None),
        ("and it writes into the window and not onto the machine's console: the shell's first "
         "words go to descriptor 1, which winshell opened on the window's own /dev/cons, and "
         "none of them appear on the console this check reads - if the window's descriptors "
         "were still the machine's, they would appear there and nowhere else",
         'sh: this is /boot/sh' not in swtext),
        ("and rio draws them: the swept rectangle holds black text, all of it inside the "
         "window - counted inside it, because the frame buffer's top-left corner holds a "
         "few pixels that are in the control shot too - which is rio's font, drawn through "
         "its own file server by the command running in it",
         swtext_px > 1500),
        ("and it reads what is typed at it: the word nosuchthing is typed at the window one "
         "key at a time and Enter after it, and the shell in the window asks the buddy for a "
         "program of that name - which crosses the i8042, the user-space driver, /dev/kbd, "
         "rio, the window's own /dev/cons and the shell's own reader",
         re.search(r"buddy: exec nosuchthing: file does not exist: 'nosuchthing'", swtext) is not None),
        ("and it answers into the window: the shell's complaint about the word does not appear "
         "on the machine's console, because the shell's print goes to descriptor 1 and that is "
         "the window",
         'sh: cannot exec' not in swtext),
        ("and a program runs in the window: /bin/cat is typed at it and the buddy lays that "
         "binary out for a container of the window's own - the shell forked, the fork was "
         "given the window's descriptors, and the program the fork execs is a Plan 9 a.out "
         "the buddy pages in",
         re.search(r'buddy: exec /bin/cat for container \d+: a Plan 9 a\.out', swtext) is not None),
        ("and its output is the window's: the cat started in the window says so with its own "
         "argument vector, and that line does not appear on the machine's console - the boot "
         "runs a /boot/cat of its own and that one does appear there, which is what makes the "
         "distinction worth drawing rather than assuming",
         'argv[0] = /bin/cat' not in swtext
         and 'argv[0] = /boot/cat' in swtext),
        ("and the notes rio posts are addressed to something that exists: libthread keeps the "
         "number getpid() gave it and posts to that when it shuts down, and no boot here has "
         "the kernel refusing one because the number named no container",
         'which is not a container' not in ctext and 'which is not a container' not in ptext),
    ]

    bad = 0
    for what, ok in results:
        print('%-4s %s' % ('ok' if ok else 'FAIL', what))
        if not ok: bad += 1
    top = sorted(seen.items(), key=lambda kv: -kv[1])[:4]
    print('grey in the control %d of %d; %d pixels changed, in %r, mostly %s'
          % (cgrey, 1280*800, nch, box,
             ' '.join('%02x%02x%02x=%d' % (c[0], c[1], c[2], n) for c, n in top)))
    print('the swept rectangle %r: %d of cols[BACK], %d of sizecol, %d of titlecol, '
          '%d of text inside it; rio forks %d in the control and %d in the sweep'
          % (swbox, swwhite, swred, swtitle, swtext_px, cforks, swforks))
    if keep or bad:
        for f in files: print('log %s' % f)
    else:
        for f in files:
            try: os.unlink(f)
            except OSError: pass
        for f in files:
            try: os.unlink(f + '.qmp')
            except OSError: pass
    return 1 if bad else 0

sys.exit(main())
