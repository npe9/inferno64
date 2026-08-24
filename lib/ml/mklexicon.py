#!/usr/bin/env python3
#
# Build the pronunciation dictionary phon(2) reads: lib/ml/en_US.dict.
#
# This runs on the host at build time and produces a file Inferno reads at run
# time, the same arrangement emu/port/mkonnxmodel.py uses. espeak-ng is needed
# to build the dictionary and never to use it.
#
# espeak-ng is the right source rather than a coincidence: this voice's
# phoneme_type is "espeak" and its phoneme_id_map holds espeak's own IPA, so
# the transcriptions land in exactly the symbol set the model was trained on.
# The five phrases in lib/demo/tour.sh, which were written by hand and listened
# to before any of this existed, come back from espeak-ng 1.52 either identical
# or differing only where espeak's own output has drifted between versions
# (i/ɪ, ɪ/ᵻ, oː/ɔː) - all symbols the voice knows.
#
# The output is SORTED, and that is load-bearing: phon(2) binary-searches it on
# disk by seeking, so a quarter of a million words cost no memory and no load
# time. Nothing sorts it at run time, so if this file stops emitting sorted
# output, lookups start failing for words either side of the disorder.
#
# Words whose transcription uses a symbol the voice does not know are dropped
# rather than emitted, because a symbol the model has never seen cannot be
# turned into an id at all. How many were dropped is printed; it should be a
# handful, and a large number means the voice and espeak have diverged.
#
import json
import subprocess
import sys

WORDS = "/usr/share/dict/words"
VOICE = "lib/ml/voices/en_US-lessac-low.onnx.json"
OUT = "lib/ml/en_US.dict"


def wordlist(path):
    """Lowercased, deduplicated, letters and apostrophes only.

    The system word list has both "A" and "a", which collapse to one key, and
    a duplicate key would make the same word pronounceable two ways depending
    on which the search happened to land on.
    """
    seen = set()
    for line in open(path, encoding="utf-8", errors="ignore"):
        w = line.strip().lower()
        if not w or not all(c.isalpha() or c == "'" for c in w):
            continue
        if not w.isascii():
            continue
        seen.add(w)
    return sorted(seen)


VOWELS = "aeiou"


def inflect(w):
    """The forms English spelling makes of a word.

    /usr/share/dict/words is web2, which holds base forms and nothing else: no
    "files", no "opened", no "jumps". A dictionary without those cannot read a
    sentence, so the forms are generated here and espeak-ng is asked to
    pronounce them - it knows the morphology, which is the point of using it
    rather than appending a "z" sound and hoping.

    Where the final consonant may or may not double, BOTH spellings are
    emitted. Whether it doubles depends on which syllable is stressed - "stop"
    gives "stopped" but "open" gives "opened", and the letters alone do not say
    which. A rule that guesses gets one of them wrong every time, and the wrong
    one is missing from the dictionary altogether; emitting both costs a little
    space for a spelling nobody ever looks up. That is the right way round.
    """
    out = []
    if not w or not w.isalpha():
        return out
    last, prev = w[-1], w[-2] if len(w) > 1 else ""

    # plural and third person singular
    if last == "y" and prev and prev not in VOWELS:
        out.append(w[:-1] + "ies")
    elif w.endswith(("s", "x", "z", "ch", "sh")):
        out.append(w + "es")
    else:
        out.append(w + "s")

    # a final consonant doubles after a single stressed vowel: stop, stopped
    dbl = (len(w) > 2 and last not in VOWELS and last not in "wxy"
           and prev in VOWELS and w[-3] not in VOWELS)

    if last == "e":
        out.append(w + "d")
        out.append(w[:-1] + "ing")
    elif last == "y" and prev and prev not in VOWELS:
        out.append(w[:-1] + "ied")
        out.append(w + "ing")
    else:
        out.append(w + "ed")
        out.append(w + "ing")
        if dbl:
            out.append(w + last + "ed")
            out.append(w + last + "ing")
    return out


def phonemise(words):
    """espeak-ng, one word per line, in bulk.

    Alignment is the thing to be careful about: this depends on one line of
    output per line of input, and a desync would silently give every word after
    it somebody else's pronunciation. So the counts are checked, and a
    mismatch is fatal rather than something to work around.
    """
    src = "\n".join(words) + "\n"
    p = subprocess.run(
        ["espeak-ng", "-q", "--ipa", "-v", "en-us"],
        input=src.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    out = p.stdout.decode("utf-8").split("\n")
    while out and out[-1] == "":
        out.pop()
    if len(out) != len(words):
        sys.exit("espeak returned %d lines for %d words; alignment is lost"
                 % (len(out), len(words)))
    return [s.strip().replace("‍", "") for s in out]


def main():
    known = set(json.load(open(VOICE))["phoneme_id_map"])

    base = wordlist(WORDS)
    print("%d base words" % len(base))
    have = set(base)
    extra = set()
    for w in base:
        for f in inflect(w):
            if f not in have:
                extra.add(f)
    words = sorted(have | extra)
    print("%d with inflections (%d generated)" % (len(words), len(extra)))
    ipa = phonemise(words)

    # spot-check alignment at both ends and the middle rather than trusting
    # the count alone: a dropped line and an added one would cancel out.
    for i in (0, len(words) // 2, len(words) - 1):
        print("  %-20s %s" % (words[i], ipa[i]))

    dropped = 0
    n = 0
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("# Generated by lib/ml/mklexicon.py from %s using espeak-ng.\n"
                % WORDS)
        f.write("# Sorted; phon(2) binary-searches this on disk. Do not edit:\n"
                "# hand-written entries go in en_US.lex, which wins over this.\n")
        for w, p in zip(words, ipa):
            if not p:
                dropped += 1
                continue
            bad = {c for c in p if c not in known}
            if bad:
                dropped += 1
                continue
            f.write("%s\t%s\n" % (w, p))
            n += 1
    print("wrote %s: %d entries, %d dropped for symbols the voice lacks"
          % (OUT, n, dropped))


if __name__ == "__main__":
    main()
