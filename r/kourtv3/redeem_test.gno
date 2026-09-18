package kourtv3

import (
	"chain"
	"math/bits"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// floorProRata is the payout recomputed by hand, in the test, with the standard
// library's 128-bit primitives — so the assertion is not the realm's mulDiv128
// agreeing with itself.
func floorProRata(reserve, amount, supply int64) int64 {
	hi, lo := bits.Mul64(uint64(reserve), uint64(amount))
	q, _ := bits.Div64(hi, lo, uint64(supply))
	return int64(q)
}

// THE PAYOUT, AND WHAT IT LEAVES BEHIND. One buy, one redeem of part of it,
// every counter checked against the arithmetic written out here rather than
// against the function under test.
func TestRedeemPaysTheFloorProRataAndBurns(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rd-alice")
	fundAndBuy(cur, "rd1", alice, 300_000_000)
	c := mustCourt("rd1")
	supply, reserve := c.coin.TotalSupply(), ReserveGNOT("rd1")
	if reserve != 270_000_000 || supply != c.coin.BalanceOf(alice) {
		t.Fatalf("fixture: reserve %d, supply %d", reserve, supply)
	}
	amount := supply / 3
	want := floorProRata(reserve, amount, supply)
	if RedeemValue("rd1", amount) != want {
		t.Fatalf("the quote must be the floor pro-rata share: %d vs %d", RedeemValue("rd1", amount), want)
	}
	held := ugnotOf(alice)
	realmBefore := ugnotOf(chain.PackageAddress(realmPath))
	position := CurvePosition("rd1")
	burnedBefore, franchiseBefore := CourtBurnedGNOT("rd1"), FranchiseOf(alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	paid := Redeem(cross(cur), "rd1", amount)

	if paid != want {
		t.Fatalf("Redeem paid %d, the floor pro-rata share is %d", paid, want)
	}
	if got := ugnotOf(alice) - held; got != paid {
		t.Fatalf("the GNOT must arrive at the redeemer: %d, want %d", got, paid)
	}
	if got := realmBefore - ugnotOf(chain.PackageAddress(realmPath)); got != paid {
		t.Fatalf("the realm's balance falls by exactly the payout: %d", got)
	}
	if ReserveGNOT("rd1") != reserve-paid || RedeemedGNOT("rd1") != paid {
		t.Fatalf("the ledgered reserve and the paid-out total move by the payout: %d / %d",
			ReserveGNOT("rd1"), RedeemedGNOT("rd1"))
	}
	if c.coin.TotalSupply() != supply-amount || c.coin.BalanceOf(alice) != supply-amount {
		t.Fatal("the redeemed coin is destroyed")
	}
	// WHAT IT DOES NOT TOUCH: the curve position, the burn record, the rank key,
	// the franchise. Every one of these counts GNOT destroyed, and nothing was.
	if CurvePosition("rd1") != position {
		t.Fatal("the curve position never walks back")
	}
	if CourtBurnedGNOT("rd1") != burnedBefore || FranchiseOf(alice) != franchiseBefore {
		t.Fatal("redeeming destroys no GNOT, so it moves neither the burn record nor the franchise")
	}
	// NAV-NEUTRAL FOR EVERYONE ELSE: the per-coin figure after is at least the
	// per-coin figure before (floor rounding leaves the dust in the reserve).
	// In 128 bits: (reserve − paid) × supply ≥ reserve × (supply − amount).
	lhi, llo := bits.Mul64(uint64(reserve-paid), uint64(supply))
	rhi, rlo := bits.Mul64(uint64(reserve), uint64(supply-amount))
	if lhi < rhi || (lhi == rhi && llo < rlo) {
		t.Fatal("a redemption lowered what the remaining holders are owed per coin")
	}
}

// THE GATE. Coin behind a live stake cannot be redeemed, and the refusal is the
// stake wording in full — check-abort-assertions refuses a substring the ledger's
// own Burn also prints. Then the free part redeems, and the numbers are exact.
// This is the covering test check-spend-paths names for Redeem.
func TestCommittedCoinCannotBeRedeemed(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rd-lock")
	fundAndBuy(cur, "rd2", alice, 300_000_000)
	bal := CoinBalanceOf("rd2", alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rd2", "Is committed coin redeemable?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "rd2", id, 0, SpendableOf("rd2", alice)*3/4)
	staked := LockedOf("rd2", alice)
	free := DisposableOf("rd2", alice)
	if staked <= 0 || free <= 0 || free+staked != CoinBalanceOf("rd2", alice) {
		t.Fatalf("fixture: staked %d, free %d, balance %d", staked, free, CoinBalanceOf("rd2", alice))
	}

	// The whole balance: refused, naming the stake.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: not enough unstaked CC", func() {
		Redeem(cross(cur), "rd2", CoinBalanceOf("rd2", alice))
	})
	// One more than the free part: refused the same way.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: not enough unstaked CC", func() {
		Redeem(cross(cur), "rd2", free+1)
	})
	if CoinBalanceOf("rd2", alice) != bal-1_100_000 { // the claim's deposit + fee moved to escrow
		t.Fatalf("a refused redeem must leave the balance alone: %d", CoinBalanceOf("rd2", alice))
	}

	// Exactly the free part: paid at the quote, and the stake is untouched.
	c := mustCourt("rd2")
	want := floorProRata(ReserveGNOT("rd2"), free, c.coin.TotalSupply())
	held := ugnotOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	paid := Redeem(cross(cur), "rd2", free)
	if paid != want || ugnotOf(alice)-held != paid {
		t.Fatalf("the free part redeems at the quote: %d vs %d", paid, want)
	}
	if LockedOf("rd2", alice) != staked || CoinBalanceOf("rd2", alice) != staked {
		t.Fatal("the stake is exactly what is left, still locked")
	}
	// Supply conservation, the assertion TestLockedStakeCannotBeSpentTwice ends on.
	if c.coin.TotalSupply() != CoinBalanceOf("rd2", alice)+CoinBalanceOf("rd2", c.escrow) {
		t.Fatal("total supply must equal the sum of balances")
	}
}

