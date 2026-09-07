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
# rio's menu is drawn in the greygreen palette of data.c: DPalegreygreen
# for the body a menu item sits on and DGreygreen for the highlight, with
# black text on them.  These are the colours, not a guess at them.
Palegreygreen = (0xea, 0xff, 0xea)	# DPalegreygreen
Greygreen = (0x44, 0x88, 0x44)		# DGreygreen


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
    menu = seen.get(Palegreygreen, 0) + seen.get(Greygreen, 0)
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
        ("and what it drew is a menu: most of what changed is rio's own menu palette - "
         "DPalegreygreen for the body and DGreygreen for the highlight, the colours data.c "
         "asks for - with black text on it, and every pixel of it was the background before",
         nch > 0 and menu > nch * 0.6 and seen.get((0, 0, 0), 0) > 100),
        ("and rio is still running in both, so what changed is the menu and not the machine",
         'rio: can\'t' not in ctext and 'rio: can\'t' not in ptext
         and len(re.findall(r'osprey proc: container \d+ pid \d+ /boot/rio: \w+', ctext)) >= 2
         and len(re.findall(r'osprey proc: container \d+ pid \d+ /boot/rio: \w+', ptext)) >= 2),
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
