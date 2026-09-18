#
# The hardware boundary.
#
# Everything here is a register-level driver in the finished port, in C,
# under os/inferno -- phase 2 of doc/pycubed-plan.ms, the 2091 lines of
# Python that become C.  The Limbo above them only ever asks for a
# reading or sets an output, which is why the boundary is this narrow.
#
# There is one implementation in the tree and it touches no hardware:
# appl/pycubed/hwstub.b.  It exists so the mission logic can be run and
# measured on a board that has none of these devices, and it says so on
# every line it prints.  It is not a driver and is not pretending to be.
#

Hw: module
{
	PATH:	con "/dis/pycubed/hwstub.dis";

	init:		fn();
	name:		fn(): string;		# what this implementation is

	# ADM1176 power monitor: battery voltage in millivolts.
	battmv:		fn(): int;

	# The RGB LED on the mainboard.
	rgb:		fn(r, g, b: int);

	# RFM9x LoRa radio.  listen() puts it in receive; recv() returns
	# nil if nothing arrived within tmo milliseconds; send() returns
	# 0 on success.
	radiolisten:	fn();
	radiosleep:	fn();
	radiosend:	fn(msg: array of byte): int;
	radiorecv:	fn(tmo: int): array of byte;
	radiorssi:	fn(): int;

	# BMX160 IMU: magnetometer, gyroscope, acceleration.  Each is
	# three axes, in milli-units, which keeps the mission logic in
	# integers -- the parts this is for have no double-precision
	# floating point (see doc/armv7m-ports.ms).
	imumag:		fn(): array of int;
	imugyro:	fn(): array of int;
	imuaccel:	fn(): array of int;

	# The watchdog and the hard reset the fail-safe path takes.
	reset:		fn();
};
