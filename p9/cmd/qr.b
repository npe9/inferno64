implement Qr;

# A structural, line-by-line translation of Plan 9's real qr(1) -
# sys/src/cmd/qr.c in the 9front tree, 1188 lines (the doc's own
# earlier scoping estimate of 1188 was, for once, exactly right).
# qr(1) encodes standard input as a QR code (ISO/IEC 18004), writing a
# small fixed header ("k8 0 0 side side ") followed by one raw byte
# per module (0 or 16rFF) to standard output - a "grey8" raw image
# meant to be piped into a separate Plan 9 image tool, not a viewable
# file on its own.
#
# A REAL, SEVERE, CONFIRMED BUG IN THE ACTUAL 9FRONT SOURCE, found
# before any Limbo was written - see doc/plan9-port.md item 25 and the
# inferno-rio-qr-encoder-bug memory for the full derivation:
# encode()'s own local `bc` (the bit-count cursor for the bits()
# packing accumulator) is passed to bits() by address on its very
# first call WITHOUT EVER BEING INITIALIZED. This is genuine C
# undefined behaviour (no zero-initialization guarantee for a plain
# local), confirmed empirically by building the real source and
# decoding its own output with a real, independent decoder
# (zxing-cpp): every QR code version 2 and above came out corrupted,
# depending on whatever garbage happened to be on the stack, while
# version 1 (reached without formsel()'s own version-search loop
# running first) happened to decode correctly by accident. A
# negative-control sweep isolated the fix to one line: `bc = 0;`
# before the first bits() call turns 100/100 test cases from garbled
# to byte-exact. THIS CANNOT BE REPRODUCED IN LIMBO, and does not need
# a fidelity decision the way a preserved logic bug would: Limbo
# guarantees every declared variable starts zero-valued, so there is
# no way to write a `bc: int;` here that reads stack garbage the way
# the C local can. This translation is therefore unconditionally
# correct where the C source is only environment-dependently correct.
#
# A second, separate, much smaller oddity in evaluate() (the 8-mask
# quality scorer): `sc = abs(cnt - s*s/2) / (s*s/20) * N4;` is a plain
# `=`, not `+=`, discarding every penalty point the preceding row-scan
# already accumulated into sc. This one IS an ordinary source
# divergence (not undefined behaviour), and is translated literally,
# bug included - comparing the bc-fixed C oracle against `segno` (a
# real, independent pip-installable QR encoder), forcing both to the
# same version/level/mask, still showed the C oracle's own OUTPUT
# decoding perfectly despite the `=`, so this looks like a legitimate
# difference in which of the 8 (all individually valid) masks gets
# picked, not a decode-breaking bug - see the memory file for the
# full reasoning. Because of this, this port's OWN verification does
# NOT compare byte-for-byte against a different implementation like
# segno (the wrong invariant for a spec that permits 8 valid masks) -
# it compares byte-for-byte against the bc-fixed real C source (same
# algorithm, so genuine byte-identity is the right expectation there),
# plus an independent decode-based round trip via zxing-cpp.
#
# A THIRD real oddity in the same function, found the hard way: a
# TRANSLATION bug, not a source one, but caused by the same source
# reading as if it must be a typo. evaluate()'s run-length scan sets
# `r = 0` on every color change and never increments `r` anywhere -
# checked directly against the real source, twice, since this looks
# so much like a missing `r++` that the first translation pass added
# one, on the assumption the obvious fix was clearly intended. It
# is not: the real C's own `r` is provably always 0 at every
# `if(r >= 5)` check (nothing between the resets ever changes it), so
# the "5-or-more-consecutive-modules" mask penalty (N1) is DEAD CODE
# in the deployed source - never fires, on any input. Adding the
# missing increment changed which of the 8 masks scores best on many
# inputs, causing this translation's own qrtest.b to fail on roughly
# half its cases with matching side/length but differing module
# content - not a placement or bit-packing bug, a mask-CHOICE bug.
# Found by testing (a full-suite run showed dozens of failures with
# identical side/len but different bytes), root-caused with a
# minimal single-case diff probe, and confirmed with a genuine
# negative control: reintroducing the `r++` reproduced the exact
# byte-level divergence at a fixed, minimal case (version 2, level Q);
# removing it again returned that case to zero byte differences. Left
# as dead code here, exactly as in the source - the lesson generalizes
# from dc.c's own dead `readc()` branch and cbtype.c's undefined-range
# access: read the actual arithmetic before "fixing" what looks like
# an oversight, especially in a function already known (via the `=`/
# `+=` note above) to carry at least one real, deliberate-looking quirk.
#
# Other translation notes:
#   - `atab[]` (cb.h's own kind of sparse designated-initializer table,
#     here indexed by raw input bytes in ANUM mode) is sized to 256
#     entries, not the C's implicit 59 (':'+1) - the same ctype-table
#     range-safety fix cb.b's own cbtype[] needed, for the same reason:
#     an input byte >= 59 is undefined behaviour in C (reads adjacent
#     statics) and would be a hard bounds-check fault in Limbo.
#   - `finalize()`'s C code treats the pattern buffer as `char*`
#     (signed) and does an ARITHMETIC right shift by 4. Limbo has no
#     signed byte type to replicate that with directly - but every
#     byte that ever reaches finalize() is provably one of exactly
#     four values: 0 and 16rff (every "fixed pattern" cell - finder,
#     timing, alignment, format, version - all written as one of
#     these two full-byte values, never anything else, confirmed by
#     reading every write site) or 16r0f and 16rf0 (fill()'s own
#     data-bit cells, which encode a bit in only one nibble). The C's
#     arithmetic shift maps 0->0, 16rff->16rff, 16r0f->0 (16r0f as a
#     signed byte is positive, shifts to 0), 16rf0->16rff (16rf0 as a
#     signed byte is negative, sign-extends to all-1s) - i.e. exactly
#     "is the top bit set?". Translated as that direct bit test, not a
#     signed-shift emulation, since the smaller, provably-equivalent
#     formula for this file's own four cases is clearer than faking C's
#     signedness with no analogue in Limbo.
#   - All of the small numeric lookup tables (gpexp/gplog/side/align/
#     cap/qrsizes/qrrawpolys/atab, and `polys[]` itself) are plain
#     `array of int`, not `array of byte` - they are numeric lookup
#     data exercised in arithmetic throughout, never raw I/O bytes, the
#     same distinction this backlog has drawn before (e.g. cb.b's own
#     keytype[]/opblanks[] as int arrays vs. its raw-byte strbuf/temp).
#     The actual data/codeword/pixel buffers (input, the encode()/
#     codewords() buffers, the returned pixel bitmap) stay
#     `array of byte`, since those genuinely are byte-for-byte I/O
#     content.
#   - `uchar *polys[69]`, an array of pointers into the middle of
#     qrrawpolys[], becomes `array of array of int` - `polys[el]` is a
#     freshly-sliced small array of the el log-coefficients for that
#     EC length, built once by qrinit()'s own walk of qrrawpolys,
#     exactly mirroring the C's own single-pass parse (including its
#     own slightly indirect "in" bookkeeping, checked by simulation
#     before translating: parses all 31 real generator-polynomial
#     lengths (7..68) cleanly with no corruption, confirmed by
#     counting distinct keys before writing a line of Limbo).
#   - `uchar *blocks[160]`, likewise a pointer into the middle of
#     qrsizes[], becomes `blockidx: array of int` - blockidx[verlev]
#     holds the flat starting INDEX into qrsizes (still 4 ints per
#     row) of the first row for that verlev, or -1 if none (C's own
#     implicit "never assigned, stays 0/NULL" - Limbo has no null
#     pointer for this shape, so -1 is the explicit sentinel).
#   - Every C operator-precedence spot the compiler itself warned about
#     (`bits + lbits + 7 >> 3`, `i << 2 | level`, `version - 1 << 2 |
#     level`) is given EXPLICIT parentheses here matching the C's own
#     actual precedence (+/- bind tighter than <</>>, matching Limbo's
#     own precedence table too), not left ambiguous.
#   - No dynamic memory management translation is needed anywhere
#     (malloc/free throughout the C map to ordinary Limbo array
#     allocation and the garbage collector).

