#!/usr/bin/env python3
"""Check the satellite simulation against the physics it claims.

    simcheck.py <qemu-system-arm> [kernel]

WHY QEMU AND NOT A BOARD.  Every number here is arithmetic inside the
kernel, so a board adds nothing but a flash cycle and a reset button --
and the first run of this hung a board hard, with no console and no
response to ^R, which cost a physical reset nobody was there to press.
QEMU's netduinoplus2 is the same Cortex-M4 and the same image.

AND THE CLOCK IS NOT THE HOST'S.  Under QEMU this kernel's tick runs
about seven times faster than wall time -- "sleep 30" at the board's
prompt returns in four and a half seconds -- so every check below takes
its elapsed time from the model's own clock and never from a host
sleep.  #P/imu.ctl reports "integrated", the simulated milliseconds the
attitude integrator has actually stepped, and #P/orbit reports a phase
computed in closed form from the same ticks.  Two clocks that agree
with each other are evidence; a host sleep compared against either is
not.  Estimating the elapsed time from the host's sleeps is what made a
correct model look five times too fast for an hour.
"""
import math, re, subprocess, sys, time

CHARDELAY = 0.01
BOOT = 10.0
QEMU = sys.argv[1]
KERNEL = sys.argv[2] if len(sys.argv) > 2 else \
    "os/inferno/stm32f407/istm32f407"
fails = []


class Board:
    def __init__(self):
        self.p = subprocess.Popen(
            [QEMU, "-M", "netduinoplus2", "-nographic",
             "-serial", "null", "-serial", "mon:stdio", "-kernel", KERNEL],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, bufsize=0)
        self.buf = ""
        self.drain(BOOT)
        if "Initial Dis" not in self.buf:
            raise SystemExit("simcheck: the kernel did not boot:\n" +
                             self.buf[-600:])

    def drain(self, secs):
        import select
        end = time.time() + secs
        got = ""
        while time.time() < end:
            r, _, _ = select.select([self.p.stdout], [], [], 0.05)
            if r:
                d = self.p.stdout.read(4096)
                if d:
                    got += d.decode("utf-8", "replace")
        got = got.replace("\r", "")
        self.buf += got
        return got

    def send(self, line, settle=1.5):
        """One character at a time, because the receive register is one
        byte deep and the echo is done from the interrupt handler: a
        line written in one go arrives as a DIFFERENT line.  Three runs
        of this blamed a kernel hang on a command that never arrived."""
        for ch in (line + "\n").encode():
            self.p.stdin.write(bytes([ch]))
            self.p.stdin.flush()
            time.sleep(CHARDELAY)
        return self.drain(settle)

    def sleep(self, boardsecs, cap=60.0):
        """Wait on the BOARD's clock, which is the only one the model
        uses, and stop as soon as it says it is done.

        A host sleep of the same length would be wrong by whatever the
        ratio between the two clocks happens to be -- under QEMU the
        board's is about seven times faster, so "sleep 120" returns in
        eighteen host seconds and a host that then waited the other
        hundred would let the model run seven hundred further seconds
        it had not asked for.  So: send it, then wait for the prompt.
        """
        for ch in ("sleep %d\n" % boardsecs).encode():
            self.p.stdin.write(bytes([ch]))
            self.p.stdin.flush()
            time.sleep(CHARDELAY)
        end = time.time() + cap
        while time.time() < end:
            got = self.drain(0.5)
            if got.rstrip().endswith(";"):
                return
        raise SystemExit("simcheck: sleep %d never gave a prompt back"
                         % boardsecs)

    def kv(self, path, settle=2.5):
        out = self.send("cat '%s'" % path, settle)
        d = {}
        for ln in out.splitlines():
            f = ln.split()
            if len(f) >= 2:
                d[f[0]] = f[1:]
        return d

    def close(self):
        self.p.terminate()
        self.p.wait()


def check(name, ok, detail):
    print("%-4s %s: %s" % ("ok" if ok else "FAIL", name, detail))
    if not ok:
        fails.append(name)


