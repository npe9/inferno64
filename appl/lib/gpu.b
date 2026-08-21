implement Gpu;

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
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

# gpu(3)'s own protocol is text for this first pass (see its SOURCE
# section for why) - marshal/unmarshal accordingly. A real high-
# throughput version would move this to a compact binary encoding
# without changing anything on the Krylov->Apply side of this file.
gpuapply(x: array of real): array of real
{
	msg := sys->sprint("X");
	for(i := 0; i < len x; i++)
		msg += sys->sprint(" %g", x[i]);
	msg += "\n";
	sys->write(gpufd, array of byte msg, len msg);
	buf := array[gpun*32 + 16] of byte;
	rn := sys->read(gpufd, buf, len buf);
	(nil, flds) := sys->tokenize(string buf[0:rn], " \n\t");
	y := array[gpun] of real;
	for(i = 0; i < gpun && flds != nil; i++){
		y[i] = real hd flds;
		flds = tl flds;
	}
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
	umsg := sys->sprint("U %d %d\n", m.n, len m.val);
	for(i := 0; i <= m.n; i++)
		umsg += sys->sprint("%d ", m.rowptr[i]);
	umsg += "\n";
	for(i = 0; i < len m.colidx; i++)
		umsg += sys->sprint("%d ", m.colidx[i]);
	umsg += "\n";
	for(i = 0; i < len m.val; i++)
		umsg += sys->sprint("%g ", m.val[i]);
	umsg += "\n";
	sys->write(fd, array of byte umsg, len umsg);
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
