module Disw

import sys "sys"
import bufio "bufio"
import math "math"
import types "types"
import gen "gen"

// a port of ember/disw.c.  output goes through a bufio buffer;
// byte-wise writes use putb, multi-byte ones putb per byte.

const DEFZ = 0
const DEFB = 1
const DEFW = 2
const DEFS = 3
const DEFF = 4
const DEFA = 5
const DIND = 6
const DAPOP = 7
const DEFL = 8
const DMAX = 16

const AMP = 0
const AFP = 1
const AIMM = 2
const AXXX = 3
const AIND = 4
const AXNON = 0
const AXIMM = 64
const AXINF = 128
const AXINM = 192

var bout ref bufio.Iobuf
var cache []byte
var ncached = 0
var ndatum = 0
var startoff = 0
var lastoff = 0
var lastkind = -1

func usetypes(t Types) {
	types = t
	gen.usetypes(t)
}

func fatal(msg string) {
	sys.fprint(sys.fildes(2), "fatal ember compiler error: %s\n", msg)
	var l list int
	hd(l)
}

func open(path string) int {
	bout = bufio.create(path, bufio.OWRITE, 420)
	if bout == nil {
		return 0
	}
	return 1
}

func close() {
	if bout != nil {
		bout.close()
		bout = nil
	}
}

func putc(c int) {
	bout.putb(byte(c))
}

func putbytes(b []byte, n int) {
	for i := 0; i < n; i++ {
		bout.putb(b[i])
	}
}

func putstr(s string) {
	b := []byte(s)
	putbytes(b, len(b))
}

func discon(val int) {
	if val >= -64 && val <= 63 {
		putc(val & ~128)
		return
	}
	if val >= -8192 && val <= 8191 {
		putc(((val >> 8) & ~192) | 128)
		putc(val)
		return
	}
	if (val < 0 && ((val >> 29) & 7) != 7) || (val > 0 && (val >> 29) != 0) {
		fatal(sys.sprint("overflow in constant %d", val))
	}
	putc((val >> 24) | 192)
	putc(val >> 16)
	putc(val >> 8)
	putc(val)
}

func disword(w int) {
	putc(w >> 24)
	putc(w >> 16)
	putc(w >> 8)
	putc(w)
}

func disdata(kind int, n int) {
	if n < DMAX && n != 0 {
		putc((kind << 4) | n)
	} else {
		putc(kind << 4)
		discon(n)
	}
}

func dismod(m ref types.Decl) {
	name := m.sym
	if len([]byte(name)) > 63 {
		name = string([]byte(name)[0:63])
	}
	putstr(name)
	putc(0)
	for e := m.ty.tof.ids; e != nil; e = e.next {
		match e.store {
		case types.Dglobal:
			discon(-1)
			discon(-1)
			disword(types.sign(e))
			putstr(".mp")
			putc(0)
		case types.Dfn:
			discon(e.pc.pc)
			discon(e.desc.id)
			disword(types.sign(e))
			if e.dot.ty.kind == types.Tadt {
				putstr(e.dot.sym + ".")
			}
			putstr(e.sym)
			putc(0)
		default:
			fatal(sys.sprint("unknown kind %d in dismod", e.store))
		}
	}
}

func dispath(name string) {
	putstr(name)
	putc(0)
}

// the exception handler table, see disw.c's disexc()
func disexc(es ref types.Except) {
	n := 0
	for e := es; e != nil; e = e.next {
		if e.p1.reach != 0 || e.p2.reach != 0 {
			n++
		}
	}
	discon(n)
	for e := es; e != nil; e = e.next {
		if e.p1.reach == 0 && e.p2.reach == 0 {
			continue
		}
		discon(e.d.offset)
		discon(e.pc1)
		discon(e.pc2)
		discon(-1)
		discon(0)
		discon(e.c.iwild.pc)
	}
	discon(0)
}

func disentry(e ref types.Decl) {
	if e == nil {
		discon(-1)
		discon(-1)
		return
	}
	discon(e.pc.pc)
	discon(e.desc.id)
}

func disdesc(d ref types.Desc) {
	for ; d != nil; d = d.next {
		discon(d.id)
		discon(d.size)
		discon(d.nmap)
		putbytes(d.map, d.nmap)
	}
}

func disvar(size int, d ref types.Decl) {
	lastkind = -1
	ncached = 0
	ndatum = 0
	for ; d != nil; d = d.next {
		if d.store == types.Dglobal && d.init != nil && d.runinit == 0 {
			disdatum(d.offset, d.init)
		}
	}
	disflush(-1, -1, 0)
	putc(0)
}