include "sys.m";
	sys: Sys;
	FD: import Sys;
include "draw.m";
	Context: import Draw;

Qr: module
{
	init:	fn(ctxt: ref Context, argv: list of string);

	# in-process test seam: args is the flag list only (as main()'s
	# own ARGBEGIN loop would see it - "-L"/"-M"/"-Q"/"-H", "-v","N",
	# "-n"/"-a"), data is exactly what would otherwise be read from
	# standard input. Returns the raw pixel bitmap (side*side bytes,
	# each exactly 0 or 16rFF) plus the side length, matching
	# qrcode()'s own (buffer, side) result. Raises "fail:qr" on error
	# (data too large for the requested version, or for every version
	# up to 40), matching qrcode()'s own nil-return-on-error contract.
	run:	fn(args: list of string, data: array of byte): (array of byte, int);
};

stderr: ref FD;

# --- mode constants (cb.h-style: renumbered from the C's own literal
# bit values 1/2/4 is NOT safe here, since NUM/ANUM/BYTE are used only
# as opaque tags in switches/comparisons, never bit-tested - but kept
# as the literal C values anyway, for direct readability against the
# source). ---
NUM: con 1;
ANUM: con 2;
BYTE: con 4;

# --- GF(256) log/antilog tables, verbatim from qr.c. ---
gpexp := array[] of {
	1, 2, 4, 8, 16, 32, 64, 128, 29, 58, 116, 232, 205, 135, 19, 38, 76,
	152, 45, 90, 180, 117, 234, 201, 143, 3, 6, 12, 24, 48, 96, 192, 157,
	39, 78, 156, 37, 74, 148, 53, 106, 212, 181, 119, 238, 193, 159, 35,
	70, 140, 5, 10, 20, 40, 80, 160, 93, 186, 105, 210, 185, 111, 222,
	161, 95, 190, 97, 194, 153, 47, 94, 188, 101, 202, 137, 15, 30, 60,
	120, 240, 253, 231, 211, 187, 107, 214, 177, 127, 254, 225, 223, 163,
	91, 182, 113, 226, 217, 175, 67, 134, 17, 34, 68, 136, 13, 26, 52,
	104, 208, 189, 103, 206, 129, 31, 62, 124, 248, 237, 199, 147, 59,
	118, 236, 197, 151, 51, 102, 204, 133, 23, 46, 92, 184, 109, 218,
	169, 79, 158, 33, 66, 132, 21, 42, 84, 168, 77, 154, 41, 82, 164, 85,
	170, 73, 146, 57, 114, 228, 213, 183, 115, 230, 209, 191, 99, 198,
	145, 63, 126, 252, 229, 215, 179, 123, 246, 241, 255, 227, 219, 171,
	75, 150, 49, 98, 196, 149, 55, 110, 220, 165, 87, 174, 65, 130, 25,
	50, 100, 200, 141, 7, 14, 28, 56, 112, 224, 221, 167, 83, 166, 81,
	162, 89, 178, 121, 242, 249, 239, 195, 155, 43, 86, 172, 69, 138, 9,
	18, 36, 72, 144, 61, 122, 244, 245, 247, 243, 251, 235, 203, 139, 11,
	22, 44, 88, 176, 125, 250, 233, 207, 131, 27, 54, 108, 216, 173, 71,
	142
};

gplog := array[] of {
	0, 0, 1, 25, 2, 50, 26, 198, 3, 223, 51, 238, 27, 104, 199, 75, 4, 100,
	224, 14, 52, 141, 239, 129, 28, 193, 105, 248, 200, 8, 76, 113, 5,
	138, 101, 47, 225, 36, 15, 33, 53, 147, 142, 218, 240, 18, 130, 69,
	29, 181, 194, 125, 106, 39, 249, 185, 201, 154, 9, 120, 77, 228, 114,
	166, 6, 191, 139, 98, 102, 221, 48, 253, 226, 152, 37, 179, 16, 145,
	34, 136, 54, 208, 148, 206, 143, 150, 219, 189, 241, 210, 19, 92,
	131, 56, 70, 64, 30, 66, 182, 163, 195, 72, 126, 110, 107, 58, 40,
	84, 250, 133, 186, 61, 202, 94, 155, 159, 10, 21, 121, 43, 78, 212,
	229, 172, 115, 243, 167, 87, 7, 112, 192, 247, 140, 128, 99, 13, 103,
	74, 222, 237, 49, 197, 254, 24, 227, 165, 153, 119, 38, 184, 180,
	124, 17, 68, 146, 217, 35, 32, 137, 46, 55, 63, 209, 91, 149, 188,
	207, 205, 144, 135, 151, 178, 220, 252, 190, 97, 242, 86, 211, 171,
	20, 42, 93, 158, 132, 60, 57, 83, 71, 109, 65, 162, 31, 45, 67, 216,
	183, 123, 164, 118, 196, 23, 73, 236, 127, 12, 111, 246, 108, 161,
	59, 82, 41, 157, 85, 170, 251, 96, 134, 177, 187, 204, 62, 90, 203,
	89, 95, 176, 156, 169, 160, 81, 11, 245, 22, 235, 122, 117, 44, 215,
	79, 174, 213, 233, 230, 231, 173, 232, 116, 214, 244, 234, 168, 80,
	88, 175
};

# polys[el] = the el log-coefficients (highest coefficient first,
# implicit leading 1) for the generator polynomial with el EC bytes -
# built once by qrinit(). nil where unused, matching the C's own
# zero-initialized (never-assigned) pointer slots.
polys: array of array of int;

# cap[verlev] = total data-byte capacity for that (version,level) combo.
cap: array of int;

# blockidx[verlev] = flat starting index into qrsizes (still 4 ints
# per logical row) of the first row for that verlev, or -1 if none.
blockidx: array of int;

side := array[] of {
	21, 25, 29, 33, 37, 41, 45, 49,
	53, 57, 61, 65, 69, 73, 77, 81,
	85, 89, 93, 97, 101, 105, 109, 113,
	117, 121, 125, 129, 133, 137, 141, 145,
	149, 153, 157, 161, 165, 169, 173, 177
};

align := array[] of {
	array[] of {0},
	array[] of {6, 18, 0},
	array[] of {6, 22, 0},
	array[] of {6, 26, 0},
	array[] of {6, 30, 0},
	array[] of {6, 34, 0},
	array[] of {6, 22, 38, 0},
	array[] of {6, 24, 42, 0},
	array[] of {6, 26, 46, 0},
	array[] of {6, 28, 50, 0},
	array[] of {6, 30, 54, 0},
	array[] of {6, 32, 58, 0},
	array[] of {6, 34, 62, 0},
	array[] of {6, 26, 46, 66, 0},
	array[] of {6, 26, 48, 70, 0},
	array[] of {6, 26, 50, 74, 0},
	array[] of {6, 30, 54, 78, 0},
	array[] of {6, 30, 56, 82, 0},
	array[] of {6, 30, 58, 86, 0},
	array[] of {6, 34, 62, 90, 0},
	array[] of {6, 28, 50, 72, 94, 0},
	array[] of {6, 26, 50, 74, 98, 0},
	array[] of {6, 30, 54, 78, 102, 0},
	array[] of {6, 28, 54, 80, 106, 0},
	array[] of {6, 32, 58, 84, 110, 0},
	array[] of {6, 30, 58, 86, 114, 0},
	array[] of {6, 34, 62, 90, 118, 0},
	array[] of {6, 26, 50, 74, 98, 122, 0},
	array[] of {6, 30, 54, 78, 102, 126, 0},
	array[] of {6, 26, 52, 78, 104, 130, 0},
	array[] of {6, 30, 56, 82, 108, 134, 0},
	array[] of {6, 34, 60, 86, 112, 138, 0},
	array[] of {6, 30, 58, 86, 114, 142, 0},
	array[] of {6, 34, 62, 90, 118, 146, 0},
	array[] of {6, 30, 54, 78, 102, 126, 150, 0},
	array[] of {6, 24, 50, 76, 102, 128, 154, 0},
	array[] of {6, 28, 54, 80, 106, 132, 158, 0},
	array[] of {6, 32, 58, 84, 110, 136, 162, 0},
	array[] of {6, 26, 54, 82, 110, 138, 166, 0},
	array[] of {6, 30, 58, 86, 114, 142, 170, 0}
};

