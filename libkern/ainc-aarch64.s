/*
 * Atomic add for aarch64, the way this tree does an instruction the C
 * compiler has no word for: an assembly function, linked in.  The
 * amd64 and riscv64 files beside this one are the same idea in
 * LOCK/XADDL and AMOADDW.
 *
 * Both return the value the memory holds afterwards, which is what a
 * caller freeing on "did I take it to zero" needs.
 *
 * What was here before was not this.  os/inferno/virtarm64 and
 * os/inferno/raspi3b each defined ainc/adec in C as
 *
 *	s = splhi(); r = ++*addr; splx(s); return r;
 *
 * which excludes an interrupt on the current processor and nothing
 * else -- correct only while MAXMACH is 1, which is what those boards
 * set and what their own comments said.  libinterp calls AINC/ADEC
 * ninety-five times across twelve files for Dis reference counts, so
 * on a second processor that is a lost update and a double free.  See
 * doc/dis-numa-survey.ms.
 *
 * The W-suffixed forms, deliberately: Heap.ref is an int (4 bytes),
 * and os/inferno/virtarm64/l.s records what the 64-bit LDXR/STXR did
 * to the adjacent field when _tas made the same mistake on Lock.key.
 *
 * The operand order below is 7a's, not the manual's: in its "STXR
 * Ws,Xt,[Xn]" grammar the STATUS register is the bare register slot
 * and the VALUE stored is the third operand.  Getting that backwards
 * stores the old contents back over themselves and throws the new
 * value away, silently -- again, l.s carries the full account of that
 * bug.  Hence the separate scratch register for the status result.
 */

TEXT	ainc(SB), 1, $-4		/* int ainc(int*) */
	MOV	R0, R3
ainc1:
	LDXRW	(R3), R1
	ADD	$1, R1, R2
	STXRW	R4, R2, (R3)
	CBNZW	R4, ainc1
	DSB	$15
	MOV	R2, R0
	RET	R30

TEXT	adec(SB), 1, $-4		/* int adec(int*) */
	MOV	R0, R3
adec1:
	LDXRW	(R3), R1
	SUB	$1, R1, R2
	STXRW	R4, R2, (R3)
	CBNZW	R4, adec1
	DSB	$15
	MOV	R2, R0
	RET	R30
