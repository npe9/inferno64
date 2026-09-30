implement Init;

#
# A board that transmits on its own, so that the other board has
# something to hear.
#
# WHY THIS EXISTS.  Plan item 3 -- receive a packet somebody else sent --
# has been the one substantial thing left on this bench for a long time,
# and it was blocked on having no cooperating transmitter.  Every
# negative taken on the air was taken with nothing known to be
# transmitting, and a receiver that hears nothing when nothing is sent
# cannot be told from a deaf one.  There are two boards with ccRF clicks
# now, which closes that.
#
# WHAT IT IS FOR, specifically.  The second board's console does not
# work: it is an RS232 click into a PL2303 where the first board uses a
# USB UART click, and nothing arrives.  The kernel is not the variable --
# it leaves the bootloader, so it runs, and otherusarts() now writes a
# socket-naming line to every USART a clicker 2 brings out -- so what is
# left is signal levels or a DTE-to-DTE cable, neither of which can be
# settled from software.
#
# But item 3 does not need that board's console.  It needs that board to
# TRANSMIT, and the receiving board's console works.  So this init
# configures the radio and beacons without being told to, and a board
# carrying it is useful with no console at all.
#
# It prints as well, on the chance that the console is fixed later, and
# because a board that beacons silently and a board that has not booted
# look identical from the far end.
#
# AND IT FLASHES THE LAMP, which on this board is the only channel that
# works.  Without it there was no way to tell a beacon that is running
# from one that stopped at "no /dev/radio0/ctl", and the difference
# decided what to do next: the first probe of the band from the other
# board found floor -108, peak -104, duty 0 per cent and no bursts, and
# either explanation fitted that equally well.  The lamp is on the
# radio's own Spidev, so it flashing says the part was found, the ctl
# file opened and the loop is turning -- three things at once, and all
# three of them are what "nothing on the air" could otherwise have
# meant.
#
# SELECTION IS BY FILE.  This is chosen by which init the build is given
# -- "mk INIT=armv7mbeacon" -- and not by a flag tested inside
# armv7minit.b.  A board carries a shell or carries this, and which one
# is a property of the image, which is the only thing that can be
# established about a board whose console is silent.
#
# WHERE AND HOW MUCH.  915MHz, inside 902-928, the unlicensed Part 15
# band, at the part's own default output into a click's antenna.  A short
# frame every two seconds, nothing modulated with anything but a fixed
# token, and nothing addressed to anybody.  The same argument as
# tools/radio/txpin.py, which is the only other thing here that keys a
# transmitter.
#

include "sys.m";
	sys: Sys;

include "draw.m";

Init: module
{
	init:	fn();
};

# What goes out, and it is deliberately recognisable: the receiving end
# greps for it, so a buffer of noise that happens to pass CRC does not
# read as a received packet.
Payload:	con "INFERNO-BEACON";
Period:		con 2000;		# ms between frames

init()
{
	sys = load Sys Sys->PATH;
	sys->print("armv7m beacon init\n");

	sys->bind("#p", "/prog", sys->MREPL);
	sys->bind("#d", "/fd", sys->MREPL);
	sys->bind("#c", "/dev", sys->MAFTER);
	sys->bind("#t", "/dev", sys->MAFTER);
	sys->bind("#e", "/env", sys->MREPL|sys->MCREATE);
	sys->bind("#P", "/dev", sys->MAFTER);
	sys->bind("#W", "/dev", sys->MAFTER);
	sys->bind("#J", "/dev", sys->MAFTER);
	sys->bind("#a", "/net", sys->MREPL|sys->MCREATE);
	sys->bind("#k", "/net", sys->MAFTER);

	ctl := sys->open("/dev/radio0/ctl", sys->OWRITE);
	if(ctl == nil){
		# No radio fitted, or #W is not in this kernel.  Say so and
		# stop: there is nothing else for this image to do, and a
		# shell would be a surprise on a board flashed to beacon.
		sys->print("beacon: no /dev/radio0/ctl: %r\n");
		sys->print("ARMV7M-BEACON-NORADIO\n");
		exit;
	}

	# Every value here is one this bench has already checked against
	# the part, and they must match what the receiving board is set to
	# or neither side is testing the other.  bw is 50000 because above
	# that the driver's arithmetic gave nonsense on silicon.
	cfg := array[] of {
		"freq 915000000",
		"rate 9600",
		"deviation 20000",
		"bw 50000",
		"txmode var",
		"sync 0xaaaa 16",
		"csthr -104",
	};
	for(i := 0; i < len cfg; i++){
		b := array of byte cfg[i];
		if(sys->write(ctl, b, len b) < 0){
			sys->print("beacon: %s: %r\n", cfg[i]);
			sys->print("ARMV7M-BEACON-CFGFAILED\n");
			exit;
		}
	}
	sys->print("beacon: configured\n");

	data := sys->open("/dev/radio0/data", sys->OWRITE);
	if(data == nil){
		sys->print("beacon: no /dev/radio0/data: %r\n");
		sys->print("ARMV7M-BEACON-NODATA\n");
		exit;
	}

	# Held open across every frame, rather than opened per frame: the
	# whole reason lil(1) exists is that a file wants holding, and an
	# init has no excuse to do otherwise.
	sys->print("ARMV7M-BEACON-OK\n");
	pkt := array of byte Payload;
	n := 0;
	lamp := 0;
	for(;;){
		if(sys->write(data, pkt, len pkt) < 0)
			sys->print("beacon: frame %d: %r\n", n);
		else if(n % 15 == 0)
			# Every thirtieth second and not every frame: the
			# console is the slow thing here and a print per
			# frame would set the real period rather than
			# Period doing it.
			sys->print("beacon: %d frames\n", n);
		# The lamp flips once per frame, so it is a half-Period
		# square wave: a one-second-on, one-second-off blink at the
		# default Period, which is unmistakably a loop turning and
		# not a pin left somewhere.  Written through the same ctl
		# file that is already open.
		lamp = !lamp;
		cmd := "led off";
		if(lamp)
			cmd = "led on";
		lb := array of byte cmd;
		sys->write(ctl, lb, len lb);
		n++;
		sys->sleep(Period);
	}
}
