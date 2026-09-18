#!/usr/bin/env python3
"""Trip if REPUTATION ever becomes transferable.

INVERTED 2026-08-20. This script used to forbid the opposite: a court coin
becoming transferable between users. That was an owner call held open since v0.32,
and it has been decided the other way — `TransferCC` now exists, gated on
`spendable()` so committed capital cannot be sold out from under a live stake,
bond or deposit. Coin transfer is DELIBERATE and no longer a defect.

What must stay soulbound is the thing that was never really protected by the
coin's immobility: an address's earned standing. `answerRecord` is keyed by
address, has no `Remove`, and no path assigns one address's record to another —
and that property stands on its own, which is why it survives the coin becoming
tradeable. This guard now protects it directly instead of relying on a side
effect.

WHY THE OLD PATTERN WOULD NOT HAVE CAUGHT THIS. It matched coin-transfer verbs —
Transfer/Approve/TransferFrom/Delegate/Sell/Send/Gift. An entrypoint called
`AssignRecord`, `MigrateCredential`, `SetStanding`, `Bequeath` or `MoveScore`
would have sailed straight through while doing the one thing that must never be
possible. So the verb list is now about records, not coins.

WHAT THE INVERSION COST, recorded because it was real and is now load-bearing
again. The old docstring named three pieces of settled reasoning that assumed
transferability was false, and each is now live:

  - The v0.31 KEEP-NETTING ruling on electionFloor. Its refutation of the
    park-stake-to-cheapen-a-coup vector turned on an attacker being unable to
    acquire existing float. A secondary market restores that ability.
  - MODERATION.md's sybil doctrine. "Only capital-keyed defences hold" was
    stronger than it read while capital itself could not move between addresses;
    transferability lets one pile of capital back several identities in sequence.
  - Vote-buying. Conviction accrues to a holder over time, and while a coin could
    not change hands its accrued conviction could not be sold. Note the narrow
    consolation: conviction lives on `stakePos`, keyed (address, side), so selling
    coin does NOT carry conviction with it — only the future ability to earn it.

And the pricing consequence the owner accepted knowingly: the quorum floor, both
quality bars, the credential bar, the election floor and the supplyFloor lid are
all denominated in % of court supply, and were calibrated when the only way to
acquire supply was a one-way curve burning GNOT at a rising price. A secondary
market can clear below that, so those bars may now be cheaper to reach than when
their constants were chosen.

So: still a tripwire, not a rule. It no longer asserts that soulbound coin is
correct — it asserts that soulbound REPUTATION is, and that flipping THAT must be
a decision rather than an accident.
"""

import re
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gnosource import strip_comments
import repolock

ROOT = Path(__file__).resolve().parent.parent
REALMS = ["kourtv1", "kourtv2", "kourtv3"]

# An exported entrypoint whose name says it moves value between holders. Matched
# on the exported surface only: unexported helpers are this realm's own business,
# and the escrow-to-user refunds are exactly what the realm is supposed to do.
# TWO patterns, because the inversion of this guard dropped coverage nobody
# replaced and it took an external review to notice.
#
# REPUTATION, which is what the inversion was for: an address's earned standing
# must not be movable.
SUSPECT = re.compile(
    r"^func (Assign|Migrate|Move|Set|Bequeath|Gift|Sell|Grant|Delegate|Transfer)"
    r"[A-Za-z0-9_]*(Record|Credential|Standing|Score|Reputation|Priority)"
    r"[A-Za-z0-9_]*\(cur realm",
    re.M,
)

# REDEMPTION, which the inversion silently stopped watching, guarded on the axis
# that actually matters: DENOMINATION, not verb names.
#
# The inversion added a required reputation-noun suffix, and `SellCC` and
# `RedeemForGNOT` both began to PASS — tested, they did. A verb list was the wrong
# instrument anyway: it trips on `WithdrawStake`, `WithdrawBonus` and V1's three
# `Redeem*` entrypoints, all of which return a holder's own CC INSIDE the court and
# touch no GNOT, while a genuine redemption could be called anything.
#
# What is existential is that no GNOT ever leaves this realm to a user. buy.gno
# says it ("the GNOT is BURNED ... nothing ever redeems") and REGULATIONS.md's whole
# position rests on it. GNOT can only move via a banker's SendCoins, so the property
# is checkable exactly: SendCoins appears in buy.gno ONLY, at a pinned count.
#
# kourtv2's two are the burn to the keyless sink and the buyer's dust change from
# the curve; kourtv1's one is its burn. A third in kourtv2, or a first anywhere
# else, is a redemption path and this refuses it.
SENDCOINS = re.compile(r"\bSendCoins\s*\(")
SENDCOINS_ALLOWED = {("kourtv1", "buy.gno"): 1, ("kourtv2", "buy.gno"): 2,
                     ("kourtv2", "courtburn.gno"): 1,
                     # THE THIRD GENERATION: the burn share and the dust change in
                     # buy.gno, the creation burn in courtburn.gno, and the ONE send
                     # the whole generation exists for — Redeem's pro-rata payout in
                     # redeem.gno. That one is user-destined by design, so the count
                     # alone would be a blank cheque; PRO_RATA_ONLY below is the rule
                     # that keeps it a payout and nothing else.
                     ("kourtv3", "buy.gno"): 2, ("kourtv3", "courtburn.gno"): 1,
                     ("kourtv3", "redeem.gno"): 1}

