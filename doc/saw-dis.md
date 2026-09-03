# Verifying Dis in SAW

SAW (the Software Analysis Workbench) proves that a program computes
what a Cryptol specification says it should. Its front ends are LLVM,
JVM, MIR and x86 — **not Dis**. So "verify the Dis crypto in SAW" is not
a matter of pointing SAW at a `.dis` file; it needs a bridge from Dis
into something SAW can symbolically execute. This is that bridge, and a
worked proof through it.

## The pipeline

```
qr.b  --limbo-->  qr.dis  --disdump(1)-->  Dis assembly
      --tests/saw/dis2ll.py-->  LLVM IR  --llvm-as-->  bitcode
      --saw (tests/saw/qr.saw)-->  proof against tests/saw/qrspec.cry
```

`tests/sawverify.sh` runs the whole thing and its negative control.

The one new piece is `dis2ll.py`: a translator from a straight-line Dis
function, as printed by `disdump(1)`, to LLVM SSA. It uses the Dis
operand semantics (`doc/dis.ms`): a word local is `N(fp)`, an immediate
is `$N`, `OP src, dst` means `dst = dst OP src`, and `OP src, mid, dst`
means `dst = mid OP src`. Each frame word becomes an SSA value, each Dis
word op becomes one LLVM op, and the store to the return slot
`0(R(fp))` becomes the LLVM `ret`. The frame words first *read* become
the function's `i32` arguments.

SAW then symbolically executes that bitcode and proves it equal to the
Cryptol spec for **all** inputs — for the `qr` kernel, all 2^128
word-tuples, discharged by z3, not a sample. This is a genuine
equivalence proof, stronger than the input-sampling done in
`tests/cryptolverify.sh` — but for a narrower class of code.

## Scope, honestly

`dis2ll.py` accepts only the **straight-line 32-bit word-arithmetic**
fragment of Dis: `addw subw mulw andw orw xorw shlw shrw`, immediates,
direct frame words, and a single indirect return slot. No branches,
loops, calls, heap, arrays, floats, or 64-bit/`big` words. It *rejects*
anything else loudly rather than mistranslate it.

That fragment is deliberately chosen: it is exactly what the *core* of a
cryptographic kernel compiles to — a quarter-round, a round function, a
field operation — and it is where a Dis instruction maps one-to-one
onto an LLVM operation, so the translation is simple and auditable.
Whole algorithms (with their loops and array indexing) do not fit yet;
extending the translator to loops (by bounded unrolling, which SAW
supports) and to array/`indx` addressing (as LLVM memory, verified with
`llvm_verify`'s memory contracts) is the path to larger kernels.

## Trust

The proof establishes: the *LLVM produced by `dis2ll.py`* equals the
Cryptol spec. Two things are trusted, not proved: that `dis2ll.py`
faithfully models Dis semantics (small, direct, and auditable for this
fragment), and that the Cryptol spec is the intended one (it is short
and matches the RFC/algorithm). The negative control guards the second
kind of mistake in the harness itself — a deliberately wrong spec must
make SAW fail with a counterexample, and it does. What would close the
first gap is verifying `dis2ll.py` against a formal Dis semantics; that
is not done here and is noted as the real remaining work.
