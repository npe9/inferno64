#!/usr/bin/env python3
"""Boot p9pair and drive its user-space i8042 keyboard driver.

The exokernel split for a legacy port device.  The kernel grants the p9
personality the i8042 ports (ReqIoport, a per-process TSS I/O-permission
bitmap) and routes IRQ1 to it as a bare notification (ReqKbdnotify); its
handler does not read the scancode.  The driver (os/osprey/cmd/p9/p9kbd.c),
woken through the container semaphore, reads each scancode off port 0x60
with its own inb - no scancode through the kernel.  This injects keys over
QMP and checks the driver prints their Set-1 scancodes.
"""
import os, re, socket, subprocess, sys, time, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
env = dict(os.environ, PATH=os.path.join(ROOT, 'MacOSX/arm64/bin') + ':' + os.environ['PATH'])

def esc(s):
    return re.sub(rb'\x1b\[[0-9;=?]*[a-zA-Z]', b'', s)

def main():
    r = subprocess.run(['mk', 'CONF=p9pair', '9p9pair'], cwd='os/osprey/pc64',
                       env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print('FAIL 9p9pair did not build'); print(r.stderr[-800:]); return 1
    subprocess.run(['sh', 'scripts/mkosprey-efi-iso.sh'],
                   env=dict(env, OSPREY_KERNEL=os.path.join(ROOT, 'os/osprey/pc64/9p9pair')),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    qmp = '/tmp/osprey-kbd.qmp'
    try: os.unlink(qmp)
    except OSError: pass
    subprocess.check_call(['cp', '.qemu/edk2-vars.fd', '.qemu/edk2-vars-run.fd'])
    qemu = ['qemu-system-x86_64', '-machine', 'q35', '-m', '1024', '-smp', '2',
            '-drive', 'if=pflash,format=raw,unit=0,readonly=on,file=%s/.qemu/edk2-code.fd' % ROOT,
            '-drive', 'if=pflash,format=raw,unit=1,file=%s/.qemu/edk2-vars-run.fd' % ROOT,
            '-cdrom', '.qemu/osprey-efi.iso', '-display', 'none', '-monitor', 'none',
            '-no-reboot', '-serial', 'stdio',
            '-netdev', 'user,id=n0', '-device', 'e1000,netdev=n0',
            '-qmp', 'unix:%s,server,nowait' % qmp]
    p = subprocess.Popen(qemu, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, bufsize=0)
    os.set_blocking(p.stdout.fileno(), False)
    buf = bytearray()

    def pump(timeout, stop=None):
        dl = time.time() + timeout
        while time.time() < dl:
            b = p.stdout.read(4096)
            if b:
                buf.extend(b)
                if stop and stop.encode() in esc(bytes(buf)):
                    return True
            else:
                time.sleep(0.03)
        return False

    # the keys to press and the Set-1 make codes the driver must read back
    keys = [('a', 0x1e), ('b', 0x30), ('c', 0x2e), ('spc', 0x39)]
    up = pump(90, stop='user-space i8042 driver up')
    if up:
        pump(1)
        s = socket.socket(socket.AF_UNIX); s.connect(qmp)
        f = s.makefile('rw'); f.readline()
        f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
        for k, _ in keys:
            f.write(json.dumps({"execute": "send-key",
                "arguments": {"keys": [{"type": "qcode", "data": k}]}}) + "\n")
            f.flush(); f.readline()
            pump(0.4)
        pump(4)
    p.kill(); p.wait()
    t = esc(bytes(buf)).decode('utf-8', 'replace')

    results = [
        ("the user-space i8042 driver comes up on the microkernel", up),
    ]
    for k, mk in keys:
        make = ('scancode %#x read from port 0x60 in user space\n' % mk) in t
        rel = ('scancode %#x read from port 0x60 in user space (release)' % (mk | 0x80)) in t
        results.append(("key '%s' - the driver read make %#04x and release %#04x by inb"
                        % (k, mk, mk | 0x80), make and rel))

    ok = True
    for name, good in results:
        print(('ok  ' if good else 'FAIL') + '  ' + name)
        ok = ok and good
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1

sys.exit(main())