# courtburn.gno's ONE send is an OWNER DECISION, and a count alone would be a
# blank cheque for it — so the entry comes with a rule that keeps the property
# being guarded actually checkable.
#
# The property is "no GNOT leaves this realm TO A USER". A send to the keyless
# burn sink does not leave to anyone: nobody holds that key, by construction
# (buy.gno's burnSinkPath note). So the court-creation burn is registered here,
# and every SendCoins in a file listed below must name burnSinkPath as its
# destination. Swap it for a user address and the count still reads 1 while the
# realm has grown a redemption path — which is exactly the substitution this
# rule refuses. buy.gno is NOT in this set: its second send is the buyer's dust
# change, deliberately user-destined, and it predates and outranks this rule.
#
# Registered when the owner reversed the v0.8.2 "no GNOT creation fee" decision
# (MODERATION.md §13.5). The creation payment burns in full and nothing is paid
# back out, which is what let the refund path be deleted rather than exempted.
SINK_ONLY = {("kourtv2", "courtburn.gno"), ("kourtv3", "courtburn.gno")}
SINK_DEST = re.compile(r"burnSinkPath")

# PRO-RATA ONLY. The two-way generation lets GNOT leave to a user through ONE
# more door than Buy's dust change, and this is what keeps that door the size
# it was designed: redeem.gno's single send must be the payout, to the caller,
# and the court's reserve must have been debited by that same payout on a line
# ABOVE it. Every other `reserve` write in the generation must be Buy's credit.
# So a redeem that pays `amount` (coin units as GNOT), pays somebody else, pays
# before it debits, or never debits, is caught here by text — and the arithmetic
# half that text cannot check (bank(realm) ≥ TotalReserveGNOT(), == on a clean
# path; payout == floor(reserve × amount / supply)) is
# TestReservesReconcileWithTheBank and kourtv3_money.txtar, named here so a
# reader knows where the other half lives.
PRO_RATA_ONLY = {("kourtv3", "redeem.gno")}
PRO_RATA_SEND = re.compile(
    r"SendCoins\(\s*cur\.Address\(\),\s*who,\s*chain\.Coins\{chain\.NewCoin\(gnotDenom,\s*payout\)\}\s*\)")
RESERVE_DEBIT = "\tc.reserve -= payout\n"
# Every write to a court's reserve, anywhere in the generation, must be one of
# these two lines. A third — an admin sweep, a rebate, a "fix" — is the custody
# surface this design says it does not have.
RESERVE_WRITE = re.compile(r"\.reserve\s*(?:\+=|-=|=)(?!=)")
RESERVE_WRITES_ALLOWED = {
    ("kourtv3", "buy.gno"): ["c.reserve = mustAdd(c.reserve, reserved)"],
    ("kourtv3", "redeem.gno"): ["c.reserve -= payout"],
}
# THE CENSUS FLOOR. A blinded RESERVE_WRITE matches nothing, flags nothing, and
# would pass — check-guards-blind's exact complaint. Two writes are KNOWN to
# exist (Buy's credit, Redeem's debit); a scan that finds fewer than two has
# broken, not found a clean tree. Fixtures pin the pattern's reading as well.
RESERVE_WRITES_FLOOR = 2
RESERVE_WRITE_MUST_FIRE = [
    "\tc.reserve = mustAdd(c.reserve, reserved)",
    "\tc.reserve -= payout",
    "\tmc.reserve += x",
]
RESERVE_WRITE_MUST_NOT_FIRE = [
    "\tif c.reserve <= 0 {",
    "\tif payout > c.reserve {",
    "\tif c.reserve == want {",
]
PRO_RATA_MUST_FIRE = [
    "\tb.SendCoins(cur.Address(), who, chain.Coins{chain.NewCoin(gnotDenom, payout)})",
]
PRO_RATA_MUST_NOT_FIRE = [
    "\tb.SendCoins(cur.Address(), who, chain.Coins{chain.NewCoin(gnotDenom, amount)})",   # coin units paid as GNOT
    "\tb.SendCoins(cur.Address(), c.escrow, chain.Coins{chain.NewCoin(gnotDenom, payout)})",  # wrong destination
    "\tb.SendCoins(cur.Address(), buyer, chain.Coins{chain.NewCoin(gnotDenom, r)})",      # Buy's dust change
]

