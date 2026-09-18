package kourtv3

// THE OTHER DIRECTION. Buy takes GNOT and mints coin; Redeem takes coin and pays
// GNOT back — the court's pro-rata share of what it HOLDS, never the price.
//
// WHY A HELD SHARE AND A BURNED SHARE, rather than one or the other. Holding
// everything would make the meta franchise free: it is denominated in GNOT
// destroyed (meta.gno), and a court where you are the only holder redeems your
// whole reserve back, so a franchise credited on held GNOT is minted for nothing,
// lap after lap. Burning everything is V2, and the owner ruled it out: a holder
// should be able to get GNOT back, less a share. So each payment splits — the
// burn share to the keyless sink, where it stays and is what rank and franchise
// count; the rest here, where the only instruction that can move it is the one
// below, and it pays every coin the same.
//
// WHAT A COIN RETURNS. payout = floor(reserve × amount / TotalSupply), in 128
// bits. Three facts about that number, each proved in TWOWAY.md and each held by
// a test here:
//
//   - it is at most the marginal price under any interleaving of buys,
//     redemptions and emission — so a buy followed at once by a redeem never
//     profits (the curve prices the next coin off total-ever-minted and never
//     walks back; the reserve holds the AVERAGE of past payments, less the burn
//     share, diluted by every coin emission minted against nothing). The one
//     operation that does NOT preserve it is a coin burn — a forfeited bond or
//     deposit shrinks TotalSupply with the reserve fixed, so the per-coin
//     return rises — and enough burns since the last offering can lift it past
//     the price. Bounded, not closed: TWOWAY.md §6 A7 prices it (the burned
//     fraction of supply must pass ~0.55 at k = 0), and every sentence a page
//     prints about the bound carries that condition;
//   - it never lowers what the remaining holders are owed per coin: floor
//     rounding leaves the dust in the reserve, so a redemption is neutral to
//     everyone else and only emission moves the per-coin figure, downward, by
//     exactly N/(N+m);
//   - it can never overdraw: amount ≤ TotalSupply gives payout ≤ reserve.
//
// WHAT IT DOES NOT TOUCH. c.minted (the curve position), burnedGNOT and the
// directory rank, the burn series, and the redeemer's franchise are all
// untouched: they count GNOT destroyed, and nothing is destroyed here.
//
// THE GATE IS mustSpendable, and that line is the whole reason a two-way coin
// does not reopen the rented vote RENTEDWEIGHT.md measured at 599x: coin
// committed to an open vote or backing a live stake cannot leave the balance
// through TransferCC, and it cannot leave through here either. Every user-
// sourced outflow in this realm carries that gate on the line above it, and
// check-epoch-coherence counts them.

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/kourt/grc20votes/v0"
)

const (
	// The burn share at launch, in basis points of each payment: a tenth burns,
	// nine tenths are held. The owner's number; see TWOWAY.md for what it
	// trades against what.
	burnBpsInit = int64(1000)
	// The bounds the DAO admin may move it within. Below 5% the meta court's
	// security base — GNOT actually destroyed — shrinks toward the one-time
	// constant MODERATION.md §13.8 was written to escape; above 50% "you get
	// less back" becomes "you get less than a quarter", and at 100% the coin is
	// one-way again by parameter, which is the owner's decision reversed by a
	// setter. A one-way court is founded as one (StartOneWayCourt), not dialled.
	minBurnBps = int64(500)
	maxBurnBps = int64(5000)

	bpsDenom = grc20votes.Bps // 10,000
	coinUnit = int64(1_000_000) // one whole coin, in base units (coinDecimals = 6)

	boughtEvent   = "Bought"
	redeemedEvent = "Redeemed"
)

// burnBps is the live burn share. Realm-wide, not per court: a per-court share
// lets a shell court pick its own and distorts the burn-ranked directory, and
// ECONOMICS.md's manipulation check — every lever is self-costly — holds for a
// realm-wide one and fails for a per-court one. Applies to payments made after
// it changes; nothing is re-split.
var burnBps = burnBpsInit

// totalReserve is Σ reserve over every court, kept as a counter so the admin
// page and the bank reconciliation can read it without walking the directory —
// an exported read may not allocate (check-read-purity) and a bank read cannot
// be per-court. bank(realm) ≥ totalReserve always; == on a clean path.
var totalReserve int64