def qangle(q):
    """The rotation angle a unit quaternion describes, in degrees.

    BY ATAN2 AND NOT BY ACOS, because acos is ill-conditioned exactly
    where the small angles are: its derivative is -1/sqrt(1-x^2), which
    at a 7.6 degree rotation is -15, so the 1e-4 quantisation of a
    quaternion stored as integers of ten thousand becomes 0.17 degrees
    of noise on the answer.  Summed over nine samples that was 1.7 per
    cent of a 1 deg/s measurement, and it looked like a model that
    turned slowly.  atan2 of the vector part against the scalar is well
    conditioned at both ends.
    """
    v = math.sqrt(q[1]*q[1] + q[2]*q[2] + q[3]*q[3])
    return 2.0 * math.degrees(math.atan2(v, abs(q[0])))


def qmul(a, b):
    return (a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3],
            a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2],
            a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1],
            a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0])


def ints(d, k):
    """The leading numbers on a line, ignoring any unit that follows.

    "field 88 0 243 mG" names its unit, which is right in a file people
    read and is why this stops at the first field that is not a number.
    """
    out = []
    for x in d[k]:
        try:
            out.append(int(x))
        except ValueError:
            break
    return tuple(out)


b = Board()
b.send("echo timescale 1 >'#P/orbit.ctl'")

