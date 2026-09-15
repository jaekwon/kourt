#!/usr/bin/env python3
"""The burn-sink read is GetCoins on gnoland-1, and this keeps it that way.

    python3 scripts/check-getcoins.py

INVERTED BY OWNER DECISION. This guard used to FORBID GetCoins, which is the
right rule for code that can still be deployed. buy.gno cannot: it is live on
gnoland-1 and a package deploys exactly once, so the repo now mirrors what runs
rather than a fix that can never reach it. Changing that line here would create a
divergence from production -- a DEPLOY decision, not a cleanup -- and this is
where that shows up.

THE RULE IT STILL ENFORCES, for everything else. Reading one balance is
`banker.GetCoin(addr, denom)`. `GetCoins(addr)`
reads EVERY denom the address holds, and anyone may send any address a new denom
without its consent -- so the cost of the read is set by a third party, not by
this realm. On any address an outsider can reach, that is a permanent
out-of-gas waiting for somebody to decide it should happen.

THIS IS NOT HYPOTHETICAL AND IT IS NOT HISTORY: it is live on gnoland-1 right
now. The deployed buy.gno reads

    b.GetCoins(chain.PackageAddress(burnSinkPath)).AmountOf(gnotDenom)

from BurnedGNOT(), which renderAdminParams() calls, which Render() reaches for
the `admin-params` page. And BurnSink() publishes that address on purpose, so
anybody can reconcile the burn -- which also tells an attacker precisely where
to send junk denoms to make the page cost more to read every time. The repo was
fixed to GetCoin; a package deploys exactly once, so the fix cannot reach that
path. This guard exists so the version people CAN still fix does not drift back.

TESTS ARE EXEMPT, and the distinction is the whole point rather than
convenience: a test picks its own addresses, so no stranger sets the cost. What
makes GetCoins dangerous is reachability by someone who wants it to hurt.

THE CENSUS COUNTS THE SAFE FORM, not the dangerous one. Counting GetCoins could
not tell "the realm is clean" from "the scan broke" -- both read zero. GetCoin
must be non-zero for the scan to have looked at anything at all.
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

# BANNED first: check-guards-blind blinds the first named pattern, and with this
# one blinded nothing is ever flagged -- so the census floor below is what has to
# turn that into a failure.
BANNED = re.compile(r"\bGetCoins\s*\(")
SAFE = re.compile(r"\bGetCoin\s*\(")
CENSUS_FLOOR = 1

# THE CENSUS ALONE CANNOT SEE A BROKEN `BANNED`. It counts the SAFE form, so
# blinding BANNED leaves the count untouched: the guard flags nothing, reports a
# clean tree and exits 0. check-guards-blind caught exactly that here once it was
# able to run a guard at all. A forbidding guard needs a string its pattern MUST
# match, the way check-spend-paths keeps MOVE_MUST_FIRE.
BANNED_MUST_FIRE = [
    "\treturn b.GetCoins(chain.PackageAddress(burnSinkPath)).AmountOf(gnotDenom)",
    "x := banker.NewReadonlyBanker().GetCoins(who)",
]
# SAFE NOW MATCHES NOTHING IN THE TREE. buy.gno was the only GetCoin and it is
# reverted to the deployed GetCoins, so blinding SAFE changes no count and the
# guard passes either way -- check-guards-blind caught it the moment the revert
# landed. A fixture tests the pattern rather than the tree, which is the only
# thing that works for a form the realm does not currently use.
SAFE_MUST_FIRE = [
    "\treturn b.GetCoin(addr, denom)",
    "x := banker.NewReadonlyBanker().GetCoin(a, d)",
]
SAFE_MUST_NOT_FIRE = ["\tb.GetCoins(addr)", "\tGetCoinCount(addr)"]
BANNED_MUST_NOT_FIRE = [
    "\treturn b.GetCoin(chain.PackageAddress(burnSinkPath), gnotDenom)",
    "total := GetCoinCount(addr)",
]


def main():
    # selftest rewrites these very sources in place; reading them
    # mid-plant invents findings out of somebody else's control.
    repolock.refuse_if_held("check-getcoins")

    safe_seen, bad = 0, []

    # The fixtures run FIRST, so a pattern that stopped matching is reported
    # before the census it would have made meaningless.
    for line in BANNED_MUST_FIRE:
        if not BANNED.search(line):
            bad.append(("check-getcoins.py", 0,
                        "SELFTEST: BANNED no longer reads %r as a GetCoins call"
                        % line.strip()))
    for line in SAFE_MUST_FIRE:
        if not SAFE.search(line):
            bad.append(("check-getcoins.py", 0,
                        "SELFTEST: SAFE no longer reads %r as a single-denom read"
                        % line.strip()))
    for line in SAFE_MUST_NOT_FIRE:
        if SAFE.search(line) and not BANNED.search(line):
            bad.append(("check-getcoins.py", 0,
                        "SELFTEST: SAFE reads %r as a single-denom read; it is not one"
                        % line.strip()))
    for line in BANNED_MUST_NOT_FIRE:
        if BANNED.search(line):
            bad.append(("check-getcoins.py", 0,
                        "SELFTEST: BANNED reads %r as a GetCoins call; it is not one, "
                        "and a guard that cries wolf gets switched off" % line.strip()))
    for p in sorted(gnosource.realm_files(REALM)):
        if p.name.endswith(("_test.gno", "_filetest.gno")):
            continue
        text = strip_comments(io.open(p, encoding="utf-8").read())
        rel = str(p.relative_to(REALM))
        for lineno, line in enumerate(text.split("\n"), 1):
            if BANNED.search(line):
                bad.append((rel, lineno, line.strip()[:90]))
            # EITHER FORM COUNTS TOWARD THE CENSUS. It used to count only GetCoin,
            # which was right while GetCoin was the rule; with buy.gno reverted to
            # the deployed GetCoins there is no GetCoin left in the realm and the
            # floor fired on a healthy tree. What the floor is for is proving the
            # scan looked at something -- a balance read of either shape does that.
            if BANNED.search(line) or SAFE.search(line):
                safe_seen += 1

    # The one site that is live on gnoland-1 and cannot be changed without a
    # redeploy. Keyed on the LINE'S TEXT, not its number: a line number rots the
    # moment anything above it moves, and adding the comment that explains this
    # already shifted it from 123 to 136. check-citations makes the same argument
    # about file:line and uses an anchor for the same reason.
    DEPLOYED = "return b.GetCoins(chain.PackageAddress(burnSinkPath)).AmountOf(gnotDenom)"
    bad = [b for b in bad if not (b[0] == "r/kourtv2/buy.gno" and b[2].strip() == DEPLOYED)]
    # STRIPPED, not raw. buy.gno's own comment says "GetCoin, NOT
    # GetCoins(...).AmountOf" -- which matches BANNED -- so a raw read reports the
    # deployed form present no matter what the code says, and this check passed
    # while the line was "fixed". That is the fourth time this session a comment
    # has been read as code; strip_comments exists for it.
    if not any(BANNED.search(l) for l in strip_comments(
               io.open(REALM / "r/kourtv2/buy.gno", encoding="utf-8").read()).split("\n")):
        print("check-getcoins: buy.gno no longer reads the burn sink with GetCoins. "
              "That is the DEPLOYED form; changing it here diverges the repo from "
              "gnoland-1, which is a deploy decision rather than a cleanup.",
              file=sys.stderr)
        return 1

    if bad:
        print("check-getcoins: %d balance read(s) whose cost a third party sets.\n"
              % len(bad), file=sys.stderr)
        for rel, lineno, src in bad:
            print("  %s:%d\n      %s" % (rel, lineno, src), file=sys.stderr)
        print("\nUse GetCoin(addr, denom). GetCoins walks every denom the address holds,\n"
              "and anyone can give an address a denom it never asked for. The deployed\n"
              "buy.gno still does this on the published burn sink -- see this file's\n"
              "header for what that costs.", file=sys.stderr)
        return 1

    if safe_seen < CENSUS_FLOOR:
        print("check-getcoins: found no balance reads at all, so this check is scanning\n"
              "for a shape the realm no longer has. Zero GetCoins means nothing when\n"
              "zero GetCoin means the scan never looked.", file=sys.stderr)
        return 1

    print("check-getcoins: %d balance read(s). The burn-sink read is still the "
          "GetCoins form gnoland-1 runs; nothing else uses it." % safe_seen)
    return 0


if __name__ == "__main__":
    sys.exit(main())
