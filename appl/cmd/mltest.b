implement Command;

#
# Tests ml(3) end to end: the model crosses as bytes, the device compiles and
# runs it, and the answer comes back.
#
# The fixture is a linear model built by emu/port/mkonnxmodel.py with weights
# chosen by hand, so the answer is known in advance:
#
#	y = Wx + b,  W = [[1,2,3],[10,20,30]],  b = [0.5,-0.5]
#
# x = (1,2,3) must give y = (14.5, 139.5). Asserting that rather than "some
# bytes came back" is the point: the two outputs differ by an order of
# magnitude and neither is symmetric in its inputs, so a transposed weight
# matrix, a swapped output, a wrong element width or a byte-order mistake all
# produce a visibly wrong number instead of a plausible one.
#
include "sys.m";
	sys: Sys;
	print, sprint: import sys;
include "string.m";
	str: String;
include "math.m";
	math: Math;
include "draw.m";

Command: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

Model:	con "/lib/ml/linear.onnx";

fail := 0;

# f32 across ml(3)'s big-endian wire. math(2) marshals f64 and there is no
# f32 equivalent, so the four bytes are laid out here.
putf32(v: array of real): array of byte
{
	b := array[4*len v] of byte;
	for(i := 0; i < len v; i++){
		u := math->realbits32(real v[i]);
		b[4*i] = byte (u >> 24);
		b[4*i+1] = byte (u >> 16);
		b[4*i+2] = byte (u >> 8);
		b[4*i+3] = byte u;
	}
	return b;
}

getf32(b: array of byte): array of real
{
	v := array[len b / 4] of real;
	for(i := 0; i < len v; i++){
		u := (int b[4*i] << 24) | (int b[4*i+1] << 16) |
			(int b[4*i+2] << 8) | int b[4*i+3];
		v[i] = math->bits32real(u);
	}
	return v;
}

