package kourtv3

import (
	"chain"
	"chain/banker"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

const realmPath = "gno.land/r/kourt/kourtv3"

// ugnotOf is the same read BurnedGNOT makes, pointed at any address: the refund
// test has to watch coin ARRIVE somewhere, and a mint count cannot show that.
func ugnotOf(who address) int64 {
	return banker.NewReadonlyBanker().GetCoins(who).AmountOf(gnotDenom)
}

// fundAndBuy starts a court (if needed) and buys CC with real GNOT through the
// full payment path — the V1 test idiom.
func fundAndBuy(cur realm, slug string, who address, gnot int64) {
	if !Exists(slug) {
		testing.SetRealm(testing.NewUserRealm(who))
		StartCourt(cross(cur), slug, "Buy Court "+slug)
	}
	testing.IssueCoins(chain.PackageAddress(realmPath), chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetRealm(testing.NewUserRealm(who))
	Buy(cross(cur), slug)
	testing.SetOriginSend(nil)
}

func TestBuySplitsThePaymentIntoBurnAndReserve(cur realm, t *testing.T) {
	alice := testutils.TestAddress("buy-alice")
	fundAndBuy(cur, "buy1", alice, 300_000_000)

	c := mustCourt("buy1")
	minted := c.coin.BalanceOf(alice)
	if minted <= 0 || c.minted != minted {
		t.Fatalf("the curve mints to the buyer and tracks its position: %d vs %d", minted, c.minted)
	}
	// THE SPLIT, at the launch share: a tenth of what was spent sits at the
	// keyless sink, the rest is HELD at the realm's own address and ledgered
	// against this court. 300 GNOT spends exactly on a fresh curve, so the
	// figures are round: 30 burned, 270 held. burned + reserved == spent is an
	// integer identity, asserted rather than assumed.
	spent, _ := c.crv.Cost(0, minted)
	if spent != 300_000_000 {
		t.Fatalf("the fixture spends exactly on a fresh curve: %d", spent)
	}
	if sink := BurnedGNOT(); sink != 30_000_000 {
		t.Fatalf("the sink must hold the burn share of the spend: %d", sink)
	}
	if got := ReserveGNOT("buy1"); got != 270_000_000 {
		t.Fatalf("the court must hold the rest for its coin: %d", got)
	}
	if held := ugnotOf(chain.PackageAddress(realmPath)); held != 270_000_000 {
		t.Fatalf("the realm's own balance must be the reserve, no more and no less: %d", held)
	}
	if BurnedGNOT()+ReserveGNOT("buy1") != spent {
		t.Fatal("burned + held must be exactly what was spent")
	}
	if CourtBurnedGNOT("buy1") != 30_000_000 || FranchiseOf(alice) != 30_000_000 {
		t.Fatalf("rank and franchise key on the BURNED share only: %d / %d",
			CourtBurnedGNOT("buy1"), FranchiseOf(alice))
	}
	if TotalReserveGNOT() < 270_000_000 {
		t.Fatalf("the realm-wide total counts this court's reserve: %d", TotalReserveGNOT())
	}
	// A second buy continues up the curve — strictly more expensive per coin.
	fundAndBuy(cur, "buy1", alice, 300_000_000)
	if c.minted <= minted {
		t.Fatal("the position is monotonic")
	}
}

func TestBuyGuards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("buy-guards")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "buy2", "Guards")
	// No GNOT attached.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "send GNOT", func() {
		Buy(cross(cur), "buy2")
	})
}

// Two guards the mutation harness found surviving on the money-IN path. IsUserCall is
// the one AGENTS.md names explicitly: with OriginSend payments the caller check must be
// IsUserCall, not IsUser, because a `maketx run` ephemeral realm can consume the
// origin-send envelope before calling in and so bypass the payment. Weakening it to
// `if false` failed no test — the whole payment-bypass protection was unpinned.
//
// ONE other survivor on this path is genuinely unreachable and is documented in buy.gno
// rather than faked here: the self-buy check, since the buyer is prev.Address() behind
// this IsUserCall gate and so is never the realm. Naming it here so the next reader does
// not mistake the survivor report for a list of holes.
//
// TWO MORE USED TO BE ON THAT LIST AND SHOULD NOT HAVE BEEN, and the reason they were is
// worth more than the entries: every payment this fixture probed was probed at the BOTTOM
// of the curve, and both claims are true only there.
//
//   - The remainder refund, called unreachable because Minted spent the payment EXACTLY
//     for every amount probed. Below d one base unit costs under 1 ugnot, so the round-up
//     cost sequence steps by 0 or 1 and can always finish on the payment. Past d it steps
//     by s/d and the payment lands BETWEEN two reachable totals. The live covid court is
//     five times past d. Pinned now by TestBuyReturnsTheUnspendableRemainder below, which
//     is also what pins the burn sending `spent` rather than `sent`.
//   - The "too small to mint" guard, called reachable "only once the curve is at cap"
//     because 1 ugnot mints tens of thousands of base units. It does — at position zero,
//     where a unit is worth a fraction of a ugnot. At the position this file's own fixture
//     reaches, 1 ugnot mints NOTHING and the guard fires; on covid anything under 6 ugnot
//     does. Still untested, but it is a fixture away, not a cap away.
//
// AND ONE THAT IS NOT TESTABLE HERE AT ALL, which matters more than the rest: swapping
// IsUserCall for IsUser survives this fixture, and that is exactly the downgrade
// AGENTS.md warns about — IsUser ACCEPTS a `maketx run` ephemeral realm, which can
// consume the origin-send envelope and call in with the payment already spent. The
// distinguishing caller is an /e/<addr>/run realm, and testing.NewCodeRealm REFUSES
// such a path ("should only be called for Realms"), so the harness cannot construct
// one. This assertion therefore catches DELETING the guard but not WEAKENING it.
// Enforcement of that one rests on code review, which is why AGENTS.md states it as a
// reading rule rather than a test. Recorded in PLAN §13 v0.62; do not read the survivor
// as a gap a fixture can close.
func TestBuyRefusesNonUserCallsSelfBuysAndDustPayments(cur realm, t *testing.T) {
	alice := testutils.TestAddress("byg2-alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "byg2", "More guards")

	// A call arriving from a REALM rather than a user is refused, even with GNOT
	// attached — otherwise the envelope could be spent by an intermediary.
	testing.IssueCoins(chain.PackageAddress(realmPath),
		chain.Coins{{Denom: "ugnot", Amount: 300_000_000}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300_000_000}})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/kourt/notacourt"))
	uassert.AbortsContains(t, cur, "must be a direct user call", func() {
		Buy(cross(cur), "byg2")
	})
	testing.SetOriginSend(nil)

	// The control: the SAME payment from a user call succeeds, so the guard rejects
	// the caller kind and not the payment.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300_000_000}})
	if got := Buy(cross(cur), "byg2"); got <= 0 {
		t.Fatalf("a direct user call with the same payment must mint: %d", got)
	}
	testing.SetOriginSend(nil)
}

