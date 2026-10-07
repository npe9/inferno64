# Working in this tree

This is the `genesize` branch: Inferno as the hypervisor.  Its plan
and its progress record are `doc/genesize-plan.ms`.  Read `AGENTS.md`
as well; its standing rules (no stubs, a booted kernel as evidence,
fix the tool and not the caller, real hardware over the emulator)
all apply.  Where it says to go on to the next item of
`doc/osprey-progress.ms` or `doc/inferno-ports.ms`, on this branch
the next item comes from `doc/genesize-plan.ms` instead.

- Do not stop to say what you are going to do next.  Do it.
- Do not end a reply with what is coming, what is left, or an offer to
  carry on.  A reply says what was built and what was verified, and
  stops there.  What is left is written down in `doc/genesize-plan.ms`.
- When a piece of work is finished, start the next one from that plan
  in the same turn.
- Every result in phases 3-5 names its backend (VMX or SVM) and its
  bench (QEMU TCG, Bochs, nested KVM, hardware).  A milestone that
  names VMX is not met by SVM.
- Keep the progress section of `doc/genesize-plan.ms` current as each
  piece lands, with what the booted kernel printed.
- Codesign (phase 16 of `doc/genesize-plan.ms`): an emulator feature
  lands with the Inferno support that uses it and a check that runs
  Inferno on it, not only Linux.  A feature added to a model that
  Inferno does not use is a debt, listed in the plan with its reason,
  and Inferno features that no bench can exercise are not merged
  untested.
