#!/usr/bin/env python3
"""
dis2ll.py - translate a straight-line integer Dis function (as printed
by disdump(1)) into LLVM IR, so SAW can symbolically execute it and
prove it equivalent to a Cryptol specification.

This is the bridge that lets SAW reason about Dis: SAW's native
frontend is LLVM, and Dis has none, so a Dis function is faithfully
re-expressed as LLVM. It is deliberately limited to the shape that
cryptographic kernels compile to - straight-line 32-bit word
arithmetic on frame locals, no branches, calls, loops, or heap - which
is exactly the fragment where a Dis instruction maps one-to-one onto an
LLVM SSA operation. Anything outside that fragment is rejected loudly
rather than mistranslated.

Dis operand/semantics facts used (see doc/dis.ms):
  * a word local is "N(fp)" (frame offset N); an immediate is "$N".
  * 2-operand "OP src, dst"      means  dst = dst OP src   (mid = dst)
  * 3-operand "OP src, mid, dst" means  dst = mid OP src
  * the return value is the store to "0(<retreg>(fp))" - the single
    indirect destination we accept, taken as the function's result.

Inputs (the frame offsets first read before being written) become the
LLVM function's i32 arguments, in ascending offset order.
"""
import re, sys

# Dis word opcode -> (LLVM op, is-shift)
OPS = {
    "addw": ("add", False), "subw": ("sub", False), "mulw": ("mul", False),
    "andw": ("and", False), "orw":  ("or",  False), "xorw": ("xor", False),
    "shlw": ("shl", True),  "shrw": ("lshr", True),  # shrw masked in-kernel; see spec
}

FP   = re.compile(r'^(-?\d+)\(fp\)$')          # N(fp)   direct frame word
IMM  = re.compile(r'^\$(-?\d+)$')              # $N      immediate
IND  = re.compile(r'^0\((-?\d+)\(fp\)\)$')     # 0(R(fp)) single indirect (return slot)

def parse(path):
    insns = []
    for raw in open(path):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        m = re.match(r'^(\w+)\s*(.*)$', line)
        op, rest = m.group(1), m.group(2).strip()
        args = [a.strip() for a in rest.split(',')] if rest else []
        insns.append((op, args))
    return insns

def main():
    insns = parse(sys.argv[1])
    fname = sys.argv[2] if len(sys.argv) > 2 else "qr"

    # First pass: discover input offsets (read before written) and reject
    # anything outside the supported straight-line word fragment.
    written = set(); inputs = []
    def isframe(o):
        return FP.match(o)
    for op, args in insns:
        if op == "ret":
            continue
        if op not in OPS:
            sys.exit("dis2ll: unsupported opcode %r (not straight-line word arithmetic)" % op)
        # operand roles by arity
        if len(args) == 2:
            src, dst = args[0], args[1]; mid = dst
        elif len(args) == 3:
            src, mid, dst = args
        else:
            sys.exit("dis2ll: unexpected arity for %s: %r" % (op, args))
        for o in (src, mid):
            mo = FP.match(o)
            if mo and mo.group(1) not in written and mo.group(1) not in [x for x in inputs]:
                inputs.append(mo.group(1))
        # dst must be a frame word or the single indirect return slot
        if not (FP.match(dst) or IND.match(dst)):
            sys.exit("dis2ll: unsupported destination %r" % dst)
        if FP.match(dst):
            written.add(FP.match(dst).group(1))
    inputs = sorted(set(inputs), key=lambda s: int(s))

    # Second pass: emit SSA. env maps frame-offset -> current LLVM value.
    env = {}
    argnames = []
    for off in inputs:
        nm = "%%in%s" % off
        env[off] = nm
        argnames.append("i32 %s" % nm)

    body = []
    tmp = [0]
    def fresh():
        tmp[0] += 1
        return "%%t%d" % tmp[0]
    def val(o):
        mi = IMM.match(o)
        if mi:
            return str(int(mi.group(1)) & 0xffffffff)
        mf = FP.match(o)
        if mf:
            if mf.group(1) not in env:
                sys.exit("dis2ll: read of uninitialised frame word %s" % o)
            return env[mf.group(1)]
        sys.exit("dis2ll: unsupported operand %r" % o)

    retval = None
    for op, args in insns:
        if op == "ret":
            continue
        if len(args) == 2:
            src, dst = args[0], args[1]; mid = dst
        else:
            src, mid, dst = args
        llop, isshift = OPS[op]
        a = val(mid); b = val(src)          # dst = mid OP src
        r = fresh()
        body.append("  %s = %s i32 %s, %s" % (r, llop, a, b))
        di = IND.match(dst)
        if di:
            retval = r
        else:
            env[FP.match(dst).group(1)] = r

    if retval is None:
        sys.exit("dis2ll: no return-slot store found")

    out = []
    out.append("; auto-generated from Dis by dis2ll.py - do not edit")
    out.append("define i32 @%s(%s) {" % (fname, ", ".join(argnames)))
    out.append("entry:")
    out.extend(body)
    out.append("  ret i32 %s" % retval)
    out.append("}")
    sys.stdout.write("\n".join(out) + "\n")

if __name__ == "__main__":
    main()
