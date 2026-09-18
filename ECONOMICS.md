# ECONOMICS.md — private emission-calibration memo (V2, with the V3 two-way addendum)

> Referenced by PLAN.md §3.3. INTERNAL: per §7.4 comms hygiene, nothing in this
> file — rates, APR-equivalents, margins — may appear in public docs, render,
> or marketing. Public copy says only: "participation rewards at a published
> protocol rate, subject to availability."

## Symbols

| | |
|---|---|
| `r` | external opportunity rate (what locked capital could earn elsewhere), per week |
| `d` | dilution rate = minted / supply, per week |
| `ρ` | `r + d` — the full carry cost of locked CC. **Right for the BUY decision, wrong for the STAKE decision:** dilution hits staked and unstaked CC alike, so the *differential* carry of staking rather than holding is `r` alone. Since the reward scales with `r + d` while the differential cost scales with `r`, every anti-farming margin here degrades linearly in `d`. **Under V3 (`r/kourtv3`) `d` is also carry on a GNOT-denominated claim**, not only on voting weight: every coin is owed `floor(reserve × amount / TotalSupply)` (`redeemQuote`, redeem.gno), so an emission of `m` coin against a supply of `N` multiplies each holder's per-coin return by exactly `N/(N+m)`. Same `d`, now with a µGNOT figure attached (TWOWAY.md §4). |
| `T_c` | conviction time: stake → answer-freeze |
| `T_L` | lock time: stake → withdraw. **ASSUMED ≈ 1.5 × T_c here ("adds 72h + escrow"); MEASURED 1.039 × T_c.** The escrow half was never built — `WithdrawStake` is deliberately unpausable, so principal is never held past the verdict. Every result below that divides by `T_L` is optimistic by ~1.44×, and §"Matched farmer" is wrong *because* of it. |
| `y` | yield per conviction actually paid (the effective rate) |
| `p` | a staker's true accuracy on the claims they stake |

## Core results (econ vet F5; reservoir vet F-R1/F-R5)

- **Matched-farming threshold**: staking both sides is profitable iff
  `y > y* = 2ρ·T_L/T_c`. Below y*, no farming capital enters at all.
- **Honest threshold**: a staker with accuracy p profits iff `y > y*/(2p)`.
- **The schedule**: `rate_n = 0.85 × y*(n)` per period n. Consequences:
  farming margin −15% (never profitable); honest break-even at
  `p_min = 1/(2×0.85) ≈ 0.59` **for the full rate** — but see the correction
  below: the CODE pays a winner 80/93 of the claim draw (the 8/5 author/answerer
  points come out of the same D, not on top), so the winner's effective rate is
  `0.85 × 80/93 = 0.731` and the true honest break-even is **`p_min ≈ 0.68`**
  (econ-vet P7, openrewards.gno:69). The 0.59 figure assumes a gross-up the code
  deliberately does not do (it is ~16% more conservative, ceiling-safer). A
  p = 0.7 staker still nets slightly positive; a p = 0.6 staker is neutral-to-
  negative on the reward (principal always returns 1× regardless). Accepted
  calibration characteristic, not a bug — the narrower reward band is the
  ceiling-safe choice.
- **Why 0.85, not 0.75**: the schedule (below) removes the *deterministic*
  y*-decay that the margin previously had to absorb; the remaining drift is r
  only. 0.75 amputated the 0.59–0.67 accuracy band — real calibration signal
  — for margin we no longer need (F-R5).

## The d_n rule (v0.20 — LIVE supply, superseding the ceiling path)

`d_n = B_n / S_live`, with `S_live` read once at each period boundary
(deterministic on-chain data, not a lever) and `B_n` the per-period budget on
the **geometrically amortized** step-down (`×2^(−1/104)` per period — no
cliffs exist, so no boundary block can be raced; 2A-T3). Then
`y*(n) = 2(r₀ + d_n)·T_L/T_c` and `rate_n = 0.85·y*(n)`.