# Exact names both patterns would otherwise trip on. WithdrawStake and
# WithdrawBonus are the reason REDEEM needs a list at all: they return a holder's
# own CC inside the court and touch no GNOT.
ALLOWED = {"TransferGlobalAdmin", "ApproveCandidate", "ApproveRetain"}


# SUSPECT MATCHES NOTHING IN A HEALTHY TREE -- that is the point of it -- so
# blinding it changes nothing and the guard passes either way. It cannot tell
# "no reputation-transfer entrypoint exists" from "my pattern stopped working",
# and check-guards-blind caught exactly that once it could see a wrapped
# re.compile(. A forbidding pattern needs strings it MUST and MUST NOT match,
# the way check-spend-paths keeps MOVE_MUST_FIRE.
SUSPECT_MUST_FIRE = [
    "func AssignRecord(cur realm, from, to address) {",
    "func TransferStanding(cur realm, to address) {",
    "func GiftReputationTo(cur realm, who address) {",
]
SUSPECT_MUST_NOT_FIRE = [
    "func AssignRecord(from, to address) {",          # not a crossing entrypoint
    "func TransferCC(cur realm, to address, n int64) {",  # coin, deliberately transferable
    "func RecordAnswer(cur realm, id uint64) {",      # records an answer, moves no standing
]


