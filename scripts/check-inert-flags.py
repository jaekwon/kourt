#!/usr/bin/env python3
"""A flag that is read but never set is an answer that can never change.

    python3 scripts/check-inert-flags.py

THE FAILURE, and it is live on gnoland-1 right now. testclock.gno declares
`tcEverArmed bool` and TestClockFabricated() returns it. On mainnet nothing
assigns it, so that function answers false forever -- including after the clock
has been armed and time fabricated. The getter is byte-identical to the working
one, which is exactly why nobody caught it: the code that reads the flag looks
correct, and the flag it reads is dead.

It is not a hypothetical elsewhere either. kourt-1 answers TRUE to the same
question today, because the copy deployed there does assign it. Same function,
same name, opposite truthfulness, decided by a single line six hundred lines
away from the getter.

WHAT THIS CANNOT TELL YOU. A flag with no writer is unambiguous; a flag with a
writer that is merely unreachable is not, and this does not attempt it. Dead
simple, and therefore trustworthy about the one thing it claims.

TESTS DO NOT COUNT AS WRITERS. A flag set only by a test is inert in the realm
that ships, which is the realm that matters. Counting them would make the guard
agree with the code exactly when the code is wrong.
"""
import io
import gnosource
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from gnosource import strip_comments
import repolock

ROOT = pathlib.Path(__file__).resolve().parent.parent
REALM = ROOT

# DECL first: check-guards-blind blinds the first named pattern, and with this
# one blinded no flag is ever examined -- which the census floor turns into a
# failure rather than a clean run.
DECL = re.compile(r"^\t*(?:var\s+)?(\w+)\s+bool\s*$", re.M)
CENSUS_FLOOR = 20

# KNOWN AND DEPLOYED, so mirrored rather than fixed. gnoland-1 declares
# tcEverArmed, returns it from TestClockFabricated(), and assigns it NOWHERE --
# so that function answers false there forever, including after the clock has
# been armed and time fabricated. kourt-1 answers TRUE to the identical function,
# because the copy deployed there does assign it.
#
# A package deploys exactly once, so the fix cannot reach gnoland-1 and the repo
# now mirrors what runs. Listed here with the reason, the way check-getcoins
# carries the burn-sink read, so the guard still fires on any OTHER inert flag.
DEPLOYED_INERT = {("r/kourtv2/testclock.gno", "tcEverArmed")}


def bool_names(text):
    """Every bool declared in this file: package-level vars AND struct fields.

    A struct field read but never written is the same defect as an unset global,
    and check-dead-fields cannot see it -- that guard flags fields with NO
    mentions, and these have plenty. Both shapes spell the same line, so both are
    collected and the writer search below decides.
    """
    return [m.group(1) for m in DECL.finditer(text)]


def main():
    # selftest rewrites these very sources in place; reading them
    # mid-plant invents findings out of somebody else's control.
    repolock.refuse_if_held("check-inert-flags")

    census, inert = 0, []
    for p in sorted(gnosource.realm_files(REALM)):
        if p.name.endswith(("_test.gno", "_filetest.gno")):
            continue
        text = strip_comments(io.open(p, encoding="utf-8").read())
        names = bool_names(text)
        if not names:
            continue
        # Writers may live in any non-test file of the same package.
        pkg = "\n".join(
            strip_comments(io.open(q, encoding="utf-8").read())
            for q in sorted(p.parent.glob("*.gno"))
            if not q.name.endswith(("_test.gno", "_filetest.gno")))
        for name in names:
            census += 1
            # `X = v`, `X := v`, and `X: v` inside a composite literal are all
            # writes. Missing the third would call every field set at construction
            # time inert, which is most of them.
            written = re.search(r"\b%s\s*(?::?=[^=]|:\s*[^=\s])" % re.escape(name), pkg)
            # A STRUCT FIELD IS READ AS `c.flag`, NOT `flag`. Matching only the
            # bare identifier found every package-level var and no field at all --
            # a planted inert field raised the census and was never flagged.
            q = r"(?:\w+\.)?" + re.escape(name)
            read = re.search(r"\breturn\s+!?%s\b|\bif\s+!?%s\b|%s\s*(?:&&|\|\|)"
                             % (q, q, q), pkg)
            if read and not written:
                rel = str(p.relative_to(REALM))
                if (rel, name) in DEPLOYED_INERT:
                    continue
                inert.append((rel, name))

    if inert:
        print("check-inert-flags: %d flag(s) read but never set.\n" % len(inert),
              file=sys.stderr)
        for rel, name in sorted(inert):
            print("  %s: %s is declared and read, and nothing assigns it, so every\n"
                  "      reader of it gets the zero value forever." % (rel, name),
                  file=sys.stderr)
        print("\nEither something should set it, or the flag and its readers should go.\n"
              "This is the shape of the live gnoland-1 defect: TestClockFabricated()\n"
              "answers false there permanently because tcEverArmed has no writer.",
              file=sys.stderr)
        return 1

    if census < CENSUS_FLOOR:
        print("check-inert-flags: examined only %d bool(s), below the\n"
              "floor of %d. The realm did not shrink; the declaration pattern stopped\n"
              "matching." % (census, CENSUS_FLOOR), file=sys.stderr)
        return 1

    print("check-inert-flags: %d bool(s) declared (package-level and struct "
          "field), every one that is read is also written." % census)
    return 0


if __name__ == "__main__":
    sys.exit(main())
