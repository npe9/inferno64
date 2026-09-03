module Md5sum

// appl/cmd/md5sum.b in Ember: MD5 digests through the keyring library

import sys "sys"
import draw "draw"
import kr "keyring"

var stderr ref sys.FD

func init(ctxt ref draw.Context, argv list string) {
	stderr = sys.fildes(2)
	a := tl(argv)
	err := 0
	if a != nil {
		for ; a != nil; a = tl(a) {
			s := hd(a)
			fd := sys.open(s, sys.OREAD)
			if fd == nil {
				sys.fprint(stderr, "md5sum: cannot open %s: %r\n", s)
				err = 1
			} else {
				err |= md5sum(fd, s)
			}
		}
	} else {
		err |= md5sum(sys.fildes(0), "")
	}
	if err != 0 {
		raise "fail:error"
	}
}

func md5sum(fd ref sys.FD, file string) int {
	err := 0
	buf := [sys.ATOMICIO]byte
	var state ref kr.DigestState
	nbytes := big(0)
	nr := 0
	for {
		nr = sys.read(fd, buf, len(buf))
		if nr <= 0 {
			break
		}
		state = kr.md5(buf, nr, nil, state)
		nbytes += big(nr)
	}
	if nr < 0 {
		sys.fprint(stderr, "md5sum: error reading %s: %r\n", file)
		err = 1
	}
	digest := [kr.MD5dlen]byte
	kr.md5(buf, 0, digest, state)
	sum := ""
	for i := range digest {
		sum += sys.sprint("%2.2ux", int(digest[i]))
	}
	if file != nil {
		sys.print("%s\t%s\n", sum, file)
	} else {
		sys.print("%s\n", sum)
	}
	return err
}