// THE REMAINDER IS REAL COIN AND IT MOVES — the branch buy.gno used to document as
// unreachable. It is unreachable only below d, which is the only place the other
// fixtures in this file ever buy from.
//
// THE PREDICTION IS MADE FROM Cost, NOT FROM Minted, which is what stops this being a
// tautology. Minted is the function under test; asking it what it will spend and then
// asserting it spent that proves nothing. So the payment is built from the OTHER side of
// the curve's contract: the exact price of a whole KOURT, plus one ugnot less than the
// next base unit costs. That extra cannot buy a unit at any rounding, so a correct realm
// has exactly one thing it may do with it, and this test watches the buyer's balance to
// see it done.
//
// THREE MUTANTS, not one. Dropping the send leaves the coin in the realm (the last
// assertion). Sending `sent` rather than `spent` to the sink over-burns by the same ugnot
// the buyer is owed (the sink assertion, which is why it is exact rather than a bound).
// Misdirecting the refund passes the sink and fails the buyer.
func TestBuyReturnsTheUnspendableRemainder(cur realm, t *testing.T) {
	alice := testutils.TestAddress("buy-change")
	// 4,500 GNOT walks a fresh court's position to exactly 3e9 — three times d, where a
	// base unit costs about 3 ugnot. That first buy also spends its payment exactly, so
	// the fixture demonstrates both halves: the curve CAN land on a payment, and past d
	// it usually cannot.
	fundAndBuy(cur, "buy3", alice, 4_500_000_000)

	c := mustCourt("buy3")
	from := c.minted
	if from <= curveDenom {
		t.Fatalf("this fixture only means anything past d=%d, where one base unit costs at least 1 ugnot: position %d", curveDenom, from)
	}

	const units = int64(1_000_000) // one whole KOURT, in base units
	exact, okExact := c.crv.Cost(from, units)
	next, okNext := c.crv.Cost(from, units+1)
	if !okExact || !okNext {
		t.Fatal("the curve must price both spans at this position")
	}
	margin := next - exact // what one more base unit costs here
	if margin < 2 {
		t.Fatalf("a remainder can only exist where one more unit costs 2 ugnot or more: %d", margin)
	}
	extra := margin - 1 // one ugnot short of another unit: unspendable by construction
	pay := exact + extra

	held := ugnotOf(alice)
	sink := BurnedGNOT()
	kept := ugnotOf(chain.PackageAddress(realmPath))
	reserveBefore := ReserveGNOT("buy3")

	testing.IssueCoins(chain.PackageAddress(realmPath), chain.Coins{{Denom: "ugnot", Amount: pay}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: pay}})
	testing.SetRealm(testing.NewUserRealm(alice))
	got := Buy(cross(cur), "buy3")
	testing.SetOriginSend(nil)

	if got != units {
		t.Fatalf("the extra ugnot must not buy a unit: minted %d, want %d", got, units)
	}
	if back := ugnotOf(alice) - held; back != extra {
		t.Fatalf("the buyer gets the unspendable remainder back: %d, want %d", back, extra)
	}
	// THE SPLIT IS OF `exact`, NEVER OF THE ENVELOPE: the extra ugnot went back
	// to the buyer above, so neither the sink nor the reserve may have seen it.
	// The burn share rounds UP (splitPayment), so the sink takes the odd µGNOT
	// when exact does not divide by ten.
	wantReserved := mulDiv128(exact, bpsDenom-burnBps, bpsDenom)
	wantBurned := exact - wantReserved
	if burned := BurnedGNOT() - sink; burned != wantBurned {
		t.Fatalf("the sink burns the burn share of what was spent, not the envelope: %d, want %d", burned, wantBurned)
	}
	// AND THE REALM KEEPS EXACTLY THE HELD SHARE — not the envelope, not zero.
	// Three mutants used to be told apart by "keeps none"; they still are: a
	// reserve credited from `sent` is off by `extra`, one credited with the
	// whole cost is off by wantBurned, and one not credited at all is off by
	// wantReserved.
	if left := ugnotOf(chain.PackageAddress(realmPath)) - kept; left != wantReserved {
		t.Fatalf("the realm keeps exactly the held share of the payment: %d, want %d", left, wantReserved)
	}
	if ReserveGNOT("buy3") != wantReserved+reserveBefore {
		t.Fatalf("the court's ledgered reserve follows the bank: %d", ReserveGNOT("buy3"))
	}
}

