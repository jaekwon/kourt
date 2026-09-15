#!/usr/bin/env python3
"""A guard must fail when its own detection stops working.

    python3 scripts/check-guards-blind.py

THE FAILURE THIS CATCHES, and why the existing lanes do not. selftest-checks.py
breaks the TREE and requires the guard to fire, which proves the guard catches a
violation. vacuity_audit() requires the expected output not to be something the
guard prints anyway, which proves the arm discriminates. Neither asks the third
question: if the guard's own pattern stops matching — a reformat, a rename, a
regex edited one character too far — does it fail, or does it scan nothing, find
nothing, and report success?

Measured when this was written: nineteen guards failed loudly, two did not.
check-tdz and check-mark-font both exited 0 with their detection blinded, and
check-tdz is the only thing standing between a reordered declaration and a blank
page — the browser enforces that ordering and no source harness can see it. A
version that silently stops looking is worse than none, because the suite goes on
reporting the ordering as verified. Both now floor their census; this is what
stops the next one regressing the same way.

HOW IT WORKS. For each guard with a module-level `NAME = re.compile(r"...")`,
rewrite that one pattern to something that cannot match, run the guard, and
require a non-zero exit. The edit is made on a COPY under a temporary directory;
the tree is never written to, which matters because an earlier hand-run of this
same idea left a guard blinded in the working tree when it timed out.

GUARDS WITH NO SINGLE NAMED PATTERN are reported, not failed. Several build
their matcher inline or hold several equal patterns, and blinding one of those
proves nothing either way.
"""
import io
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"

# Guards this cannot run: they need a chain, a gno toolchain, or they rewrite the
# tree themselves. Named with the reason so the list cannot quietly grow.
SKIP = {
    "check-live-reads": "queries a running node",
    "check-isolation": "runs the realm suite once per test, tens of minutes",
    "check-mutation-scope": "drives mutate.py over the corpus",
    "check-mutant-collisions": "drives mutate.py over the corpus",
    "check-guards-blind": "this file",
}

# Split from its compile so a control arm can blind it with a plain-ASCII
# anchor. The regex contains both quote characters and several backslashes,
# and an arm quoting all of that inside a Python string got one escape wrong
# and planted nothing — check-control-anchors caught it, which is what that
# guard is for.
# `\s*` rather than nothing between the paren and the quote, because a pattern
# long enough to wrap is still a named pattern. Measured: check-seed-assets and
# check-block-time were skipped as "no single named pattern" purely because
# re.compile( ended their line -- and check-seed-assets is the only unverified
# guard that DISCOVERS its work (LINE.finditer) rather than walking a declared
# table, so it is the only one that can go quiet by drift instead of by somebody
# emptying a list on purpose.
PATTERN_SRC = r"^([A-Z][A-Z_0-9]*)\s*=\s*re\.compile\(\s*(r['\"])"
PATTERN = re.compile(PATTERN_SRC, re.M)
TIMEOUT = 180


def blind(src, sym):
    """Replace one named pattern's regex with one that cannot match."""
    return re.sub(r"^(%s\s*=\s*re\.compile\(\s*)r(['\"]).*?\2" % re.escape(sym),
                  lambda m: m.group(1) + 'r"ZZ_BLINDED_NEVER_MATCHES_ZZ"',
                  src, count=1, flags=re.M | re.S)


