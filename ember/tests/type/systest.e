module Systest

import sys "sys"

// the full sys.ei against the real $Sys builtin: every function
// called here has its signature checked at link time, and Dir's
// field list (with the nested Qid value) is signed into stat, fstat
// and dirread.  stat/fstat of a known file, dirread of a directory,
// tokenize, dup/pipe/read/write, millisec/sleep, and a raw
// read-into-bytes converted with string().

func init() {
	ok, d := sys.stat("/ember/tests/type/hello.e")
	sys.print("stat=%d name=%s length=%bd isdir=%d\n", ok, d.name, d.length, (d.mode & sys.DMDIR) != 0)
	ok, d = sys.stat("/ember/tests/type")
	sys.print("dir isdir=%d qtype=%d\n", (d.mode & sys.DMDIR) != 0, d.qid.qtype & sys.QTDIR)
	bad, _ := sys.stat("/no/such")
	sys.print("bad=%d\n", bad)

	fd := sys.open("/ember/tests/type", sys.OREAD)
	if fd == nil {
		sys.print("open failed\n")
		return
	}
	n := 0
	found := 0
	for {
		cnt, dirs := sys.dirread(fd)
		if cnt <= 0 {
			break
		}
		for i := 0; i < cnt; i++ {
			n++
			if dirs[i].name == "hello.e" {
				found = 1
			}
		}
	}
	sys.print("entries>20=%d found=%d\n", n > 20, found)

	f := sys.open("/ember/tests/type/hello.e", sys.OREAD)
	buf := [64]byte{}
	r := sys.read(f, buf, len(buf))
	sys.print("read=%d first=%s\n", r > 0, string(buf[0:12]))
	fok, fd2 := sys.fstat(f)
	sys.print("fstat=%d same=%d path=%s\n", fok, fd2.length == d.length || fd2.name == "hello.e", sys.fd2path(f))

	cnt, toks := sys.tokenize("a b  c", " ")
	sys.print("tokens=%d first=%s\n", cnt, hd(toks))

	// a pipe: write one end, read the other
	fds := [2]ref sys.FD{nil, nil}
	if sys.pipe(fds) < 0 {
		sys.print("pipe failed\n")
		return
	}
	sys.fprint(fds[0], "through the pipe")
	pbuf := [32]byte{}
	pn := sys.read(fds[1], pbuf, len(pbuf))
	sys.print("pipe=%s\n", string(pbuf[0:pn]))

	t0 := sys.millisec()
	sys.sleep(20)
	sys.print("slept=%d\n", sys.millisec() - t0 >= 15)

	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
}