bad(s: string)
{
	print("FAIL: %s\n", s);
	fail = 1;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	math = load Math Math->PATH;
	if(str == nil || math == nil){
		print("mltest: load: %r\n");
		raise "fail:load";
	}

	mod := Model;
	if(tl argv != nil)
		mod = hd tl argv;

	if(sys->bind("#N", "/dev", Sys->MBEFORE) < 0){
		print("mltest: bind #N: %r\n");
		raise "fail:no device";
	}

	# The clone fd becomes this instance's ctl, and reading it gives the
	# instance number - the same arrangement /dev/draw/new uses.
	ctl := sys->open("/dev/ml/clone", Sys->ORDWR);
	if(ctl == nil){
		print("mltest: /dev/ml/clone: %r\n");
		raise "fail:no device";
	}
	buf := array[32] of byte;
	n := sys->read(ctl, buf, len buf);
	if(n <= 0){
		print("mltest: read instance number: %r\n");
		raise "fail:ctl";
	}
	(id, nil) := str->toint(str->drop(string buf[0:n], " "), 10);
	if(id <= 0){
		bad(sprint("instance number %d", id));
		raise "fail:test";
	}
	dir := sprint("/dev/ml/%d", id);

	# The model crosses as bytes. No host path is handed over at any
	# point, which is what lets this work on a model that lives on a Styx
	# mount rather than on the host's own filesystem.
	mfd := sys->open(mod, Sys->OREAD);
	if(mfd == nil){
		print("mltest: open %s: %r\n", mod);
		raise "fail:open";
	}
	wfd := sys->open(dir + "/model", Sys->OWRITE);
	if(wfd == nil){
		print("mltest: open %s/model: %r\n", dir);
		raise "fail:open";
	}
	total := 0;
	blk := array[8192] of byte;
	for(;;){
		k := sys->read(mfd, blk, len blk);
		if(k <= 0)
			break;
		if(sys->write(wfd, blk[0:k], k) != k){
			bad(sprint("write model bytes: %r"));
			raise "fail:test";
		}
		total += k;
	}
	if(total == 0){
		bad(sprint("%s is empty", mod));
		raise "fail:test";
	}

	if(sys->fprint(ctl, "load") < 0){
		bad(sprint("load: %r"));
		raise "fail:test";
	}

	# What the model takes and returns, and what actually ran it. A client
	# cannot form a valid write without this.
	ifd := sys->open(dir + "/info", Sys->OREAD);
	if(ifd == nil){
		bad(sprint("open info: %r"));
		raise "fail:test";
	}
	ibuf := array[8192] of byte;
	n = sys->read(ifd, ibuf, len ibuf);
	if(n <= 0){
		bad(sprint("read info: %r"));
		raise "fail:test";
	}
	info := string ibuf[0:n];
	print("%s", info);

	# The declared element type is checked rather than assumed. This model
	# is f32; guessing f64 would write twice the bytes.
	#
	# The -1 is the batch dimension, which the model leaves open. That it
	# is reported rather than guessed at is the whole reason for the ONNX
	# backend: a model with a variable-length input could not be fed at all
	# before, because every write was sized against a fixed declared shape.
	if(!has(info, "in x f32 -1 3"))
		bad("info does not describe input x as f32 [-1 3]");
	if(!has(info, "out y f32 -1 2"))
		bad("info does not describe output y as f32 [-1 2]");
	if(!has(info, "device "))
		bad("info does not say what ran the model");
	if(fail)
		raise "fail:test";

	# Feed it one row. The device's wire is big-endian whatever the host
	# is, and this model is f32, so the four bytes of each value go out
	# most significant first.
	x := array[3] of real;
	x[0] = 1.0; x[1] = 2.0; x[2] = 3.0;
	xb := putf32(x);
	infd := sys->open(dir + "/in", Sys->OWRITE);
	if(infd == nil){
		bad(sprint("open in: %r"));
		raise "fail:test";
	}
	if(sys->write(infd, xb, len xb) != len xb){
		bad(sprint("write input: %r"));
		raise "fail:test";
	}

	if(sys->fprint(ctl, "run") < 0){
		bad(sprint("run: %r"));
		raise "fail:test";
	}

	ofd := sys->open(dir + "/out", Sys->OREAD);
	if(ofd == nil){
		bad(sprint("open out: %r"));
		raise "fail:test";
	}
	yb := array[8] of byte;			# two f32
	n = sys->readn(ofd, yb, len yb);
	if(n != len yb){
		bad(sprint("read output: got %d of %d bytes: %r", n, len yb));
		raise "fail:test";
	}
	y := getf32(yb);

	want := array[] of { 14.5, 139.5 };
	for(i := 0; i < len y; i++)
		if(y[i] - want[i] > 0.01 || want[i] - y[i] > 0.01)
			bad(sprint("y[%d] = %g, expected %g", i, y[i], want[i]));

	# A wrong-sized input must be refused, not quietly padded or truncated.
	# Without this the size check has never been seen to do anything, and
	# a silently short input is exactly the failure that returns a
	# plausible number.
	# 10 bytes is not a whole number of f32 values, so it cannot be any
	# batch size at all.
	short := array[10] of byte;
	if(sys->write(infd, short, len short) >= 0)
		bad("a 10-byte input was accepted for a feature of 4-byte values");

	# And the open dimension really is open: two rows, twice the bytes,
	# twice the answer back. Before the ONNX backend this was the case
	# that could not be expressed at all.
	x2 := array[6] of real;
	x2[0] = 1.0; x2[1] = 2.0; x2[2] = 3.0;
	x2[3] = 1.0; x2[4] = 2.0; x2[5] = 3.0;
	xb2 := putf32(x2);
	if(sys->write(infd, xb2, len xb2) != len xb2)
		bad(sprint("write two rows: %r"));
	else if(sys->fprint(ctl, "run") < 0)
		bad(sprint("run two rows: %r"));
	else {
		ofd2 := sys->open(dir + "/out", Sys->OREAD);
		yb2 := array[16] of byte;		# four f32
		if(ofd2 == nil || sys->readn(ofd2, yb2, len yb2) != len yb2)
			bad("two rows did not give four values back");
		else {
			y2 := getf32(yb2);
			for(k := 0; k < 4; k++){
				w := 14.5;
				if(k % 2 == 1)
					w = 139.5;
				if(y2[k] - w > 0.01 || w - y2[k] > 0.01)
					bad(sprint("two rows: y[%d] = %g, expected %g", k, y2[k], w));
			}
		}
	}

	# What "device" reports has to track what was asked for, or it is not
	# a report at all. A constant string would pass every check above.
	# Loading the same model on a second instance with "units cpu" must
	# say cpu, whatever the first one said - which holds on a machine with
	# no neural engine too.
	dev2 := loaded(mod, "cpu");
	if(dev2 != "cpu")
		bad(sprint("asked for cpu, info reports device %#q", dev2));

	stale();

	if(fail)
		raise "fail:test";
	print("  %s: %d bytes of model\n", mod, total);
	print("  x = (1, 2, 3) gives y = (%g, %g), expected (14.5, 139.5)\n", y[0], y[1]);
	print("  ran on %#q by default, %#q when cpu was asked for\n",
		devof(info), dev2);
	print("PASS\n");
}

