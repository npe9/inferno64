# eqn2hoc: translate eqn(7) math notation into hoc(2) expression source.
#
# eqn is Kernighan/Cherry's troff math-equation formatter (real source:
# plan9port's src/cmd/eqn, ~2500 lines across 26 files - fetched and
# read in full to build this). It has NO computational semantics
# anywhere in it: every one of its "boxes" (eqnbox.c, over.c, sqrt.c,
# subsup via the grammar, paren.c, matrix.c, pile.c, diacrit.c, ...) is
# troff drawing code - widths, baselines, font-switch escapes - for
# TYPESETTING an expression on a page, not evaluating one. Its own
# keyword table (lookup.c's resword[]) maps "sin"/"cos"/"log"/etc to a
# ROMAN-FONT ESCAPE STRING, not a function call - eqn never treats them
# as callable. So this is NOT a 1:1 translation of eqn's behavior (there
# is no numeric behavior in eqn to preserve) - it is a NEW semantic
# mapping of eqn's real, familiar SYNTAX (its grammar shape from eqn.y,
# its keyword vocabulary from lookup.c, both followed faithfully) onto
# hoc's scalar expression language, which eqn's own source never had.
#
# What maps and what doesn't, decided once here rather than discovered
# piecemeal:
#   + - = == != > < >= <=, and bare juxtaposition ("4 a c")
#                   -> ordinary hoc arithmetic/comparison, and
#                       multiplication respectively. Real eqn's own
#                       grammar has NONE of this - `eqn: box | eqn box`
#                       is just a sequence of boxes typeset side by
#                       side, with "+" itself being ordinary text, no
#                       different from any other word (confirmed
#                       directly in eqn.y). Refusing every juxtaposition
#                       as unsupported would refuse nearly every real
#                       equation (arithmetic operators, and "4ac"-style
#                       implicit multiplication, are both exactly this),
#                       so this is a second deliberate new-semantics
#                       layer, on the same footing as sup/over below -
#                       not a translation of anything, because there is
#                       nothing there to translate.
#   sup             -> hoc `^` (real exponentiation - eqn only ever
#                       draws a raised box, no computed meaning, but
#                       "x sup 2" unambiguously MEANS x squared to
#                       every reader, so this is the one eqn construct
#                       where its typeset appearance and a natural hoc
#                       meaning coincide exactly)
#   over            -> hoc `/` (division - same reasoning: "a over b"
#                       means a/b to any reader even though eqn itself
#                       only draws a fraction bar)
#   sqrt            -> hoc's own sqrt() builtin
#   { } and left/right delim
#                   -> grouping (eqn's ONLY real grouping construct is
#                       "{ }" - bare "(" ")" typed with no left/right
#                       are ordinary TEXT characters in real eqn, not
#                       delimiters, confirmed by reading lex.c's own
#                       getstr(): it does not stop scanning at '(' or
#                       ')' at all)
#   sin cos tan sinh cosh tanh log exp
#                   -> a hoc builtin CALL when immediately followed by
#                       a "{...}" or "left(...)right" group (the real
#                       eqn convention for "roman word next to a
#                       parenthesized box"); the bare word alone is
#                       just an ordinary hoc identifier otherwise,
#                       exactly as ambiguous as it already is in real
#                       eqn (every other resword - alpha, times, inf,
#                       ...) - passed through as an identifier name,
#                       unchanged, no unicode substitution
#   sub             -> folded into an identifier name ("x sub i"
#                       becomes the single hoc identifier "x_i") -
#                       ONLY when both sides are already simple names;
#                       hoc has no array/index type (the same boundary
#                       already documented for Orbital's plugins in
#                       doc/danby-tks-plan.md), so this is name-
#                       mangling, not real indexing, and is refused
#                       with a clear error on anything but a simple
#                       name on both sides
#   diacritical marks (hat vec dyad dot dotdot bar lowbar highbar
#   tilde utilde under)
#                   -> folded into an identifier name the same way
#                       ("x hat" -> "xhat"), same simple-name-only rule
#   size/font/roman/italic/bold/fat, fwd/up/back/down
#                   -> no-ops: parsed and discarded, keeping the box
#                       they wrap unchanged (pure typesetting, no
#                       numeric meaning to preserve or drop)
#   sum/prod/int/integral/union/inter, matrix/pile/lcol/ccol/rcol/col/
#   above, mark/lineup, from/to, define/tdefine/ndefine/ifdef/include/
#   delim/gsize/gfont, quoted "..." text
#                   -> UNSUPPORTED, a clear translate() error, not a
#                       silent wrong answer. Two different reasons,
#                       stated so they aren't confused: sum/prod/int
#                       have NO computational meaning even in real eqn
#                       (they are just special CHARACTERS drawn with
#                       sub/sup as visual limits, never evaluated) so
#                       there is nothing to translate; matrix/pile/
#                       column have no hoc target because hoc has no
#                       arrays (same boundary as sub, but too structural
#                       to name-mangle away); mark/lineup/quoted text/
#                       define & friends are eqn's own macro/alignment
#                       layer, out of scope for a single expression
#                       string with no macro system of its own.

Eqn2hoc: module
{
	PATH: con "/dis/lib/eqn2hoc.dis";

	# Parses one eqn expression (the text between .EQ/.EN or $$...$$ in
	# a real troff document - this library takes just that inner text,
	# nothing about the delimiters themselves) and returns the
	# equivalent hoc(2) expression source, ready for hoc->compile() -
	# or (nil, an error naming which construct isn't supported and why,
	# per the list above) rather than a silently wrong translation.
	translate: fn(src: string): (string, string);
};
