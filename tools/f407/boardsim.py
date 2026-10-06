#!/usr/bin/env python3
#
# The simulation's physics, asserted ON SILICON.
#
# Every figure in doc/pycubed-plan.ms for the corrected model came from
# QEMU, where this kernel's tick runs about seven times faster than wall
# time.  The arithmetic is the same on the board and the CLOCK is not,
# so the checks take their elapsed time from the model's own counters
# exactly as tools/f407/simcheck.py does -- "integrated" in #P/imu.ctl
# and the orbit's closed-form phase -- and nothing here is timed by a
# host sleep.
#
# Driven through the screen session that owns the board's port.  Opening
# the device while screen holds it wedges the adapter, which costs a
# physical replug, so this never opens it.
#
import math, re, sys, time
sys.path.insert(0, "/Users/npe/src/inferno64-branches/xip/tools/radio")
import twoboard

SESS = sys.argv[1]
b = twoboard.Board(SESS, name="b1")
fails = []


def cmd(line, settle=2.0):
    b._stuff(line)
    time.sleep(settle)


def kv(path, settle=3.5):
    b._stuff("cat " + path)
    time.sleep(settle)
    d = {}
    for ln in b.text().splitlines():
        f = ln.split()
        if len(f) >= 2:
            out = []
            for x in f[1:]:
                try:
                    out.append(int(x))
                except ValueError:
                    break
            if out:
                d[f[0]] = out
    return d


def check(name, ok, detail):
    print("%-4s %s: %s" % ("ok" if ok else "FAIL", name, detail), flush=True)
    if not ok:
        fails.append(name)


if not b.live(wait=15):
    raise SystemExit("board not running commands (marker %d)"
                     % getattr(b, "lastcount", -1))
cmd("cd '#P'")
if "imu.ctl" not in b.text():
    cmd("ls")
    if "imu.ctl" not in b.text():
        raise SystemExit("not in #P")

cmd("echo timescale 1 >orbit.ctl")

# THE FIELD, round the orbit, by SETTING the phase rather than waiting:
# a sample interval timed on the host aliases against a clock ratio
# nobody controls.
mags = []
N = 12
for i in range(N):
    cmd("echo phase %d >orbit.ctl" % (i * 360000 // N), settle=1.2)
    f = kv("orbit", settle=1.6).get("field")
    if f:
        mags.append(int(math.sqrt(sum(v*v for v in f[:3]))))
check("field magnitude", mags and min(mags) <= 260 and max(mags) >= 400,
      "%s mG at %d points round one orbit; 247 is the magnetic equator"
      % ("%d..%d" % (min(mags), max(mags)) if mags else "none", N))

# ECLIPSE at beta zero: 38 per cent of the orbit, from sin(theta)=Re/r.
cmd("echo beta 0 >orbit.ctl")
dark = 0
M = 24
for i in range(M):
    cmd("echo phase %d >orbit.ctl" % (i * 360000 // M), settle=1.2)
    e = kv("orbit", settle=1.6).get("eclipse")
    dark += e[0] if e else 0
check("eclipse fraction", 30 <= 100.0*dark/M <= 46,
      "%.0f%% of %d points in shadow at beta 0 (the geometry says 38%%)"
      % (100.0*dark/M, M))
cmd("echo beta 20000 >orbit.ctl")

# THE ATTITUDE TURNS AT THE RATE IT REPORTS.  The angle is accumulated
# over consecutive samples and taken by atan2: acos is ill-conditioned
# where the small angles are and turned 2593 degrees into 0.00 once.
def qmul(a, c):
    return (a[0]*c[0]-a[1]*c[1]-a[2]*c[2]-a[3]*c[3],
            a[0]*c[1]+a[1]*c[0]+a[2]*c[3]-a[3]*c[2],
            a[0]*c[2]-a[1]*c[3]+a[2]*c[0]+a[3]*c[1],
            a[0]*c[3]+a[1]*c[2]-a[2]*c[1]+a[3]*c[0])


def qangle(q):
    v = math.sqrt(q[1]*q[1]+q[2]*q[2]+q[3]*q[3])
    return 2.0*math.degrees(math.atan2(v, abs(q[0])))


for rate in (10, 1):
    cmd("echo still >imu.ctl")
    cmd("echo 0 0 0 >torque")
    cmd("echo spin 0 0 %d >imu.ctl" % rate)
    prev = None
    turned = 0.0
    t0 = t1 = None
    worst = 0.0
    for k in range(8):
        d = kv("imu.ctl", settle=1.4)
        q = tuple(v/10000.0 for v in d["quaternion"][:4])
        t1 = d["integrated"][0]
        if prev is not None:
            step = qangle(qmul((prev[0], -prev[1], -prev[2], -prev[3]), q))
            turned += step
            worst = max(worst, step)
        else:
            t0 = t1
        prev = q
    dt = (t1 - t0)/1000.0
    want = rate*dt
    err = abs(turned-want)/max(1.0, want)
    check("spin %d deg/s" % rate, err < 0.05 and worst < 150,
          "turned %.1f deg in %.1fs of model time, wanted %.1f (%.1f%%,"
          " worst step %.0f of 180)" % (turned, dt, want, 100*err, worst))

# A FREE BODY KEEPS ITS MOMENTUM.  |L| is read out of the model rather
# than rebuilt from the rate and a copy of the tensor here.
cmd("echo still >imu.ctl")
cmd("echo 0 0 0 >torque")
cmd("echo tumble >imu.ctl")
a = kv("imu.ctl", settle=1.4)
I = a["inertia"][:3]
w0 = a["spin"][:3]
L0 = math.sqrt(sum(float(x)*x for x in a["momentum"][:3]))
E0 = sum(I[i]*w0[i]*w0[i] for i in range(3))/2.0
wL = wE = 0.0
moved = [0, 0, 0]
for i in range(5):
    cmd("sleep 10", settle=12.0)
    c = kv("imu.ctl", settle=1.4)
    w = c["spin"][:3]
    L = math.sqrt(sum(float(x)*x for x in c["momentum"][:3]))
    E = sum(I[j]*w[j]*w[j] for j in range(3))/2.0
    wL = max(wL, abs(L-L0)/L0)
    wE = max(wE, abs(E-E0)/E0)
    moved = [max(moved[j], abs(w[j]-w0[j])) for j in range(3)]
dt = (c["integrated"][0] - a["integrated"][0])/1000.0
check("free-body |L|", wL < 0.02,
      "drifts %.3f%% over %.0fs of model time" % (100*wL, dt))
check("free-body energy", wE < 0.03,
      "drifts %.3f%% over %.0fs" % (100*wE, dt))
check("precession happens", moved[0] > 500 and moved[1] > 500,
      "the body rate moved %d %d %d mdeg/s from %d %d %d with nothing"
      " pushing" % tuple(moved + list(w0)))
check("symmetry axis holds", moved[2]*20 < abs(w0[2]),
      "omega_z moved %d of %d, and for Ixx == Iyy it is a constant of"
      " the motion" % (moved[2], w0[2]))

print("---")
if fails:
    print("BOARDSIM-FAILED " + " ".join(fails))
    sys.exit(1)
print("BOARDSIM-OK the orbit sweeps, the attitude turns at the rate it"
      " reports, and a free body keeps its momentum -- ON SILICON")
