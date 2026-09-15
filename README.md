# kourt

The Gno realms and packages behind [kourt.xyz](https://kourt.xyz): a directory of
prediction-market **courts**, each with its own coin, bonding curve, governor and
set of claims.

This repository is the contract source and nothing else. The website, the chat
service, the archive and the deployment tooling live elsewhere and are not needed
to read, build or test anything here.

---

## What is in here

Twelve packages. The `p/` ones are general and were written to be read on their
own; the `r/` ones are the product.

### `p/` — libraries

| Package | What it is |
|---|---|
| [`p/governor`](p/governor) | A proposal engine. Holds proposals, epochs, quorum floors, the roll and the tally — and decides nothing about what agreement *means*. Adoption yields a kind and a payload; the installing realm turns those into an effect. |
| [`p/grc20votes`](p/grc20votes) | A GRC20-shaped ledger that remembers what every holder's voting power *used to be*, so a vote is weighed at the block its question opened. |
| [`p/checkpoint`](p/checkpoint) | Remembers what a number used to be. The primitive under `grc20votes`. |
| [`p/curve`](p/curve) | A linear, one-way bonding curve: issue a token against a reserve, price rising with position. One-way is the safety property, not a limitation. |
| [`p/cshares`](p/cshares) | A conditional-share ledger — the collateral-conserving core of a prediction market, with custody of the collateral left to the caller. |
| [`p/tickbook`](p/tickbook) | A tick-quantised central limit order book: gas-bounded, integer-only, on a fixed price grid. |
| [`p/twap`](p/twap) | A fixed-window trailing average of an integer series. Cheap to keep, cheap to read, hard to move with a one-block spike. |

### `r/` — realms

| Realm | What it is |
|---|---|
| [`r/kourtv2`](r/kourtv2) | The product. Courts, claims, answers, disputes, escrow, moderation, curation, rendering. The largest thing here by a wide margin. |
| [`r/kourtv1`](r/kourtv1) | The audited predecessor, kept intact as the reference V2 is measured against. Not superseded in the repository, only on chain. |
| [`r/govern`](r/govern) | An analog of OpenZeppelin's ERC20Votes + Governor for gno.land, and the worked consumer of `p/governor`. |
| [`r/offerer`](r/offerer) | A fixture that matters: a *second* realm extending the same governor from its own package, proving the extension point works across a realm boundary rather than only within one. |
| [`r/ccwrap`](r/ccwrap) | Makes a court coin tradeable on a DEX without handing the DEX any authority inside the court. |

### How the governance layer fits together

The `/p/` half is reusable: any realm can import it and get a checkpointed voting
token and a governor over it without forking anything. The `/r/` half is one
worked consumer.

**checkpoint** remembers what a number used to be, as of an epoch. Two points
inline plus a paged archive, so an account whose balance has not moved since it
was created answers without touching the archive at all. No crossing functions
and no realm state — which is what makes it the half that can be a `/p/` package.

**grc20votes** is the ledger: balances, allowances, one-hop delegation with self
as the default, and a checkpoint of voting power on every change. A `*Ledger` is
a value the consuming realm allocates, so one realm can run several — a court per
coin — and each names its own token.

It takes an acting address rather than reading one. A `/p/` package cannot declare
a crossing function and so has no caller to authenticate; the realm above holds
the `cur realm`, checks `IsCurrent()`, and passes the address in. That is the
split, and it is why the ledger needs no capability of its own.

**governor** is the engine: the kind registry, every proposal, the tally
arithmetic, the rules, the slot sweep and the pages — over any `Electorate` and
`Token`, whether that is a ledger or a council with one address and one vote.

It cannot run a kind by itself. Handing a kind its sub-realm token needs a live
`cur`, which a pure package does not have, so the realm supplies a one-line
`Dispatch`. What that dispatcher receives is a kind, a subpath and a payload —
never a pointer into governor or ledger state.

**govern** is one realm consuming these. It owns what only a realm can: the
entrypoints, the deployer captured at init, the minter policy, and the governor
that decides by reading the ledger's history at an epoch sealed when the question
was asked — which is what stops voting weight being bought once a fight is
visible. `r/govern` is 432 lines of non-test code; everything else it used to
hold is `p/governor` now.

A proposal is a kind name and a string. Kinds are registered by realms and adopted
by vote, so an ordinary account can propose without being able to write Gno —
which matters, because `MsgCall.Args` is `[]string`, and any entrypoint taking a
struct has silently restricted proposing to people who can deploy code.

**offerer** is the worked example: a realm that is *not* `govern` publishing a
power for the holders to adopt. It exists as a realm rather than a test because
`Offer` takes an interface, and a transaction cannot carry one.

Each package declares its on-chain path in its `gnomod.toml` — `gno.land/r/kourt/…`
and `gno.land/p/kourt/…/v0`.

---

## Building and testing

### The toolchain is pinned, and you want it to be

Gno's semantics move between chain releases — the interrealm spec most of all — so
a suite run against whatever `gno` happens to be on your `PATH` proves very little
about the chain these realms are deployed to. This is not a hypothetical: while
this repository was being split out, a `gno` built from `master` failed `r/ccwrap`
with `name PreviousRealm not declared` inside an *upstream example package*, which
looks exactly like a bug here and is not one.

So `make` builds its own:

```sh
make toolchain      # go install gno@v1.2.0 into ~/.cache/gno-toolchains/v1.2.0
make test           # every package, plus the guards that read the source
```

`v1.2.0` is the gnoland-1 mainnet release — its tag peels to the same commit as the
deployment lock, so it is the chain's own source rather than a version that merely
happens to work. Override with `make GNO_REF=… test` if you need another. The
binary is never added to `PATH`; every command invokes it by full path, so which
version ran is explicit and two refs can coexist.

You need Go (for the toolchain build and the two harnesses) and Python 3 (for the
guards). Nothing else.

### The targets

```
make test             the gno suites for all 12 packages, plus the source guards
make check            everything above that needs no node and no network
make txtar-test       the realms on a real, in-memory gnoland node
make chain-test       the realms on a live gnodev (needs one at :26657)
make isolation-test   every suite alone, so none passes on a neighbour's state
make mutate / gaps    break the money path on purpose; check the suites object
make selftest         break each guard on purpose; check the guard objects
make help             the same list, from the Makefile
```

---

## About the guards

`scripts/check-*.py` are not linters. Each one is a claim about the source that no
test could make, written after something got through — a persisted struct field
nothing reads, a `realm` value trusted in a position the caller chose, a balance
read whose cost a stranger sets, a flag that is read and never written.

Three things police the guards themselves, because a check that quietly stops
matching is worse than no check:

- **`check-guards-armed`** — every committed guard is named in `selftest-checks.py`.
- **`check-guards-run`** — every guard is reachable from a target `check` depends on.
- **`check-guards-blind`** — every guard still *fails* when its own detection
  pattern is blinded. Four guards were caught reporting a clean tree while
  scanning nothing.

`make selftest` goes further: it breaks each guard's subject on purpose and
requires the guard to notice. `scripts/mutations-kourtv2*.json` does the same to
the realm — several hundred deliberate defects, each asserting which suite objects.

---

## A note on the test clock

`r/kourtv2/testclock.gno` carried two planted defects for a while, and how they
got there is worth recording: a `make mutate` run was killed part-way, leaving its
mutants in the working tree, and the next commit swept them up. The commit is
`d639cea` in the application repository, whose message is entirely about wallet
signing and never mentions the realm. Both changes were verbatim the `find` →
`replace` of two rows in `scripts/mutations-kourtv2-KNOWN-GAPS.json`:

    if CourtCount() > 1  ->  if CourtCount() > 2      the arming gate widened
    tcEverArmed = true   ->  (deleted)                the disclosure never set

The second is the worse one: `TestClockFabricated()` reads `tcEverArmed`, so a
chain whose clock HAS been fabricated answered that it had not. Both are reverted.

What makes this worth a section rather than a line in a log: the repository's own
checks caught it and said so in four places at once — `anchors` and `collisions`
could no longer find those rows' anchors, because the source had come to read the
way the rows describe the MUTANT; `txtar-test` failed on the disclosure and on the
arming gate; `elsewhere-test` on the same two rows from the other direction. Four
red targets, one cause, and the cause was that the corpus and the source agreed
when they are supposed to disagree.

`make mutate` restores what it plants. A killed run does not, which is why
`scripts/repolock.py` exists — and why a run that dies still leaves work to undo
by hand.

---

## Licence

GNO Network General Public License v6 — see [LICENSE.md](LICENSE.md).

Copyright © 2026 Jae Kwon.