Why live, not ceiling (the v0.15→v0.20 reversal, PLAN decision #19): the
ceiling path understates d early — at 10% of ceiling supply, actual d is 10×
the scheduled figure, actual y* ≈ 3.75%/wk vs a 0.89%/wk rate, and honest
break-even needs p > 1: **the early court pays nobody**. With live d the 15%
anti-farm margin tracks the true y* at every supply level. Manipulation check:
buying CC lowers everyone's rate including yours (self-defeating for a
yield-seeker); redeeming your CC raises the rate for those who stay — and
under V3 **not at your sole cost**, because `Redeem` (redeem.gno) pays the
redeemer the pro-rata return `floor(reserve × amount / TotalSupply)` rather
than nothing. A mass redemption therefore lifts stayers' rate for free to the
redeemer, which is why the lift is *bounded* rather than priced: `rollPeriod`
(emission.gno) takes `d_eff` as the min of realized dilution and the budget
ceiling, the ceiling is 38 bps (`budgetBpsFPStart`, stake.gno), so the
published rate `rateBpsFP = 2.55 × (r₀ + d_eff)` never exceeds
`2.55 × (25 + 38) = 160 bps/wk`; and a redeemer who wants back in pays the
marginal price for a coin whose return is at most half of it (TWOWAY.md §4,
threat A14: an accepted nuisance). On a court founded one-way
(`StartOneWayCourt`, court.gno) `Redeem` refuses and the V2 sentence stands —
giving up your CC costs you the whole coin. Every remaining lever is
self-costly or capped. Self-bound unchanged: draws are conviction-based,
so `d_real ≤ rate × staked-fraction` — no court dilutes faster than its own
participation earns.

Conviction itself is **rate-weighted** (∫rate(t)·stake·dt — V2-8): there is no
rate snapshot anywhere, accrual is priced as it happens, and the F5 band holds
within every era because 0.85·y*(t) < y*(t) pointwise.

## Reference launch numbers (used across all vet math)

r₀ = 0.25%/wk (~13%/yr), d₀ ≈ 0.1%/wk, T_L/T_c = 1.5 →
y*₀ = 2(0.35%)(1.5) = 1.05%/wk → **rate₀ = 0.89%/wk per unit conviction**.

> **The `(1.5)` in that line is the unbuilt escrow assumption.** The shipped constant is
> `rateBpsFP = 2.55 × (r0 + d_eff)` with `2.55 = 0.85 × 2 × 1.5`, so the 1.5 is baked into every
> staker's reward — the rate was priced for a lock duration the code does not deliver. That is the
> root cause of the matched-farmer row being wrong, and it is the single least-examined number in
> this memo. Note also that `r0WeeklyBps = 25` (13%/yr) is an *assumption about the outside world*
> hardcoded into the reward: if real alternative yields are lower, every farming margin here is
> more favourable to the farmer than stated.