# --- qrrawpolys[], verbatim from qr.c (the length-prefixed run of
# generator-polynomial log-coefficients, terminated by "0, 0"). ---
qrrawpolys := array[] of {
	7, 87, 229, 146, 149, 238, 102, 21,
	0, 10, 251, 67, 46, 61, 118, 70,
	64, 94, 32, 45, 0, 13, 74, 152,
	176, 100, 86, 100, 106, 104, 130, 218,
	206, 140, 78, 0, 15, 8, 183, 61,
	91, 202, 37, 51, 58, 58, 237, 140,
	124, 5, 99, 105, 0, 16, 120, 104,
	107, 109, 102, 161, 76, 3, 91, 191,
	147, 169, 182, 194, 225, 120, 0, 17,
	43, 139, 206, 78, 43, 239, 123, 206,
	214, 147, 24, 99, 150, 39, 243, 163,
	136, 0, 18, 215, 234, 158, 94, 184,
	97, 118, 170, 79, 187, 152, 148, 252,
	179, 5, 98, 96, 153, 0, 20, 17,
	60, 79, 50, 61, 163, 26, 187, 202,
	180, 221, 225, 83, 239, 156, 164, 212,
	212, 188, 190, 0, 22, 210, 171, 247,
	242, 93, 230, 14, 109, 221, 53, 200,
	74, 8, 172, 98, 80, 219, 134, 160,
	105, 165, 231, 0, 24, 229, 121, 135,
	48, 211, 117, 251, 126, 159, 180, 169,
	152, 192, 226, 228, 218, 111, 117, 232,
	87, 96, 227, 21, 0, 26, 173, 125,
	158, 2, 103, 182, 118, 17, 145, 201,
	111, 28, 165, 53, 161, 21, 245, 142,
	13, 102, 48, 227, 153, 145, 218, 70,
	0, 28, 168, 223, 200, 104, 224, 234,
	108, 180, 110, 190, 195, 147, 205, 27,
	232, 201, 21, 43, 245, 87, 42, 195,
	212, 119, 242, 37, 9, 123, 0, 30,
	41, 173, 145, 152, 216, 31, 179, 182,
	50, 48, 110, 86, 239, 96, 222, 125,
	42, 173, 226, 193, 224, 130, 156, 37,
	251, 216, 238, 40, 192, 180, 0, 32,
	10, 6, 106, 190, 249, 167, 4, 67,
	209, 138, 138, 32, 242, 123, 89, 27,
	120, 185, 80, 156, 38, 69, 171, 60,
	28, 222, 80, 52, 254, 185, 220, 241,
	0, 34, 111, 77, 146, 94, 26, 21,
	108, 19, 105, 94, 113, 193, 86, 140,
	163, 125, 58, 158, 229, 239, 218, 103,
	56, 70, 114, 61, 183, 129, 167, 13,
	98, 62, 129, 51, 0, 36, 200, 183,
	98, 16, 172, 31, 246, 234, 60, 152,
	115, 167, 152, 113, 248, 238, 107, 18,
	63, 218, 37, 87, 210, 105, 177, 120,
	74, 121, 196, 117, 251, 113, 233, 30,
	120, 0, 40, 59, 116, 79, 161, 252,
	98, 128, 205, 128, 161, 247, 57, 163,
	56, 235, 106, 53, 26, 187, 174, 226,
	104, 170, 7, 175, 35, 181, 114, 88,
	41, 47, 163, 125, 134, 72, 20, 232,
	53, 35, 15, 0, 42, 250, 103, 221,
	230, 25, 18, 137, 231, 3, 58, 242,
	221, 191, 110, 84, 230, 8, 188, 106,
	96, 147, 15, 131, 139, 34, 101, 223,
	39, 101, 213, 199, 237, 254, 201, 123,
	171, 162, 194, 117, 50, 96, 0, 44,
	190, 7, 61, 121, 71, 246, 69, 55,
	168, 188, 89, 243, 191, 25, 72, 123,
	9, 145, 14, 247, 238, 44, 78, 143,
	62, 224, 126, 118, 114, 68, 163, 52,
	194, 217, 147, 204, 169, 37, 130, 113,
	102, 73, 181, 0, 46, 112, 94, 88,
	112, 253, 224, 202, 115, 187, 99, 89,
	5, 54, 113, 129, 44, 58, 16, 135,
	216, 169, 211, 36, 4, 96, 60, 241,
	73, 104, 234, 8, 249, 245, 119, 174,
	52, 25, 157, 224, 43, 202, 223, 19,
	82, 15, 0, 48, 228, 25, 196, 130,
	211, 146, 60, 24, 251, 90, 39, 102,
	240, 61, 178, 63, 46, 123, 115, 18,
	221, 111, 135, 160, 182, 205, 107, 206,
	95, 150, 120, 184, 91, 21, 247, 156,
	140, 238, 191, 11, 94, 227, 84, 50,
	163, 39, 34, 108, 0, 50, 232, 125,
	157, 161, 164, 9, 118, 46, 209, 99,
	203, 193, 35, 3, 209, 111, 195, 242,
	203, 225, 46, 13, 32, 160, 126, 209,
	130, 160, 242, 215, 242, 75, 77, 42,
	189, 32, 113, 65, 124, 69, 228, 114,
	235, 175, 124, 170, 215, 232, 133, 205,
	0, 52, 116, 50, 86, 186, 50, 220,
	251, 89, 192, 46, 86, 127, 124, 19,
	184, 233, 151, 215, 22, 14, 59, 145,
	37, 242, 203, 134, 254, 89, 190, 94,
	59, 65, 124, 113, 100, 233, 235, 121,
	22, 76, 86, 97, 39, 242, 200, 220,
	101, 33, 239, 254, 116, 51, 0, 54,
	183, 26, 201, 87, 210, 221, 113, 21,
	46, 65, 45, 50, 238, 184, 249, 225,
	102, 58, 209, 218, 109, 165, 26, 95,
	184, 192, 52, 245, 35, 254, 238, 175,
	172, 79, 123, 25, 122, 43, 120, 108,
	215, 80, 128, 201, 235, 8, 153, 59,
	101, 31, 198, 76, 31, 156, 0, 56,
	106, 120, 107, 157, 164, 216, 112, 116,
	2, 91, 248, 163, 36, 201, 202, 229,
	6, 144, 254, 155, 135, 208, 170, 209,
	12, 139, 127, 142, 182, 249, 177, 174,
	190, 28, 10, 85, 239, 184, 101, 124,
	152, 206, 96, 23, 163, 61, 27, 196,
	247, 151, 154, 202, 207, 20, 61, 10,
	0, 58, 82, 116, 26, 247, 66, 27,
	62, 107, 252, 182, 200, 185, 235, 55,
	251, 242, 210, 144, 154, 237, 176, 141,
	192, 248, 152, 249, 206, 85, 253, 142,
	65, 165, 125, 23, 24, 30, 122, 240,
	214, 6, 129, 218, 29, 145, 127, 134,
	206, 245, 117, 29, 41, 63, 159, 142,
	233, 125, 148, 123, 0, 60, 107, 140,
	26, 12, 9, 141, 243, 197, 226, 197,
	219, 45, 211, 101, 219, 120, 28, 181,
	127, 6, 100, 247, 2, 205, 198, 57,
	115, 219, 101, 109, 160, 82, 37, 38,
	238, 49, 160, 209, 121, 86, 11, 124,
	30, 181, 84, 25, 194, 87, 65, 102,
	190, 220, 70, 27, 209, 16, 89, 7,
	33, 240, 0, 62, 65, 202, 113, 98,
	71, 223, 248, 118, 214, 94, 122, 37,
	23, 2, 228, 58, 121, 7, 105, 135,
	78, 243, 118, 70, 76, 223, 89, 72,
	50, 70, 111, 194, 17, 212, 126, 181,
	35, 221, 117, 235, 11, 229, 149, 147,
	123, 213, 40, 115, 6, 200, 100, 26,
	246, 182, 218, 127, 215, 36, 186, 110,
	106, 0, 64, 45, 51, 175, 9, 7,
	158, 159, 49, 68, 119, 92, 123, 177,
	204, 187, 254, 200, 78, 141, 149, 119,
	26, 127, 53, 160, 93, 199, 212, 29,
	24, 145, 156, 208, 150, 218, 209, 4,
	216, 91, 47, 184, 146, 47, 140, 195,
	195, 125, 242, 238, 63, 99, 108, 140,
	230, 242, 31, 204, 11, 178, 243, 217,
	156, 213, 231, 0, 66, 5, 118, 222,
	180, 136, 136, 162, 51, 46, 117, 13,
	215, 81, 17, 139, 247, 197, 171, 95,
	173, 65, 137, 178, 68, 111, 95, 101,
	41, 72, 214, 169, 197, 95, 7, 44,
	154, 77, 111, 236, 40, 121, 143, 63,
	87, 80, 253, 240, 126, 217, 77, 34,
	232, 106, 50, 168, 82, 76, 146, 67,
	106, 171, 25, 132, 93, 45, 105, 0,
	68, 247, 159, 223, 33, 224, 93, 77,
	70, 90, 160, 32, 254, 43, 150, 84,
	101, 190, 205, 133, 52, 60, 202, 165,
	220, 203, 151, 93, 84, 15, 84, 253,
	173, 160, 89, 227, 52, 199, 97, 95,
	231, 52, 177, 41, 125, 137, 241, 166,
	225, 118, 2, 54, 32, 82, 215, 175,
	198, 43, 238, 235, 27, 101, 184, 127,
	3, 5, 8, 163, 238, 0, 0
};

