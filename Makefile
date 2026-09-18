.PHONY: help test check realm-test txtar-test chain-test isolation-test elsewhere-test \
	anchors paths guards controls collisions rendertext staleguards nodelegate height-shim \
	scenarios scenarios-check mutate gaps selftest fmt vet toolchain

# THE TOOLCHAIN IS PINNED, AND THAT IS THE WHOLE REPRODUCIBILITY STORY.
#
# Gno's semantics move between chain releases — the interrealm spec most of all —
# so a suite run against whatever `gno` happens to be on your PATH proves nothing
# about the chain these realms are deployed to. That is not hypothetical here: on
# the machine this was split from, a `gno` built from master failed r/ccwrap with
# "name PreviousRealm not declared" in an UPSTREAM example package, which looks
# exactly like a bug in this repo and is not one.
#
# GNO_REF is the mainnet release. gnoland-1 launched from v1.2.0, whose tag peels
# to the same commit as the deployment lock, so this is the chain's own source
# rather than a version that merely works. The binary is built into a store keyed
# by that ref and invoked by full path — never added to PATH — so which one ran is
# explicit in every command and two refs can coexist.
GNO_REF   ?= v1.2.0
GNO_STORE ?= $(HOME)/.cache/gno-toolchains/$(GNO_REF)
GNO       ?= $(GNO_STORE)/gno

help:
	@echo "kourt — the Gno realms behind kourt.xyz"
	@echo
	@echo "  make toolchain      build the pinned gno ($(GNO_REF)) into $(GNO_STORE)"
	@echo "  make test           the realm suites and the guards that read them"
	@echo "  make check          everything that does not need a node"
	@echo
	@echo "  realm-test          gno test, every package, plus the source guards"
	@echo "  txtar-test          the realms on an in-memory gnoland node"
	@echo "  chain-test          the realms on a live gnodev (needs one running)"
	@echo "  isolation-test      every suite alone, so none passes on a neighbour"
	@echo "  mutate / gaps       break the money path on purpose; check it is noticed"
	@echo "  selftest            break each guard on purpose; check IT is noticed"

# Builds the pinned binary if it is not already there. Cheap to re-run: the
# existence test short-circuits, so every target can depend on this without
# paying for it.
toolchain:
	@if [ ! -x "$(GNO)" ]; then \
		echo "building gno $(GNO_REF) into $(GNO_STORE) (once)"; \
		GOBIN="$(GNO_STORE)" go install "github.com/gnolang/gno/gnovm/cmd/gno@$(GNO_REF)" || exit 1; \
	fi; \
	echo "gno: $(GNO)"

test: realm-test

# Everything that needs no node and no network. chain-test is deliberately out:
# it wants a gnodev listening, which a stranger cloning this repo will not have.
#
# ONE LINE, NO CONTINUATION, and that is load-bearing rather than a style choice.
# check-mutation-anchors decides whether an `elsewhere` excuse is honoured by
# walking the prerequisites of this target and reading the recipes it reaches. It
# takes them from the line — so a `\` continuation hid every target after the
# break, and eight rows were reported as excuses pointing at suites nothing runs
# while `make check` was in fact running all of them. The guard failing loudly is
# the good case here; the same break in a target it did not police would simply
# have been wrong.
check: fmt vet paths anchors collisions rendertext guards controls staleguards nodelegate height-shim scenarios-check realm-test txtar-test elsewhere-test

# ---------------------------------------------------------------- the realms --

