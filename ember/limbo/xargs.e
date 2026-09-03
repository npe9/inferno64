module Xargs

// appl/cmd/xargs.b in Ember: apply a command to argument lists read
// from standard input.  The command module is loaded through the
// Command interface at run time.

import sys "sys"
import draw "draw"
import command "command"
import bufio "bufio"

var stderr ref sys.FD

func usage() {
	sys.fprint(stderr, "Usage: xargs command [command args] <[list of last command arg]\n")
}

func init(ctxt ref draw.Context, args list string) {
	stderr = sys.fildes(2)
	if args != nil {
		args = tl(args)
	}
	if args == nil {
		usage()
		return
	}
	cmd := hd(args)
	args = tl(args)
	if len(cmd) < 4 || cmd[len(cmd) - 4:] != ".dis" {
		cmd += ".dis"
	}
	sh := load command cmd
	if sh == nil {
		cmd = "/dis/" + cmd
		sh = load command cmd
	}
	if sh == nil {
		sys.fprint(stderr, "xargs: can't load %s: %r\n", cmd)
		exit()
	}

	stdin := sys.fildes(0)
	if stdin == nil {
		sys.fprint(stderr, "xargs: no standard input\n")
		exit()
	}
	b := bufio.fopen(stdin, bufio.OREAD)
	for {
		t := b.gets('\n')
		if t == nil {
			break
		}
		n, rargs := sys.tokenize(t, " \t\n")
		if rargs == nil {
			continue
		}
		if args == nil {
			rargs = cmd :: rargs
		} else {
			rargs = append(cmd :: args, rargs)
		}
		sh.init(ctxt, rargs)		// BUG: process environment?
	}
}

func reverse[T](l list T) list T {
	var t list T
	for ; l != nil; l = tl(l) {
		t = hd(l) :: t
	}
	return t
}

func append(h list string, t list string) list string {
	r := reverse(h)
	for ; r != nil; r = tl(r) {
		t = hd(r) :: t
	}
	return t
}