# --- qrsizes[], verbatim from qr.c (4 ints per logical row:
# (version-1)*4+level, number of blocks, bytes/block, data bytes/block;
# terminated by a "0,0,0,0" sentinel row). ---
qrsizes := array[] of {
	0, 1, 26, 19,
	1, 1, 26, 16,
	2, 1, 26, 13,
	3, 1, 26, 9,
	4, 1, 44, 34,
	5, 1, 44, 28,
	6, 1, 44, 22,
	7, 1, 44, 16,
	8, 1, 70, 55,
	9, 1, 70, 44,
	10, 2, 35, 17,
	11, 2, 35, 13,
	12, 1, 100, 80,
	13, 2, 50, 32,
	14, 2, 50, 24,
	15, 4, 25, 9,
	16, 1, 134, 108,
	17, 2, 67, 43,
	18, 2, 33, 15,
	18, 2, 34, 16,
	19, 2, 33, 11,
	19, 2, 34, 12,
	20, 2, 86, 68,
	21, 4, 43, 27,
	22, 4, 43, 19,
	23, 4, 43, 15,
	24, 2, 98, 78,
	25, 4, 49, 31,
	26, 2, 32, 14,
	26, 4, 33, 15,
	27, 4, 39, 13,
	27, 1, 40, 14,
	28, 2, 121, 97,
	29, 2, 60, 38,
	29, 2, 61, 39,
	30, 4, 40, 18,
	30, 2, 41, 19,
	31, 4, 40, 14,
	31, 2, 41, 15,
	32, 2, 146, 116,
	33, 3, 58, 36,
	33, 2, 59, 37,
	34, 4, 36, 16,
	34, 4, 37, 17,
	35, 4, 36, 12,
	35, 4, 37, 13,
	36, 2, 86, 68,
	36, 2, 87, 69,
	37, 4, 69, 43,
	37, 1, 70, 44,
	38, 6, 43, 19,
	38, 2, 44, 20,
	39, 6, 43, 15,
	39, 2, 44, 16,
	40, 4, 101, 81,
	41, 1, 80, 50,
	41, 4, 81, 51,
	42, 4, 50, 22,
	42, 4, 51, 23,
	43, 3, 36, 12,
	43, 8, 37, 13,
	44, 2, 116, 92,
	44, 2, 117, 93,
	45, 6, 58, 36,
	45, 2, 59, 37,
	46, 4, 46, 20,
	46, 6, 47, 21,
	47, 7, 42, 14,
	47, 4, 43, 15,
	48, 4, 133, 107,
	49, 8, 59, 37,
	49, 1, 60, 38,
	50, 8, 44, 20,
	50, 4, 45, 21,
	51, 12, 33, 11,
	51, 4, 34, 12,
	52, 3, 145, 115,
	52, 1, 146, 116,
	53, 4, 64, 40,
	53, 5, 65, 41,
	54, 11, 36, 16,
	54, 5, 37, 17,
	55, 11, 36, 12,
	55, 5, 37, 13,
	56, 5, 109, 87,
	56, 1, 110, 88,
	57, 5, 65, 41,
	57, 5, 66, 42,
	58, 5, 54, 24,
	58, 7, 55, 25,
	59, 11, 36, 12,
	59, 7, 37, 13,
	60, 5, 122, 98,
	60, 1, 123, 99,
	61, 7, 73, 45,
	61, 3, 74, 46,
	62, 15, 43, 19,
	62, 2, 44, 20,
	63, 3, 45, 15,
	63, 13, 46, 16,
	64, 1, 135, 107,
	64, 5, 136, 108,
	65, 10, 74, 46,
	65, 1, 75, 47,
	66, 1, 50, 22,
	66, 15, 51, 23,
	67, 2, 42, 14,
	67, 17, 43, 15,
	68, 5, 150, 120,
	68, 1, 151, 121,
	69, 9, 69, 43,
	69, 4, 70, 44,
	70, 17, 50, 22,
	70, 1, 51, 23,
	71, 2, 42, 14,
	71, 19, 43, 15,
	72, 3, 141, 113,
	72, 4, 142, 114,
	73, 3, 70, 44,
	73, 11, 71, 45,
	74, 17, 47, 21,
	74, 4, 48, 22,
	75, 9, 39, 13,
	75, 16, 40, 14,
	76, 3, 135, 107,
	76, 5, 136, 108,
	77, 3, 67, 41,
	77, 13, 68, 42,
	78, 15, 54, 24,
	78, 5, 55, 25,
	79, 15, 43, 15,
	79, 10, 44, 16,
	80, 4, 144, 116,
	80, 4, 145, 117,
	81, 17, 68, 42,
	82, 17, 50, 22,
	82, 6, 51, 23,
	83, 19, 46, 16,
	83, 6, 47, 17,
	84, 2, 139, 111,
	84, 7, 140, 112,
	85, 17, 74, 46,
	86, 7, 54, 24,
	86, 16, 55, 25,
	87, 34, 37, 13,
	88, 4, 151, 121,
	88, 5, 152, 122,
	89, 4, 75, 47,
	89, 14, 76, 48,
	90, 11, 54, 24,
	90, 14, 55, 25,
	91, 16, 45, 15,
	91, 14, 46, 16,
	92, 6, 147, 117,
	92, 4, 148, 118,
	93, 6, 73, 45,
	93, 14, 74, 46,
	94, 11, 54, 24,
	94, 16, 55, 25,
	95, 30, 46, 16,
	95, 2, 47, 17,
	96, 8, 132, 106,
	96, 4, 133, 107,
	97, 8, 75, 47,
	97, 13, 76, 48,
	98, 7, 54, 24,
	98, 22, 55, 25,
	99, 22, 45, 15,
	99, 13, 46, 16,
	100, 10, 142, 114,
	100, 2, 143, 115,
	101, 19, 74, 46,
	101, 4, 75, 47,
	102, 28, 50, 22,
	102, 6, 51, 23,
	103, 33, 46, 16,
	103, 4, 47, 17,
	104, 8, 152, 122,
	104, 4, 153, 123,
	105, 22, 73, 45,
	105, 3, 74, 46,
	106, 8, 53, 23,
	106, 26, 54, 24,
	107, 12, 45, 15,
	107, 28, 46, 16,
	108, 3, 147, 117,
	108, 10, 148, 118,
	109, 3, 73, 45,
	109, 23, 74, 46,
	110, 4, 54, 24,
	110, 31, 55, 25,
	111, 11, 45, 15,
	111, 31, 46, 16,
	112, 7, 146, 116,
	112, 7, 147, 117,
	113, 21, 73, 45,
	113, 7, 74, 46,
	114, 1, 53, 23,
	114, 37, 54, 24,
	115, 19, 45, 15,
	115, 26, 46, 16,
	116, 5, 145, 115,
	116, 10, 146, 116,
	117, 19, 75, 47,
	117, 10, 76, 48,
	118, 15, 54, 24,
	118, 25, 55, 25,
	119, 23, 45, 15,
	119, 25, 46, 16,
	120, 13, 145, 115,
	120, 3, 146, 116,
	121, 2, 74, 46,
	121, 29, 75, 47,
	122, 42, 54, 24,
	122, 1, 55, 25,
	123, 23, 45, 15,
	123, 28, 46, 16,
	124, 17, 145, 115,
	125, 10, 74, 46,
	125, 23, 75, 47,
	126, 10, 54, 24,
	126, 35, 55, 25,
	127, 19, 45, 15,
	127, 35, 46, 16,
	128, 17, 145, 115,
	128, 1, 146, 116,
	129, 14, 74, 46,
	129, 21, 75, 47,
	130, 29, 54, 24,
	130, 19, 55, 25,
	131, 11, 45, 15,
	131, 46, 46, 16,
	132, 13, 145, 115,
	132, 6, 146, 116,
	133, 14, 74, 46,
	133, 23, 75, 47,
	134, 44, 54, 24,
	134, 7, 55, 25,
	135, 59, 46, 16,
	135, 1, 47, 17,
	136, 12, 151, 121,
	136, 7, 152, 122,
	137, 12, 75, 47,
	137, 26, 76, 48,
	138, 39, 54, 24,
	138, 14, 55, 25,
	139, 22, 45, 15,
	139, 41, 46, 16,
	140, 6, 151, 121,
	140, 14, 152, 122,
	141, 6, 75, 47,
	141, 34, 76, 48,
	142, 46, 54, 24,
	142, 10, 55, 25,
	143, 2, 45, 15,
	143, 64, 46, 16,
	144, 17, 152, 122,
	144, 4, 153, 123,
	145, 29, 74, 46,
	145, 14, 75, 47,
	146, 49, 54, 24,
	146, 10, 55, 25,
	147, 24, 45, 15,
	147, 46, 46, 16,
	148, 4, 152, 122,
	148, 18, 153, 123,
	149, 13, 74, 46,
	149, 32, 75, 47,
	150, 48, 54, 24,
	150, 14, 55, 25,
	151, 42, 45, 15,
	151, 32, 46, 16,
	152, 20, 147, 117,
	152, 4, 148, 118,
	153, 40, 75, 47,
	153, 7, 76, 48,
	154, 43, 54, 24,
	154, 22, 55, 25,
	155, 10, 45, 15,
	155, 67, 46, 16,
	156, 19, 148, 118,
	156, 6, 149, 119,
	157, 18, 75, 47,
	157, 31, 76, 48,
	158, 34, 54, 24,
	158, 34, 55, 25,
	159, 20, 45, 15,
	159, 61, 46, 16,
	0, 0, 0, 0
};