# THE SUITES, plus the guards that can only run with a toolchain present.
#
# Each package is staged into a private GNOROOT shadow (scripts/gnoroot.py) under
# the import path baked into its source, because that is what makes `gno test`
# resolve a sibling p/kourt package at all. The shadow is per-run and per-pid, so
# two checkouts can run this at the same time without deleting each other's
# staged tree — which they used to do.
realm-test: toolchain
	@if [ ! -x "$(GNO)" ]; then echo "run 'make toolchain' first"; exit 1; fi; \
	export PATH="$(GNO_STORE):$$PATH"; \
	python3 scripts/repolock.py check realm-test || exit 1; \
	rc=0; \
	python3 scripts/check-citations.py         || rc=1; \
	python3 scripts/check-docnumbers.py        || rc=1; \
	python3 scripts/check-storage.py           || rc=1; \
	python3 scripts/check-nontransferable.py   || rc=1; \
	python3 scripts/check-epoch-coherence.py   || rc=1; \
	python3 scripts/check-membership-clears.py || rc=1; \
	python3 scripts/check-read-purity.py       || rc=1; \
	python3 scripts/check-spend-paths.py       || rc=1; \
	python3 scripts/check-abort-assertions.py  || rc=1; \
	root=$$(python3 scripts/gnoroot.py build --label realm-test --pid $$$$) || exit 1; \
	trap 'python3 scripts/gnoroot.py remove --path "$$root"' EXIT; \
	export GNOROOT="$$root"; \
	rbase="$$root/examples/gno.land/r/kourt"; \
	pbase="$$root/examples/gno.land/p/kourt"; \
	for p in checkpoint grc20votes governor twap cshares tickbook curve; do \
		mkdir -p "$$pbase/$$p/v0" && \
		cp p/$$p/*.gno p/$$p/gnomod.toml "$$pbase/$$p/v0/" || exit 1; \
	done; \
	for p in checkpoint grc20votes governor twap cshares tickbook curve; do \
		( cd "$$pbase/$$p/v0" && "$(GNO)" test . ) || rc=1; \
	done; \
	for r in govern offerer kourtv1 kourtv2 kourtv3 ccwrap guilds; do \
		mkdir -p "$$rbase/$$r" && \
		cp r/$$r/*.gno r/$$r/gnomod.toml "$$rbase/$$r/" || exit 1; \
		( cd "$$rbase/$$r" && "$(GNO)" test . ) || rc=1; \
	done; \
	exit $$rc

# The realms on a real (in-memory) gnoland node, the way gno.land's own
# integration tests run. Needs no external node — the harness starts one per
# script. This is the only place the on-chain coin invariant is checkable: the
# unit suites can only assert internal consistency.
txtar-test: toolchain
	@root=$$(python3 scripts/gnoroot.py build --label txtar --pid $$$$) || exit 1; \
	trap 'python3 scripts/gnoroot.py remove --path "$$root"' EXIT; \
	GNOROOT="$$root" go test -tags txtar -count=1 -timeout 20m ./harness/gnoland/

# What a transaction actually costs, what an indexer sees, and whether the deploy
# fits. Needs gnodev on 127.0.0.1:26657 (chain id dev).
#
# -p 1 because every test drives the SAME node with keys from one mnemonic. Run
# in parallel they interleave transactions on one account and fail on sequence
# numbers, which reads as a realm bug and is not one.
chain-test:
	REQUIRE_GNODEV=1 go test -tags gnochain -count=1 -p 1 -timeout 40m ./harness/chain/

# Every suite run on its own. A gno test file shares package state and these
# suites do not rewind the clock, so a test can pass only because of what ran
# before it. Slow — each suite once per test — hence its own target.
isolation-test: toolchain
	@PATH="$(GNO_STORE):$$PATH" python3 scripts/check-isolation.py

elsewhere-test:
	@python3 scripts/check-elsewhere.py

# ----------------------------------------------------------------- the guards --

# Guards that need NO toolchain are kept out of realm-test on purpose: that
# target cannot run without a gno binary, and a guard that is pure Python should
# not be switched off by a missing one.
anchors:
	python3 scripts/check-mutation-anchors.py

paths:
	python3 scripts/check-paths.py

# Every committed guard must be named in selftest-checks.py, so an unarmed one
# fails here rather than in the next periodic selftest — which is days later and
# fails for a reason unrelated to whatever its author is doing.
guards:
	python3 scripts/check-guards-armed.py
	python3 scripts/check-guards-run.py
	@# The third question the other two do not ask. armed says a guard HAS a
	@# control arm; run says a target runs it. Neither asks whether it still
	@# fails when its own detection stops matching — and two of them did not.
	@# Runs every guard against a blinded COPY; never writes to the tree.
	python3 scripts/check-guards-blind.py
	@# One block is five seconds, said in two languages that cannot import it
	@# from each other, and two kourtv2 deadlines written once in blocks and once
	@# in seconds. A drift does not fail — it quietly gives an old record and a
	@# new one different windows.
	python3 scripts/check-block-time.py
	@# What the mutation corpus covers is a claim about the IMPORT GRAPH, and
	@# mutate.py's exclusion of cshares and tickbook rests on it.
	python3 scripts/check-mutation-scope.py
	@# These structs persist, so a field nothing reads is a deposit paid at every
	@# write for a value no caller can observe.
	python3 scripts/check-dead-fields.py
	@# A realm value in any position but the FIRST is one the CALLER chose, so
	@# asking it who called you and believing the answer executes somebody else's
	@# authority.
	python3 scripts/check-interrealm.py
	@# GetCoins walks every denom an address holds, and anyone can give an address
	@# a denom it never asked for — so a stranger sets the cost of the read.
	python3 scripts/check-getcoins.py
	@# A flag read but never assigned answers the same thing forever.
	python3 scripts/check-inert-flags.py

# `guards` asks whether each guard is REGISTERED. This asks whether each control
# arm's PLANT still applies: a rotted anchor makes the arm a no-op, the guard
# runs against an unmodified tree, and it is reported SILENT.
controls:
	python3 scripts/check-control-anchors.py

# check-mutation-anchors compares the (pkg, file, find, replace) triple, so two
# rows expressing ONE mutation through different anchor text are distinct to it.
# This finds the next collision by applying every row and hashing the result.
collisions:
	python3 scripts/check-mutant-collisions.py

# User text reaches a rendered page through a named gate and only through it. A
# census, because the check that catches a NEW reader is "the set changed", and
# no regex over call sites can say that.
rendertext:
	python3 scripts/check-render-text.py

staleguards:
	python3 scripts/check-stale-guards.py

# Vote weight is min(snapshot, own balance), and those two agree in kourtv2 only
# because nothing there can delegate.
nodelegate:
	python3 scripts/check-nodelegate.py

# Every height read in the realm must go through heightNow(), or a seeded chain
# sees two different heights in one transaction. The guard counts the call sites
# on every run and prints what it found, so the number lives in its output rather
# than in this comment.
height-shim:
	python3 scripts/check-height-shim.py

# -------------------------------------------------------------- the scenarios --

# Recompile every scenario. The generated txtars name this target in their own
# header, so it has to exist — and `check` runs the --check twin so a stale
# generated file fails the build instead of being silently trusted.
scenarios:
	@for f in $$(python3 scripts/scenario.py --list-ci); do \
		out="harness/gnoland/testdata/scn_$$(basename $$f .py).txtar"; \
		python3 scripts/scenario.py "$$f" --out "$$out" || exit 1; \
	done

# Two questions about a seed, and the second is about BYTES. check-seed-emitters
# asks that every emitter a scenario drives still exists; check-seed-assets asks
# that the media digest a seed files still describes the image committed beside
# it in scenarios/assets. Replace the picture and the seed files the old address:
# no reader can resolve it, while the seed, the realm and every check go on
# saying the filing succeeded.
scenarios-check:
	@rc=0; tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	for f in $$(python3 scripts/scenario.py --list-ci); do \
		n="$$(basename $$f .py)"; out="harness/gnoland/testdata/scn_$$n.txtar"; \
		python3 scripts/scenario.py "$$f" --out "$$tmp/$$n.txtar" >/dev/null || exit 1; \
		if ! cmp -s "$$out" "$$tmp/$$n.txtar"; then \
			echo "$$out is stale — run 'make scenarios'"; rc=1; \
		fi; \
	done; \
	for t in harness/gnoland/testdata/scn_*.txtar; do \
		[ -e "$$t" ] || continue; \
		src="scenarios/$$(basename $$t .txtar | sed 's/^scn_//').py"; \
		[ -e "$$src" ] || { echo "$$t has no scenario ($$src) — it runs in txtar-test with no source"; rc=1; continue; }; \
		python3 scripts/scenario.py --list-ci | grep -q "/$$(basename $$src)$$" || \
			{ echo "$$t was generated from $$src, which is now CI = False — delete the txtar"; rc=1; }; \
	done; \
	[ $$rc -eq 0 ] && echo "scenarios-check: every generated txtar matches its scenario."; \
	python3 scripts/check-seed-emitters.py || rc=1; \
	python3 scripts/check-seed-assets.py || rc=1; \
	exit $$rc

# --------------------------------------------------------------- the mutators --

# Break the money path on purpose and check the suite objects. Every `elsewhere`
# row names a harness that must OBJECT to that row's mutation. Applies each
# mutation to the tree in place and restores it, so run it on a clean tree.
mutate: toolchain
	PATH="$(GNO_STORE):$$PATH" python3 scripts/mutate-parallel.py scripts/mutations-kourtv2.json

# THE GAPS ARE CLAIMS, SO RUN THEM. Every row in the KNOWN-GAPS file asserts that
# no test can catch it. Until this target existed nothing checked that, and a gap
# closed by somebody's new test would sit there asserting the opposite for ever.
#
# Rows marked "slow" are skipped BY NAME rather than waited out: each burns a full
# SUITE_TIMEOUT every run, and what they assert is a property of that bound rather
# than of any test.
gaps: toolchain
	@PATH="$(GNO_STORE):$$PATH" python3 -c "import json,sys; \
	  rows=[r for r in json.load(open('scripts/mutations-kourtv2-KNOWN-GAPS.json')) if not r.get('slow')]; \
	  print('gaps: %d row(s), %d skipped as slow' % (len(rows), \
	    len(json.load(open('scripts/mutations-kourtv2-KNOWN-GAPS.json')))-len(rows)), file=sys.stderr); \
	  json.dump(rows, sys.stdout)" | PATH="$(GNO_STORE):$$PATH" python3 scripts/mutate-parallel.py --shards 4 --expect-survive

# Break each guard on purpose and check IT notices. Periodic rather than
# per-commit: a check that reports success while measuring nothing is the failure
# this catches, and it has caught it.
selftest:
	python3 scripts/selftest-checks.py

# ------------------------------------------------------------------- the Go --

fmt:
	@out=$$(gofmt -l .); \
	if [ -n "$$out" ]; then echo "unformatted:"; echo "$$out"; exit 1; fi; \
	echo "gofmt: clean"

vet:
	go vet -tags gnochain ./...
	go vet -tags txtar ./...
