// Buy: the bonding curve, V3 disposition — the payment SPLITS. A DAO-set share
// (BurnBps, a tenth at launch) is BURNED to a keyless sink exactly as V2 burned
// the whole of it; the rest is HELD in c.reserve and paid back pro-rata by
// Redeem (redeem.gno). A one-way court burns all of it, as V2 did. The curve
// position never walks back. No "backing" figure is rendered; RedeemValue is.

package kourtv3

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
)

const gnotDenom = "ugnot"

// burnSinkPath derives the keyless burn address. chain.PackageAddress hashes the
// string it is given, and THE GUARANTEE IS THE PACKAGE-PATH GRAMMAR, not any
// realm API: this string carries a ':', which no deployable package path may
// contain, so no addpkg can ever create a realm at it, no `maketx run` can be
// it, and it is not a sub-realm of kourtv3 either — gno's sub-realm separator
// is '#', so kourtv3's own realm.Sub("burned") would derive a different address
// altogether. (An earlier comment here called it "a sub-realm identity that is
// never created"; that was the right conclusion for the wrong reason, and the
// frozen kourtv2 copy still says it.) No key, no code, no path to the coins,
// ever — and the address is recomputable by anyone from this line, which is
// what kourtv3_money.txtar does.
const burnSinkPath = "gno.land/r/kourt/kourtv3:burned"

// Buy mints CC for GNOT on the curve, burns the burn share of the payment and
// holds the rest in the court's reserve. Returns the CC minted; the unspent
// remainder of the payment is refunded. The curve is the only GNOT-side mint
// and its position is monotonic — the same stretch is never sold twice, and
// Redeem never walks it back.
//
// minUnits IS THE BUYER'S FLOOR: the fewest base units they will accept for
// the GNOT attached. 0 means no floor. If the offering would mint fewer, the
// call aborts BEFORE any state moves or any coin is sent, so the attached GNOT
// comes back with the aborted transaction.
//
// WHY A FLOOR, AND WHY ON THE BUYER'S SIDE. Curve-minted coin is redeemable in
// the very next transaction, and a buy is priced off the position at the
// moment it lands, not the moment it was signed. So whoever can order a block
// ahead of a large buy into a young court has a riskless lap: buy just before
// it, let the victim's buy walk the price up, redeem just after — the victim
// is the "later buyer" whose GNOT funds the §4 early-position windfall, and
// they receive fewer units than the page quoted them (TWOWAY.md §6 A15: worth
// doing once the incoming buy is about four times what the court has taken
// in, and needing ordering control, which a proposer or an announced launch buy
// supplies). The realm cannot see intent, but the buyer knows what they were
// quoted: passing that figure here turns "I received less than I was shown"
// from a loss into a refusal. The alternative — a per-position cost basis or a
// redemption hold on fresh curve coin — would reprice every holder's exit to
// close one ordering attack; TWOWAY.md §9 records it as considered and not
// taken. A negative floor is vacuous, exactly like 0: delta is positive by the
// guard above the check, so it can never be below one.
func Buy(cur realm, slug string, minUnits int64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	// Payment auth (V1 AUDIT.md obligation, unchanged): a DIRECT user call —
	// IsUserCall, not IsUser, so a maketx-run ephemeral realm cannot pre-consume
	// the coin envelope. Reading unsafe.OriginSend under IsCurrent+IsUserCall is
	// the sanctioned inbound-payment pattern (what AGENTS.md flags is
	// unsafe.PreviousRealm, not this).
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("kourtv3: a buy must be a direct user call")
	}
	buyer := prev.Address()

	c := mustCourt(slug)
	if buyer == cur.Address() {
		panic("kourtv3: the court's own address may not buy")
	}
	touch(c)

	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent <= 0 {
		panic("kourtv3: send GNOT to buy the coin")
	}

	delta, spent := c.crv.Minted(c.minted, sent)
	if delta <= 0 {
		// Aborting reverts the incoming send — the buyer keeps their GNOT.
		panic("kourtv3: payment too small to mint a coin")
	}
	// THE FLOOR, checked before the first write OF THE BUY. touch(c) above is
	// time accrual that every call into this court performs whether or not this
	// one goes through — it moves lastAccrual, the accrual carry and, at a
	// period boundary, the period — and on a node the aborted transaction
	// reverts it with everything else. Nothing the BUY does has happened yet:
	// everything below this line moves the position, the ledger, the reserve
	// or the sink, so a refusal here leaves all four exactly as they were and
	// the aborted transaction returns the envelope
	// (TestBuyMinUnitsRefusesAndRefunds pins the four). Both figures are
	// named, need-and-have, as every refusal in this realm leads with them.
	if delta < minUnits {
		panic("kourtv3: this offering would mint fewer units than your floor — " +
			strconv.FormatInt(delta, 10) + " < " + strconv.FormatInt(minUnits, 10))
	}
	c.minted += delta // monotonic curve position
	recordPrice(c)     // the position moved, so the price may have ticked
	c.coin.Mint(buyer, delta)

	// THE SPLIT. Of the exact curve cost — `spent`, never `sent`: the dust below
	// is the buyer's — a share burns and the rest is held for this court's coin.
	// The held share stays at this realm's own address with no send at all; the
	// money-path add fails loud rather than skip (mustAdd), because a reserve
	// that quietly under-counts is a reserve that pays out somebody else's GNOT.
	burned, reserved := splitPayment(c, spent)
	c.reserve = mustAdd(c.reserve, reserved)
	c.paidIn = mustAdd(c.paidIn, spent)
	totalReserve = mustAdd(totalReserve, reserved)
	// RANK AND FRANCHISE KEY ON THE BURNED SHARE ONLY. Burned GNOT is the one
	// un-sybil-able signal a court can accrue — you cannot fake having destroyed
	// real money — which is why the front page ranks on it (MODERATION.md §3.2)
	// and why the appeals-layer entitlement (meta.gno) is denominated in it. The
	// held share is exactly what Redeem can pay back, so crediting either on it
	// would make a shell court a free mint: buy, accrue, redeem, repeat. On the
	// burned share a lap costs what it earns. Both are render-layer or accrual-
	// only: no money path reads the index, and nothing is minted until claimed.
	reindexBurn(c, burned)
	accrueFranchise(c, buyer, burned)

	// BURN the burn share: send it to the keyless sink. Verifiable on-chain;
	// never described as a scarcity feature (§7.4 / Munchee). The ceiling on the
	// split (splitPayment) makes this at least 1 µGNOT for every real buy, so
	// this send always runs and its textual count is its runtime count.
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), chain.PackageAddress(burnSinkPath),
		chain.Coins{chain.NewCoin(gnotDenom, burned)})

	// THE BUYER'S CHANGE, and it is paid on most buys — which is the opposite of what
	// this comment used to say. It read: unreachable at this curve's granularity, delta
	// is in base units so one more of them costs far under 1 ugnot, Minted's step-up
	// loop plus round-up Cost land `spent` EXACTLY on `sent` for every payment probed,
	// and a fixture would have to coarsen the curve to reach it.
	//
	// Every clause of that is true BELOW d and false above it, and the only payments
	// ever probed were below d. A base unit costs s/d: under 1 ugnot while s < d, so the
	// round-up cost sequence steps by 0 or 1 and can always finish exactly on the
	// payment. Past d it steps by s/d, and a payment lands BETWEEN two reachable totals
	// with no way to spend the difference.
	//
	// Measured on the deployed covid court, which sits at s ≈ 5.1e9 — five times d, so
	// one base unit costs 5 ugnot: 100 GNOT buys 19,533,968 of them for 99,999,999, and
	// this line returns the last ugnot. The nearest reachable totals either side are
	// 99,999,994 and 100,000,004.
	//
	// Pinned by TestBuyReturnsTheUnspendableRemainder, which builds its payment from
	// Cost rather than from Minted so the assertion is not the function under test
	// agreeing with itself. It also pins the burn above: sending `sent` instead of
	// `spent` over-burns by exactly the ugnot owed back here.
	if r := sent - spent; r > 0 {
		b.SendCoins(cur.Address(), buyer, chain.Coins{chain.NewCoin(gnotDenom, r)})
	}
	// THE SPLIT IS ON THE RECORD. A buyer can verify what burned and what was
	// held for them without trusting the page that quoted it, and an indexer can
	// total the reserve from events alone. Strings, as every emit here.
	chain.Emit(boughtEvent,
		"court", c.id,
		"who", buyer.String(),
		"minted", strconv.FormatInt(delta, 10),
		"spent", strconv.FormatInt(spent, 10),
		"burned", strconv.FormatInt(burned, 10),
		"reserved", strconv.FormatInt(reserved, 10),
	)
	return delta
}