# atab[], sized 256 (not the C's implicit 59) - see header comment.
# ['0']=1..10, ['A'..'Z']/['a'..'z']=11..36, then the punctuation set.
atab: array of int;

initatab()
{
	atab = array[256] of int;
	for(i := 0; i <= 9; i++)
		atab['0' + i] = i + 1;
	for(i = 0; i <= 25; i++){
		atab['A' + i] = i + 11;
		atab['a' + i] = i + 11;
	}
	atab[' '] = 37;
	atab['$'] = 38;
	atab['%'] = 39;
	atab['*'] = 40;
	atab['+'] = 41;
	atab['-'] = 42;
	atab['.'] = 43;
	atab['/'] = 44;
	atab[':'] = 45;
}

# --- qrinit(): parse qrrawpolys[] into polys[], and qrsizes[] into
# cap[]/blockidx[] - both walked exactly once, mirroring the C's own
# single init pass (qrinit() itself is idempotent and safe to call
# more than once, matching the C, which calls it unconditionally at
# the top of every qrcode() invocation). ---
qrinit()
{
	polys = array[69] of array of int;
	inrun, p, hdr: int;

	inrun = 0;
	p = 0;
	for(;;){
		if(inrun == 0 && qrrawpolys[p] == 0)
			break;
		if(inrun == 0){
			hdr = qrrawpolys[p];
			coeffs := array[hdr] of int;
			for(i := 0; i < hdr; i++)
				coeffs[i] = qrrawpolys[p + 1 + i];
			polys[hdr] = coeffs;
		}
		inrun = qrrawpolys[p];
		p++;
	}

	cap = array[160] of int;
	blockidx = array[160] of int;
	for(i := 0; i < 160; i++)
		blockidx[i] = -1;
	p = 0;
	while(qrsizes[p] != 0 || qrsizes[p+1] != 0){
		v := qrsizes[p];
		cap[v] += qrsizes[p+1] * qrsizes[p+3];
		if(blockidx[v] == -1)
			blockidx[v] = p;
		p += 4;
	}
}

# --- bits(): the core bit-packing accumulator. b/elen/bctr are the
# C's own uchar*/int*/int* triple, all passed here as a buffer plus
# two ref cells (Limbo has no bare "int*" - a one-element array of int
# stands in for each out-parameter, matching the established
# convention elsewhere in this backlog for a C out-param). ---
bits(b: array of byte, elenr, bctrr: array of int, data: int, n: int)
{
	l, bc, s: int;

	l = elenr[0];
	bc = bctrr[0];

	s = int b[l] << n | data;
	bc += n;
	while(bc > 8){
		bc -= 8;
		b[l] = byte (s >> bc);
		l++;
	}
	b[l] = byte s;
	if(bc == 8){
		l++;
		bc = 0;
	}

	elenr[0] = l;
	bctrr[0] = bc;
}

