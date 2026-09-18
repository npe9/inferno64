implement Hwsim;

#
# Serves the hardware directory with no hardware behind it.
#
# There is no ADM1176, no RFM9x and no BMX160 on an MPS2 or a Teensy.
# This serves the files module/pycubedhw.m describes so that the mission
# can be run and measured on a board that has none of the parts, and
# every number it returns is invented.  Its "source" file says exactly
# that, and appl/pycubed/hw.b's source() prints it at startup, so a run
# cannot be mistaken for a reading.
#
# It is a file server, using sys->file2chan over #s, which is how a
# Limbo program serves files in Inferno (appl/cmd/ramfile.b is the
# smallest example in the tree).  That is deliberate: the boundary the
# mission sees is the same one a C device would present, so replacing
# this with the real drivers changes nothing above it.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Hwsim: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

# The battery discharges so that the vbatt task's low-battery path can
# be reached at all.  It is a ramp, not a measurement.
vbatt := 4000;

# What the radio has "received": nothing, ever.  A radio with no
# antenna and no correspondent hears nothing, and inventing traffic
# would be inventing a result.
listening := 0;

# One process for all six files.  file2chan gives a FileIO per file and
# the obvious thing is a process each, which is what the first version
# did: it cost 37632 bytes of pool for six of them.  A single alt over
# the six pairs does the same work, because these files are answered
# immediately and nothing here blocks.  A server whose files could block
# would need the processes back.
server(f: array of ref Sys->FileIO, names: array of string)
{
	for(;;) alt {
	(off, n, nil, rc) := <-f[0].read =>
		rd(rc, names[0], off, n);
	(nil, d, nil, wc) := <-f[0].write =>
		wr(wc, names[0], d);
	(off, n, nil, rc) := <-f[1].read =>
		rd(rc, names[1], off, n);
	(nil, d, nil, wc) := <-f[1].write =>
		wr(wc, names[1], d);
	(off, n, nil, rc) := <-f[2].read =>
		rd(rc, names[2], off, n);
	(nil, d, nil, wc) := <-f[2].write =>
		wr(wc, names[2], d);
	(off, n, nil, rc) := <-f[3].read =>
		rd(rc, names[3], off, n);
	(nil, d, nil, wc) := <-f[3].write =>
		wr(wc, names[3], d);
	(off, n, nil, rc) := <-f[4].read =>
		rd(rc, names[4], off, n);
	(nil, d, nil, wc) := <-f[4].write =>
		wr(wc, names[4], d);
	(off, n, nil, rc) := <-f[5].read =>
		rd(rc, names[5], off, n);
	(nil, d, nil, wc) := <-f[5].write =>
		wr(wc, names[5], d);
	}
}

rd(rc: Sys->Rread, name: string, off: big, nbytes: int)
{
	if(rc == nil)
		return;
	if(off != big 0){
		rc <-= (nil, nil);		# one read, no seeking
		return;
	}
	rc <-= (rdfile(name, nbytes), nil);
}

wr(wc: Sys->Rwrite, name: string, data: array of byte)
{
	if(wc == nil)
		return;
	wrfile(name, data);
	wc <-= (len data, nil);
}

rdfile(name: string, nbytes: int): array of byte
{
	s: string;
	case name {
	"source" =>
		s = "hwsim: no hardware, every reading below is invented\n";
	"battery" =>
		if(vbatt > 3000)
			vbatt -= 40;
		s = sys->sprint("%d\n", vbatt);
	"imu" =>
		# Still, level, and not turning: zero field because there
		# is no magnetometer to have one, and 1g down because a
		# board on a bench is the one thing that would be true.
		s = "mag 0 0 0\ngyro 0 0 0\naccel 0 0 1000\n";
	"radioctl" =>
		s = "rssi -137\n";
	"radio" =>
		return nil;			# nothing received, ever
	* =>
		return nil;
	}
	b := array of byte s;
	if(len b > nbytes)
		b = b[0:nbytes];
	return b;
}

wrfile(name: string, data: array of byte)
{
	case name {
	"rgb" =>
		sys->print("\thwsim: RGB %s\n", string data);
	"radio" =>
		sys->print("\thwsim: radio send %d bytes: %s\n",
			len data, string data);
	"radioctl" =>
		cmd := string data;
		case cmd {
		"listen" =>	listening = 1;
		"sleep" =>	listening = 0;
		}
		sys->print("\thwsim: radio %s\n", cmd);
	}
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	dir := "/n/pycubed";
	if(tl argv != nil)
		dir = hd tl argv;

	# Not /dev: that is where a real device's files go, and this is
	# not a device.  The mission is told which directory to use, so
	# the difference is visible rather than hidden.
	if(sys->bind("#s", dir, Sys->MBEFORE) < 0){
		sys->fprint(stderr, "hwsim: bind #s %s: %r\n", dir);
		return;
	}

	files := array[] of {"source", "battery", "rgb", "imu", "radio", "radioctl"};
	fio := array[len files] of ref Sys->FileIO;
	for(i := 0; i < len files; i++){
		fio[i] = sys->file2chan(dir, files[i]);
		if(fio[i] == nil){
			sys->fprint(stderr, "hwsim: file2chan %s: %r\n", files[i]);
			return;
		}
	}
	spawn server(fio, files);
	sys->print("HWSIM-SERVING %s\n", dir);
}
