# TWOWAY.md — the two-way court coin (kourtv3)

> The owner's decision, 2026-09-17: *"make the bonding curve two way. yes, we
> have inflation, but you should be able to withdraw to gnot even with inflation
> accounted for. you just get less."* And, asked whether a court should be able to
> choose: yes — one-way or two-way, fixed at creation. This file records what
> that became, with the numbers, the proofs, the attacks, the guards, and the
> cut-over. Where this file and the code disagree, the code governs; every
> mechanism named here is in `r/kourtv3` and every claim is held by a test named
> here. Cited by file and function, never by line, so check-citations can police
> this document without it rotting.

## 1. What changed, in one screen

Under V2 (`r/kourtv2`, live on gnoland-1) every payment for a court's coin was
burned to a keyless address. Nothing ever came back. That was the design's
capture-resistance and its regulatory posture in one stroke — and it was also
the single hardest thing to ask of a newcomer.

Under V3 (`r/kourtv3`) the payment **splits**:

| share | where it goes | who counts it |
|---|---|---|
| **burn share** — `BurnBps`, a tenth at launch | the keyless sink, exactly as V2 burned the whole payment | the directory rank (`CourtBurnedGNOT`) and the meta franchise (`FranchiseOf`) |
| **held share** — the rest | this realm's own account, ledgered per court as `reserve` | `ReserveGNOT`; the only things that move it are `Buy`'s credit and `Redeem`'s debit |

A holder may **return coin** through `Redeem(court, amount)` and is paid the
court's pro-rata share of what it holds:

```
payout = floor( reserve × amount / TotalSupply )      (128-bit)
```

That figure is below the curve's price for the next coin — unless coin has been
destroyed by bonds since the last offering, which raises every remaining coin's
share (§4 proof (c), §6 A7) — is about half of it right after an offering, and
falls as emission mints coin against nothing. "You just get less" is that
arithmetic, and §4 states exactly how much.