// THE REFUSALS THAT ARE NOT ABOUT THE AMOUNT, each by its full text.
func TestRedeemRefusesWhatItMust(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rd-refuse")
	fundAndBuy(cur, "rd3", alice, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: redeem amount must be positive", func() {
		Redeem(cross(cur), "rd3", 0)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: no such court", func() {
		Redeem(cross(cur), "nosuchcourt", 1)
	})
	// META IS ONE-WAY BY CONSTRUCTION, and so is any court founded that way.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: this court's coin is one-way", func() {
		Redeem(cross(cur), metaSlug, 1)
	})
	// A two-way court nobody has paid into holds nothing, and says so rather
	// than reaching the pro-rata arithmetic with a zero reserve.
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "rd3e", "Empty Court")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: this court holds no reserve", func() {
		Redeem(cross(cur), "rd3e", 1)
	})
	// Attached GNOT would land at the realm address uncredited: refused.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1}})
	uassert.AbortsContains(t, cur, "kourtv3: Redeem takes no GNOT", func() {
		Redeem(cross(cur), "rd3", 1)
	})
	testing.SetOriginSend(nil)
	// The dust refusal names the smallest redeemable amount rather than burning
	// coin for nothing: on this court one base unit returns 0 µGNOT.
	c := mustCourt("rd3")
	if RedeemValue("rd3", 1) != 0 {
		t.Fatalf("fixture: one unit must round to nothing here (reserve %d, supply %d)", c.reserve, c.coin.TotalSupply())
	}
	supplyBefore := c.coin.TotalSupply()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: too small to return a µGNOT", func() {
		Redeem(cross(cur), "rd3", 1)
	})
	if c.coin.TotalSupply() != supplyBefore {
		t.Fatal("a refused dust redeem must burn nothing")
	}
	// RedeemValue never panics on junk: over-supply, zero, negative all read 0.
	if RedeemValue("rd3", supplyBefore+1) != 0 || RedeemValue("rd3", 0) != 0 || RedeemValue("rd3", -5) != 0 {
		t.Fatal("RedeemValue answers 0 for an unredeemable amount")
	}
}

// A COURT FOUNDED ONE-WAY burns the whole payment, holds nothing, and refuses to
// return anything — V2's coin, by choice, beside a two-way one in the same realm.
func TestAOneWayCourtBurnsEverythingAndHoldsNothing(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rd-oneway")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartOneWayCourt(cross(cur), "rd4", "One Way Court")
	if !CourtOneWay("rd4") || CourtOneWay(metaSlug) != true {
		t.Fatal("the flag is set at creation, and meta carries it too")
	}
	sink := BurnedGNOT()
	fundAndBuy(cur, "rd4", alice, 300_000_000)
	if BurnedGNOT()-sink != 300_000_000 {
		t.Fatalf("a one-way court burns the whole payment: %d", BurnedGNOT()-sink)
	}
	if ReserveGNOT("rd4") != 0 || RedeemValue("rd4", 1_000_000) != 0 {
		t.Fatal("a one-way court holds nothing for its coin")
	}
	if FranchiseOf(alice) != 300_000_000 || CourtBurnedGNOT("rd4") != 300_000_000 {
		t.Fatal("rank and franchise count the whole payment on a one-way court, because all of it burned")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv3: this court's coin is one-way", func() {
		Redeem(cross(cur), "rd4", 1_000_000)
	})
	// And a two-way court by default: StartCourt founds the other kind.
	bob := testutils.TestAddress("rd-twoway")
	fundAndBuy(cur, "rd5", bob, 300_000_000)
	if CourtOneWay("rd5") || ReserveGNOT("rd5") != 270_000_000 {
		t.Fatal("StartCourt founds a two-way court")
	}
}

