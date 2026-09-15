package kourtv1

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// gnotDenom is the chain coin the curve takes in.
const gnotDenom = "ugnot"

// Buy is the one-way bonding curve: send GNOT, receive court coin (CC), and the
// GNOT STAYS as the court's treasury — there is no sell-back, which is the whole
// point (§2). Returns the CC minted; the unspent remainder of the payment is
// refunded.
//
// The curve is the ONLY thing that mints CC. Its position (`minted`) is monotonic:
// it never moves back on a burn or a redeem, so the same stretch of the curve can
// never be bought twice.
func Buy(cur realm, slug string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	// Payment auth (AUDIT.md): the caller must be a DIRECT user call — NOT a
	// maketx-run ephemeral realm, which IsUser() would accept and which could
	// pre-consume the coin envelope before this check. IsUserCall is the guard the
	// audit obligation names and the pmkt reference realm uses.
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("court: a buy must be a direct user call")
	}
	buyer := prev.Address()

	c := mustCourt(slug)
	if buyer == cur.Address() {
		// Otherwise treasury GNOT could cycle out and back while new coin is issued
		// against no new backing (§2.1).
		panic("court: the court's own address may not buy")
	}

	// OriginSend lives ONLY in chain/runtime/unsafe (there is no banker.OriginSend);
	// reading it is the sanctioned way to see the inbound payment. What AGENTS.md
	// flags is unsafe.PreviousRealm (which skips frame verification) — NOT this. The
	// IsUserCall + IsCurrent guards above are exactly the frame check that makes
	// reading the origin send here safe.
	sent := unsafe.OriginSend().AmountOf(gnotDenom)
	if sent <= 0 {
		panic("court: send GNOT to buy the coin")
	}

	delta, spent := c.crv.Minted(c.minted, sent)
	if delta <= 0 {
		// Even one base unit costs more than was sent. Panicking aborts the tx,
		// which reverts the incoming send — the buyer keeps their GNOT.
		panic("court: payment too small to mint a coin")
	}
	c.minted += delta   // MONOTONIC curve position
	c.treasury += spent // GNOT backing, kept (unspendable in V1)
	c.coin.Mint(buyer, delta)

	if r := sent - spent; r > 0 {
		refundGNOT(cur, buyer, r)
	}
	return delta
}

// refundGNOT sends GNOT from the realm's own account back to `to`.
//
// THE GUARD IS NOT REDUNDANT WITH Buy's, and that is the whole reason it is
// here. This function is unexported, so it is NOT a crossing entrypoint and the
// runtime makes no promise that its `cur` is current — by the time a realm value
// arrives as an ordinary argument it is a SECONDARY realm parameter, and a stale
// one names a different realm. Both of its uses below are capability uses rather
// than reads: `cur` mints the banker, and `cur.Address()` is the account the
// coins leave from.
//
// Its only caller today is Buy, which checks IsCurrent at its own top, so
// nothing reaches this with a stale value. That is a fact about the call graph,
// not about this function — a second caller is all it takes, and the check costs
// one comparison on a path that is already sending coins. kourtv2 reached the
// same conclusion independently: takeCourtCreationBurn opens with exactly this
// guard and says so in the same words.
func refundGNOT(cur realm, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin(gnotDenom, amount)})
}

// -------------------------------------------------------------------- reads --

// CoinPrice is the marginal price (GNOT per whole CC unit) at the court's current
// position; CoinBacking is the reserve behind one coin, exactly half of it — every
// buyer pays about twice the backing of the coin they buy (§2.3). CurvePosition is
// the monotonic total ever minted.
func CoinPrice(slug string) int64     { c := mustCourt(slug); return c.crv.Price(c.minted) }
func CoinBacking(slug string) int64   { c := mustCourt(slug); return c.crv.Backing(c.minted) }
func CurvePosition(slug string) int64 { return mustCourt(slug).minted }

// CoinBalanceOf is who's court-coin balance. A value read — the ledger never
// leaves the realm.
func CoinBalanceOf(slug string, who address) int64 { return mustCourt(slug).coin.BalanceOf(who) }