def main():
    quiet, loud, skipped, nopat, slow, broken = [], [], [], [], [], []
    work = tempfile.mkdtemp(prefix="kourt-blind-")
    try:
        for p in sorted(SCRIPTS.glob("check-*.py")):
            name = p.stem
            if name in SKIP:
                skipped.append(name)
                continue
            src = io.open(p, encoding="utf-8").read()
            # EVERY named pattern, not just the first. A guard's first pattern is
            # usually what it ENUMERATES -- functions, structs, files -- so
            # blinding it empties the census and the floor fires. The patterns
            # that DETECT the violation come later, and blinding one of those
            # leaves the census healthy and finds nothing. Blind AUTHORITY in
            # check-interrealm and it still reports "175 function(s) take a realm
            # parameter"; it just never notices one that trusts a realm value it
            # never proved. 21 guards hold more than one pattern.
            syms = [m.group(1) for m in PATTERN.finditer(src)]
            if not syms:
                nopat.append(name)
                continue
            # A SHADOW REPO OF SYMLINKS, not a loose file in a temp dir. Every
            # guard finds the tree with ROOT = Path(__file__).parent.parent, so a
            # copy sitting anywhere else looks for realm/ beside itself, finds
            # nothing, and exits non-zero for a reason that has nothing to do
            # with blinding. Measured: ALL 24 guards died that way, and every one
            # was being counted as proof the check worked. The tree itself is
            # still never written to.
            shadow = os.path.join(work, name)
            os.makedirs(os.path.join(shadow, "scripts"), exist_ok=True)
            for entry in os.listdir(ROOT):
                if entry == "scripts":
                    continue
                link = os.path.join(shadow, entry)
                if not os.path.lexists(link):
                    os.symlink(os.path.join(ROOT, entry), link)
            for entry in os.listdir(SCRIPTS):
                link = os.path.join(shadow, "scripts", entry)
                if not os.path.lexists(link):
                    os.symlink(os.path.join(SCRIPTS, entry), link)
            tmp = os.path.join(shadow, "scripts", name + ".py")
            os.remove(tmp)                      # drop the symlink; a real file replaces it
            ctlpath = os.path.join(shadow, "scripts", "_control_" + name + ".py")
            io.open(ctlpath, "w", encoding="utf-8").write(src)
            # scripts/ ON THE PATH, because a guard that cannot import is not a
            # guard that noticed anything. Measured: 14 of 24 were dying on
            # `import repolock`/`mutate`/`gnosource`, read as detection.
            env = dict(os.environ, PYTHONPATH=os.path.join(shadow, "scripts"))
            # THE CONTROL, once per guard: if the UNBLINDED copy does not pass
            # from here, nothing the blinded copies do afterwards says anything
            # about blinding.
            try:
                ctl = subprocess.run([sys.executable, ctlpath], cwd=str(ROOT),
                                     capture_output=True, timeout=TIMEOUT, env=env)
            except subprocess.TimeoutExpired:
                slow.append(name)
                continue
            if ctl.returncode != 0:
                broken.append((name, ctl.stderr.decode("utf-8", "replace")
                               .strip().split("\n")[-1][:60]))
                continue
            for sym in syms:
                out = blind(src, sym)
                if out == src:
                    nopat.append("%s (%s)" % (name, sym))
                    continue
                io.open(tmp, "w", encoding="utf-8").write(out)
                try:
                    rc = subprocess.run([sys.executable, tmp], cwd=str(ROOT),
                                        capture_output=True, timeout=TIMEOUT,
                                        env=env).returncode
                except subprocess.TimeoutExpired:
                    slow.append("%s (%s)" % (name, sym))
                    continue
                (quiet if rc == 0 else loud).append("%s (%s)" % (name, sym))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if broken:
        print("check-guards-blind: %d guard(s) cannot even RUN from a copy, so "
              "blinding them proves nothing.\n" % len(broken), file=sys.stderr)
        for n, why in broken:
            print("  %-34s %s" % (n, why), file=sys.stderr)
        print("\nThey are reported, not counted. Until the copy runs, a non-zero exit "
              "is\na crash and not a catch.", file=sys.stderr)

    for name in slow:
        print("  %-34s timed out at %ds; blinding it proves nothing"
              % (name, TIMEOUT), file=sys.stderr)

    if quiet:
        print("check-guards-blind: %d guard(s) report success with their own detection "
              "blinded.\n" % len(quiet), file=sys.stderr)
        for n in quiet:
            print("  %s" % n, file=sys.stderr)
        print("\nEach scans nothing, finds nothing, and exits 0. Floor the census the way\n"
              "check-spend-paths.py does — zero sites means the pattern broke, not that\n"
              "the tree is clean.", file=sys.stderr)
        return 1

    print("check-guards-blind: %d guard(s) fail when blinded, %d could not run from a "
          "copy, %d have no single named pattern to blind, %d skipped."
          % (len(loud), len(broken), len(nopat), len(skipped)))
    if not loud:
        print("check-guards-blind: blinded no guard at all, so this check is scanning "
              "for a shape scripts/ no longer has.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