// THE PROPERTY THE BURN SHARE EXISTS FOR. On a court where the buyer is the only
// holder, redeeming returns the whole held share — so anything credited on that
// share would be minted for free, lap after lap. Franchise and rank are credited
// on the burned share only, and a lap earns exactly what it destroys.
func TestAShellCourtLapAccruesOnlyWhatItBurns(cur realm, t *testing.T) {
	farmer := testutils.TestAddress("rd-farmer")
	var burnedTotal int64
	for lap := 0; lap < 3; lap++ {
		sink := BurnedGNOT()
		fundAndBuy(cur, "rd6", farmer, 100_000_000)
		burnedTotal += BurnedGNOT() - sink
		testing.SetRealm(testing.NewUserRealm(farmer))
		Redeem(cross(cur), "rd6", CoinBalanceOf("rd6", farmer))
	}
	if FranchiseOf(farmer) != burnedTotal || CourtBurnedGNOT("rd6") != burnedTotal {
		t.Fatalf("three laps must accrue exactly what they burned: franchise %d, rank %d, burned %d",
			FranchiseOf(farmer), CourtBurnedGNOT("rd6"), burnedTotal)
	}
	if burnedTotal != 30_000_000 {
		t.Fatalf("a tenth of each 100 GNOT lap: %d", burnedTotal)
	}
	// The sole holder got the held share back each lap; the burn share is gone.
	if ReserveGNOT("rd6") != 0 || mustCourt("rd6").coin.TotalSupply() != 0 {
		t.Fatalf("a sole holder redeems the whole reserve: reserve %d, supply %d",
			ReserveGNOT("rd6"), mustCourt("rd6").coin.TotalSupply())
	}
}

// A BUY THEN A REDEEM NEVER PROFITS, at any position: the next coin is priced off
// total-ever-minted while the reserve holds the average of past payments less the
// burn share. Proved in TWOWAY.md; held here at three positions of one court.
func TestBuyThenRedeemNeverProfits(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rd-flip")
	bob := testutils.TestAddress("rd-anchor")
	fundAndBuy(cur, "rd7", bob, 200_000_000) // somebody else is in the pool
	for _, pay := range []int64{1_000_000, 50_000_000, 400_000_000} {
		before := CoinBalanceOf("rd7", alice)
		held := ugnotOf(alice)
		fundAndBuy(cur, "rd7", alice, pay)
		got := CoinBalanceOf("rd7", alice) - before
		testing.SetRealm(testing.NewUserRealm(alice))
		back := Redeem(cross(cur), "rd7", got)
		// fundAndBuy issues `pay` to the realm and Buy refunds only the dust, so
		// alice's balance moves by the payout less what she actually spent; the
		// round trip must leave her with no more than she started with.
		if ugnotOf(alice) > held+back && back >= pay {
			t.Fatalf("a round trip at %d returned %d: more than was paid", pay, back)
		}
		if back >= pay {
			t.Fatalf("a round trip must lose the burn share and the curve spread: paid %d, got back %d", pay, back)
		}
	}
}

