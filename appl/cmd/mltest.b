implement Command;

#
# Tests ml(3) end to end: the model crosses as bytes, the device compiles and
# runs it, and the answer comes back.
#
# The fixture is a linear model built by emu/MacOSX/mkmlmodel.py with weights
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

Model:	con "/lib/ml/linear.mlmodel";

fail := 0;

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
	# is f64; guessing f32 would write half the bytes.
	if(!has(info, "in x f64 3"))
		bad("info does not describe input x as f64 [3]");
	if(!has(info, "out y f64 2"))
		bad("info does not describe output y as f64 [2]");
	if(!has(info, "device "))
		bad("info does not say what ran the model");
	if(fail)
		raise "fail:test";

	# Feed it. export_real writes big-endian IEEE754 doubles, which is
	# what the device's wire is, so no marshalling by hand.
	x := array[3] of real;
	x[0] = 1.0; x[1] = 2.0; x[2] = 3.0;
	xb := array[8*len x] of byte;
	math->export_real(xb, x);
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
	yb := array[16] of byte;
	n = sys->readn(ofd, yb, len yb);
	if(n != len yb){
		bad(sprint("read output: got %d of %d bytes: %r", n, len yb));
		raise "fail:test";
	}
	y := array[2] of real;
	math->import_real(yb, y);

	want := array[] of { 14.5, 139.5 };
	for(i := 0; i < len y; i++)
		if(y[i] - want[i] > 0.01 || want[i] - y[i] > 0.01)
			bad(sprint("y[%d] = %g, expected %g", i, y[i], want[i]));

	# A wrong-sized input must be refused, not quietly padded or truncated.
	# Without this the size check has never been seen to do anything, and
	# a silently short input is exactly the failure that returns a
	# plausible number.
	short := array[8] of byte;
	if(sys->write(infd, short, len short) >= 0)
		bad("a 8-byte input was accepted for a 24-byte feature");

	# What "device" reports has to track what was asked for, or it is not
	# a report at all. A constant string would pass every check above.
	# Loading the same model on a second instance with "units cpu" must
	# say cpu, whatever the first one said - which holds on a machine with
	# no neural engine too.
	dev2 := loaded(mod, "cpu");
	if(dev2 != "cpu")
		bad(sprint("asked for cpu, info reports device %#q", dev2));

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
