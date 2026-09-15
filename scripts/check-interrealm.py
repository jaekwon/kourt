#!/usr/bin/env python3
"""A secondary `realm` parameter is not the caller until you prove it is.

    python3 scripts/check-interrealm.py

THE RULE, and it is not the one Solidity teaches. A crossing function's FIRST
`cur realm` parameter is runtime-current by construction -- the VM sets it, the
caller cannot forge it, and `cur.Previous()` inside it really is the caller. A
realm value in ANY OTHER position is just an argument. Whoever called you chose
it. Asking such a value who the caller was and believing the answer is how a
realm ends up executing somebody else's authority, and it does not look wrong on
the page: `rlm.Previous().Address()` reads identically whether `rlm` is the
first parameter or the fourth.

`rlm.IsCurrent()` is the proof. It returns true only when that realm value
matches the topmost live crossing frame, so a value handed in by a caller fails
it. Check first, then trust.

WHY THIS GUARD EXISTS WHILE THE TREE IS CLEAN. It is clean by ABSENCE: eleven
`Do(_ int, rlm realm, payload string)` implementations carry a secondary realm
parameter and not one of them touches it -- authority comes from the proposal
having passed, not from `rlm`. That is a safe design nobody wrote down, and the
next person to need the caller's address inside a `Do` will reach for `rlm`
because it is right there in the signature. This guard is the note that says
check it first.

ALSO FLAGGED: `unsafe.PreviousRealm()` in a function that has a `cur realm`
parameter. It is a STACK-WALKER -- it answers about the last realm boundary,
not about your caller -- and reaching for it when `cur` is in scope means
bypassing the frame verification `cur` gives you for free. Today this tree calls
only `unsafe.OriginCaller` and `unsafe.OriginSend`, both legitimate.
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

# FUNC first: check-guards-blind blinds the first named pattern, and blinding
# this one takes the census to zero, which the floor turns into a failure.
FUNC = re.compile(r"^func\s+(?:\([^)]*\)\s*)?(\w+)\s*\(([^)]*)\)")
REALM_PARAM = re.compile(r"(?:^|,)\s*(\w+)\s+realm\b")
AUTHORITY = re.compile(r"\b%s\.(Previous|Address|Send)\s*\(")
IS_CURRENT = re.compile(r"\b%s\.IsCurrent\s*\(")
UNSAFE_PREV = re.compile(r"\bunsafe\.PreviousRealm\s*\(")

CENSUS_FLOOR = 40

# THESE TWO ONLY FIRE ON A VIOLATION THIS TREE DOES NOT HAVE, so blinding either
# changes nothing and the guard passes regardless -- check-guards-blind caught
# exactly that once it began blinding every pattern rather than the first.
# AUTHORITY is exercised by the control arm in selftest; these are not, so they
# carry the strings they MUST and MUST NOT match, as check-spend-paths does.
IS_CURRENT_MUST_FIRE = ["if !rlm.IsCurrent() {", "if rlm.IsCurrent() && x {"]
IS_CURRENT_MUST_NOT_FIRE = ["if rlm.Previous().IsUserCall() {", "// rlm.IsCurrent is not called here"]
UNSAFE_PREV_MUST_FIRE = ["p := unsafe.PreviousRealm()", "\tif unsafe.PreviousRealm().PkgPath() == x {"]
UNSAFE_PREV_MUST_NOT_FIRE = ["a := unsafe.OriginCaller()", "s := unsafe.OriginSend()"]


def is_test(p):
    return p.name.endswith(("_test.gno", "_filetest.gno"))


def bodies(text):
    """Yield (lineno, name, params, body) for each top-level func.

    A top-level func ends at the next column-zero `}` -- true of gofmt'd Gno,
    and gofmt is enforced separately.
    """
    lines = text.split("\n")
    for i, line in enumerate(lines):
        m = FUNC.match(line)
        if not m:
            continue
        end = i + 1
        while end < len(lines) and not lines[end].startswith("}"):
            end += 1
        yield i + 1, m.group(1), m.group(2), "\n".join(lines[i + 1:end])


def main():
    # The fixtures run FIRST, so a pattern that stopped matching is reported
    # before the scan it would have made meaningless.
    for pat, fire, nofire, label in (
            (IS_CURRENT, IS_CURRENT_MUST_FIRE, IS_CURRENT_MUST_NOT_FIRE, "IS_CURRENT"),
            (UNSAFE_PREV, UNSAFE_PREV_MUST_FIRE, UNSAFE_PREV_MUST_NOT_FIRE, "UNSAFE_PREV")):
        rx = pat.pattern % re.escape("rlm") if "%s" in pat.pattern else pat.pattern
        for line in fire:
            if not re.search(rx, line):
                print("check-interrealm: SELFTEST %s no longer reads %r; the guard would "
                      "stop noticing the thing it exists for." % (label, line), file=sys.stderr)
                return 1
        for line in nofire:
            if re.search(rx, line):
                print("check-interrealm: SELFTEST %s reads %r, which is not one; a guard "
                      "that cries wolf gets switched off." % (label, line), file=sys.stderr)
                return 1

    # selftest rewrites these very sources in place; reading them
    # mid-plant invents findings out of somebody else's control.
    repolock.refuse_if_held("check-interrealm")

    files = [p for p in sorted(gnosource.realm_files(REALM)) if not is_test(p)]
    census, bad = 0, []
    for p in files:
        rel = str(p.relative_to(REALM))
        text = strip_comments(io.open(p, encoding="utf-8").read())
        for lineno, name, params, body in bodies(text):
            found = list(REALM_PARAM.finditer(params))
            if not found:
                continue
            census += 1
            has_cur = False
            for idx, rm in enumerate(found):
                var = rm.group(1)
                # Position among ALL parameters, not among realm ones: what makes
                # the first `cur realm` trustworthy is that it is parameter zero.
                first = params[:rm.start(1)].count(",") == 0
                if first:
                    has_cur = True
                    continue
                if not re.search(AUTHORITY.pattern % re.escape(var), body):
                    continue
                if re.search(IS_CURRENT.pattern % re.escape(var), body):
                    continue
                bad.append((rel, lineno, name,
                            "derives authority from `%s`, a realm parameter in "
                            "position %d that the caller chose. Prove it with "
                            "`%s.IsCurrent()` before trusting it."
                            % (var, params[:rm.start(1)].count(",") + 1, var)))
            if has_cur and UNSAFE_PREV.search(body):
                bad.append((rel, lineno, name,
                            "calls unsafe.PreviousRealm() while a `cur realm` is in "
                            "scope. That is a stack-walker, not your caller; use "
                            "cur.Previous()."))

    if bad:
        print("check-interrealm: %d function(s) trust a realm value they have not "
              "proved.\n" % len(bad), file=sys.stderr)
        for rel, lineno, name, why in sorted(bad):
            print("  %s:%d  func %s\n      %s" % (rel, lineno, name, why), file=sys.stderr)
        return 1

    if census < CENSUS_FLOOR:
        print("check-interrealm: found only %d function(s) taking a realm parameter, "
              "below the floor of %d. The realm did not shrink; the signature pattern "
              "stopped matching." % (census, CENSUS_FLOOR), file=sys.stderr)
        return 1

    print("check-interrealm: %d function(s) take a realm parameter; every secondary "
          "one is either unused or proved with IsCurrent() first." % census)
    return 0


if __name__ == "__main__":
    sys.exit(main())