// BurnBps is the live burn share, in basis points.
func BurnBps() int64 { return burnBps }

// SetBurnBps moves the burn share, for payments from now on.
//
// Gated on the global DAO admin, matching SetCourtCreationBurn: the same kind
// of knob, pricing a stranger's entry realm-wide. Emitted as a global act with
// court "*" because it moves the floor under every court at once and there is
// no single court to log it against (posting.gno's SetLadderDefault precedent).
func SetBurnBps(cur realm, bps int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv3: only the global DAO admin sets the burn share")
	}
	mustSaneBurnBps(bps)
	old := burnBps
	burnBps = bps
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-burn-bps:"+strconv.FormatInt(old, 10)+"->"+strconv.FormatInt(bps, 10),
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}

// mustSaneBurnBps refuses a share outside the bounds. Its own function, as
// mustSanePrice is, so the harness can reach the value check without a caller.
func mustSaneBurnBps(bps int64) {
	if bps < minBurnBps || bps > maxBurnBps {
		panic("kourtv3: the burn share must be between " + strconv.FormatInt(minBurnBps, 10) +
			" and " + strconv.FormatInt(maxBurnBps, 10) + " bps")
	}
}

// splitPayment divides the exact curve cost into the share that BURNS and the
// share that is HELD. A one-way court burns all of it.
//
// ROUNDING UP ON THE BURN, so the sink takes the odd µGNOT. Then burned ≥ 1 for
// every real buy (spent ≥ 1 because delta > 0), which means the sink send in
// Buy always runs and its textual count is its runtime count, no buy accrues
// zero franchise, and reserved ≤ (1−φ)·spent holds exactly — the direction that
// keeps "a buy then a redeem never profits" a fortiori. burned + reserved ==
// spent is an integer identity either way. Computed as spent minus the floored
// held share so the one 128-bit helper serves, with no ceiling variant to test.
func splitPayment(c *Court, spent int64) (burned, reserved int64) {
	if c.oneWay {
		return spent, 0
	}
	reserved = mulDiv128(spent, bpsDenom-burnBps, bpsDenom)
	return spent - reserved, reserved
}

// redeemQuote is THE pro-rata expression, and the only place this file reads
// TotalSupply:
//
//	payout = floor(reserve × amount / supply)
//
// in 128 bits — reserve × amount reaches ~1e33 at real magnitudes, so the naive
// product wraps (curve.gno's Cost has the same discipline). Zero when the court
// is one-way, holds no reserve, has no supply, or the amount exceeds supply; the
// last arm is what keeps mulDiv128 inside its hi < den precondition for a READ,
// which has no mustSpendable in front of it. For amount ≤ supply the
// precondition holds by arithmetic: reserve < 2^63 and amount ≤ supply give
// hi < supply / 2.
//
// The denominator is the LIVE ledger total: it includes coin sitting in the
// court's escrow as bonds and deposits and coin held by a wrapper's vault, and
// excludes emission that is owed but not yet minted (SeniorOwed and the junior
// reservations, only one of which has a counter). Documented, not adjusted: the
// bias favours a redeemer who exits before a pending pull is minted by at most
// about 1.5% plus SeniorOwed/supply of their own payout, and the owed party
// controls the pull.
func redeemQuote(c *Court, amount int64) (payout, supply int64) {
	supply = c.coin.TotalSupply()
	if c.oneWay || amount <= 0 || c.reserve <= 0 || supply <= 0 || amount > supply {
		return 0, supply
	}
	return mulDiv128(c.reserve, amount, supply), supply
}

// mustReturnAMicroGNOT refuses a redeem that would burn coin for nothing. ONE
// LINE at the call site, because check-epoch-coherence wants mustSpendable
// within the three lines above the Burn and a formatted if-block is three
// lines by itself. Names the smallest amount that returns 1 µGNOT, the way every
// refusal here leads with need-and-have.
func mustReturnAMicroGNOT(c *Court, payout, supply int64) {
	if payout > 0 {
		return
	}
	least := supply / c.reserve
	if supply%c.reserve != 0 {
		least++
	}
	panic("kourtv3: too small to return a µGNOT — redeem at least " + ccAmt(least) + " CC")
}

