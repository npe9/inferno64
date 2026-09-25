#!/usr/bin/env python3
#
# Exercise board.py's LilStream against a booted kernel, with no board.
#
# LilStream exists to do the one thing Stream structurally cannot: send a
# liveness marker while the ctl file is held open.  Stream holds the file
# with "cat >file", inside which a marker would be written to the file
# rather than run, so board.py gave up asking whether the board was alive
# and infers it instead -- from whether a reply repeated, and from echoes
# that keep coming back from the uart interrupt handler long after the
# shell is dead.  A class written to fix that and never run against a
# kernel would be a worse thing than the workaround.
#
# qemu is given "-serial pty", which it prints the path of, and board.py
# is aimed at that path with INFERNO_BOARD_PORT.  Setting it also stops
# board.py looking for a screen session, which matters: a test that found
# the bench's screen instead would type these commands at the physical
# board.
#
#	lilstream.py <qemu-system-arm> [kernel]
#
import os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))


def boot(qemu, kernel):
    """Start the kernel with its console on a pty, and return (proc, path)."""
    p = subprocess.Popen(
        [qemu, "-M", "netduinoplus2,radio=on", "-nographic",
         "-serial", "null", "-serial", "pty", "-kernel", kernel],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # qemu says "char device redirected to /dev/ttys004 (label serial1)"
    end = time.time() + 20
    while time.time() < end:
        line = p.stdout.readline()
        if not line:
            break
        m = re.search(r"redirected to (\S+)", line)
        if m:
            return p, m.group(1)
    p.kill()
    sys.exit("lilstream: qemu never said which pty it took")


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: lilstream.py <qemu-system-arm> [kernel]")
    qemu = sys.argv[1]
    kernel = sys.argv[2] if len(sys.argv) > 2 \
        else "os/inferno/stm32f407/istm32f407"

    proc, pty = boot(qemu, kernel)
    print("console on %s" % pty)
    os.environ["INFERNO_BOARD_PORT"] = pty
    sys.path.insert(0, HERE)
    import board
    bad = 0
    try:
        time.sleep(14)              # the kernel reaching its prompt
        c = board.Console(os.environ.get("CLAUDE_JOB_DIR", "/tmp") + "/tmp")
        c.run("bind -a '#W' /dev", wait=20)

        st = c.lilstream()
        if not st.ok:
            print("  FAILED  lilstream would not start")
            return 1
        print("  ok      entered lil and opened the ctl file")

        # The whole point: a marker WHILE the file is open.  Stream
        # cannot do this at all, so there is nothing to compare against
        # -- the pass condition is simply that it answers.
        if st.alive():
            print("  ok      answered a marker with the ctl file still open")
        else:
            print("  FAILED  no answer to a marker with the file open")
            bad += 1

        for line in ("rate 9600", "bw 50000", "freq 915000000"):
            r = st.send(line, wait=25)
            if r is None:
                print("  FAILED  %-16s no reply" % line)
                bad += 1
            else:
                print("  ok      %-16s written" % line)

        # And a marker again afterwards, because the interesting failure
        # is a stream that stops running what is typed halfway through
        # and keeps echoing it.
        if st.alive():
            print("  ok      still answering after three writes")
        else:
            print("  FAILED  stopped answering after the writes")
            bad += 1

        # Did the writes land?  Read the part back through lil, which is
        # the other thing a cat cannot do: inside it every line is data.
        out = st.stmt('print(slurp("/dev/radio0/stats"))', wait=25) or ""
        if "rate 9600" in out and "freq 915000000" in out:
            print("  ok      the part shows rate 9600 and freq 915000000")
        else:
            print("  FAILED  stats does not show what was written")
            print("          %s" % out.replace("\n", " | ")[:200])
            bad += 1

        st.close()
        # Leaving lil must leave a usable shell, because close() types a
        # ^D and this tree has a note about a ^D fallback killing one.
        if c.mark("AFTER%d" % (int(time.time()) % 1000)):
            print("  ok      the shell still runs what is typed after close()")
        else:
            print("  FAILED  no shell after leaving lil")
            bad += 1
    finally:
        proc.kill()
    print()
    print("LILSTREAM-OK" if bad == 0 else "LILSTREAM-FAILED %d" % bad)
    return bad


if __name__ == "__main__":
    sys.exit(main())
