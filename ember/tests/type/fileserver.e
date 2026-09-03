module Fileserver

import sys "sys"

// a file served from a process: sys.file2chan on a directory bound
// from the srv device, requests received with alt on the FileIO adt's
// two channels of four-field tuples (offset, count/data, fid, reply
// channel), replies sent as tuples with nil components on the reply
// channels, and the file read back through the ordinary sys.open/
// sys.read.  the server exits after two requests (the read and the
// EOF read) so no process is left blocked.

func serve(fio ref sys.FileIO, done chan int) {
	content := []byte("served\n")
	for n := 0; n < 2; {
		alt {
		case r := <-fio.read:
			off, cnt, fid, rc := r
			if rc == nil {
				break
			}
			if int(off) >= len(content) {
				rc <- (nil, nil)
			} else {
				rc <- (content[int(off):], nil)
			}
			n++
		case w := <-fio.write:
			off, data, fid, wc := w
			if wc == nil {
				break
			}
			wc <- (len(data), nil)
			n++
		}
	}
	done <- 1
}
func init() {
	if sys.bind("#s", "/tmp", sys.MREPL) < 0 {
		sys.print("bind failed\n")
		return
	}
	fio := sys.file2chan("/tmp", "served")
	if fio == nil {
		sys.print("file2chan failed\n")
		return
	}
	done := chan int
	spawn serve(fio, done)
	fd := sys.open("/tmp/served", sys.OREAD)
	if fd == nil {
		sys.print("open failed\n")
		return
	}
	buf := [64]byte
	n := sys.read(fd, buf, len(buf))
	sys.print("read %d: %s", n, string(buf[0:n]))
	n2 := sys.read(fd, buf, len(buf))
	sys.print("eof=%d\n", n2)
	<-done
	sys.print("done\n")
}