func disldt(size int, ds ref types.Decl) {
	m := 0
	for d := ds; d != nil; d = d.next {
		if d.store == types.Dglobal && d.init != nil {
			m++
		}
	}
	discon(m)
	for d := ds; d != nil; d = d.next {
		if d.store == types.Dglobal && d.init != nil {
			n := d.init
			if n.ty.kind != types.Tiface {
				fatal("disldt: not Tiface")
			}
			discon(int(n.val))
			for id := n.decl.ty.ids; id != nil; id = id.next {
				disword(types.sign(id))
				if id.dot.ty.kind == types.Tadt {
					putstr(id.dot.sym + ".")
				}
				putstr(id.sym)
				putc(0)
			}
		}
	}
	discon(0)
}

func disdatum(offset int, n ref types.Node) {
	match n.ty.kind {
	case types.Tbyte:
		disbyte(offset, int(n.val))
	case types.Tint:
		disint(offset, int(n.val))
	case types.Tbig:
		disbig(offset, n.val)
	case types.Tstring:
		if n.decl != nil {
			disstring(offset, n.decl.sym)
		} else {
			disstring(offset, n.sym)
		}
	case types.Treal:
		disreal(offset, n.rval)
	case types.Tadt, types.Tadtpick, types.Ttuple:
		id := n.ty.ids
		for e := n.left; e != nil; e = e.right {
			disdatum(offset + id.offset, e.left)
			id = id.next
		}
	case types.Tany:
		break
	case types.Tcase:
		c := n.ty.cse
		disint(offset, c.nlab)
		offset += types.IBY2WD
		for i := 0; i < c.nlab; i++ {
			lab := c.labs[i]
			disint(offset, int(lab.start.val))
			offset += types.IBY2WD
			disint(offset, int(lab.stop.val) + 1)
			offset += types.IBY2WD
			disint(offset, lab.inst.pc)
			offset += types.IBY2WD
		}
		if c.iwild != nil {
			disint(offset, c.iwild.pc)
		} else {
			disint(offset, -1)
		}
	case types.Tgoto:
		c := n.ty.cse
		disint(offset, n.ty.size / types.IBY2WD - 1)
		offset += types.IBY2WD
		for i := 0; i < c.nlab; i++ {
			disint(offset, c.labs[i].inst.pc)
			offset += types.IBY2WD
		}
		if c.iwild != nil {
			disint(offset, c.iwild.pc)
		}
	case types.Tcasec:
		c := n.ty.cse
		disint(offset, c.nlab)
		offset += types.IBY2WD
		for i := 0; i < c.nlab; i++ {
			lab := c.labs[i]
			disstring(offset, lab.start.sym)
			offset += types.IBY2WD
			if lab.stop != lab.start {
				disstring(offset, lab.stop.sym)
			}
			offset += types.IBY2WD
			disint(offset, lab.inst.pc)
			offset += types.IBY2WD
		}
		if c.iwild != nil {
			disint(offset, c.iwild.pc)
		} else {
			disint(offset, -1)
		}
	case types.Tiface:
		disint(offset, int(n.val))
		offset += types.IBY2WD
		for id := n.decl.ty.ids; id != nil; id = id.next {
			offset = types.align(offset, types.IBY2WD)
			disint(offset, types.sign(id))
			offset += types.IBY2WD
			if id.dot.ty.kind == types.Tadt {
				b := []byte(id.dot.sym)
				disbytes(offset, b, len(b))
				offset += len(b)
				disbyte(offset, '.')
				offset++
			}
			b := []byte(id.sym)
			disbytes(offset, b, len(b))
			offset += len(b)
			disbyte(offset, 0)
			offset++
		}
	default:
		fatal(sys.sprint("can't dis global type %s", types.tprint(n.ty)))
	}
}

func cachebyte(v int) {
	cache[ncached] = byte(v)
	ncached++
}

func disbyte(off int, v int) {
	disflush(DEFB, off, 1)
	cachebyte(v)
	ndatum++
}

func disbytes(off int, v []byte, n int) {
	disflush(DEFB, off, n)
	for i := 0; i < n; i++ {
		cache[ncached] = v[i]
		ncached++
	}
	ndatum += n
}

