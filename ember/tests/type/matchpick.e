module Matchpick

import sys "sys"

// match on a pick-adt subject ("match r { case Result.Ok(v): ...;
// case Result.Err(e): ... }") -- the second design fork from this
// branch's own pick-adt plan (ember-language-status.md's memory doc),
// put to the user directly and shipped per their answer: reuse the
// EXISTING int-label Tcase/casecom() jump-table machinery a plain
// "match i { case 1: ... }" already has, dispatching on the subject's
// own tag word (a plain int at offset 0, sizetype()'s own layout)
// instead of building a separate compare-and-branch chain.
//
// mechanism: check.c's matchcheck() resolves the subject's real type
// (ref-to-tagged-adt, or an already-narrowed bare Tadtpick value --
// both accepted) and, for each "case Adt.Tag(binders):" pattern,
// resolves the tag via stype()'s own Odot-into-tag case (the same one
// pick construction already uses), stashes it back on the pattern's
// own type-name node, sets the pattern's .val to the tag's ordinal
// (Decl.tag) so the *existing*, completely unmodified label-sort/
// overlap-detection machinery (matchlabels(), casecmp(), findlab())
// treats it exactly like a plain "case 3:" -- and installs a fresh
// Dlocal per binder, scoped to just that arm, positionally matched
// against the tag's own fields. A tag pattern must be the only
// pattern in its arm (deliberately refused otherwise -- combining
// would need each combined tag to bind the same names to potentially
// different field types, not attempted).
//
// com.c's casecom() reads the tag word out of the ORIGINAL subject
// expression (Oind(Oadd(base,$0)), the same shape storecomposite()'s
// own tag-word WRITE already uses, mirrored for a read) as the actual
// ICASE dispatch value, but keeps the original subject's own address
// around afterward (deferred tfree, not the usual immediate one --
// every arm may still need it) to extract each Opat arm's own binder
// fields, positionally, the same Oind(Oadd(base,$offset)) shape every
// other field access in this file already uses.
//
// one more real gap found and fixed getting the ref-subject case to
// actually compile: "ref Result.Ok{...}" (Tref{Tadtpick}) wasn't
// assignable to a "ref Result"-typed destination (Tref{the outer,
// unspecified-tag adt}) at all -- the realistic construction site for
// a value a caller will later match on ("func mk() ref Result {
// return ref Result.Ok{...} }"). assignable() (check.c) gained one
// special-cased widening rule for exactly this relationship, kept
// deliberately separate from tequal()'s own general, strict
// structural equality (used far more broadly, not safe to loosen).

type Result pick {
	Ok(val int)
	Err(msg string)
}

func mk(which int) ref Result {
	if which == 0 {
		return ref Result.Ok{val: 99}
	}
	return ref Result.Err{msg: "oops"}
}

func init() {
	// ref subject, both tags, each with a real binder read back.
	r := mk(0)
	match r {
	case Result.Ok(v):
		sys.print("ok v=%d\n", v)
	case Result.Err(e):
		sys.print("err e=%s\n", e)
	}

	r2 := mk(1)
	match r2 {
	case Result.Ok(v):
		sys.print("ok v=%d\n", v)
	case Result.Err(e):
		sys.print("err e=%s\n", e)
	}

	// bare (non-ref), already-narrowed Tadtpick subject -- a real,
	// separately-verified path (not just the ref case above): a
	// directly-constructed value, not one routed through a function's
	// own ref-typed return.
	rv := Result.Ok{val: 55}
	match rv {
	case Result.Ok(v):
		sys.print("value ok v=%d\n", v)
	case Result.Err(e):
		sys.print("value err e=%s\n", e)
	}

	// runtime-computed dispatch, in a loop -- not just two fixed,
	// compile-time-obvious calls -- same reasoning as this branch's
	// own runtime-index tests elsewhere.
	i := 0
	for i < 3 {
		x := mk(i)
		match x {
		case Result.Ok(v):
			sys.print("loop ok %d\n", v)
		case Result.Err(e):
			sys.print("loop err %s\n", e)
		}
		i = i + 1
	}

	// a poisoned local right before more dispatch, same methodology
	// as every other investigation this session.
	poison := 66666
	poison = 0
	sys.print("poison=%d\n", poison)
	match mk(0) {
	case Result.Ok(v):
		sys.print("final ok %d\n", v)
	case Result.Err(e):
		sys.print("final err %s\n", e)
	}
}