# Load the model on a fresh instance with the given compute units, and return
# what it says ran.
loaded(mod, units: string): string
{
	ctl := sys->open("/dev/ml/clone", Sys->ORDWR);
	if(ctl == nil)
		return sprint("clone: %r");
	buf := array[32] of byte;
	n := sys->read(ctl, buf, len buf);
	if(n <= 0)
		return sprint("read clone: %r");
	(id, nil) := str->toint(str->drop(string buf[0:n], " "), 10);
	dir := sprint("/dev/ml/%d", id);

	if(sys->fprint(ctl, "units %s", units) < 0)
		return sprint("units: %r");
	mfd := sys->open(mod, Sys->OREAD);
	wfd := sys->open(dir + "/model", Sys->OWRITE);
	if(mfd == nil || wfd == nil)
		return sprint("open: %r");
	blk := array[8192] of byte;
	for(;;){
		k := sys->read(mfd, blk, len blk);
		if(k <= 0)
			break;
		if(sys->write(wfd, blk[0:k], k) != k)
			return sprint("write model: %r");
	}
	if(sys->fprint(ctl, "load") < 0)
		return sprint("load: %r");
	ifd := sys->open(dir + "/info", Sys->OREAD);
	if(ifd == nil)
		return sprint("open info: %r");
	ib := array[8192] of byte;
	n = sys->read(ifd, ib, len ib);
	if(n <= 0)
		return sprint("read info: %r");
	return devof(string ib[0:n]);
}

# An fd on an instance may outlive the ctl fd that owned it - ml(3) allows
# that on purpose, so a program can open, write and close "in" as it likes.
# The slot it names is reused, so such an fd must be refused rather than
# silently resolving to whoever took the slot next.
#
# Without the check this does not fail loudly: the write reaches the new
# instance and succeeds if that instance has a model loaded. What
# distinguishes the two cases is which error comes back - "file does not
# exist" from the stale fd being rejected, against an error belonging to the
# other instance - so this compares the error and not just success.
stale()
{
	ctl1 := sys->open("/dev/ml/clone", Sys->ORDWR);
	if(ctl1 == nil){
		bad(sprint("clone: %r"));
		return;
	}
	b := array[32] of byte;
	n := sys->read(ctl1, b, len b);
	if(n <= 0){
		bad(sprint("read clone: %r"));
		return;
	}
	(id, nil) := str->toint(str->drop(string b[0:n], " "), 10);
	in1 := sys->open(sprint("/dev/ml/%d/in", id), Sys->OWRITE);
	if(in1 == nil){
		bad(sprint("open in: %r"));
		return;
	}
	ctl1 = nil;			# releases the instance, freeing its slot

	ctl2 := sys->open("/dev/ml/clone", Sys->ORDWR);
	if(ctl2 == nil){
		bad(sprint("second clone: %r"));
		return;
	}
	n = sys->read(ctl2, b, len b);
	(id2, nil) := str->toint(str->drop(string b[0:n], " "), 10);
	if(id2 == id){
		bad("the second instance got the first one's number");
		return;
	}

	if(sys->write(in1, array[8] of byte, 8) >= 0){
		bad("a stale fd wrote into the instance that reused its slot");
		return;
	}
	err := sprint("%r");
	if(err != "file does not exist")
		bad(sprint("stale fd gave %#q, expected the fd to be rejected", err));
}

devof(info: string): string
{
	for(i := 0; i < len info; i++){
		if(i != 0 && info[i-1] != '\n')
			continue;
		if(i+7 <= len info && info[i:i+7] == "device "){
			j := i+7;
			while(j < len info && info[j] != '\n')
				j++;
			return info[i+7:j];
		}
	}
	return "";
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}