def main() -> int:
    repolock.refuse_if_held("check-nontransferable")
    scanned, hits = 0, []

    # The fixtures run FIRST, so a pattern that stopped matching is reported
    # before the scan it would have made meaningless.
    for line in SUSPECT_MUST_FIRE:
        if not SUSPECT.search(line):
            hits.append(("SELFTEST", "-", "check-nontransferable.py", 0,
                         "SUSPECT no longer reads %r as a standing transfer" % line.strip()))
    for line in SUSPECT_MUST_NOT_FIRE:
        if SUSPECT.search(line):
            hits.append(("SELFTEST", "-", "check-nontransferable.py", 0,
                         "SUSPECT reads %r as a standing transfer; it is not one, and a "
                         "guard that cries wolf gets switched off" % line.strip()))
    for line in PRO_RATA_MUST_FIRE:
        if not PRO_RATA_SEND.search(line):
            hits.append(("SELFTEST", "-", "check-nontransferable.py", 0,
                         "PRO_RATA_SEND no longer reads %r as the payout" % line.strip()))
    for line in PRO_RATA_MUST_NOT_FIRE:
        if PRO_RATA_SEND.search(line):
            hits.append(("SELFTEST", "-", "check-nontransferable.py", 0,
                         "PRO_RATA_SEND reads %r as the payout; it is not" % line.strip()))
    for line in RESERVE_WRITE_MUST_FIRE:
        if not RESERVE_WRITE.search(line):
            hits.append(("SELFTEST", "-", "check-nontransferable.py", 0,
                         "RESERVE_WRITE no longer reads %r as a reserve write" % line.strip()))
    for line in RESERVE_WRITE_MUST_NOT_FIRE:
        if RESERVE_WRITE.search(line):
            hits.append(("SELFTEST", "-", "check-nontransferable.py", 0,
                         "RESERVE_WRITE reads %r as a write; it is a read" % line.strip()))
    reserve_writes_seen = 0
    for realm in REALMS:
        d = ROOT / "r" / realm
        files = [p for p in sorted(d.glob("*.gno")) if not p.name.endswith("_test.gno")]
        if not files:
            # A silent zero here would make this check report success forever.
            print(f"check-nontransferable: no .gno files under {d}; the layout "
                  f"moved and this check is measuring nothing.", file=sys.stderr)
            return 1
        for p in files:
            scanned += 1
            # COMMENTS STRIPPED, because a comment that says "SendCoins(" is not
            # a send and counted as one until this line — the rule check-getcoins
            # already keeps for the same reason.
            src = strip_comments(p.read_text())
            for m in SUSPECT.finditer(src):
                name = m.group(0)[len("func "):].split("(")[0]
                if name in ALLOWED:
                    continue
                line = src[: m.start()].count("\n") + 1
                hits.append(("reputation", realm, p.name, line, name))
            n = len(SENDCOINS.findall(src))
            want = SENDCOINS_ALLOWED.get((realm, p.name), 0)
            if n != want:
                hits.append(("GNOT leaves the realm", realm, p.name, 0,
                             f"{n} SendCoins call(s), expected {want}"))
            # A sink-only file's sends must each name the keyless sink. Checked
            # per call rather than per file, so adding a second, user-destined
            # send is caught by this even if the count were ever raised.
            if (realm, p.name) in SINK_ONLY:
                for m in SENDCOINS.finditer(src):
                    # The destination sits in the call's own argument list; one
                    # line of slack past the closing paren covers the wrapped
                    # form the realm actually uses.
                    tail = src[m.start(): m.start() + 400]
                    stop = tail.find("\n\t}")
                    if stop != -1:
                        tail = tail[:stop]
                    if not SINK_DEST.search(tail):
                        line = src[: m.start()].count("\n") + 1
                        hits.append(("GNOT leaves the realm", realm, p.name, line,
                                     "a sink-only file sends somewhere that is "
                                     "not burnSinkPath"))
            # The pro-rata door: its one send is the payout to the caller, and the
            # reserve was debited by that payout above it.
            if (realm, p.name) in PRO_RATA_ONLY:
                for m in SENDCOINS.finditer(src):
                    tail = src[m.start(): m.start() + 200]
                    line = src[: m.start()].count("\n") + 1
                    if not PRO_RATA_SEND.search(tail):
                        hits.append(("GNOT leaves the realm", realm, p.name, line,
                                     "sends something that is not the pro-rata payout "
                                     "to the caller"))
                    elif src.count(RESERVE_DEBIT) != 1 or src.index(RESERVE_DEBIT) > m.start():
                        hits.append(("GNOT leaves the realm", realm, p.name, line,
                                     "never debits the reserve before paying "
                                     "(c.reserve -= payout, exactly once, above the send)"))
            # And no third hand on the reserve, anywhere in the generation.
            if realm == "kourtv3":
                allowed = RESERVE_WRITES_ALLOWED.get((realm, p.name), [])
                for m in RESERVE_WRITE.finditer(src):
                    reserve_writes_seen += 1
                    stmt = src[src.rfind("\n", 0, m.start()) + 1: src.find("\n", m.end())].strip()
                    if stmt not in allowed:
                        line = src[: m.start()].count("\n") + 1
                        hits.append(("GNOT leaves the realm", realm, p.name, line,
                                     f"writes a court's reserve outside Buy's credit and "
                                     f"Redeem's debit: {stmt}"))

    if reserve_writes_seen < RESERVE_WRITES_FLOOR:
        hits.append(("SELFTEST", "kourtv3", "-", 0,
                     f"RESERVE_WRITE found {reserve_writes_seen} reserve write(s), below the "
                     f"floor of {RESERVE_WRITES_FLOOR}; the pattern broke rather than the tree "
                     f"coming clean"))
    if hits:
        print("check-nontransferable: something that must not be movable "
              "appears to have become movable.\n", file=sys.stderr)
        for kind, realm, fname, line, name in hits:
            print(f"  [{kind}] {realm}/{fname}:{line}  {name}", file=sys.stderr)
        print("\nTwo properties are guarded here. An address's earned standing "
              "must not be movable. The coin is "
              "transferable by decision (TransferCC), but answerRecord is keyed "
              "by address with no Remove precisely so a credential cannot be "
              "sold — the answer-priority window and the difficulty record both "
              "price a CAREER, and a sellable one prices nothing. If this is "
              "intended, it is an owner decision: say so here and in "
              "MODERATION.md, and price rent-a-lead first.\n\nAnd GNOT leaves "
              "this realm to a user through exactly two doors: Buy's dust change, "
              "and — in the two-way generation — Redeem's pro-rata payout, which "
              "must be the payout the reserve was debited by, to the caller, and "
              "nothing else. Every other SendCoins names the keyless sink, at the "
              "pinned count per file; every other write to a court's reserve is "
              "Buy's credit. A send or a reserve write that fits none of those is "
              "a new door, and TWOWAY.md is where the design says there is none.",
              file=sys.stderr)
        return 1

    print(f"check-nontransferable: {scanned} realm files, no entrypoint moves "
          f"an address's record; GNOT reaches a user only as Buy's change or as "
          f"Redeem's pro-rata payout, and nothing but Buy and Redeem touches a "
          f"court's reserve. Coin is transferable between holders by decision; "
          f"standing is not.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
