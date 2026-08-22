#!/usr/bin/env python3
"""Boot the Osprey EFI ISO under QEMU and drive its serial console.

The kernel's console is on the first serial port, so QEMU is run with
-serial stdio and the guest is spoken to through the pipe.  Expectations
are (pattern, reply) pairs applied in order: each pattern is a regular
expression matched against the output seen so far, and the reply, if any,
is typed at the guest.

usage: scripts/osprey-console.py [-d disk] [-t secs] [-l log]
                                 [-e pattern[=reply]] ... [-u pattern]
                                 [-c command] ...

-e adds an expectation, -u sets the pattern that means a successful boot,
and -c runs a shell command once the -u pattern has matched.
"""

import argparse, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
	ap = argparse.ArgumentParser()
	ap.add_argument('-i', '--iso', default=os.path.join(ROOT, '.qemu/osprey-efi.iso'))
	ap.add_argument('-d', '--disk', default=None)
	ap.add_argument('-t', '--timeout', type=float, default=120.0)
	ap.add_argument('-l', '--log', default=os.path.join(ROOT, '.qemu/console.log'))
	ap.add_argument('-m', '--memory', default='1024')
	ap.add_argument('-p', '--cpus', default='1')
	ap.add_argument('-e', '--expect', action='append', default=[])
	ap.add_argument('-u', '--until', default=None)
	ap.add_argument('-c', '--command', action='append', default=[])
	ap.add_argument('-q', '--quiet', action='store_true')
	ap.add_argument('-n', '--net', default=None,
		help='attach a nic, e.g. e1000')
	ap.add_argument('-2', '--serial2', default=None,
		help='a second serial port, e.g. unix:/tmp/com2,server,nowait')
	a = ap.parse_args()

	qemu = [
		'qemu-system-x86_64', '-machine', 'q35', '-m', a.memory, '-smp', a.cpus,
		'-drive', 'if=pflash,format=raw,unit=0,readonly=on,file=%s/.qemu/edk2-code.fd' % ROOT,
		'-drive', 'if=pflash,format=raw,unit=1,file=%s/.qemu/edk2-vars-run.fd' % ROOT,
		'-cdrom', a.iso,
		'-display', 'none', '-monitor', 'none', '-no-reboot',
		'-serial', 'stdio',
	]
	if a.serial2:
		qemu += ['-serial', a.serial2]
	if a.net:
		qemu += ['-netdev', 'user,id=n0', '-device', a.net + ',netdev=n0']
	if a.disk:
		qemu += [
			'-drive', 'file=%s,format=qcow2,if=none,id=hd0' % a.disk,
			'-device', 'ich9-ahci,id=ahci',
			'-device', 'ide-hd,drive=hd0,bus=ahci.0',
		]

	subprocess.check_call(['cp', '%s/.qemu/edk2-vars.fd' % ROOT,
		'%s/.qemu/edk2-vars-run.fd' % ROOT])

	steps = []
	for e in a.expect:
		pat, sep, reply = e.partition('=')
		steps.append((re.compile(pat.encode(), re.M), reply if sep else None))
	until = re.compile(a.until.encode(), re.M) if a.until else None
	cmds = list(a.command)

	log = open(a.log, 'wb')
	p = subprocess.Popen(qemu, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
		stderr=subprocess.DEVNULL, bufsize=0)
	os.set_blocking(p.stdout.fileno(), False)

	def send(s):
		p.stdin.write(s.encode() + b'\r')
		p.stdin.flush()

	esc = re.compile(rb'\x1b\[[0-9;=?]*[a-zA-Z]')
	seen = b''
	deadline = time.time() + a.timeout
	status = 1
	try:
		while time.time() < deadline:
			b = p.stdout.read(4096)
			if b is None:
				time.sleep(0.05)
				continue
			if b == b'':
				break
			log.write(b); log.flush()
			if not a.quiet:
				sys.stdout.write(b.decode('utf-8', 'replace'))
				sys.stdout.flush()
			seen = esc.sub(b'', seen + b)[-65536:]

			# expectations are consumed in order, so a pattern that
			# also appears earlier in the boot cannot fire twice.
			if steps:
				pat, reply = steps[0]
				if pat.search(seen):
					steps.pop(0)
					seen = b''
					deadline = time.time() + a.timeout
					if reply is not None:
						send(reply)
					continue

			if not steps and until is not None and until.search(seen):
				seen = b''
				deadline = time.time() + a.timeout
				if cmds:
					send(cmds.pop(0))
					continue
				status = 0
				break
	finally:
		p.kill()
		p.wait()
		log.close()
	if status != 0:
		sys.stderr.write('\nosprey-console: timed out waiting for %r\n' %
			(a.until or 'end of output'))
	return status

sys.exit(main())