// Redeem burns `amount` of the caller's uncommitted coin in a court and pays the
// court's reserve pro-rata: floor(reserve × amount / supply) µGNOT, from this
// realm's own address. Returns the µGNOT paid.
//
// Realm-callable: there is no inbound payment to protect, so IsUserCall has
// nothing to do here. It TAKES no GNOT — coins attached to the call would land
// at the realm address uncredited and be lost to the sender — so an attached
// send is refused rather than silently kept.
//
// THE GUARD IS TRANSACTION-WIDE, and that is wider than the sentence above.
// unsafe.OriginSend is the MsgCall's envelope, set once per message and shared
// by every realm in the call chain; the keeper deposits it at the ENTRY realm.
// So a realm that took a payment through its own entrypoint and then calls
// Redeem in the same transaction is refused here although kourtv3 received
// nothing — TransferCC, which this used to be described as "like", makes no
// such check. Accepted, deliberately: the refusal costs an over-strict caller
// one transaction and loses nobody a µGNOT, no realm in this repo calls Redeem,
// and gating on IsUserCall instead would let a user's direct paid call through
// only by weakening the one line that keeps GNOT out of a path that has no way
// to credit it. A wrapper that wants to take a fee and redeem does it in two
// transactions.
//
// Refusals, in order: stale frame; a non-positive amount; attached GNOT; no such
// court; a one-way court; the court's own escrow as caller (it holds bonds and
// deposits, and paying the realm from the realm would turn a bond into GNOT —
// the refusal TransferCC makes); a court holding no reserve; committed coin
// (mustSpendable's four); an amount too small to return a µGNOT.
func Redeem(cur realm, courtSlug string, amount int64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount <= 0 {
		panic("kourtv3: redeem amount must be positive")
	}
	if unsafe.OriginSend().AmountOf(gnotDenom) > 0 {
		panic("kourtv3: Redeem takes no GNOT")
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if c.oneWay {
		panic("kourtv3: this court's coin is one-way; nothing returns GNOT")
	}
	if who == c.escrow {
		panic("kourtv3: the court escrow cannot redeem")
	}
	touch(c) // the period boundary reads S_live BEFORE this burn, as Buy's does before its mint
	if c.reserve <= 0 {
		panic("kourtv3: this court holds no reserve")
	}
	// GATE FIRST, then price, then the one-line dust refusal, then the burn: the
	// gate guarantees amount ≤ BalanceOf ≤ TotalSupply so the 128-bit divide is
	// in domain, and it sits exactly three lines above the Burn for the
	// adjacency check every user-sourced outflow carries.
	mustSpendable(c, who, amount)
	payout, supply := redeemQuote(c, amount)
	mustReturnAMicroGNOT(c, payout, supply)
	c.coin.Burn(who, amount)
	if payout > c.reserve {
		panic("kourtv3: reserve accounting") // unreachable: floor(R·a/N) ≤ R for a ≤ N
	}
	c.reserve -= payout
	totalReserve -= payout
	c.redeemedGNOT = mustAdd(c.redeemedGNOT, payout)
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), who, chain.Coins{chain.NewCoin(gnotDenom, payout)})
	chain.Emit(redeemedEvent,
		"court", c.id,
		"who", who.String(),
		"amount", strconv.FormatInt(amount, 10),
		"ugnot", strconv.FormatInt(payout, 10),
	)
	return payout
}

// -------------------------------------------------------------------- reads --
// Every read here returns a value and allocates nothing (check-read-purity).

// ReserveGNOT is the µGNOT a court holds for its coin. 0 for a one-way court.
// The ledgered counter, never a bank read.
func ReserveGNOT(courtSlug string) int64 { return mustCourt(courtSlug).reserve }

// TotalReserveGNOT is the µGNOT this realm holds for coin across every court.
// The realm's bank balance is at least this; equal on a clean path.
func TotalReserveGNOT() int64 { return totalReserve }

// RedeemedGNOT is the µGNOT a court has ever paid back out.
func RedeemedGNOT(courtSlug string) int64 { return mustCourt(courtSlug).redeemedGNOT }

// RedeemValue is what Redeem would pay right now for `amount` coin: the floor
// pro-rata share, 0 for a one-way court or an amount that cannot be redeemed.
// The per-coin figure is RedeemValue(slug, 1_000_000). It is NOT CoinPrice/2:
// it already carries emission dilution and escrowed coin, and it falls as
// emission mints.
func RedeemValue(courtSlug string, amount int64) int64 {
	p, _ := redeemQuote(mustCourt(courtSlug), amount)
	return p
}