# ---------------------------------------------------------------- orbit
#
# The dipole field at 500km: 247mG where the geomagnetic axis is
# perpendicular to the position and twice that over the poles.  Sampled
# around one orbit, the magnitude has to cover most of that range and
# the direction has to sweep; a field of constant magnitude is the fault
# the first version of this simulation had.
#
# THE PHASE IS SET RATHER THAN WAITED FOR.  Letting the orbit run and
# sampling it needs a time scale, and then the sampling interval in
# simulated seconds depends on the ratio between QEMU's clock and the
# host's -- which aliases a periodic quantity against an interval
# nobody controls.  Writing the phase makes each sample an exact point
# on the orbit and the sweep independent of every clock.
mags, n = [], 24
for i in range(n):
    b.send("echo phase %d >'#P/orbit.ctl'" % (i * 360000 // n), settle=0.8)
    f = ints(b.kv("#P/orbit", settle=0.9), "field")
    mags.append(int(math.sqrt(sum(v*v for v in f))))
# 494mG is the dipole's polar value and this orbit does not reach it:
# at 51.6 degrees of inclination the sub-satellite point never passes
# over the geomagnetic pole, so the maximum along the track is lower.
# What matters is that the magnitude varies by a large factor at all --
# the first version of this simulation had one magnitude for ever.
check("field magnitude", min(mags) <= 260 and max(mags) >= 400,
      "%d..%d mG at %d points round one orbit; 247 is the magnetic"
      " equator and a 51.6 degree track tops out below the 494 of the"
      " pole" % (min(mags), max(mags), n))

# Eclipse at beta zero is 38 per cent of the orbit: sin(theta) = Re/r
# is 0.927, a half-angle of 68 degrees, so 136 of 360.
b.send("echo beta 0 >'#P/orbit.ctl'")
dark, n = 0, 72
for i in range(n):
    b.send("echo phase %d >'#P/orbit.ctl'" % (i * 360000 // n), settle=0.8)
    dark += int(b.kv("#P/orbit", settle=0.9)["eclipse"][0])
frac = 100.0 * dark / n
check("eclipse fraction", 33 <= frac <= 43,
      "%.0f%% of %d points round the orbit in shadow at beta 0"
      " (the geometry says 38%%)" % (frac, n))
b.send("echo beta 20000 >'#P/orbit.ctl'")
b.send("echo timescale 1 >'#P/orbit.ctl'")

# --------------------------------------------------------------- rotate
#
# A pure spin with no torque: the attitude must turn at exactly the
# commanded rate.  This is the check the quaternion renormalisation
# cannot make, and the integer truncation that used to stop rotation
# below about 1.2 deg/s would fail it outright.
#
# THE ANGLE IS ACCUMULATED OVER CONSECUTIVE SAMPLES, not measured in
# one go, because a quaternion gives an angle modulo 360 degrees and
# its scalar part cannot tell 60 from 300.  One host round trip is
# about a second, which under QEMU is seven seconds of board time, so
# at 10 deg/s a single interval is already seventy degrees and at the
# 30 the controller sees it would be past the ambiguity.  Sampling as
# fast as the console allows keeps every step well inside half a turn
# and the sum is unambiguous.
#
# 1 deg/s is in the test for its own reason: the quaternion update used
# to divide to zero below about 1.2, so a satellite turning slowly did
# not turn at all.  That is the regime a settled detumble hands over in.
for rate in (10, 1):
    b.send("echo still >'#P/imu.ctl'")
    b.send("echo 0 0 0 >'#P/torque'")
    b.send("echo spin 0 0 %d >'#P/imu.ctl'" % rate)
    prev = None
    turned = 0.0
    t0 = t1 = None
    worststep = 0.0
    for k in range(10):
        d = b.kv("#P/imu.ctl", settle=1.0)
        q = tuple(v / 10000.0 for v in ints(d, "quaternion"))
        t1 = int(d["integrated"][0])
        if prev is not None:
            rel = qmul((prev[0], -prev[1], -prev[2], -prev[3]), q)
            step = qangle(rel)
            turned += step
            worststep = max(worststep, step)
        else:
            t0 = t1
        prev = q
    dt = (t1 - t0) / 1000.0
    want = rate * dt
    err = abs(turned - want) / max(1.0, want)
    check("spin %d deg/s" % rate, err < 0.03 and worststep < 150,
          "turned %.1f deg in %.1fs of model time, wanted %.1f (%.1f%%,"
          " worst single step %.0f deg of the 180 a quaternion can tell)"
          % (turned, dt, want, 100 * err, worststep))

# ---------------------------------------------------------------- rates
#
# A fixed dipole from rest: the rate must change at m x B / I.  The
# field is taken from the model's own report so the check is of the
# torque law and the integration, not of the orbit.
b.send("echo still >'#P/imu.ctl'")
b.send("echo 0 0 0 >'#P/torque'")
b.send("echo inertia 33333 33333 6667 >'#P/imu.ctl'")
b.send("echo 200 0 0 >'#P/torque'")
a = b.kv("#P/imu.ctl")
b.sleep(4)
c = b.kv("#P/imu.ctl")
dt = (int(c["integrated"][0]) - int(a["integrated"][0])) / 1000.0
f0, f1 = ints(a, "field"), ints(c, "field")
w0, w1 = ints(a, "spin"), ints(c, "spin")
iyy = ints(a, "inertia")[1]
# T_y = (mz Bx - mx Bz)/10 nN.m, averaged over the interval
ty = (-200 * (f0[2] + f1[2]) / 2.0) / 10.0
want = ty * dt * 57296 / (iyy * 1e6) * 1000     # milli-deg/s
got = w1[1] - w0[1]
err = abs(got - want) / max(1.0, abs(want))
check("m x B about y", err < 0.15,
      "%d mdeg/s in %.2fs, m x B / I says %.0f (%.0f%%)"
      % (got, dt, want, 100 * err))

# ----------------------------------------------------------- conserving
#
# Torquers off and a three-axis tumble.  Two things must happen at once
# and the old integrator managed neither: the BODY RATE must move,
# because the momentum is fixed in the inertial frame and the body is
# turning underneath it, and |L| must not, because nothing is pushing.
#
# The momentum is read from the model rather than rebuilt from the rate
# and a tensor this file holds a copy of -- a check that recomputes the
# invariant from the same numbers the model derives is checking its own
# arithmetic.  The only torque left is the gravity gradient, about 122
# nano-newton-metres against 8.2 milli-newton-metre-seconds of
# momentum, which is a quarter of a per cent in three minutes.
#
# Explicit Euler on the body-frame equation grew the energy 183 per cent
# and |L| 89 per cent here.  Nothing else in the model complained.
b.send("echo still >'#P/imu.ctl'")
b.send("echo 0 0 0 >'#P/torque'")
b.send("echo tumble >'#P/imu.ctl'")


def mag(v):
    return math.sqrt(sum(float(x) * x for x in v))


a = b.kv("#P/imu.ctl")
I = ints(a, "inertia")
w0 = ints(a, "spin")
L0 = mag(ints(a, "momentum"))
E0 = sum(I[i] * w0[i] * w0[i] for i in range(3)) / 2.0
worstL = worstE = 0.0
moved = [0, 0, 0]
for i in range(6):
    b.sleep(20)
    c = b.kv("#P/imu.ctl")
    w = ints(c, "spin")
    L = mag(ints(c, "momentum"))
    E = sum(I[i] * w[i] * w[i] for i in range(3)) / 2.0
    worstL = max(worstL, abs(L - L0) / L0)
    worstE = max(worstE, abs(E - E0) / E0)
    moved = [max(moved[k], abs(w[k] - w0[k])) for k in range(3)]
dt = (int(c["integrated"][0]) - int(a["integrated"][0])) / 1000.0
check("free-body |L|", worstL < 0.02,
      "drifts %.3f%% over %.0fs of model time" % (100 * worstL, dt))
# 2 per cent against a measured 0.29 at this step length over 82
# seconds.  Before the rate was taken at the middle of the step it was
# 39.7, and before the momentum was held inertially it was 183.
check("free-body energy", worstE < 0.02,
      "drifts %.3f%% over %.0fs" % (100 * worstE, dt))
# WHAT MUST MOVE AND WHAT MUST NOT, and getting this round the wrong
# way failed a correct model.  The default tensor is axisymmetric --
# Ixx == Iyy -- and for such a body omega_z is a CONSTANT of the free
# motion while omega_x and omega_y rotate about the symmetry axis.  A
# check that asked all three to move was asking for something the
# physics forbids, and reported "the z rate moved 0" as a fault.
check("precession happens", moved[0] > 500 and moved[1] > 500,
      "the body rate moved %d %d %d mdeg/s from %d %d %d with nothing"
      " pushing" % tuple(moved + list(w0)))
check("symmetry axis holds", moved[2] * 20 < abs(w0[2]),
      "omega_z moved %d mdeg/s of %d, and for Ixx == Iyy it is a"
      " constant of the motion" % (moved[2], w0[2]))

# ------------------------------------------------------------- battery
#
# Terminal volts are the open-circuit curve less the drop across 80
# milliohms, and the charge falls at the coulomb rate.  A 2600mAh pack
# at 500mA loses 1.9 per cent of its charge a minute.
#
# MEASURED IN ECLIPSE, so that the only current is the one being
# commanded.  The panels make whatever the attitude gives them and the
# attitude is tumbling, so predicting the charge lost from the net
# current at the two ENDPOINTS was 21 per cent out -- and it was the
# prediction that was wrong, not the counter.  At beta zero the
# anti-sun point is half way round the orbit from the ascending node,
# the shadow spans 136 degrees of it, and 290 seconds is 18; so
# starting at the middle of the eclipse keeps it there for the whole
# measurement.  The check asserts solar is zero rather than assuming
# it, because a premise that is not tested is not a premise.
b.send("echo beta 0 >'#P/orbit.ctl'")
b.send("echo phase 180000 >'#P/orbit.ctl'")
b.send("echo drain 500 >'#P/power.ctl'")
a = b.kv("#P/power", settle=4.0)
pa = float(b.kv("#P/orbit")["phase"][0])
b.sleep(240)
c = b.kv("#P/power", settle=4.0)
pc = float(b.kv("#P/orbit")["phase"][0])
check("terminal volts",
      abs((int(c["open"][0]) - int(c["volts"][0])) - 40) <= 12,
      "open %s, terminal %s: 500mA through 80 milliohms is 40mV"
      % (c["open"][0], c["volts"][0]))
check("in eclipse throughout", ints(a, "solar")[0] == 0
      and ints(c, "solar")[0] == 0 and ints(c, "eclipse")[0] == 1,
      "the panels made %s then %s mA, eclipse %s"
      % (a["solar"][0], c["solar"][0], c["eclipse"][0]))
# The orbit's phase is the clock here, for the same reason as above and
# because it is computed in closed form from the same ticks.  A 2600mAh
# pack is 9360000 milliamp-seconds, so 500mA is 53.4 per mille an hour.
dt = (pc - pa) / 360.0 * float(b.kv("#P/orbit")["period"][0])
want = ints(a, "draw")[0] * dt / 9360000.0 * 1000.0
got = int(a["soc"][0]) - int(c["soc"][0])
err = abs(got - want) / max(1.0, want)
# 15 per cent, because soc is reported as an integer per mille and the
# drop being measured is fifteen of them: the quantisation alone is
# six and a half per cent of the answer.
check("coulomb count", err < 0.15,
      "state of charge fell %d per mille over %.0fs of orbit time;"
      " %smA out of 2600mAh says %.1f (%.0f%%)"
      % (got, dt, a["draw"][0], want, 100 * err))

b.close()
if fails:
    print("SIMCHECK-FAILED " + " ".join(fails))
    sys.exit(1)
print("SIMCHECK-OK the orbit sweeps, the attitude turns at the rate it")
print("reports, a dipole gives m x B / I, a free body keeps its momentum")
print("and the pack counts coulombs")