getlbits(version: int, mode: int): int
{
	if(version <= 9){
		case mode {
		NUM => return 10;
		ANUM => return 9;
		BYTE => return 8;
		}
	}else if(version <= 26){
		case mode {
		NUM => return 12;
		ANUM => return 11;
		BYTE => return 16;
		}
	}else{
		case mode {
		NUM => return 14;
		ANUM => return 13;
		BYTE => return 16;
		}
	}
	return -1;
}

# formsel(): picks the smallest (version,level) combo (as verlev =
# (version-1)*4+level) that fits dlen bytes of mode data, or a
# specific forced version if ver != 0. nchar is filled with the
# character count formsel() itself computed (digits-only for NUM,
# alnum-only for ANUM, dlen itself for BYTE). Returns -1 on failure
# (16rff in the C, since verlev is a uchar there and -1 doesn't fit -
# Limbo has no such width constraint, so plain -1 is used as the
# sentinel throughout this file, not 16rff).
formsel(ver: int, level: int, mode: int, data: array of byte, dlen: int, ncharr: array of int): int
{
	nbits, lbits, i, n: int;

	nbits = 8;
	case mode {
	NUM =>
		n = 0;
		for(i = 0; i < dlen; i++)
			if(isdigit(int data[i]))
				n++;
		ncharr[0] = n;
		nbits += 10 * (n / 3);
		case n % 3 {
		1 => nbits += 4;
		2 => nbits += 7;
		}
	ANUM =>
		n = 0;
		for(i = 0; i < dlen; i++)
			if(atab[int data[i]] != 0)
				n++;
		ncharr[0] = n;
		nbits += 11 * (n >> 1) + 6 * (n & 1);
	BYTE =>
		nbits += 8 * dlen;
		ncharr[0] = dlen;
	}

	if(ver == 0){
		lbits = 0;
		for(i = 0; i < 40; i++){
			if(i == 0 || i == 10 || i == 27){
				lbits = getlbits(i + 1, mode);
				if(lbits < 0)
					return -1;
			}
			if(cap[(i << 2) | level] >= ((nbits + lbits + 7) >> 3))
				return (i << 2) | level;
		}
	}else{
		lbits = getlbits(ver, mode);
		if(lbits < 0)
			return -1;
		if(cap[((ver - 1) << 2) | level] >= ((nbits + lbits + 7) >> 3))
			return ((ver - 1) << 2) | level;
	}
	return -1;
}

# encode(): packs data into codeword bytes (mode header, count field,
# payload, terminator, then 0xec/0x11 pad bytes to fill the block's
# own capacity) - see this file's own header comment for the encode()
# `bc` bug this corrects simply by Limbo's own zero-initialization
# guarantee (bc here needs no explicit `=0`, but is given one anyway,
# for direct readability against the fixed C source).
encode(verlev: int, data: array of byte, dlen: int, mode: int, nchar: int): array of byte
{
	b: array of byte;
	bc, n, c, nd, acc, i: int;
	elenr, bctrr: array of int;

	n = 0;
	bc = 0;
	c = cap[verlev];
	b = array[c] of byte;
	elenr = array[] of {n};
	bctrr = array[] of {bc};
	bits(b, elenr, bctrr, mode, 4);
	bits(b, elenr, bctrr, nchar, getlbits((verlev >> 2) + 1, mode));

	case mode {
	NUM =>
		nd = 0;
		acc = 0;
		for(i = 0; i < dlen; i++)
			if(isdigit(int data[i])){
				acc = acc * 10 + int data[i] - '0';
				nd++;
				if(nd == 3){
					nd = 0;
					bits(b, elenr, bctrr, acc, 10);
					acc = 0;
				}
			}
		if(nd == 1)
			bits(b, elenr, bctrr, acc, 4);
		else if(nd == 2)
			bits(b, elenr, bctrr, acc, 7);
	ANUM =>
		nd = 0;
		acc = 0;
		for(i = 0; i < dlen; i++)
			if(atab[int data[i]] != 0){
				acc = acc * 45 + atab[int data[i]] - 1;
				nd++;
				if(nd == 2){
					nd = 0;
					bits(b, elenr, bctrr, acc, 11);
					acc = 0;
				}
			}
		if(nd == 1)
			bits(b, elenr, bctrr, acc, 6);
	BYTE =>
		for(i = 0; i < dlen; i++)
			bits(b, elenr, bctrr, int data[i], 8);
	}

	bits(b, elenr, bctrr, 0, 4);
	n = elenr[0];
	bc = bctrr[0];
	if(bc != 0){
		b[n] = byte (int b[n] << (8 - bc));
		n++;
	}
	while(n < c){
		b[n++] = byte 16rec;
		if(n == c)
			break;
		b[n++] = byte 16r11;
	}
	return b;
}

isdigit(c: int): int
{
	return c >= '0' && c <= '9';
}

# ecc(): Reed-Solomon error-correction computation over GF(256).
# err/erroff/str replace the C's own strided uchar* (err[i*str]),
# writing into err[erroff + i*str] for i in 0..el-1 - see this file's
# own header comment.
ecc(data: array of byte, doff, dl: int, poly: array of int, err: array of byte, erroff, el, str: int)
{
	q: array of int;
	i, k, l, x, dv: int;

	q = array[el] of int;
	for(i = 0; i < el; i++){
		q[i] = gpexp[poly[i]];
		err[erroff + i * str] = byte 0;
	}
	for(k = dl - 1; k >= 0; k--){
		dv = int data[doff + k];
		if(dv != 0){
			l = gplog[dv];
			for(i = 0; i < el; i++){
				if(q[i] != 0){
					x = gplog[q[i]] + l;
					if(x >= 255)
						x -= 255;
					err[erroff + i * str] = byte (int err[erroff + i * str] ^ gpexp[x]);
				}
			}
		}
		l = q[0];
		if(l != 0){
			l = gplog[l];
			for(i = 0; i < el; i++){
				x = l + poly[i];
				if(x >= 255)
					x -= 255;
				nextq := 0;
				if(i != el - 1)
					nextq = q[i + 1];
				q[i] = nextq ^ gpexp[x];
			}
		}else{
			for(i = 0; i < el - 1; i++)
				q[i] = q[i + 1];
			q[el - 1] = 0;
		}
	}
}

# codewords(): splits data[] into its blocks (per qrsizes), computes
# each block's own ECC codewords via ecc(), then interleaves data and
# ECC codewords in the standard column-major order. Returns the full
# interleaved codeword buffer and its length via ncr[0].
codewords(verlev: int, data: array of byte, ncr: array of int): array of byte
{
	bp, el, ncol, ne, nb, nc: int;
	i, j, p: int;
	r: array of byte;

	bp = blockidx[verlev];
	el = qrsizes[bp + 2] - qrsizes[bp + 3];
	ncol = 0;
	ne = 0;
	nc = 0;
	nb = 0;
	for(p = bp; qrsizes[p] == verlev; p += 4){
		nb += qrsizes[p + 1];
		ne += qrsizes[p + 1] * el;
		nc += qrsizes[p + 1] * qrsizes[p + 2];
		ncol = qrsizes[p + 3];
	}
	r = array[nc] of byte;

	doff := 0;
	eoff := nc - ne;
	for(p = bp; qrsizes[p] == verlev; p += 4){
		for(j = 0; j < qrsizes[p + 1]; j++){
			ecc(data, doff, qrsizes[p + 3], polys[el], r, eoff, el, nb);
			doff += qrsizes[p + 3];
			eoff++;
		}
	}

	rp := 0;
	for(i = 0; i < ncol; i++){
		doff = i;
		for(p = bp; qrsizes[p] == verlev; p += 4){
			for(j = 0; j < qrsizes[p + 1]; j++){
				if(qrsizes[p + 3] > i){
					r[rp] = data[doff];
					rp++;
				}
				doff += qrsizes[p + 3];
			}
		}
	}

	ncr[0] = nc;
	return r;
}

