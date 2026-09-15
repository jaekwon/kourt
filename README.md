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

## Known red, and it is not the build

Four of `make check`'s fifteen targets fail here, all on **one** defect in the
test-clock disclosure. They fail identically in the repository this was split out
of; the split did not cause them and does not hide them.

1. `r/kourtv2/testclock.gno` declares `tcEverArmed` and reads it in
   `TestClockFabricated()`, but nothing in the **arming path** ever sets it. Only
   `testclock_test.gno` writes it. So a chain whose clock *has* been fabricated
   reports that it has not.
2. The arming gate reads `if CourtCount() > 2`, while the mutation corpus records
   the audited rule as `> 1`. A realm with a used meta court plus one more is still
   armable.

They surface four ways, all downstream of the same two facts:

- `make txtar-test` — `kourtv2_testclock` and `scn_dispute`/`scn_covid` look for a
  disclosure of `true` and get `false`; `kourtv2_usedrealm_seeded` expects the
  arming gate to refuse and it does not.
- `make anchors` and `make collisions` — the two mutation-corpus rows that describe
  these defects can no longer find their anchors, *because the source now reads the
  way the rows describe the mutant*.
- `make elsewhere-test` — the same two rows, from the other direction.

That is the whole of it. `make test` and the other eleven `check` targets are green,
and so is `go vet` on both harnesses.

---

## Licence

GNO Network General Public License v6 — see [LICENSE.md](LICENSE.md).

Copyright © 2026 Jae Kwon.