A buyer states a **floor**: `Buy(court, minUnits)` refuses, before any state
moves, an offering that would mint fewer units than `minUnits` at the position
the transaction actually lands on (0 is no floor). That is the buyer's only
defence against being ordered behind another buy (§6 A15), and the page passes
the units it quoted less a 0.5 % tolerance, or 0 when it has no quote
(cryptocourt's `twoway-overlay` branch; §11).

A court may instead be founded **one-way** (`StartOneWayCourt`): every payment
burns in full and `Redeem` refuses it forever. The meta court is founded one-way
at realm init, and that is what keeps its franchise sound (§5). The choice is
fixed at creation — there is no setter — because a court that could flip later
would turn every holder's returnable share into a burn under them.

Nothing else moved. The curve position (`c.minted`) is still monotone and still
prices the next coin off total-ever-minted. Stakes are still locked in place;
votes still lock coin until the round resolves; emission is still the bounded,
stepping-down schedule; forfeitures still burn coin and compensation still mints
it. `Redeem` goes through `mustSpendable` like every other outflow, so committed
coin cannot be cashed out any more than it could be transferred.

## 2. Why a third generation, and what happened to the second

The repo's `r/kourtv2` **mirrors what runs on gnoland-1**. Its own `buy.gno`
says so beside the one line it would otherwise fix ("the repo mirrors what is
live rather than a fix that can never reach it"), and `check-getcoins.py`
enforces the mirror by requiring the deployed `GetCoins` read there verbatim. A
Gno package deploys exactly once. So the two-way curve could not be edited into
kourtv2 without making the repo lie about mainnet, and it lives in `r/kourtv3`
— copied byte for byte (`b2ec84a`), then moved under the development guards
while still one-way (`02fb6a3`), then changed. Every red in the two-way commit
is attributable to the two-way change and nothing else, which is the reason for
three commits rather than one.

kourtv2 is **behaviourally frozen** from here, the way kourtv1 was: its tests
may be fixed, its behaviour may not. It keeps `gno test .` in the Makefile loop,
its filetests and storage row, and its eight on-node txtars, because those are
the mirror's only proof.

### The three mainnet courts

`gno.land/r/g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6/kourt` (`package kourt`,
added at height 9676) is never patched. **atomone, covid and meta stay there,
one-way, forever.** Every ugnot they took — 481,130,000 ugnot, 481.13 GNOT — sits
at `g10rgavxmnk59vn5c82wpcehexqttxpkfdz9dqrt`, an address with no key and
sequence 0. It is gone, and recoverable by nobody, including us. Their supplies
today: atomone 141,421,356 µCC, covid 691,563,441 µCC, meta 856,737,994 µCC;
`EmittedTotal` is 0 in all three. Unclaimed franchise on that realm stays
claimable there and represents nothing in V3.

**Abandon in place.** No on-chain migration exists and none is built: `Court`
has no version field, the realm has exactly three mint sites (a fourth would
break check-epoch-coherence's ARM 13), and a holder snapshot cannot reproduce
staked positions. Re-creating the three courts by slug with an airdrop was
considered and rejected: it mints coin against a reserve of zero, diluting
every real V3 buyer by exactly the airdropped share, which is the one outcome
a two-way coin exists to avoid. V3 courts start empty. What CAN carry is a
position: a deployer may found a `covid` court on V3 one-way and mint each
holder their exact balance (15 holders, all readable), promising no reserve
that does not exist — an owner option, not part of this change.

## 3. The mechanism, precisely

### Buy (`buy.gno`)

```
func Buy(cur realm, slug string, minUnits int64) int64   // units minted
```

The curve prices `delta` units for the exact cost `spent` off the position at
the moment the call lands. Then, **before any write of the buy** (the only
state a refused `Buy` has touched is `touch(c)`'s time accrual, which every
call into the court performs and which the aborted transaction reverts with
everything else):

```
if delta < minUnits { panic("… fewer units than your floor — delta < minUnits") }
```

`minUnits` is the fewest base units the buyer will accept for the GNOT
attached; 0 (or anything negative, which is vacuous — `delta` is positive by
the guard above it) is no floor. A refusal here leaves the position, the
ledger, the reserve and the sink untouched, and the aborted transaction returns
the envelope. `TestBuyMinUnitsRefusesAndRefunds` holds the three arms; the
ordering — floor before mint — is pinned by the same test, because the gno test
harness does not roll state back on an abort, so a floor checked after the mint
would leave minted coin behind the refusal. Then:

```
burned, reserved := splitPayment(c, spent)      // one-way court: spent, 0
c.reserve    = mustAdd(c.reserve, reserved)      // money path: fail loud
totalReserve = mustAdd(totalReserve, reserved)
c.paidIn     = mustAdd(c.paidIn, spent)
reindexBurn(c, burned)                           // rank keys on the burn share
accrueFranchise(c, buyer, burned)                // franchise keys on the burn share
SendCoins(realm → sink, burned)                  // the held share has NO send
SendCoins(realm → buyer, sent − spent)           // dust change, unchanged
Emit Bought{court, who, minted, spent, burned, reserved}
```

`splitPayment` rounds the burn share **up**: `reserved = floor(spent × (10000 −
BurnBps) / 10000)`, `burned = spent − reserved`. So `burned ≥ 1` for every real
buy, the sink send always runs (its textual count is its runtime count), no buy
accrues zero franchise, and `reserved ≤ (1−φ)·spent` holds exactly. Cost still
rounds up in the curve; the payout rounds down; every rounding pushes the
reserve up relative to exact arithmetic.

### Redeem (`redeem.gno`)

```
func Redeem(cur realm, courtSlug string, amount int64) int64   // µGNOT paid
```

In order: stale frame · `amount ≤ 0` · attached GNOT (refused: it would land at
the realm address uncredited; the check reads the transaction's envelope, so it
is transaction-wide — see below) · no such court · a one-way court · the court's
own escrow as caller (it holds bonds and deposits; paying the realm from the
realm would turn a bond into GNOT — `TransferCC`'s refusal) · `touch(c)` · a
court holding no reserve · **`mustSpendable(c, who, amount)`** · quote ·
`mustReturnAMicroGNOT` (a redeem that would pay 0 is refused, naming the
smallest amount that pays 1) · `c.coin.Burn(who, amount)` · debit `reserve` and
`totalReserve`, credit `redeemedGNOT` · one `SendCoins(realm → who, payout)` ·
`Emit Redeemed{court, who, amount, ugnot}`.

Realm-callable: there is no inbound payment to protect, so `IsUserCall` has
nothing to do here. The attached-GNOT refusal is nonetheless **transaction-
wide**: `unsafe.OriginSend` is the message's envelope, shared by every realm in
the call chain and deposited at the entry realm, so a realm that took a payment
through its own entrypoint and then calls `Redeem` in the same transaction is
refused although kourtv3 received nothing — `TransferCC`, which this used to be
described as "like", makes no such check. Accepted: the over-refusal costs a
caller one transaction and nobody a µGNOT, no realm in this repo calls
`Redeem`, and gating on `IsUserCall` instead would weaken the one line that
keeps GNOT out of a path with no way to credit it. Wrapped coin (ccwrap)
redeems by `Unwrap` then `Redeem` as the holder; no passthrough.

**Not touched:** `c.minted`, `CourtBurnedGNOT`, `BurnSeries`, the directory
index, `FranchiseOf`. They count GNOT destroyed, and nothing is destroyed.

### The denominator

`TotalSupply()` — the live ledger total, read once in `redeemQuote`. It
**includes** coin in the court's escrow (bonds, deposits) and in a wrapper's
vault, and **excludes** emission that is owed but not yet minted (`SeniorOwed`
and the junior reservations, only one of which has a counter) and unclaimed
franchise. Documented, not adjusted: a redeemer who exits before a pending pull
is minted takes about `reservoir/N + SeniorOwed/N + unpulled junior draws/N`
more per coin than one who waits. The first term is capped (`rMax`, four
periods at 38 bps, ~1.5%); the second has a counter; the third — draws already
awarded to settled claims and not yet pulled — has neither counter nor cap:
`juniorReserved` only rises, the coin is minted only on pull with no expiry,
and each settled claim can add up to a period budget (~38 bps) to the unminted
mass, so ten unpulled claims are ~3.8% on their own. No "at most" is claimed,
and the owed party controls the pull. Escrowed and wrapped coin dilute redeemers; their share
strands to the remaining holders as bonds burn or return.

### The knob

`BurnBps()` is realm-wide, DAO-admin-settable through `SetBurnBps` within
`[500, 5000]` basis points (`mustSaneBurnBps`), applies to payments after the
change, and is emitted as a global act (`set-burn-bps:<old>-><new>`). Not per
court: a per-court share lets a shell court pick its own and distorts the
burn-ranked directory. Not a constant: a package deploys once and this is the
least-examined number in the design. Not 0 (franchise and rank would key on
nothing) and not 10000 (the owner's decision reversed by parameter; a one-way
court is founded as one, not dialled).

### Reads

`ReserveGNOT(slug)`, `TotalReserveGNOT()` (a maintained counter, never a bank
read and never a tree walk — one realm address holds every court's GNOT and an
exported read may not allocate), `RedeemValue(slug, amount)` (0 for a one-way
court or an unredeemable amount; per coin = `RedeemValue(slug, 1_000_000)`),
`RedeemedGNOT(slug)`, `BurnBps()`, `CourtOneWay(slug)`. Kept with their meaning
made exact: `CourtBurnedGNOT` (Σ burn shares into this court), `BurnSeries`,
`BurnSink()`, `BurnedGNOT()` (the `GetCoin` form). No `Backing` read:
`curve.Backing(s) = s/2D` overstates what a coin returns the moment emission
mints or anyone redeems, and it is called nowhere.

### Invariants, each a test

| | invariant | held by |
|---|---|---|
| I1 | per Buy: `burned + reserved == spent`; burn share rounds up; one-way: `burned == spent` | `TestBuySplitsThePaymentIntoBurnAndReserve`, `TestAOneWayCourtBurnsEverythingAndHoldsNothing` |
| I2 | per court: `CourtBurnedGNOT + ReserveGNOT + RedeemedGNOT == paidIn` | `TestReservesReconcileWithTheBank` |
| I3 | bank(realm) ≥ `TotalReserveGNOT()` == Σ `ReserveGNOT`; == on a clean path; bank(sink) ≥ Σ burn shares + creation burns (== absent donations — the sink is a published address anyone may send to, so `BurnedGNOT()` is the sink's held balance, not a ledgered total) | `TestReservesReconcileWithTheBank`, `kourtv3_money.txtar` |
| I4 | `0 < payout ≤ reserve`; `reserve ≥ 0` after every operation | `TestRedeemPaysTheFloorProRataAndBurns`, `TestRedeemRefusesWhatItMust` |
| I5 | a redemption never lowers what remaining holders are owed per coin | `TestRedeemPaysTheFloorProRataAndBurns` (128-bit compare) |
| I6 | a buy then a redeem never returns more than it cost | `TestBuyThenRedeemNeverProfits` |
| I7 | Redeem leaves `c.minted`, rank, series, franchise unchanged | `TestRedeemPaysTheFloorProRataAndBurns` |
| I8 | staked and vote-locked coin cannot be redeemed | `TestCommittedCoinCannotBeRedeemed`, `TestVotedCoinCannotBeRedeemedUntilTheRoundResolves` |
| I9 | a shell-court lap accrues exactly what it burned | `TestAShellCourtLapAccruesOnlyWhatItBurns` |
| I10 | the reserve is never derived from a bank balance; only Buy credits it and only Redeem debits it | check-nontransferable (`RESERVE_WRITE`, `PRO_RATA_ONLY`) |

## 4. The arithmetic

Symbols: `S` curve position (coins ever minted on the curve), `D` the curve's
reciprocal slope, `P = S/D` the marginal price, `E` coins minted by emission,
`N = S + E` the supply, `k = E/S` (≤ 0.78 over a court's lifetime), `φ` the burn
share, `R = (1−φ)·S²/2D` the reserve with no redemptions.

**Per-coin return.** `R/N = (1−φ)·P / (2(1+k))`. At φ = 0.10:

| k = E/S | return ÷ average price paid | return ÷ marginal price |
|---|---|---|
| 0 | 0.90 | 0.45 |
| 0.2 | 0.75 | 0.375 |
| 0.5 | 0.60 | 0.30 |
| 0.78 | 0.506 | 0.253 |

**A buyer at position fraction x** who paid the marginal price there recovers
`(1−φ) / (2x(1+k))` of their outlay by returning at once when the court has
filled to S. Break-even is `x* = (1−φ)/(2(1+k))` — 0.45 at k = 0, 0.253 at
k = 0.78. Below it a holder exits at a profit funded by later buyers; a
*marginal* buyer at x = 0.1 recovers 4.5× (k = 0) or 2.5× (k = 0.78), and the
actor who bought the whole first 10% does better still (A2: 9× / 5.1×, with the
arithmetic in the row). **Accepted and disclosed**,
not closed by mechanism: it is the shape of a bonding curve with a pro-rata
exit, it is neutral to every other holder (I5), and the alternative — a per-
position cost basis — narrows "a holder can redeem" to "a curve buyer can
redeem", strands emission-earned and transferred coin, and adds two counters per
holder. The whitepaper must say it; counsel must see it (§8).

**A buyer who dwarfs the court.** The grid above is the small buyer's. For Δ
coin bought into position S with emission kS, the exact recovery of an
immediate return is

```
(1−φ)·(S+Δ)² / ((2S+Δ)·(S(1+k)+Δ))      → 1−φ as Δ → ∞
```

60% at Δ = S, 82.5% at Δ = 10S, 89% at Δ = 100S (φ = 0.10, k = 0). The
"54–75%" loss is therefore the small buyer's figure; a buyer large against the
court loses toward φ. Worked: 500 GNOT into a court holding 50 GNOT takes the
supply from 316,227,766 to 1,048,808,848 (×3.32), recovers 69.2% and loses
≈154 GNOT (31%); taking a court's supply ×11 needs about 6,000 GNOT and loses
≈1,050 GNOT (17.5%). That regime is what A16 prices.

**Proofs** (also checked, while this was written, in a scratch simulation of
400,000 random operations; the script is not committed):

- *(c) return ≤ marginal price, on every path but a coin burn.* Invariant
  `R ≤ N·s/D` holds at zero, is preserved by emission (N rises), by redemption
  up to floor dust (`R'/N' = R/N + δ/(N−a)`, `0 ≤ δ < 1` — a µGNOT-scale
  exception, worthless per A13), and by a buy of Δ at cost C ≥ Δ·s/D (the new
  bound exceeds the new R by `(NΔ + Δ²/2)/D ≥ 0`). Hence
  `floor(Δ(R+C)/(N+Δ)) ≤ C`: a round trip never profits. It is **not**
  preserved by a coin burn: every `Burn` of escrowed coin — dispute fees,
  forfeits and passes in `dispute.gno`, a deposit burn in `claim.gno`, the
  association and election bonds, the comment pass in `posting.gno` — shrinks
  N with R fixed, so R/N rises by N/(N−X). The bound survives while the
  cumulative burned fraction of supply since the last buy stays below
  `1 − (1−φ)/(2(1+k))` — 0.550 at k = 0, 0.625 at k = 0.2, 0.747 at k = 0.78
  (A7). Worked: a 300 GNOT buy gives S = N = 774,596,669, R = 270,000,000,
  R/N = 0.45P; burn 60% of N and R/N = 0.871 µGNOT per unit against P = 0.775
  — 1.125P — after which a 1 GNOT buy
  mints 1,289,920 units that redeem for 1,123,134 µGNOT. Degenerate end: the
  last coin burned by a fee leaves N = 0 with R > 0; `redeemQuote` answers 0
  while supply is 0 and the next buyer inherits the stranded reserve (accepted,
  §9). Every sentence a page prints about the bound carries the burn condition
  (`writeCourtCoin`, the help page, `CoinPrice`'s comment), and
  `TestReservesReconcileWithTheBank` asserts `RedeemValue(slug, coinUnit) ≤
  Cost(minted, coinUnit)` after every burn-free step, and
  `TestABurnLiftsTheReturnPastTheNextCoinsPrice` walks the exception itself:
  half the supply burned from escrow the way a forfeit burns it, the bound
  still standing; 60% burned, a coin returning more than the next one costs;
  then the 1 GNOT buy above minting exactly 1,289,920 units and redeeming for
  exactly 1,123,134 µGNOT, with conservation intact. The stronger "≤ half the
  marginal price" holds only while `N ≥ s` and can fail after heavy
  redemption; the marginal bound is the one that prevents arbitrage.
- *(d) solvency.* `payout = floor(a·R/N) ≤ R` because `a ≤ N` (mustSpendable
  gives `a ≤ BalanceOf ≤ TotalSupply`), so `R ≥ 0` after every step under any
  interleaving, and `Σ payouts = Σ reserved − R_final ≤ Σ reserved`.
- *(e) neutrality.* After a redemption `R'/N' = R/N + δ/(N−a)`, `0 ≤ δ < 1`:
  unchanged up to dust, never down. After emission of m: `× N/(N+m)`. After a
  buy: up, since `C/Δ ≥ R/N` by (c).

**Rounding table:** cost rounds up (curve); mint rounds down (curve); burn share
rounds up (`splitPayment`); payout rounds down (`redeemQuote`, 128-bit, refuse
0). Every rounding leaves dust in the reserve; excess over exact is under
`1/N` µGNOT per coin per operation.

**Emission** now dilutes a GNOT-denominated claim. ECONOMICS.md's `ρ = r + d` is
the carry on that claim; its manipulation check "burning your CC raises the rate
at your sole cost" no longer holds for a redemption (the redeemer is paid), but
the rate rise for stayers is bounded by the 38 bps `d_eff` cap at 160 bps/wk.

## 5. Franchise, rank, and why the burn share exists

The meta franchise (`meta.gno`) is denominated in GNOT **destroyed**, per
µGNOT, court-independent — sound because nobody can fake having destroyed real
money. A held share is exactly what Redeem can pay back, so a franchise
credited on it is minted for free: on a court where the buyer is the only
holder, `Redeem(all)` returns the whole reserve. `StartCourt` is permissionless
and the creation burn defaults to 0, so the loop *found a court → Buy G → claim
franchise → Redeem → repeat* would mint unbounded META for a fixed float and
collapse WHITEPAPER §5's capture table to nothing. The same loop farms directory
rank.

Keying both on the **burn share only** closes it: a lap costs `φ·G` and earns
`φ·G` of franchise and rank, 1:1 with GNOT destroyed, identical per burned µGNOT
to a direct `Buy(meta)` (which burns in full). The capture table's multiples
(0.11× / 0.56× / 3× / 99× of everything burned into META's curve) stay true as
written; what changes is the absolute base: `B = φ × non-META curve volume`, so
a 5% pivot costs `0.108·φ·V`. That is the trade φ makes — court voice against
appeals voice — and the reason its default is the owner's number.

**META stays one-way** and is founded so at init: franchise-minted META has no
GNOT behind it, so a META reserve would hold only direct buyers' GNOT while
every claimant held a share of it.

## 6. Threats, and what stands against each

| # | attack | cost (φ = 10%) | status |
|---|---|---|---|
| A1 | OTC vote rental: buy near return value on gnoswap → unwrap → wait an epoch → vote → hold through resolution → Redeem | premium over the floor + (25 + ≤38 bps)·T; downside bounded at the return value | **accepted residual**, disclosed in RENTEDWEIGHT.md. Two-way makes the exit a protocol bid, so the vote lock prices *time*, not price risk. An exit fee does not price it (it is capitalised into the market floor and paid by every seller); a redemption delay is worth 25 bps/wk (TRADEANDLOCK.md). The curve route loses 54–75% of outlay for a buyer small against the court (a 5%-of-supply buyer 54–73%, a marginal buyer 55–75%); a buyer who dwarfs the court loses less — §4's general formula: 40% at Δ = S, 17.5% at Δ = 10S, tending to φ — and that door is priced in A16. |
| A2 | founder pump-and-exit: buy the first 10% of a curve, promote, return at 9× (k = 0) or 5.1× (k = 0.78) | 0.005 S·P | **accepted and disclosed** (§4); neutral to other holders (I5). The arithmetic: the span [0, 0.1S] costs (0.1S)²/2D = 0.005·S·P; those 0.1S coins redeem at R/N = (1−φ)P/(2(1+k)), i.e. 0.1S × 0.9P/(2(1+k)) = 0.045·S·P/(1+k) → 0.045/0.005 = **9.0×** at k = 0, 0.045/(1.78 × 0.005) = **5.06×** at k = 0.78. §4's 4.5×/2.5× is the *marginal* buyer at x = 0.1 — who paid the price at the 10% mark, not the whole span below it — and an earlier version of this row wrongly carried that figure. |
| A3 | φ shrinks META's base to `φ·V` | — | accepted; φ bounded in code `[500, 5000]` |
| A4 | test clock armed at deploy, then vote locks released and emission rolled with GNOT in reserve | 0 | **closed by the runbook**: `AddPackage` and the first `StartCourt` are consecutive transactions from the deployer key; arming needs a pristine realm and `SealTestClock` cannot run on a never-armed one; post-deploy asserts `TestClockFabricated() == false` |
| A5 | front-run owed emission by redeeming before a pull mints | — | about reservoir/N + SeniorOwed/N + unpulled junior draws/N of own payout: the first capped at ~1.5%, the second counted, the third — awarded, not yet pulled — neither capped nor counted (§3, the denominator); documented, not bounded |
| A6 | reserve drift: GNOT sent to the realm outside Buy, or attached to a non-Buy call | the sender's loss | Redeem refuses attached GNOT, and so do `StartCourt` / `StartCourtP` / `StartOneWayCourt` from a user call while the creation burn is off (`takeCourtCreationBurn`: "court creation is free right now; send no GNOT") — those are the only other entrypoints the protocol's own page arms with a send, and before this refusal a page rendered while creation was priced paid GNOT into the realm's balance, outside every reserve and the sink, uncounted for ever; with the burn on, the whole envelope burns by design. A plain bank send to the realm address is still the sender's loss; bank ≥ Σ reserve always, == on a clean path; no sweep entrypoint (a third door) |
| A7 | escrow-burn spike: a bond burn raises everyone's return, and enough of them lift it past the next coin's price | — | profitable only if the burned fraction of supply since the last offering exceeds `1 − (1−φ)/(2(1+k))` — 0.55 at k = 0, 0.75 at k = 0.78 (§4 (c)); a single bond is capped far below, and nothing caps the cumulative figure, so every page states the marginal bound with this condition rather than as "always"; funded by the forfeited coin's stranded share, never by holders' principal; a self-burn gains at most the redeem value of what was burned (`TestABurnLiftsTheReturnPastTheNextCoinsPrice`: half the supply burned and the bound stands, 60% and a coin returns more than the next one costs) |
| A9 | shell-court franchise/rank farm | φ·G per lap, earns φ·G | **closed** (§5), `TestAShellCourtLapAccruesOnlyWhatItBurns` |
| A10 | META drain via franchise mints or a META reserve | — | **closed**: META founded one-way; `ReserveGNOT("meta") == 0` pinned |
| A11 | mass redemption lowers %-of-supply bars under an open vote | — | bars are frozen at their question's epoch (`quorumFloor` at OpenDispute, `credWeightFloor` from the snapshot, `electionFloor` stored on the election); no change |
| A12 | escrow, vault or realm caller redeems what it should not | — | escrow refused by address; ccwrap has no Redeem passthrough; a realm caller gains nothing a user lacks |
| A13 | rounding dust | gas | ≤ 1 µGNOT per prior op stays in the reserve; zero payouts refused |
| A14 | redeem an unstaked pile before a period roll to raise the rate on the staked one | the entry spread | accepted nuisance; rate capped at 160 bps/wk |
| A15 | sandwich a pending Buy: land a Buy ahead of a large buy into a young court, Redeem right after it — the victim's own transaction is the "later buyer" that funds the §4 early-position windfall | ordering control: a block proposer, or an announced launch buy; probabilistic for a mempool watcher on a FIFO mempool, and without ordering the attacker's own lap loses ~47% | **closed for a buyer who states a floor**: `Buy(slug, minUnits)` refuses, before any write of the buy, when the units minted at the landing position fall below the floor, so the victim is refused rather than shorted and keeps their GNOT (`TestAnInterleavedBuyIsBoundedByTheFloor`, `TestBuyMinUnitsRefusesAndRefunds`). Profitable whenever the incoming buy is ≳ 3.9–4× the GNOT the court has already taken in — the launch-buy shape: 50 GNOT in, attacker 50 ahead of a victim's 500 → attacker +14.57 GNOT (+29%), victim 648,231,519 units for 732,581,082 quoted (−11.5%); attacker 25 / victim 1,000 → +88%; a brand-new court, 10 / 100 → +198%. A buyer who passes 0 is exposed exactly as before, and the page says so. A redemption hold on fresh curve coin would close it for everyone and was not taken (§9) |
| A16 | buy across one epoch seal to inflate the `PastTotal`-based bars (`electionFloor`, `quorumFloor`'s votable/3 arm, `credWeightFloor`) for every question opened against that epoch, then Redeem | the §4 large-buyer loss: ≈31% of outlay to triple a court's supply (500 GNOT into a 50 GNOT court, ≈154 GNOT), ≈17.5% to take it ×11 (≈6,000 GNOT, ≈1,050 lost) | **accepted residual**, disclosed here and as MODERATION.md's "mint and abstain raises the floor"; cheaper than V2's 100% for the same inflation, still a loss of tens to hundreds of GNOT for a bar that binds one epoch's questions, and A11's frozen bars mean the inflated figure cannot be lowered again under those questions either. The redemption hold considered under A15 would price it too; not taken |

## 7. The gate under two generations

| idiom | guards | under V3 |
|---|---|---|
| per-realm map | check-nontransferable (`REALMS`, `SENDCOINS_ALLOWED`, `SINK_ONLY`, `PRO_RATA_ONLY`, `RESERVE_WRITES_ALLOWED`), check-epoch-coherence's `(pkg, file)` tables, check-storage `TARGETS` | kourtv3 rows added; kourtv2's frozen |
| one `REALM` path | spend-paths, epoch-coherence, nodelegate, render-text, read-purity, abort-assertions, height-shim, membership-clears, scenario.py, mutate.py, the corpus | moved to kourtv3 |
| whole tree | everything else | nothing, except check-citations reads `r/kourtv3` and this file |

**check-nontransferable** now guards: GNOT leaves this realm to a user through
exactly two doors — Buy's dust change and Redeem's pro-rata payout; the payout
send must be `SendCoins(cur.Address(), who, …payout)` with `c.reserve -= payout`
exactly once above it; every other `SendCoins` names the sink at its pinned
count; every write to a court's `reserve` is Buy's credit or Redeem's debit
(census floored at two, so a blinded pattern cannot pass). Comments are stripped
before the scan.

**check-spend-paths** carries `("redeem.gno", "Redeem") →
TestCommittedCoinCannotBeRedeemed`. **check-epoch-coherence** counts nine
user-sourced coin outflows (was eight; re-derived by listing) and allows
redeem.gno one live `TotalSupply` read. **check-storage** re-measured kourtv3:
the four new `Court` scalars cost 155b across three courts; z_events moved from
a 0.8% ceiling to a 4% one with the reason written beside it.

**The corpus** (`mutations-kourtv3.json`) gained twenty rows for the split and
for Redeem, and six more with the audit — the floor comparison dropped, the
floor checked after the mint, the free-creation refusal dropped, the split
reading the launch constant instead of the live share, `SetBurnBps` losing its
bounds call (held by `kourtv3_money.txtar`), the dust hint losing its round-up
— — each dropped guard, each skipped write, each wrong denomination,
the position walking back, the one-way court redeeming, a zero payout burning
coin — and two KNOWN-GAPS rows that say why they cannot be caught (the escrow
as caller; `touch` before the burn). **kourtv3_money.txtar** moves real coin on
a real node: 50 GNOT → realm 45,000,000 / sink 5,000,000; 5 more → 49,500,000 /
5,500,000 / position 331,662,479; `Redeem 100,000,000` pays exactly
`RedeemValue`'s 14,924,811 — the redeemer's own balance rises by exactly that
less the gas fee — leaves 34,575,189 held, supply 231,662,479, the position and
the sink unchanged; a one-unit redeem is refused; a direct offering to meta
holds nothing and leaves the realm's balance where it was; the deployer moves
the burn share to 2000 and the next 5 GNOT splits 1 / 4, while 499 and 5001
are refused with the knob unmoved.

## 8. What goes to counsel, not asserted

REGULATIONS.md listed "non-redeemable in-protocol" and "no treasury
expectations (GNOT burned)" as Howey mitigants. Both are **withdrawn** by this
change, not argued around. What replaces them, for counsel to weigh rather than
for this file to conclude:

- the held share sits in immutable code with one exit — pro-rata `Redeem` —
  and no other instruction, admin or vote can move it;
- the payout reads reserve and supply only, never a verdict, so the exit is
  outcome-independent; but every bond forfeiture now raises every holder's
  pro-rata share, including the prevailing party's;
- the payout is below the curve price whenever no coin has been burned by
  bonds since the last offering, so an immediate round trip loses in that
  regime; cumulative forfeitures past ~55% of supply can lift the return past
  the price (A7), funded by the forfeited coin's stranded share rather than by
  any holder's principal; an early position recovers above cost only when
  later buyers arrive (the profit-expectation prong);
- the Munchee note stands: the burn share and the held share are never
  marketed as scarcity or value. Public copy says "less than half its price
  right after an offering, and less as emission mints"; the grids above are
  internal.

WHITEPAPER §7's "the coins are not investments" is kept with a re-opinion flag.

## 9. Owner decisions, as taken here

| decision | taken | alternative considered |
|---|---|---|
| burn share default | 1000 bps | 2000 (META's base ~9.8× the genesis constant instead of ~4.9× at 100k GNOT of volume; marginal recovery 40% not 45%) |
| exit fee | none | a bounded DAO knob at 0; rejected as a second lever nobody can price, taxing honest exits while the OTC renter pays it only above the floor |
| early-buyer windfall | accept and disclose | deposit-receipt cap (contradicts "a holder can redeem") |
| the ordered same-block variant (A15) | a **buyer-side floor**, `Buy(slug, minUnits)`: the buyer names the fewest units they will take and the realm refuses below it before any write; 0 is no floor | a per-position cost basis (strands emission-earned and transferred coin; two counters per holder), or an epoch-long **redemption hold on curve-minted coin** — considered: it would blunt A15 for a buyer who states no floor and price A16 as well, but it reprices every honest holder's exit to close an ordering attack the buyer can refuse for free. Not taken; the owner's call if A16 is ever exercised |
| stranded reserve (the last coin burned by a fee leaves supply 0 with reserve > 0) | accept: `redeemQuote` answers 0 while supply is 0 and the next buyer inherits it | a sweep from Buy to the sink (a third door on the reserve) |
| one-way by choice | `StartOneWayCourt`, fixed at creation | a setter (rejected: consent) |
| META | one-way at init | a reserve of direct buyers' GNOT drained by claimants |
| mainnet | abandon the three courts in place | airdrop against zero reserve |
| denominator | live `TotalSupply` | `+ SeniorOwed` (a half-fix: junior reservations have no counter) |
| test clock | ships unchanged; window closed by the first `StartCourt` | strip (forks tested from shipped source), seal at deploy (cannot run on an unarmed realm) |

## 10. Deploying it (kourtv3 to gnoland-1, key g1ecsuj0…)

1. Clean tree at a tag; cryptocourt's `realm` submodule at that tag;
   `REQUIRE_GNO=1 make check`, `make txtar-test`, `make selftest`, `make mutate`
   (all caught), `make isolation-test` green.
2. Rehearse on the devnet re-genesised with the V3 root: Buy 50 GNOT → realm
   45,000,000 / sink 5,000,000; Redeem and assert the redeemer's ugnot rises by
   exactly the `RedeemValue` quoted the block before; measure Redeem gas against
   a holder with twenty dead vote-lock rows.
3. `scripts/retarget.sh <ns> <key> kourtv3 --src kourtv3` on the clean tree.
   The script lives in **cryptocourt**, not here, and is being parametrised in
   parallel to take a SOURCE realm: run without `--src` it copies the one-way
   kourtv2 tree and stamps `package kourtv3` on it, and its path rewrite looks
   for `/r/kourt/kourtv2`, so kourtv3's ~37 self-path literals (`burnSinkPath`,
   `metaRealmPath`, every rendered link) would ship unrewritten. It refuses a
   dirty tree — the two testclock mutants live on mainnet because a dirty tree
   was retargeted once. **Before broadcasting anything**:
   `grep -r 'gno.land/r/kourt/' build/ && exit 1` must print nothing — an
   unrewritten literal is not a diff line, so "only path literals differ"
   cannot see it, and a missed `metaRealmPath` makes `CourtEscrow("meta")` an
   address nobody holds, caught only by step 7 after the irreversible addpkg.
   Then diff the build against `r/kourtv3` and expect exactly two kinds of
   line: the `package` line, and every `gno.land/r/kourt/kourtv3` rewritten to
   `gno.land/r/<ns>/kourtv3` (a `:burned` sink path included — the colon keeps
   it keyless under any namespace). A `Redeem` or `BurnBps` missing from the
   build means the source was kourtv2; stop. The five `p/` libraries are
   already on chain and are not redeployed (V3 changes none of them; a change
   would need a `/v1` path).
4. `gnokey maketx addpkg … -simulate only`; record gas and the storage deposit
   (V2's was 200 GNOT).
5. Broadcast the `addpkg`. The **next** transaction from the same key is
   `StartCourt` of the first real court — this closes the test clock's arming
   window for good. There is no seal step.
6. If a burn share other than 1000 is wanted: `SetBurnBps` as the third
   transaction (the deployer is DAO admin from `AddPackage`, because init founds
   the meta court).
7. Post-deploy asserts: `BurnSink()` is not the V2 sink; `CourtEscrow("meta")`
   is the new realm's address; `DirectoryAdmin()` is the deployer; `BurnBps() ==
   1000`; `TestClockFabricated() == false`; `CourtCount() ≥ 2`;
   `ReserveGNOT("meta") == 0`; `CourtOneWay("meta") == true`.
8. Then, in order: a guilds realm importing V3 signed by the same key (so the
   overlay derives its path); `kourtchat.service`'s `--archive-realm` and
   `--guild-realm`; the overlay stamp (`SITE_PKG`, and `SITE_PKG_PREV` for the
   "earlier generation" block); `kourtguildctl` and `internal/binding`
   defaults (whose `no such court` match must accept any generation's prefix);
   the docs. One overlay build serves both generations by probing `BurnBps()`
   once per realm: an answer is V3, "not declared" is V2's copy verbatim, a
   transport error offers no control at all.

## 11. Sentences that stopped being true

Applied in the docs commit that follows this file. The realm's own comments
were corrected in the two-way commit; these are the documents:

WHITEPAPER.md — the abstract's "the payment is burned"; §4's "No treasury / No
redemption"; §5's franchise sentence ("burning GNOT in any court" → the burned
share); §7's "no treasury, no dividend, no buyback, no redemption" and the
disclosure; §8's "a burn of faucet tokens". REGULATIONS.md — the lever row
"Real money exits contingent on outcomes"; §7.2 item 2's two withdrawn
mitigants; item 4's "no loser-pays-winner"; a §8 to-do and a §9 dated entry.
ECONOMICS.md — `ρ = r + d` as GNOT carry; the "at your sole cost" manipulation
check. MODERATION.md — the "~49× better" figure becomes `φ×`; the franchise
tripwire restated. RENTEDWEIGHT.md, TRADEANDLOCK.md, LOSERLOCK.md, STRADDLE.md,
GAMETHEORY.md, VOTEFLOOR.md, VOTELOCK.md — the lines that say the curve is
one-way, that CC is soulbound, that a burned fee benefits nobody, or that
escrow conservation has six components (it has a seventh, GNOT-denominated).
README.md — the realm table gains kourtv3 and marks kourtv2 the frozen mirror.
docs/CLAIM_BOARDS.md — §20.1's "GNOT buys a court's coin, one way" (both
sentences, not only the first). Left as it is, on purpose: `r/kourtv2`'s
`burnSinkPath` comment still calls the sink "a sub-realm identity of THIS realm
that is never created" — the right conclusion for the wrong reason (gno's
sub-realm separator is `#`, not `:`; the guarantee is that no package path may
carry a colon), corrected in kourtv3's copy and frozen in kourtv2's because
that file mirrors mainnet.
cryptocourt: PLAN.md's decision rows, DEPLOY-MAINNET.md (its "zero courts at
deploy", "no admin until step 2" and "seal the clock" are wrong),
GUILD.md/deploy README/web README paths, and the overlay comments that quote
devnet figures as live. Both overlay-side gaps the audit named are closed on
cryptocourt's `twoway-overlay` branch: web/index.html's coin panel passes
`minUnits` (the quoted units less a 0.5 % tolerance, 0 with no quote) and
`cliCmd`'s Buy arm prints the third `-args`; scripts/retarget.sh takes
`--src <realm>`, rewrites that realm's path and package line, and refuses a
build with any `gno.land/[pr]/kourt/` literal left in it — the invocation §10
step 3 names. The `realm` submodule there is pinned to the commit that
introduced the third argument, so a retarget build and the page agree.
