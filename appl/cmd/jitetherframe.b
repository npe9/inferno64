implement Jitetherframe;

#
# jitetherframe - etherusb's frame arithmetic, out of etherusb, with a
# checkable answer.
#
# With cflag=1 on the Raspberry Pi 3B the USB ethernet stops passing
# packets while the wifi, which is a kernel driver in C, keeps working;
# and naming Etherusb in the JIT's skip list -- so that one module
# interprets and every other compiles -- brings the ethernet straight
# back.  So the fault is in compiled Etherusb, and the next question is
# which part of it.
#
# This is the part that touches every received and transmitted byte:
# smscrx()'s status-word decode and frame walk, and txwrap()'s command
# header, copied out of appl/cmd/usb/etherusb.b rather than rewritten, so
# that what is tested is what runs.  No USB, no channels, no processes:
# synthetic bursts in, a checksum out.
#
# Run it both ways and compare:
#
#	emu -c0 -r. /dis/jitetherframe.dis
#	emu -c1 -r. /dis/jitetherframe.dis
#
# The host's comp-arm64.c and the board's comp-aarch64.c are the same
# generator, so a difference here is reproducible in a second instead of
# in a four-minute boot.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Jitetherframe: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Rxerror:	con 16r8000;
Txfirst:	con 16r2000;
Txlast:		con 16r1000;

# frames recovered, and a running checksum of their bytes
nframes := 0;
sum := big 0;

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	#
	# Bursts covering the cases the status word can present: a short
	# frame, one needing pad, one with the error bit, one whose length
	# puts a 1 in bit 31 of the status word -- which is the case an int
	# that is 32 bits to the compiler and 64 at runtime is most likely
	# to disagree about.
	#
	for(i := 0; i < 64; i++){
		b := burst(i);
		smscrx(b);
	}
	sys->print("RX frames %d sum %bd\n", nframes, sum);

	tsum := big 0;
	for(i = 0; i < 64; i++){
		f := array[14 + (i*37) % 1000] of byte;
		for(j := 0; j < len f; j++)
			f[j] = byte ((i*7 + j*13) & 16rff);
		t := txwrap(f);
		for(j = 0; j < len t; j++)
			tsum += big int t[j];
	}
	sys->print("TX sum %bd\n", tsum);

	#
	# txproc()'s gather: a channel, a non-blocking alt, and the
	# concatenation that grows the transfer -- "t[len b:] = w" with a
	# COMPUTED offset, which the arithmetic above never exercises
	# because txwrap's own copy is at a constant 8.
	#
	sys->print("BATCH sum %bd\n", batch());
}

Txbatch:	con 8192;

batch(): big
{
	c := chan[64] of array of byte;
	tot := big 0;

	for(r := 0; r < 40; r++){
		for(k := 0; k < 8; k++){
			f := array[14 + (r*13 + k*7) % 900] of byte;
			for(j := 0; j < len f; j++)
				f[j] = byte ((r + k + j) & 16rff);
			c <-= txwrap(f);
		}
		b := <-c;
		nb := 1;
		more := 1;
		while(more && len b + 8 + 1514 <= Txbatch){
			alt {
			g := <-c =>
				t := array[len b + len g] of byte;
				t[0:] = b;
				t[len b:] = g;
				b = t;
				nb++;
			* =>
				more = 0;
			}
		}
		for(j := 0; j < len b; j++)
			tot += big int b[j];
		tot += big (nb * 1000003);
		#
		# drain whatever the gather left, so each round starts clean
		#
		for(;;)
			alt {
			g := <-c =>
				for(j = 0; j < len g; j++)
					tot += big int g[j];
			* =>
				return tot;
			}
	}
	return tot;
}

#
# One synthetic bulk-in transfer: a few frames, each [status][data][pad].
#
burst(seed: int): array of byte
{
	nf := 1 + seed % 4;
	tot := 0;
	lens := array[nf] of int;
	for(i := 0; i < nf; i++){
		lens[i] = 18 + (seed*11 + i*29) % 300;	# incl. the 4-byte FCS
		tot += 4 + ((lens[i] + 3) & ~3);
	}
	b := array[tot] of byte;
	o := 0;
	for(i = 0; i < nf; i++){
		n := lens[i];
		sts := n << 16;
		#
		# The high byte, deliberately.  b[3]<<24 of anything from
		# 0x80 up sets bit 31, and that is the bit whose width the
		# interpreter and a code generator can disagree about.
		#
		hi := 0;
		if((seed & 3) == 0)
			hi = 16r80;	# bit 31 of the status word, on the wire
		if((seed & 7) == 3)
			sts |= Rxerror;
		b[o] = byte sts;
		b[o+1] = byte (sts>>8);
		b[o+2] = byte (sts>>16);
		b[o+3] = byte ((sts>>24) | hi);
		o += 4;
		for(j := 0; j < n; j++)
			b[o+j] = byte ((seed*5 + i*3 + j) & 16rff);
		o += (n + 3) & ~3;
	}
	return b;
}

# copied from etherusb.b, with the channel send replaced by a checksum
smscrx(b: array of byte)
{
	while(len b >= 4){
		sts := int b[0] | int b[1]<<8 | int b[2]<<16 | int b[3]<<24;
		n := (sts>>16) & 16r3fff;
		b = b[4:];
		if(n < 4 || n > len b)
			break;
		if((sts & Rxerror) == 0 && n - 4 >= 14){
			f := array[n-4] of byte;	# strip the FCS
			f[0:] = b[0:n-4];
			nframes++;
			for(j := 0; j < len f; j++)
				sum += big int f[j];
		}
		n = (n + 3) & ~3;
		if(n > len b)
			break;
		b = b[n:];
	}
}

# copied from etherusb.b, the Ksmsc arm
txwrap(f: array of byte): array of byte
{
	n := len f;
	t := array[8+n] of byte;
	a := n | Txfirst | Txlast;
	t[0] = byte a; t[1] = byte (a>>8); t[2] = byte (a>>16); t[3] = byte (a>>24);
	t[4] = byte n; t[5] = byte (n>>8); t[6] = byte (n>>16); t[7] = byte (n>>24);
	t[8:] = f;
	return t;
}
