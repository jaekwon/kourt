#!/usr/bin/env python3
"""Run every realm test on its own, and require it to pass there too.

A gno test file shares package state with every other test in it. These suites
reset what they know to reset — the trees, the supply, the clock — and two
things were never on that list: the KIND REGISTRY, and where the clock had got
to. So a test could pass only in company:

  A rules test asserting messages that need the kind "fee" to exist, without
  registering it. Some neighbour always has. Run alone it refuses every payload
  with "no kind by that name has been offered" instead — and an assertion on
  the prefix every refusal shares matches that too, so the dependency stays
  invisible until the messages get specific.

  A history test asserting a holder had nothing at epoch 1. True only because
  neighbours pushed the clock well past epoch 1; run first, its own mint lands
  there and the holder has ten.

Both pass in the suite. Neither is testing what it says. That is the failure
mode this guards: not a test that breaks, but one that quietly reports on the
wrong thing.

    python3 scripts/check-isolation.py
    python3 scripts/check-isolation.py --only TestSomething   # one test

The whole sweep runs every Test function in every staged package as the only
test that runs — presently on the order of 1,600 of them — so it is its own
target rather than part of realm-test. --only exists so a control can prove
this guard fires without paying for the sweep.

HOW "ALONE" IS RUN, and why that changed. It used to mean one `gno test -run
^Name$ -v .` process per test. Each of those re-type-checked and re-compiled the
package and its imports and re-ran every init just to run one function: measured
on r/kourtv3, a spawn was ~98% load and ~2% test, and the tree cost forty
minutes single-file. It now means ONE PROCESS PER PACKAGE and ONE FRESH STORE
LAYER PER TEST: harness/isolation (a Go program in this module, built into the
shadow root at the start of the run) loads the package once, exactly the way
`gno test` does, and runs each test in a child transaction store that is thrown
away afterwards, so no test sees another's writes. The whole tree takes a few
minutes; kourtv3's 630 tests took ~30 s after a ~2 s load, at tens of
milliseconds per test, when this was measured. What the layer isolates and what
it does not is the comment block on runOne in harness/isolation/run.go, and the
runner's own test in that directory is a two-test package where one leaks to the
other. --slow is the old per-process path, byte for byte, kept so the two can be
cross-checked against each other.

That cost is stated as a range on purpose. It read "143 of them, a few minutes"
for as long as the realm lists were a hand-copy, and stayed at 143 through the
fix that added kourtv2 and quadrupled the real number. A figure nobody can
recompute from the tree is a figure that will be wrong again.

Everything `make realm-test` compiles, not just the realm most likely to have
the problem. Covering where somebody has already looked is opt-in coverage, and
opt-in coverage is how a citation goes unregistered, a filetest unbudgeted and a
guard uncontrolled. The point of a sweep is the instance nobody predicted.

Needs a gno toolchain; skips without one unless REQUIRE_GNO is set, and says so
rather than passing quietly.
"""

import os
import re
import subprocess
import sys
import time

import gnoroot
import repolock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Everything `make realm-test` compiles, staged the same way it stages them.
# DERIVED from the Makefile, not copied from it. The hand-maintained copy
# drifted and nothing noticed: it swept 151 tests while realm-test compiled 388,
# and every package it skipped was the newer half of the tree (kourtv1, kourtv2,
# p/twap, p/cshares, p/tickbook, p/curve) — i.e. the system under active
# development. A guard that measures less than it claims is worse than no guard,
# because a passing run looks identical either way and the only symptom is a
# count that stops moving. So the coupling is now enforced rather than
# documented.
#
# (Both sessions working this repo found this independently, in the same week,
# and reached the same fix. Treat that as evidence about the failure mode rather
# than about either reader: hand-maintained scope lists fail open, silently.)
#
# Parsing a Makefile is not elegant, but it fails LOUDLY: if either loop stops
# matching, realms() raises and the sweep refuses to run, where the previous
# arrangement just quietly swept less.
def realms():
    mk = open(os.path.join(REPO, "Makefile")).read()
    pkgs = re.search(r"for p in ([\w \t-]+); do", mk)
    rlms = re.search(r"for r in ([\w \t-]+); do", mk)
    if not pkgs or not rlms:
        raise SystemExit(
            "check-isolation: cannot read realm-test's package lists out of the "
            "Makefile. Fix the parse rather than hardcoding a list here — a "
            "hardcoded one is what silently stopped covering kourtv2.")
    out = [(os.path.join(REPO, "p", n), f"examples/gno.land/p/kourt/{n}/v0")
           for n in pkgs.group(1).split()]
    out += [(os.path.join(REPO, "r", n), f"examples/gno.land/r/kourt/{n}")
            for n in rlms.group(1).split()]
    for src, _ in out:
        if not os.path.isdir(src):
            raise SystemExit(f"check-isolation: {src} is in the Makefile but not on disk")
    return out