| Actor | Position | Net per episode (on stake, T_c = 2wk ref) |
|---|---|---|
| Matched farmer | both sides, 2× lock | ~~**negative**~~ → **MEASURED POSITIVE, +5.6% to +9.7% of carry** (and +27.6% if the farmer also authors and answers the claim, taking 93/93 of the draw rather than the stakers' 80/93). This row assumed `T_L = 1.5·T_c`; at the delivered 1.039 the sign flips. It is the one row in this table the code contradicts, and the straddle *is* that gap. Bounded in practice by the draw cap at the high tier, by the per-period budget on thin courts, and by needing a >91% claim-survival rate to profit at all. See `STRADDLE.md`. |
| Coin-flipper (p = .5) | one side | negative (0.85/2·y*·T_c < ρ·T_L) |
| Break-even staker | p ≈ 0.59 | ≈ 0 |
| Good staker (p = 0.7) | one side | ≈ +0.19·ρ·T_L ≈ +0.10%·stake/wk-equivalent |
| Mill (post-v0.20 repricing) | self-claim | negative at modest flag probability — now economically supplied (bounty = flagger's own bond, paid flag-voters); deposit slash + tier-0 at risk vs mid-tier crumbs. (The old "q ≥ 0.2" figure was retracted as unreproducible, V2-1.) |
| Redeemer (V3) | returns uncommitted coin through `Redeem` | paid `floor(reserve × amount / TotalSupply)` µGNOT — at most the marginal price, about half of it right after an offering, less as emission mints (see "V3: what a coin returns" below). Committed coin cannot be redeemed (`mustSpendable`, redeem.gno). Neutral to stayers' per-coin return (TWOWAY.md I5); raises stayers' *rate* only up to the 160 bps/wk cap (A14). Below the break-even position `x*` an early buyer recovers above cost from later buyers — disclosed, not closed. |

## V3: what a coin returns (INTERNAL — TWOWAY.md §4 carries the proofs)

> Same hygiene as the header: none of these figures — the grid, the break-even
> position, any percentage — may appear in public copy, render or marketing.
> Public copy says only: "less than half its price right after an offering,
> and less as emission mints." The held share is never presented as backing,
> NAV or worth, and the burn is never marketed as scarcity (PLAN §7.4; Munchee).

Under `r/kourtv3` a payment **splits** (`splitPayment`, redeem.gno). The burn
share `φ` — `BurnBps`, 1000 bps at launch, DAO-admin-set realm-wide within
`[500, 5000]` bps (`mustSaneBurnBps`) — goes to the keyless sink exactly as V2
burned the whole payment; the rest is held per court as `reserve`. `Redeem`
pays `floor(reserve × amount / TotalSupply)` (`redeemQuote`, 128-bit) and goes
through `mustSpendable` like every other outflow, so staked and vote-locked
coin cannot be cashed out. There is no exit fee. A court may be founded
one-way (`StartOneWayCourt`, court.gno): every payment burns in full and
`Redeem` refuses it forever; META is founded one-way at init. Franchise and
directory rank key on the burned share only (`accrueFranchise`, meta.gno;
`reindexBurn`, modrender.gno). The three mainnet courts stay one-way at their V2
path forever; their 481.13 GNOT sits at a keyless address and is
unrecoverable; kourtv3 is a fresh realm and its courts start empty.

Symbols as in TWOWAY.md §4: `S` the curve position, `P = S/D` the marginal
price, `E` coin minted by emission, `N = S + E` the supply, `k = E/S` (≤ 0.78
over a court's lifetime), `φ` the burn share. With no redemptions the reserve
is `R = (1−φ)·S²/2D`, so the per-coin return is

```
R/N = (1−φ)·P / (2(1+k))
```

**The marginal buyer's immediate return**, φ = 0.10 — what a coin bought at
the current price returns if redeemed at once:

| k = E/S | return ÷ marginal price `(1−φ)/(2(1+k))` | return ÷ average price paid |
|---|---|---|
| 0 | 0.45 | 0.90 |
| 0.2 | 0.375 | 0.75 |
| 0.5 | 0.30 | 0.60 |
| 0.78 | 0.253 | 0.506 |

So a buy followed at once by a redeem loses at least 55% of outlay at k = 0
and about 75% by k = 0.78 — for a buyer small against the court. A buyer who
dwarfs it loses less: the exact recovery of Δ coin into position S is
`(1−φ)(S+Δ)²/((2S+Δ)(S(1+k)+Δ))`, 60% at Δ = S, 82.5% at Δ = 10S, tending to
1−φ (TWOWAY.md §4, §6 A16). The return is at most the marginal price under any
interleaving of buys, redemptions and emission (TWOWAY.md §4 proof (c)); a
coin burn is the exception — a forfeited bond shrinks supply with the reserve
fixed, and cumulative burns past ~55% of supply lift the return over the price
(TWOWAY.md §6 A7); the "at most half" form holds while `N ≥ S`, which heavy
redemption can break — the marginal bound is the one that prevents arbitrage.

**Break-even position.** A buyer at position fraction `x` who paid the
marginal price there and returns coin once the court has filled to `S`
recovers `(1−φ) / (2x(1+k))` of their outlay. Break-even is

```
x* = (1−φ)/(2(1+k))      = 0.45 at k = 0,  0.253 at k = 0.78
```

Below `x*` an early position recovers above cost — funded by later buyers,
never by other holders, since a redemption never lowers what stayers are owed
per coin (TWOWAY.md I5). A marginal buyer at x = 0.1 recovers 4.5× at k = 0,
2.5× at k = 0.78; the actor who bought the whole first 10% recovers 9× / 5.1×
(TWOWAY.md §6 A2, with the arithmetic). **Accepted and disclosed**, not closed by mechanism (a per-position
cost basis would strand emission-earned and transferred coin); the whitepaper
carries it qualitatively and counsel weighs it (TWOWAY.md §8).

**What this does to the memo above.** `d` now carries a µGNOT figure (the `ρ`
row); the manipulation check gains the redeemer (the d_n rule); the actor
table gains a row. The schedule, the 0.85 margin, the 80/8/7/5 split and the
caps are unchanged — emission mints exactly as before, against a claim that is
now GNOT-denominated. Nothing in this section changes `rate_n`.

## Sizing B and R_max (v0.32 — OWNER: 20% ceiling)

`B_n = (20%/52) × S_live × 2^(−n/104)` per period: worst-case dilution ≤
20%/yr year one at any court size, halving-amortized. Total growth factor
bounded: Σ exponents = (0.2/52)·Σ2^(−n/104) ≈ (0.2/52)·150 ≈ 0.577 → supply
< e^0.577 ≈ 1.78× curve-sold, hence curveCapV2 = (MaxInt64/Bps)/2 keeps the
tally-overflow headroom. Realized dilution is participation-scaled as before
(d_real ≤ rate × staked-fraction); 20% binds only at full saturation.

## Sizing B and R_max (superseded v0.17 text)

`B_period` is a throughput ceiling, not a target: size it ≥ the forecast
`rate × Σconviction` of a healthy busy week so honest demand never scales down
in normal operation (scaling is reserved for genuine surges). `R_max = 4 ×
B_period` banks a month of quiet; anything longer is forgone by design
(ceiling-not-floor). Under-demand mints nothing; over-demand rations by
availability, farmers exit first (F-R4 ordering).

## The 80/8/7/5 split — tuning rationale (v0.19; converts "provisional" to "reasoned-provisional")

The split's job is ordering, not precision — each slice must clear its role's
participation threshold without inverting the hierarchy *winners ≫ author >
voters > answerer*:

- **Winners 80%**: the core signal incentive must dominate everything else
  combined, or staking becomes a side-show to service extraction. 80% keeps
  the effective staker rate at 0.8 × rate_n — the F5/F-R5 margins in this memo
  are computed on exactly that basis, so moving this number moves p_min.
- **Author 8%**: with the conditional fee refund (mech vet R7b), the author's
  worst honest case is ≈ 0 (fee back, small slice) and the good case is
  8% × a draw their claim attracted — pure upside for surfacing questions the
  crowd funds. Above ~10% authorship starts to compete with staking as the
  yield path (invites claim-spam pressure the fee must then re-price); below
  ~5% thin-claim authorship pays nothing at all.
- **Voters 7%**: deliberately a *token* at small draws (0.7 CC/voter on a
  1,000 CC draw) — voters' real motive is stake-protection and the court's
  credibility; the carrot only needs to beat gas and tip marginal attention.
  Making it large enough to be a primary income would recreate the F2/F3
  vote-for-pay dynamics the tier-invariance fix just contained.
- **Answerer 5%**: intentionally the smallest — the answerer's true
  compensation is the bond return + the difficulty-weighted credential
  (priority access to future slices); the slice is a top-up. Raising it
  re-inflates the self-answer mill margin that A15's fixes just priced out
  (the mill keeps winner+author+answerer = 93%; every answerer point is a
  mill point).

Tune freely at deploy **within the ordering and the caps** (§4); crossing the
ordering or touching cap *rules* re-opens A15/F2 and needs a fresh vet.

## Cross-references

PLAN.md §3.3 (mechanism + pins) · §3.5 (slices/caps) · §5 A1/A14 (the attacks
this math closes) · §6 (the p < 0.59 exclusion, owned) · vet findings F5,
F-R1, F-R4, F-R5 (derivations verified adversarially, twice).