// -------------------------------------------------------------------- reads --

// CurvePosition is the monotonic total ever minted by the curve (emission
// mints separately — see EmittedTotal).
func CurvePosition(slug string) int64 { return mustCourt(slug).minted }

// BurnSink is the keyless address the GNOT goes to — published so anyone can
// audit the burn against bank balances.
func BurnSink() address { return chain.PackageAddress(burnSinkPath) }

// BurnedGNOT is the sink's live balance — the audit read for the burn.
//
// GetCoin, NOT GetCoins(...).AmountOf, and this is the one line kourtv3 was
// allowed to change before anything else. GetCoins reads EVERY denom the address
// holds and its iterator walk is charged for all of them, so its cost is set by
// whoever last sent that address a coin. The sink is keyless and published, so
// that is anybody: a stranger can make this read arbitrarily expensive by
// sending it junk denoms. kourtv2 carries the GetCoins form because that is what
// gnoland-1 runs and a package deploys exactly once (its note says "carry it
// into a v2" — this is that). GetCoin reads the one denom asked for and cannot
// be inflated from outside.
func BurnedGNOT() int64 {
	b := banker.NewReadonlyBanker()
	return b.GetCoin(chain.PackageAddress(burnSinkPath), gnotDenom)
}

// CoinBalanceOf is who's court-coin balance (a value read).
func CoinBalanceOf(slug string, who address) int64 { return mustCourt(slug).coin.BalanceOf(who) }