// RESERVES RECONCILE WITH THE BANK. Two courts, a scripted interleaving of buys
// and redeems, and after every step the ledgered reserves add up to the realm's
// own balance while the sink holds exactly the burned shares. This is the
// conservation the guard cannot check by text.
func TestReservesReconcileWithTheBank(cur realm, t *testing.T) {
	a, b := testutils.TestAddress("rd-rec-a"), testutils.TestAddress("rd-rec-b")
	sink0 := BurnedGNOT()
	total0 := TotalReserveGNOT()
	realm0 := ugnotOf(chain.PackageAddress(realmPath))
	check := func(step string) {
		sum := ReserveGNOT("rd8a") + ReserveGNOT("rd8b")
		if TotalReserveGNOT()-total0 != sum {
			t.Fatalf("%s: the realm-wide total must be the sum of the courts: %d vs %d", step, TotalReserveGNOT()-total0, sum)
		}
		if ugnotOf(chain.PackageAddress(realmPath))-realm0 != sum {
			t.Fatalf("%s: the bank must hold exactly the reserves: %d vs %d", step, ugnotOf(chain.PackageAddress(realmPath))-realm0, sum)
		}
		if BurnedGNOT()-sink0 != CourtBurnedGNOT("rd8a")+CourtBurnedGNOT("rd8b") {
			t.Fatalf("%s: the sink must hold exactly the burned shares", step)
		}
		for _, s := range []string{"rd8a", "rd8b"} {
			c := mustCourt(s)
			if CourtBurnedGNOT(s)+ReserveGNOT(s)+RedeemedGNOT(s) != c.paidIn {
				t.Fatalf("%s: %s: burned + held + paid out must be every µGNOT paid in", step, s)
			}
		}
	}
	// Both courts exist before the first check reads them both.
	fundAndBuy(cur, "rd8a", a, 300_000_000)
	fundAndBuy(cur, "rd8b", b, 4_500_000_000) // past d: dust change fires here
	check("two buys")
	fundAndBuy(cur, "rd8a", b, 77_777_777)
	check("buy a2")
	for i := 0; i < 4; i++ {
		testing.SetRealm(testing.NewUserRealm(b))
		Redeem(cross(cur), "rd8b", CoinBalanceOf("rd8b", b)/3)
		check("redeem b")
		fundAndBuy(cur, "rd8a", a, 12_345_678)
		check("buy a3")
		testing.SetRealm(testing.NewUserRealm(a))
		Redeem(cross(cur), "rd8a", CoinBalanceOf("rd8a", a)/2)
		check("redeem a")
	}
}

// THE KNOB. Admin-only, bounded, applies to later payments only, and the packed
// admin-params line carries it.
func TestSetBurnBpsIsAdminOnlyAndBounded(cur realm, t *testing.T) {
	stranger := testutils.TestAddress("rd-stranger")
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "kourtv3: only the global DAO admin sets the burn share", func() {
		SetBurnBps(cross(cur), 2000)
	})
	shouldPanicV2(t, "burn share must be between", func() { mustSaneBurnBps(499) })
	shouldPanicV2(t, "burn share must be between", func() { mustSaneBurnBps(5001) })
	mustSaneBurnBps(500)
	mustSaneBurnBps(5000)
	if BurnBps() != 1000 {
		t.Fatalf("the launch share is a tenth: %d", BurnBps())
	}
}

// THE VOTE LOCK BINDS ON REDEEM, and this is the line that keeps a two-way coin
// from reopening the rented ballot RENTEDWEIGHT.md measured at 599x: a holder who
// voted cannot cash the voted coin out through the court until the round resolves,
// any more than they could transfer it. Modelled on
// TestVotedCoinCannotLeaveUntilTheRoundResolves, with every party buying through
// the curve so the court holds a reserve to refuse from.
func TestVotedCoinCannotBeRedeemedUntilTheRoundResolves(cur realm, t *testing.T) {
	author := testutils.TestAddress("rd-vl-author")
	staker := testutils.TestAddress("rd-vl-staker")
	voter := testutils.TestAddress("rd-vl-voter")
	fundAndBuy(cur, "rd9", author, 300_000_000)
	fundAndBuy(cur, "rd9", staker, 300_000_000)
	fundAndBuy(cur, "rd9", voter, 300_000_000)
	c := mustCourt("rd9")
	id := stakeAnswerDispute(cur, "rd9", author, staker)

	// A sealed epoch behind the voter, so their snapshot carries weight.
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenDispute(cross(cur), "rd9", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "rd9", id, "yes")
	w := VoteLockedOf("rd9", voter)
	if w <= 0 {
		t.Fatal("fixture is vacuous: nothing was voted, so nothing is being locked")
	}
	bal := CoinBalanceOf("rd9", voter)
	free := DisposableOf("rd9", voter)
	if free >= bal {
		t.Fatalf("fixture: the vote must commit something: balance %d, free %d", bal, free)
	}

	// The voted coin cannot be cashed out, and the refusal names the vote.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "kourtv3: not enough uncommitted CC", func() {
		Redeem(cross(cur), "rd9", bal)
	})
	// Coin above the commitment still can — the lock is amount-keyed.
	if free > 0 {
		want := floorProRata(ReserveGNOT("rd9"), free, c.coin.TotalSupply())
		testing.SetRealm(testing.NewUserRealm(voter))
		if paid := Redeem(cross(cur), "rd9", free); paid != want {
			t.Fatalf("the free part redeems at the quote: %d vs %d", paid, want)
		}
	}
	if VoteLockedOf("rd9", voter) != w {
		t.Fatal("redeeming the free part must not touch the vote lock")
	}
}
