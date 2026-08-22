implement Command;

#
# Tests gpu(3)'s protocol and handle table, and gpu(2)'s precision
# negotiation.
#
# Talks to /dev/gpuclone directly rather than through gpu(2) for the
# concurrency part, deliberately: gpu(2) keeps its device fd and matrix
# order in module-level variables and documents itself as not reentrant,
# so driving it from several procs at once would be testing the wrong
# thing. The device is what has to survive many handles at once.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "math.m";
	math: Math;
include "sparse.m";
	sparse: Sparse;
	CSR: import sparse;
include "krylov.m";
include "gpu.m";
	gpu: Gpu;
	Backend: import gpu;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Nproc: con 40;		# > 16, so the handle table has to grow while in use
Niter: con 60;

fail := 0;

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

# One diagonal matrix per proc, sized differently so a mixed-up handle
# shows as a wrong length as well as wrong values. y[i] = (i+1)*x[i].
worker(id: int, done: chan of string)
{
	n := 8 + id;

	fd := sys->open("/dev/gpuclone", Sys->ORDWR);
	if(fd == nil){
		done <-= sprint("proc %d: open: %r", id);
		return;
	}

	rowptr := array[n+1] of int;
	colidx := array[n] of int;
	val := array[n] of real;
	for(i := 0; i <= n; i++)
		rowptr[i] = i;
	for(i = 0; i < n; i++){
		colidx[i] = i;
		val[i] = real (i+1);
	}

	hdr := array[2] of int;
	hdr[0] = n;
	hdr[1] = n;
	umsg := array[1 + 8 + (n+1)*4 + n*4 + n*4] of byte;
	umsg[0] = byte 'U';
	math->export_int(umsg[1:9], hdr);
	o := 9;
	math->export_int(umsg[o:o+(n+1)*4], rowptr);
	o += (n+1)*4;
	math->export_int(umsg[o:o+n*4], colidx);
	o += n*4;
	math->export_real32(umsg[o:o+n*4], val);
	if(sys->write(fd, umsg, len umsg) != len umsg){
		done <-= sprint("proc %d: upload write: %r", id);
		return;
	}
	ack := array[16] of byte;
	an := sys->read(fd, ack, len ack);
	if(an < 3 || string ack[0:3] != "OK\n"){
		done <-= sprint("proc %d: upload not acked", id);
		return;
	}

	x := array[n] of real;
	for(i = 0; i < n; i++)
		x[i] = real (i+1);

	for(k := 0; k < Niter; k++){
		msg := array[1 + n*4] of byte;
		msg[0] = byte 'X';
		math->export_real32(msg[1:], x);
		if(sys->write(fd, msg, len msg) != len msg){
			done <-= sprint("proc %d: matvec write: %r", id);
			return;
		}
		rbuf := array[n*4] of byte;
		off := 0;
		while(off < len rbuf){
			nr := sys->read(fd, rbuf[off:], len rbuf - off);
			if(nr <= 0){
				done <-= sprint("proc %d: short matvec read at %d", id, off);
				return;
			}
			off += nr;
		}
		y := array[n] of real;
		math->import_real32(rbuf, y);
		# Small integers, so exact in f32 - any difference is the
		# device confusing this handle with another one's.
		for(i = 0; i < n; i++){
			want := real ((i+1)*(i+1));
			if(y[i] != want){
				done <-= sprint("proc %d iter %d: y[%d]=%g want %g",
					id, k, i, y[i], want);
				return;
			}
		}
	}
	done <-= nil;
}

# Diagonal, so y[i] = (i+1)*x[i] and every value is a small integer that
# survives the f32 wire exactly. One single-node element per row gives a
# pattern with just the diagonal in it.
diag(n: int): ref CSR
{
	elems := array[n] of array of int;
	for(i := 0; i < n; i++){
		elems[i] = array[1] of int;
		elems[i][0] = i;
	}
	m := sparse->newfrompattern(n, elems);
	for(i = 0; i < n; i++)
		sparse->set(m, i, i, real (i+1));
	return m;
}

precisiontest()
{
	if(!gpu->available()){
		print("  precision: no /dev/gpuclone, skipped\n");
		return;
	}
	m := diag(16);

	# The device is f32 on every path (see gpu(3)): with a hardware
	# backend because Metal has no double, without one because the wire
	# carries singles regardless. So f64 must be refused, not silently
	# downgraded - this is the whole point of the P request.
	b := gpu->new();
	if((e := b.cmd("device gpu\nprecision f64")) != nil){
		bad("cmd: " + e);
		return;
	}
	b.apply(m);
	if(b.lasterror == nil)
		bad("precision f64 was accepted by an f32 device");
	else
		print("  precision f64 declined: %s\n", b.lasterror);

	b2 := gpu->new();
	if((e = b2.cmd("device gpu\nprecision f32")) != nil){
		bad("cmd: " + e);
		return;
	}
	f := b2.apply(m);
	if(b2.lasterror != nil){
		bad("precision f32 refused: " + b2.lasterror);
		return;
	}
	x := array[16] of real;
	for(i := 0; i < 16; i++)
		x[i] = real (i+1);
	y := f(x);
	for(i = 0; i < 16; i++)
		if(y[i] != real ((i+1)*(i+1))){
			bad(sprint("precision f32 matvec: y[%d]=%g want %d",
				i, y[i], (i+1)*(i+1)));
			return;
		}
	print("  precision f32 accepted, matvec correct\n");
}

handletest()
{
	fd := sys->open("/dev/gpuclone", Sys->OREAD);
	if(fd == nil){
		print("  handles: no /dev/gpuclone, skipped\n");
		return;
	}
	fd = nil;

	done := chan of string;
	for(i := 0; i < Nproc; i++)
		spawn worker(i, done);
	nerr := 0;
	for(i = 0; i < Nproc; i++){
		e := <-done;
		if(e != nil){
			print("FAIL: %s\n", e);
			nerr++;
		}
	}
	if(nerr != 0){
		fail = 1;
		print("  handles: %d of %d procs failed\n", nerr, Nproc);
	}else
		print("  %d concurrent handles x %d matvecs: all correct\n",
			Nproc, Niter);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	sparse = load Sparse Sparse->PATH;
	gpu = load Gpu Gpu->PATH;
	if(math == nil || sparse == nil || gpu == nil){
		print("gputest: load: %r\n");
		raise "fail:load";
	}

	precisiontest();
	handletest();

	if(fail)
		raise "fail:test";
	print("PASS\n");
}
