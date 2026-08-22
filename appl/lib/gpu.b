implement Gpu;

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "math.m";
	math: Math;
include "sparse.m";
	sparse: Sparse;
	CSR: import sparse;
include "krylov.m";
	krylov: Krylov;
	Apply: import krylov;
include "gpu.m";

init()
{
	if(sys == nil){
		sys = load Sys Sys->PATH;
		str = load String String->PATH;
		sparse = load Sparse Sparse->PATH;
		math = load Math Math->PATH;
	}
}

new(): ref Backend
{
	init();
	return ref Backend("cpu", "f64", 1, nil);
}

# A real check, not a promise: attempts to reach gpu(3) (see gpu(2)'s
# own SOURCE section) rather than hardcoding a return value.
available(): int
{
	init();
	fd := sys->open("/dev/gpuclone", Sys->OREAD);
	if(fd == nil)
		return 0;
	return 1;
}

words(s: string): array of string
{
	l := str->fields(s);
	a := array[len l] of string;
	for(i := 0; l != nil; (i,l) = (i+1,tl l))
		a[i] = hd l;
	return a;
}

Backend.cmd(b: self ref Backend, arg: string): string
{
	init();
	(nil, after) := str->splitl(arg, "\n");
	if(after != nil){
		for(rest := arg; rest != nil;){
			(line, tail) := str->splitl(rest, "\n");
			if(tail != nil)
				tail = tail[1:];
			if(str->fields(line) != nil){
				err := b.cmd(line);
				if(err != nil)
					return err;
			}
			rest = tail;
		}
		return nil;
	}
	a := words(arg);
	if(len a == 0)
		return nil;
	case a[0] {
	"device" =>
		if(len a != 2 || (a[1] != "cpu" && a[1] != "gpu"))
			return "usage: device cpu|gpu";
		b.device = a[1];
	"precision" =>
		if(len a != 2 || (a[1] != "f32" && a[1] != "f64"))
			return "usage: precision f32|f64";
		b.precision = a[1];
	"resident" =>
		if(len a != 2 || (a[1] != "on" && a[1] != "off"))
			return "usage: resident on|off";
		b.resident = a[1] == "on";
	* =>
		return "gpu: unknown command " + a[0];
	}
	return nil;
}

# Krylov->Apply is a bare function reference, not a closure (Limbo has
# no closure literals) - module-level state is how context reaches it,
# the same reason fem(2)'s own femop() does this for its cpu path.
# Not reentrant across concurrent solves in one process; nothing in
# this tree runs two solves at once, the same non-constraint pde(2)/
# fem(2) already note for their own module-level operator state.
cpumatrix: ref CSR;

cpuapply(x: array of real): array of real
{
	return sparse->matvec(cpumatrix, x);
}

gpufd: ref Sys->FD;
gpun: int;

# One request per matvec: tag byte then the vector as big-endian
# IEEE754 singles, which is what math->export_real32 emits and what
# gpu(3) decodes. Text here cost more than the arithmetic and could not
# scale - see gpu(3).
gpuapply(x: array of real): array of real
{
	msg := array[1 + gpun*4] of byte;
	msg[0] = byte 'X';
	math->export_real32(msg[1:], x);
	if(sys->write(gpufd, msg, len msg) != len msg)
		return sparse->matvec(cpumatrix, x);
	rbuf := array[gpun*4] of byte;
	off := 0;
	while(off < len rbuf){
		nr := sys->read(gpufd, rbuf[off:], len rbuf - off);
		if(nr <= 0)
			return sparse->matvec(cpumatrix, x);
		off += nr;
	}
	y := array[gpun] of real;
	math->import_real32(rbuf, y);
	return y;
}

Backend.apply(b: self ref Backend, m: ref CSR): Apply
{
	init();
	b.lasterror = nil;
	if(b.device != "gpu"){
		cpumatrix = m;
		return cpuapply;
	}
	if(!available()){
		b.lasterror = "backend: device gpu requested but unavailable, using cpu";
		cpumatrix = m;
		return cpuapply;
	}
	fd := sys->open("/dev/gpuclone", Sys->ORDWR);
	if(fd == nil){
		b.lasterror = sys->sprint("backend: device gpu open failed (%r), using cpu");
		cpumatrix = m;
		return cpuapply;
	}
	# Ask the device what it would ACTUALLY compute in before trusting
	# it with a solve. A real hardware backend is f32-only (Metal has
	# no double), so honouring a caller's "precision f64" means
	# declining the device rather than quietly handing back single
	# precision - the same never-silently-wrong discipline the
	# unavailable-device path above already follows.
	pq := array of byte "P\n";
	sys->write(fd, pq, len pq);
	pbuf := array[16] of byte;
	pn := sys->read(fd, pbuf, len pbuf);
	devprec := "f64";
	if(pn >= 3)
		devprec = string pbuf[0:3];
	# Asking for f32 and getting f64 is strictly more precision than
	# requested, never a problem; only the reverse is.
	if(b.precision == "f64" && devprec != "f64"){
		b.lasterror = "backend: device gpu computes in " + devprec +
			", precision f64 requested - using cpu";
		cpumatrix = m;
		return cpuapply;
	}
	nnz := len m.val;
	hdr := array[2] of int;
	hdr[0] = m.n;
	hdr[1] = nnz;
	umsg := array[1 + 8 + (m.n+1)*4 + nnz*4 + nnz*4] of byte;
	umsg[0] = byte 'U';
	math->export_int(umsg[1:9], hdr);
	o := 9;
	math->export_int(umsg[o:o+(m.n+1)*4], m.rowptr);
	o += (m.n+1)*4;
	math->export_int(umsg[o:o+nnz*4], m.colidx);
	o += nnz*4;
	math->export_real32(umsg[o:o+nnz*4], m.val);
	if(sys->write(fd, umsg, len umsg) != len umsg){
		b.lasterror = "backend: device gpu upload write failed, using cpu";
		cpumatrix = m;
		return cpuapply;
	}
	ack := array[16] of byte;
	an := sys->read(fd, ack, len ack);
	if(an < 3 || string ack[0:3] != "OK\n"){
		b.lasterror = "backend: device gpu upload failed, using cpu";
		cpumatrix = m;
		return cpuapply;
	}
	gpufd = fd;
	gpun = m.n;
	return gpuapply;
}