REALMS = realms()


def pkgname(rel):
    parts = rel.rstrip("/").split("/")
    return parts[-2] if parts[-1] == "v0" else parts[-1]

def main():
    # The last guard to take the lock, and the one that needed it most: this is
    # the heaviest reader in the repo — it stages every realm and runs the suite
    # once per test — so the window in which a selftest could rewrite a source
    # underneath it is minutes wide rather than seconds. A test broken on purpose
    # by another gate would be reported here as an isolation failure, which is a
    # false finding in a guard whose whole output is a list of suspect tests.
    repolock.refuse_if_held("check-isolation")
    if not gnoroot.real_root():
        if os.environ.get("REQUIRE_GNO"):
            print("check-isolation: gno not installed", file=sys.stderr)
            return 1
        print("check-isolation: gno not installed - skipping")
        return 0

    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]
    # --slow is the one-process-per-test path this guard used before
    # harness/isolation existed. It is kept reachable, not as a fallback — the
    # fast path is the path — but because two independent ways of running a
    # test alone are worth more than one: if the fast path ever disagrees with
    # `gno test -run`, this is how the disagreement is shown.
    slow = "--slow" in sys.argv
    # --pkgs kourtv3,ccwrap sweeps only those packages (everything is still
    # STAGED, because imports need it; only the work list shrinks). --shard k/n
    # keeps every n-th test starting at k, so n sweeps in n processes cover the
    # whole list between them. Both exist for one reason: the full sweep is the
    # slowest gate in the repo, and a commit that touches one realm does not
    # change what the frozen ones do alone. A partial sweep is a partial
    # verdict — the summary line names the packages and the shard it covered,
    # so nobody reads its "all N pass" as the whole tree.
    pkgs = None
    if "--pkgs" in sys.argv:
        pkgs = set(sys.argv[sys.argv.index("--pkgs") + 1].split(","))
        known = {pkgname(rel) for _, rel in REALMS}
        if pkgs - known:
            raise SystemExit(f"check-isolation: --pkgs names nothing staged: {sorted(pkgs - known)}")
    shard_k, shard_n = 0, 1
    if "--shard" in sys.argv:
        k, n = sys.argv[sys.argv.index("--shard") + 1].split("/")
        shard_k, shard_n = int(k), int(n)
        if not (shard_n > 0 and 0 <= shard_k < shard_n):
            raise SystemExit("check-isolation: --shard wants k/n with 0 <= k < n")

    work = []
    idx = 0
    for src, rel in REALMS:
        if pkgs and pkgname(rel) not in pkgs:
            continue
        names = []
        for f in sorted(os.listdir(src)):
            if f.endswith("_test.gno"):
                names += re.findall(r"^func (Test\w+)",
                                    open(os.path.join(src, f)).read(), flags=re.M)
        if only:
            names = [n for n in names if re.search(only, n)]
        kept = []
        for n in names:
            if idx % shard_n == shard_k:
                kept.append(n)
            idx += 1
        names = kept
        if names:
            work.append((rel, names))
    if not work:
        where = f" matching {only}" if only else ""
        print(f"check-isolation: no tests found{where}, which is itself wrong",
              file=sys.stderr)
        return 1

    bad, total = [], 0
    red = set()   # (pkg, test) pairs that fail WITH their package too
    rered = []    # packages whose suite is red as a whole
    never = []    # (pkg, test) whose -run filter selected nothing at all
    with gnoroot.shadow("check-isolation") as root:
        gnoroot.stage(root, REALMS)
        # The together-run comes FIRST, and unconditionally. It used to run only
        # for packages that had already produced a per-test failure, which meant
        # the success line — "pass alone as well as together" — asserted a thing
        # the guard had never once checked when everything passed alone. A slug
        # collision between two tests is invisible test-by-test and fails the
        # suite instantly; that is exactly what slipped through. One `gno test`
        # per package, alongside the one runner process per package the alone
        # loop now costs: the together-run is the cheaper half.
        for rel, names in work:
            r = subprocess.run(["gno", "test", "."], cwd=os.path.join(root, rel),
                               capture_output=True, text=True,
                               env={**os.environ, "GNOROOT": root})
            if r.returncode != 0:
                out = r.stdout + r.stderr
                rered.append((rel, out.strip().split("\n")))
                for t in names:
                    if f'failed: "{t}"' in out or f"--- FAIL: {t}" in out:
                        red.add((rel, t))
        if slow:
            for rel, names in work:
                base = os.path.join(root, rel)
                for t in names:
                    total += 1
                    # `-v` IS LOAD-BEARING, not noise. `gno test -run` exits 0 when
                    # the filter matches NOTHING, and without -v the output is
                    # identical to a pass — filetests run regardless, so a name that
                    # selects no test still prints its GAS lines and then `ok`. This
                    # loop reads only the return code, so such a test would be
                    # counted in `total` and asserted to "pass alone" having never
                    # run: the same non-result-as-result this file was already bitten
                    # by once (see the together-run comment above). `=== RUN` is the
                    # only discriminator, and -v is what prints it.
                    r = subprocess.run(["gno", "test", "-run", f"^{t}$", "-v", "."],
                                       cwd=base, capture_output=True, text=True,
                                       env={**os.environ, "GNOROOT": root})
                    out = r.stdout + r.stderr
                    if r.returncode != 0:
                        bad.append((rel, t, out.strip().split("\n")))
                    elif not re.search(r"^=== RUN\s+%s\b" % re.escape(t), out, re.M):
                        never.append((rel, t))
        else:
            # The fast path: harness/isolation, built here into the shadow root so
            # the binary dies with it and can never be a stale one from another
            # checkout. A Go toolchain is required for this — `make toolchain`
            # already assumes one to build gno itself, so that is not a new
            # demand, but it is said out loud when it is missing.
            runner = os.path.join(root, "isolation-runner")
            b = subprocess.run(["go", "build", "-o", runner, "./harness/isolation"],
                               cwd=REPO, capture_output=True, text=True)
            if b.returncode != 0:
                print("check-isolation: cannot build harness/isolation (a Go "
                      "toolchain is now required; make toolchain already assumes "
                      "one)", file=sys.stderr)
                print(b.stderr, file=sys.stderr)
                return 1
            # One RESULT line per test the runner ran, in the runner's stable
            # form; the tab-prefixed lines that follow a FAIL are what the test
            # printed. A local pattern rather than a module-level one on purpose:
            # check-guards-blind blinds every module-level NAME = re.compile(...)
            # to prove the guard notices, and this guard cannot run under it.
            result_line = re.compile(r"^RESULT\t(\w+)\t(PASS|FAIL|SKIP)\t(\d+)$")
            summary_line = re.compile(r"^SUMMARY\t.*\tload_ms=(\d+)\ttests_ms=(\d+)$")
            sweep_t0 = time.time()
            for rel, names in work:
                base = os.path.join(root, rel)
                total += len(names)
                t0 = time.time()
                # THE FILTER IS THE GUARD'S OWN, and it is the hole the NEVER
                # classification below exists for: a filter that selects nothing
                # runs nothing and exits 0, exactly as `gno test -run` does, so
                # the only evidence a test ran is its RESULT line. Every name
                # harvested above must produce one.
                r = subprocess.run([runner, "-root", root, "-pkg", base, "-run",
                                    "^(" + "|".join(map(re.escape, names)) + ")$"],
                                   capture_output=True, text=True,
                                   env={**os.environ, "GNOROOT": root})
                if r.returncode not in (0, 1):
                    # Exit 2 is "could not load this package the way gno test
                    # does" — a type error, a refused shape, a missing import —
                    # and anything else is a crash. Either way no test of the
                    # package ran, so every one of them is reported with the
                    # runner's message. That reproduces what the per-process path
                    # did for an unbuildable package (every spawn failed), and
                    # the together-run above is red for the same package, so the
                    # SUITE line names the cause.
                    err = (r.stderr + r.stdout).strip().split("\n")
                    for t in names:
                        bad.append((rel, t, err))
                    continue
                seen, load_ms = {}, 0
                cur = None
                for line in r.stdout.split("\n"):
                    m = result_line.match(line)
                    if m:
                        cur = [m.group(2), []]
                        seen[m.group(1)] = cur
                    elif line.startswith("\t") and cur is not None:
                        cur[1].append(line[1:])
                    else:
                        cur = None
                        m = summary_line.match(line)
                        if m:
                            load_ms = int(m.group(1))
                for t in names:
                    if t not in seen:
                        never.append((rel, t))
                    elif seen[t][0] == "FAIL":
                        bad.append((rel, t, seen[t][1]))
                took = time.time() - t0
                per = (took - load_ms / 1000) * 1000 / max(len(names), 1)
                print(f"check-isolation: {pkgname(rel)} {len(names)} tests "
                      f"alone in {took:.1f}s (load {load_ms / 1000:.1f}s, "
                      f"{per:.0f}ms/test)", file=sys.stderr)
            print(f"check-isolation: alone loop {time.time() - sweep_t0:.1f}s across "
                  f"{len(work)} packages", file=sys.stderr)

    alone = [(rel, t, out) for rel, t, out in bad if (rel, t) not in red]
    broken = [(rel, t, out) for rel, t, out in bad if (rel, t) in red]
    # THE EXCERPT DROPS GAS LINES, and until it did this printed nothing useful.
    # `gno test -v` emits one "--- GAS:" line per crossing call, and they come
    # FIRST — measured on a single-test run of this realm, the first four lines of
    # output were four gas numbers and nothing else. So a flat four-line slice, on
    # the tool BRANCHING.md sends people to for "the real error", showed four
    # integers and hid the uassert message three lines below them. The same defect
    # bit twice in one programme: a scratch runner kept a last-4000-characters
    # window that these very lines flooded.
    def excerpt(out, n=8):
        keep = [l for l in out if not l.lstrip().startswith("--- GAS:")]
        return (keep or out)[:n]

    for rel, t, out in broken:
        print(f"BROKEN  {t} ({os.path.basename(rel)}) fails alone AND with its "
              f"package — an ordinary failure, not an isolation problem")
        for line in excerpt(out):
            print(f"        {line}")
    for rel, t, out in alone:
        print(f"ALONE   {t} ({os.path.basename(rel)}) fails when it is the only "
              f"test that runs, but passes with its package")
        for line in excerpt(out):
            print(f"        {line}")
    unattributed = [(rel, out) for rel, out in rered
                    if not any(rl == rel for rl, _ in red)]
    for rel, out in unattributed:
        print(f"SUITE   {os.path.basename(rel)} fails as a whole with no single "
              f"test to blame — the package dies before any test's own marker "
              f"prints. A slug collision or a package-level panic looks like this.")
        for line in excerpt(out):
            print(f"        {line}")
    for rel, t in never:
        print(f"NEVER   {t} ({os.path.basename(rel)}) was selected by no test — "
              f"`gno test -run ^{t}$` ran zero tests and exited 0, so this test "
              f"would have been counted as passing alone without running. The name "
              f"is harvested from the source, so either it is not a test the runner "
              f"recognises or -run's matching has changed.")
    if bad or unattributed or never:
        if never:
            print(f"\n{len(never)} of {total} tests never ran at all. That is worse "
                  f"than a failure: the summary line below counts them as passing.")
        if alone:
            print(f"\n{len(alone)} of {total} tests pass only in company. A test "
                  f"that needs its neighbours is reporting on their state, not on "
                  f"the thing it names.")
        if broken:
            print(f"{len(broken)} of {total} tests fail either way. Fix those "
                  f"first: a red suite tells you nothing about isolation.")
        if unattributed:
            print(f"{len(unattributed)} package suite(s) are red as a whole. Fix "
                  f"those first: a red suite tells you nothing about isolation.")
        return 1
    scope = ""
    if pkgs or shard_n > 1:
        scope = " (PARTIAL sweep:" + (f" packages {','.join(sorted(pkgs))}" if pkgs else "") \
                + (f" shard {shard_k}/{shard_n}" if shard_n > 1 else "") + ")"
    print(f"all {total} tests across {len(work)} packages pass alone as well as "
          f"together.{scope}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