func disint(off int, v int) {
	disflush(DEFW, off, types.IBY2WD)
	cachebyte(v >> 24)
	cachebyte(v >> 16)
	cachebyte(v >> 8)
	cachebyte(v)
	ndatum++
}

func disbig(off int, v big) {
	disflush(DEFL, off, types.IBY2LG)
	iv := int(v >> 32)
	cachebyte(iv >> 24)
	cachebyte(iv >> 16)
	cachebyte(iv >> 8)
	cachebyte(iv)
	iv = int(v)
	cachebyte(iv >> 24)
	cachebyte(iv >> 16)
	cachebyte(iv >> 8)
	cachebyte(iv)
	ndatum++
}

func disreal(off int, v real) {
	disflush(DEFF, off, types.IBY2LG)
	b := [8]byte
	math.export_real(b, [1]real{v})
	for i := 0; i < 8; i++ {
		cachebyte(int(b[i]))
	}
	ndatum++
}

func disstring(offset int, s string) {
	disflush(-1, -1, 0)
	b := []byte(s)
	disdata(DEFS, len(b))
	discon(offset)
	putbytes(b, len(b))
}

func disflush(kind int, off int, size int) {
	if kind != lastkind || off != lastoff {
		if lastkind != -1 && ncached != 0 {
			disdata(lastkind, ndatum)
			discon(startoff)
			putbytes(cache, ncached)
		}
		startoff = off
		lastkind = kind
		ncached = 0
		ndatum = 0
	}
	lastoff = off + size
	for kind >= 0 && (cache == nil || ncached + size >= len(cache)) {
		nc := [ncached + 1024]byte
		for i := 0; i < ncached; i++ {
			nc[i] = cache[i]
		}
		cache = nc
	}
}

// operand encodings per addressing mode (disw.c's dismode/disregmode)
func dismode(am int) int {
	return [gen.Aend]int{AIMM, AMP, AMP | AIND, AFP, AFP | AIND, AIMM, AIMM, AIMM, AIMM, AXXX, AXXX, AIMM}[am]
}

func disregmode(am int) int {
	return [gen.Aend]int{AXIMM, AXINM, AXNON, AXINF, AXNON, AXIMM, AXIMM, AXIMM, AXIMM, AXNON, AXNON, AXIMM}[am]
}

var ibuf []byte
var nibuf = 0

const NIBUF = 1024
const MAXINST = 26

func disinst(in ref types.Inst) {
	ibuf = [NIBUF]byte
	nibuf = 0
	for ; in != nil; in = in.next {
		if in.op == gen.INOOP {
			continue
		}
		if nibuf >= NIBUF - MAXINST {
			putbytes(ibuf, nibuf)
			nibuf = 0
		}
		ibuf[nibuf] = byte(in.op)
		nibuf++
		ibuf[nibuf] = byte((dismode(in.sm) << 3) | dismode(in.dm) | disregmode(in.mm))
		nibuf++
		if in.mm != gen.Anone {
			disaddr(in.mm, in.m)
		}
		if in.sm != gen.Anone {
			disaddr(in.sm, in.s)
		}
		if in.dm != gen.Anone {
			disaddr(in.dm, in.d)
		}
	}
	if nibuf > 0 {
		putbytes(ibuf, nibuf)
	}
	ibuf = nil
}

func disaddr(m int, a types.Addr) {
	val := 0
	match m {
	case gen.Aimm, gen.Apc, gen.Adesc:
		val = a.offset
	case gen.Aoff:
		val = a.decl.iface.offset
	case gen.Anoff:
		val = -(a.decl.iface.offset + 1)
	case gen.Afp, gen.Amp, gen.Aldt:
		val = a.reg
	case gen.Afpind, gen.Ampind:
		disbcon(a.reg)
		val = a.offset
	default:
		val = 0
	}
	disbcon(val)
}

func ibufbyte(v int) {
	ibuf[nibuf] = byte(v)
	nibuf++
}

func disbcon(val int) {
	if val >= -64 && val <= 63 {
		ibufbyte(val & ~128)
		return
	}
	if val >= -8192 && val <= 8191 {
		ibufbyte(((val >> 8) & ~192) | 128)
		ibufbyte(val)
		return
	}
	if (val < 0 && ((val >> 29) & 7) != 7) || (val > 0 && (val >> 29) != 0) {
		fatal(sys.sprint("overflow in constant %d", val))
	}
	ibufbyte((val >> 24) | 192)
	ibufbyte(val >> 16)
	ibufbyte(val >> 8)
	ibufbyte(val)
}