# --- basepat(): builds the (s+8)x(s+8) base pattern (a 4-module
# border on every side folded into the same flat buffer, matching the
# C's own pointer arithmetic starting 4 rows/cols before the true
# origin) - finder patterns + separators, timing pattern, alignment
# patterns, and the reserved-but-not-yet-known format/version-info
# cells. Cell values: 16rff/0 = a fixed dark/light module; 16rd0 =
# reserved for format(); 16rc0 = reserved for version() (only when
# verlev>=24); 16r80 = still-empty, to be filled by fill(). ---
max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

basepat(verlev: int): array of byte
{
	s, i, j, d, w: int;
	pat: array of byte;

	s = side[verlev >> 2];
	w = s + 8;
	pat = array[w * w] of byte;

	p := 0;
	for(j = -4; j < s + 4; j++)
		for(i = -4; i < s + 4; i++){
			if(i < 0 || j < 0 || i >= s || j >= s)
				pat[p] = byte 16rff;
			else if(i < 8 && j < 8 || i >= s - 8 && j < 8 || i < 8 && j >= s - 8){
				ii := i;
				if(i >= 8)
					ii = i - s + 4;
				else
					ii = i - 3;
				jj := j;
				if(j >= 8)
					jj = j - s + 4;
				else
					jj = j - 3;
				d = max(abs(ii), abs(jj));
				if(d == 2 || d == 4)
					pat[p] = byte 16rff;
				else
					pat[p] = byte 0;
			}else if(i == 6 || j == 6){
				if((i + j & 1) != 0)
					pat[p] = byte 16rff;
				else
					pat[p] = byte 0;
			}else if(i <= 8 && j <= 8 || i <= 8 && j >= s - 8 || i >= s - 8 && j <= 8)
				pat[p] = byte 16rd0;
			else if(verlev >= 24 && (j >= s - 11 && i < 6 || i >= s - 11 && j < 6))
				pat[p] = byte 16rc0;
			else
				pat[p] = byte 16r80;
			p++;
		}

	al := align[verlev >> 2];
	for(ai := 0; al[ai] != 0; ai++)
		for(aj := 0; al[aj] != 0; aj++){
			ap := al[ai];
			aq := al[aj];
			if(ap == 6 && aq == 6 || ap >= s - 7 && aq == 6 || ap == 6 && aq >= s - 7)
				continue;
			for(i = ap - 2; i <= ap + 2; i++)
				for(j = aq - 2; j <= aq + 2; j++){
					idx := i * w + j + 4 + w * 4;
					if(max(abs(i - ap), abs(j - aq)) == 1)
						pat[idx] = byte 16rff;
					else
						pat[idx] = byte 0;
				}
		}
	return pat;
}

abs(n: int): int
{
	if(n < 0)
		return -n;
	return n;
}

# fill(): the zigzag placement walk, writing codeword bits (MSB
# first per byte) into every still-empty (16r80) cell, continuing
# with zero-padding once the codewords run out (matching the C's own
# infinite loop, which keeps walking - and so keeps zero-filling -
# until it runs off the left edge of the whole (s+8)x(s+8) buffer).
fill(verlev: int, p: array of byte, d: array of byte, nc: int)
{
	s, x, y, i, up, dp, db: int;

	s = side[verlev >> 2] + 8;
	x = s - 5;
	y = s - 5;
	up = 1;
	db = 0;
	dp = 0;
	i = 0;
	for(;;){
		if(i == 0){
			if(dp == nc)
				db = 0;
			else{
				db = int d[dp];
				dp++;
			}
		}
		i = i + 1 & 7;
		while(int p[y * s + x] != 16r80){
			lt10 := 0;
			if(x < 10)
				lt10 = 1;
			if(up != 0){
				if(((x & 1) ^ lt10) == 0)
					x--;
				else if(y >= 4){
					x++;
					y--;
				}else{
					x--;
					up = 0;
					if(x == 10)
						x--;
				}
			}else{
				if(((x & 1) ^ lt10) == 0)
					x--;
				else if(y < s - 4){
					x++;
					y++;
				}else{
					x--;
					up = 1;
					if(x == 10)
						x--;
				}
			}
			if(x < 0)
				return;
		}
		bit := (db & 16r80) != 0;
		if(bit)
			p[y * s + x] = byte 16r0f;
		else
			p[y * s + x] = byte 16rf0;
		db = (db << 1) & 16rff;
	}
}

mask(verlev: int, p: array of byte, m: int)
{
	s, i, j, w: int;
	q: int;

	s = side[verlev >> 2];
	w = s + 8;
	for(i = -4; i < s + 4; i++)
		for(j = -4; j < s + 4; j++){
			idx := (i + 4) * w + (j + 4);
			q = int p[idx];
			if(((q ^ q >> 4) & 15) == 15){
				case m {
				0 => if(((i + j) & 1) == 0) p[idx] = byte (q ^ 16rff);
				1 => if((i & 1) == 0) p[idx] = byte (q ^ 16rff);
				2 => if(j % 3 == 0) p[idx] = byte (q ^ 16rff);
				3 => if((i + j) % 3 == 0) p[idx] = byte (q ^ 16rff);
				4 => if(((i / 2) + (j / 3) & 1) == 0) p[idx] = byte (q ^ 16rff);
				5 => if((i * j % 2) + (i * j % 3) == 0) p[idx] = byte (q ^ 16rff);
				6 => if(((i * j + i * j % 3) & 1) == 0) p[idx] = byte (q ^ 16rff);
				7 => if(((i + j + i * j % 3) & 1) == 0) p[idx] = byte (q ^ 16rff);
				}
			}
		}
}

evaluate(verlev: int, p: array of byte): int
{
	r, i, j, l, s, sc, cnt, w: int;
	q, sh: int;

	s = side[verlev >> 2];
	w = s + 8;
	sc = 0;
	cnt = 0;

	for(i = 0; i < s; i++){
		r = 0;
		l = -1;
		sh = 0;
		for(j = 0; j < s; j++){
			q = 0;
			if(int p[i * w + j + 4 + w * 4] >= 16r80)
				q = 1;
			cnt += q;
			sh = (sh << 1 | l) & 16rff;
			if(q != l){
				if(r >= 5)
					sc += 3 + r;
				l = q;
				r = 0;
			}
			if((sh & 16r7f) == 16r5d)
				sc += 40;
		}
		if(r >= 5)
			sc += 3 * r;
	}
	sc = abs(cnt - s * s / 2) / (s * s / 20) * 10;

	for(j = 0; j < s; j++){
		r = 0;
		l = -1;
		sh = 0;
		for(i = 0; i < s; i++){
			q = int p[i * w + j + 4 + w * 4];
			sh = (sh << 1 | l) & 16rff;
			if(q != l){
				if(r >= 5)
					sc += 3 + r;
				l = q;
				r = 0;
			}
			if((sh & 16r7f) == 16r5d)
				sc += 40;
		}
		if(r >= 5)
			sc += 3 * r;
	}

	for(j = 1; j < s; j++)
		for(i = 1; i < s; i++){
			pp := i * w + j + 4 + w * 4;
			if(p[pp] == p[pp - 1] && p[pp] == p[pp - w] && p[pp] == p[pp - 1 - w])
				sc += 3;
		}
	return sc;
}

