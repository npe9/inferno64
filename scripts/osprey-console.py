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

import argparse, json, os, re, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
	ap = argparse.ArgumentParser()
	ap.add_argument('-i', '--iso', default=os.path.join(ROOT, '.qemu/osprey-efi.iso'))
	ap.add_argument('-b', '--build', action='store_true',
		help='build the iso first, with the root device answered')
	ap.add_argument('-d', '--disk', default=None)
	ap.add_argument('-t', '--timeout', type=float, default=120.0)
	ap.add_argument('-l', '--log', default=os.path.join(ROOT, '.qemu/console.log'))
	ap.add_argument('-m', '--memory', default='1024')
	ap.add_argument('-p', '--cpus', default='1')
	ap.add_argument('-e', '--expect', action='append', default=[])
	ap.add_argument('-u', '--until', default=None)
	ap.add_argument('-c', '--command', action='append', default=[])
	ap.add_argument('-q', '--quiet', action='store_true')
	ap.add_argument('-S', '--snapshot', action='store_true',
		help='write nowhere: the disk is left as it was, so two of\n'
		     'these may share one image')
	ap.add_argument('-n', '--net', default=None,
		help='attach a nic, e.g. e1000')
	ap.add_argument('--blk', default=None,
		help='attach this raw image as a virtio 1.0 block device (legacy off)')
	ap.add_argument('--netdev', default='user,id=n0',
		help='how the nic is attached, e.g. socket,id=n0,listen=:1234')
	ap.add_argument('-2', '--serial2', default=None,
		help='a second serial port, e.g. unix:/tmp/com2,server,nowait')
	ap.add_argument('--shot', default=None,
		help='screendump to this file (ppm) once the run reaches its end')
	ap.add_argument('--click', default=None,
		help='before the shot, move the mouse and hold this button down '
		     '(left|middle|right), or "move" to only move; needs --shot')
	ap.add_argument('--input', default=None,
		help='before the shot, run a sequence over QMP/serial; comma-'
		     'separated ops m:DX:DY (relative move), d:BUTTON / u:BUTTON '
		     '(button down/up), s:SECONDS (pause), k:TEXT (type TEXT then '
		     'Enter on the serial line); needs --shot')
	ap.add_argument('--shot-on', default=None,
		help='take the shot when this pattern appears rather than when '
		     'the commands run out; lets a foreground program (rio) own '
		     'the console while the shot still fires')
	ap.add_argument('--display', default='none',
		help='qemu display backend; "cocoa" opens a live window on macOS '
		     'you can drive with the mouse (default none, headless)')
	ap.add_argument('--hold', action='store_true',
		help='after the commands run, keep qemu running rather than '
		     'killing it, so a live --display window stays interactive')
	a = ap.parse_args()

	if a.build:
		# The harness answers no prompts before the shell, so the iso it
		# boots must have the root device in its plan9.ini.  An iso built
		# without it stops at bootargs and every check fails, which reads
		# exactly like a broken kernel; building it here is what stops
		# that from happening again.
		env = dict(os.environ, OSPREY_NOBOOTPROMPT='local!/dev/sdE0/fs')
		subprocess.run(['sh', os.path.join(ROOT, 'scripts/mkosprey-efi-iso.sh'),
			a.iso], env=env, check=True,
			stdout=subprocess.DEVNULL)

	qemu = [
		'qemu-system-x86_64', '-machine', 'q35', '-m', a.memory, '-smp', a.cpus,
		'-drive', 'if=pflash,format=raw,unit=0,readonly=on,file=%s/.qemu/edk2-code.fd' % ROOT,
		'-drive', 'if=pflash,format=raw,unit=1,file=%s/.qemu/edk2-vars-run.fd' % ROOT,
		'-cdrom', a.iso,
		'-display', a.display, '-monitor', 'none', '-no-reboot',
		'-serial', 'stdio',
	]
	qmpsock = None
	if a.shot:
		qmpsock = a.shot + '.qmp'
		try: os.unlink(qmpsock)
		except OSError: pass
		qemu += ['-qmp', 'unix:%s,server,nowait' % qmpsock]
	if a.serial2:
		qemu += ['-serial', a.serial2]
	if a.net:
		qemu += ['-netdev', a.netdev, '-device', a.net + ',netdev=n0']
	if a.blk:
		qemu += ['-drive', 'file=%s,format=raw,if=none,id=blk0' % a.blk,
			'-device', 'virtio-blk-pci,drive=blk0,disable-legacy=on,disable-modern=off']
	if a.snapshot:
		qemu += ['-snapshot']
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
	shot_on = re.compile(a.shot_on.encode(), re.M) if a.shot_on else None
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
	lastout = time.time()
	retries = 0		# boots restarted because the loader stalled reading the kernel
	try:
		while time.time() < deadline:
			b = p.stdout.read(4096)
			if b is None:
				# The loader now and then prints its configuration and
				# then nothing: it stalled reading the kernel off the
				# CD (a test-bench flake of firmware and loader, not the
				# kernel's).  Start the boot over, up to twice, rather
				# than time the whole run out.
				if retries < 2 and time.time() - lastout > 30 \
						and b'bootfile=' in seen and not re.search(rb'^boot\r?$', seen, re.M):
					retries += 1
					log.write(b'\n[osprey-console: the loader stalled; restarting the boot]\n'); log.flush()
					p.kill(); p.wait()
					seen = b''
					lastout = time.time()
					deadline = time.time() + a.timeout
					p = subprocess.Popen(qemu, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
						stderr=subprocess.DEVNULL, bufsize=0)
					os.set_blocking(p.stdout.fileno(), False)
					continue
				time.sleep(0.05)
				continue
			if b == b'':
				break
			log.write(b); log.flush()
			if not a.quiet:
				sys.stdout.write(b.decode('utf-8', 'replace'))
				sys.stdout.flush()
			seen = esc.sub(b'', seen + b)[-65536:]

			lastout = time.time()

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
				if cmds:
					seen = b''
					deadline = time.time() + a.timeout
					send(cmds.pop(0))
					continue
				elif shot_on is None:
					seen = b''
					status = 0
					break
				# else: wait for shot_on while the foreground program runs

			if not steps and shot_on is not None and not cmds \
					and shot_on.search(seen):
				status = 0
				break
		if a.shot and status == 0:
			try:
				qs = socket.socket(socket.AF_UNIX); qs.connect(qmpsock)
				qf = qs.makefile('rw'); qf.readline()
				qf.write(json.dumps({"execute":"qmp_capabilities"})+chr(10)); qf.flush(); qf.readline()
				def qmp(cmd, args):
					qf.write(json.dumps({"execute":cmd,"arguments":args})+chr(10))
					qf.flush(); qf.readline()
				def mrel(dx, dy):
					# PS/2 deltas are one signed byte; send in small steps
					while dx or dy:
						sx = max(-100, min(100, dx)); dx -= sx
						sy = max(-100, min(100, dy)); dy -= sy
						qmp("input-send-event", {"events":[
							{"type":"rel","data":{"axis":"x","value":sx}},
							{"type":"rel","data":{"axis":"y","value":sy}}]})
						time.sleep(0.03)
				def mbtn(button, down):
					qmp("input-send-event", {"events":[
						{"type":"btn","data":{"button":button,"down":down}}]})
					time.sleep(0.1)
				# optionally drive the mouse before the shot: move a little,
				# then hold a button down so a menu that opens on press shows.
				if a.click:
					mrel(240, 160)
					if a.click != 'move':
						mbtn(a.click, True)
						time.sleep(0.4)
				# a general mouse sequence for multi-step interactions
				if a.input:
					for op in a.input.split(','):
						f = op.split(':')
						if f[0] == 'm':   mrel(int(f[1]), int(f[2]))
						elif f[0] == 'd': mbtn(f[1], True)
						elif f[0] == 'u': mbtn(f[1], False)
						elif f[0] == 's': time.sleep(float(f[1]))
						elif f[0] == 'k': send(':'.join(f[1:]))
						elif f[0] == 'K':
							qmp("send-key", {"keys":[
								{"type":"qcode","data":f[1]}]})
							time.sleep(0.08)
				qf.write(json.dumps({"execute":"screendump","arguments":{"filename":a.shot}})+chr(10)); qf.flush(); qf.readline()
				qs.close()
			except Exception as e:
				sys.stderr.write('screendump failed: %s\n' % e)
		if a.hold and status == 0:
			# keep qemu alive and its serial drained so a live --display
			# window stays interactive until it is closed
			os.set_blocking(p.stdout.fileno(), True)
			while True:
				b = p.stdout.read(4096)
				if not b:
					break
				log.write(b); log.flush()
				if not a.quiet:
					sys.stdout.write(b.decode('utf-8', 'replace'))
					sys.stdout.flush()
	finally:
		p.kill()
		p.wait()
		log.close()
	if status != 0:
		sys.stderr.write('\nosprey-console: timed out waiting for %r\n' %
			(a.until or 'end of output'))
	return status

sys.exit(main())