format(verlev: int, p: array of byte, m: int)
{
	fmt := array[] of {
		21522, 20773, 24188, 23371, 17913, 16590, 20375, 19104, 30660,
		29427, 32170, 30877, 26159, 25368, 27713, 26998, 5769, 5054, 7399,
		6608, 1890, 597, 3340, 2107, 13663, 12392, 16177, 14854, 9396, 8579,
		11994, 11245
	};
	s, i, w: int;
	f: int;
	c: int;

	s = side[verlev >> 2];
	w = s + 8;
	f = (fmt[((verlev << 3) & 16r18) ^ 8 | m] ^ 16rffff) & 16rffff;
	for(i = 0; i < 15; i++){
		if((f & 1) != 0)
			c = 16rff;
		else
			c = 0;
		if(i < 8){
			r := i;
			if(i >= 6)
				r++;
			p[r * w + 8 + 4 + w * 4] = byte c;
			p[12 * w + (s + 3 - i)] = byte c;
		}else{
			p[(s - 15 + i) * w + 8 + 4 + w * 4] = byte c;
			col := 18 - i;
			if(i == 8)
				col++;
			p[12 * w + col] = byte c;
		}
		f >>= 1;
	}
	p[(s - 8) * w + 8 + 4 + w * 4] = byte 0;
}

version(verlev: int, p: array of byte)
{
	ver := array[] of {
		16r07C94, 16r085BC, 16r09A99, 16r0A4D3, 16r0BBF6, 16r0C762, 16r0D847,
		16r0E60D, 16r0F928, 16r10B78, 16r1145D, 16r12A17, 16r13532, 16r149A6,
		16r15683, 16r168C9, 16r177EC, 16r18EC4, 16r191E1, 16r1AFAB, 16r1B08E,
		16r1CC1A, 16r1D33F, 16r1ED75, 16r1F250, 16r209D5, 16r216F0, 16r228BA,
		16r2379F, 16r24B0B, 16r2542E, 16r26A64, 16r27541, 16r28C69
	};
	s, i: int;
	f, c, q: int;

	if(verlev < 24)
		return;
	s = side[verlev >> 2] + 8;
	f = (ver[(verlev >> 2) - 6] ^ 16r3ffff) & 16r3ffff;
	for(i = 0; i < 18; i++){
		if((f & 1) != 0)
			c = 16rff;
		else
			c = 0;
		f >>= 1;
		q = (s - 15 + i % 3) * s + (4 + i / 3);
		p[q] = byte c;
		p[(q * s) % (s * s - 1)] = byte c;
	}
}

# finalize(): collapse the nibble/byte dual-encoding into a plain
# 0/16rff bitmap - see this file's own header comment for why "is the
# top bit set" is an exactly-equivalent, simpler replacement for the
# C's own signed-char arithmetic shift, for the four byte values that
# ever reach this function.
finalize(buf: array of byte)
{
	for(i := 0; i < len buf; i++){
		if((int buf[i] & 16r80) != 0)
			buf[i] = byte 16rff;
		else
			buf[i] = byte 0;
	}
}

# qrcode(): the top-level driver - picks version/level (or uses a
# forced version), encodes, computes codewords, builds the base
# pattern, fills in the data, tries all 8 masks and keeps the
# best-scoring one, writes format/version info, and finalizes.
# Returns (nil, 0) on error (data too large for the requested/every
# version), matching qrcode()'s own nil-return contract.
qrcode(ver, level, mode: int, data: array of byte, dlen: int): (array of byte, int)
{
	qrinit();

	ncharr := array[] of {0};
	verlev := formsel(ver, level, mode, data, dlen, ncharr);
	if(verlev == -1)
		return (nil, 0);
	s := side[verlev >> 2];

	d := encode(verlev, data, dlen, mode, ncharr[0]);

	ncr := array[] of {0};
	w := codewords(verlev, d, ncr);
	nc := ncr[0];

	b := basepat(verlev);

	fill(verlev, b, w, nc);

	mbest, mval, m, mv: int;
	mbest = 0;
	mval = 0;
	for(m = 0; m < 8; m++){
		mask(verlev, b, m);
		mv = evaluate(verlev, b);
		if(m == 0 || mv < mval){
			mbest = m;
			mval = mv;
		}
		if(m != 7 || mbest != m)
			mask(verlev, b, m);
	}
	if(mbest != 7)
		mask(verlev, b, mbest);
	format(verlev, b, mbest);
	version(verlev, b);
	finalize(b);
	return (b, s + 8);
}

fail(s: string)
{
	sys->fprint(stderr, "qr: %s\n", s);
	raise "fail:qr";
}

usage()
{
	fail("usage: qr [-LMQHna] [-v ver] [file]");
}

# --- flag parsing: matches ascii.b's/crc32.b's own hand-rolled
# style, since the C's ARGBEGIN flags here (-L/-M/-Q/-H/-n/-a are
# single-character no-argument flags, -v takes a value) don't need
# bundled-multi-flag support beyond a single leading '-' group, but
# still follow the same "each option character is its own case"
# convention as crc32.b for consistency across this backlog. ---
run(args: list of string, data: array of byte): (array of byte, int)
{
	# Defensive self-load: run() is the in-process test seam, called
	# directly by qrtest.b without qr.b's own init() ever running -
	# sys/stderr are otherwise nil here, and the first internal
	# sys->fprint() (inside fail()/usage(), on any parse or capacity
	# error) would dereference a nil sys, crashing emu natively rather
	# than raising a catchable Limbo exception. Same convention as
	# cb.b's own loadmods() and every other test-seam run() in this
	# backlog - MISSING here in this file's own first draft, and found
	# the hard way: qrtest.b's very first case crashed emu itself
	# (a native disfault, misreported by the crash handler as an
	# unrelated "module not loaded"), not a caught test failure. Traced
	# by a minimal standalone probe calling run() directly (bypassing
	# qrtest.b's own machinery entirely) down to this exact missing
	# guard; adding it turned the crash into a clean, catchable
	# "qr: too many bits" (itself then found to be a real test-sizing
	# mistake, not a qr.b bug - see qrtest.b's own header comment).
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(stderr == nil)
		stderr = sys->fildes(2);

	ver := 0;
	level := 1;
	mode := BYTE;

	if(atab == nil)
		initatab();

	l := args;
	while(l != nil){
		w := hd l;
		if(len w < 2 || w[0] != '-')
			break;
		l = tl l;
		case w[1] {
		'L' => level = 0;
		'M' => level = 1;
		'Q' => level = 2;
		'H' => level = 3;
		'v' =>
			vs: string;
			if(len w > 2)
				vs = w[2:];
			else{
				if(l == nil)
					usage();
				vs = hd l;
				l = tl l;
			}
			(v, ok) := sysstrtoint(vs);
			if(!ok || v < 0 || v > 40)
				usage();
			ver = v;
		'n' => mode = NUM;
		'a' => mode = ANUM;
		* => usage();
		}
	}
	if(l != nil)
		usage();

	(b, s) := qrcode(ver, level, mode, data, len data);
	if(b == nil)
		fail("too many bits");
	return (b, s);
}

sysstrtoint(s: string): (int, int)
{
	if(len s == 0)
		return (0, 0);
	n := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c < '0' || c > '9')
			return (0, 0);
		n = n * 10 + (c - '0');
	}
	return (n, 1);
}

init(nil: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	args: list of string;
	if(argv != nil)
		args = tl argv;

	# The C's own main() reads at most one 8192-byte readn() from
	# standard input and silently truncates anything longer - a real,
	# deliberately preserved limitation, not translated away (see
	# BUGS in man/1/qr).
	buf := array[8192] of byte;
	stdin := sys->fildes(0);
	n := 0;
	for(;;){
		if(n == len buf)
			break;
		nr := sys->read(stdin, buf[n:], len buf - n);
		if(nr <= 0)
			break;
		n += nr;
	}
	data := buf[0:n];

	(b, s) := run(args, data);
	stdout := sys->fildes(1);
	hdr := sys->sprint("%11s %11d %11d %11d %11d ", "k8", 0, 0, s, s);
	sys->write(stdout, array of byte hdr, len hdr);
	sys->write(stdout, b, len b);
}
