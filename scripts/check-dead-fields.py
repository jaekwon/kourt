#!/usr/bin/env python3
"""A struct field nothing reads or writes is storage nobody asked for.

    python3 scripts/check-dead-fields.py

WHY THIS IS NOT MERELY TIDINESS. These structs persist. A field that is written
and never read is a storage deposit paid at every write, forever, for a value no
caller can observe; a field that is neither written nor read is a claim in the
source that the realm tracks something it does not. Both mislead a reader of the
struct, which is the first thing anyone reads.

WHAT IT DOES NOT CATCH, said plainly so nobody reads more into a pass than is
there: this finds fields mentioned NOWHERE outside their declaration. A field
that is assigned once and never read afterwards still costs the deposit, and a
name-based scan cannot tell that from a legitimate write. Use it as a floor, not
a proof.

THREE WAYS THIS SCAN WAS WRONG BEFORE IT WAS RIGHT, each of which made it report
FEWER dead fields than there were -- the failure direction that looks like a
pass:

  1. Unexported fields were searched across the whole tree, so an unrelated field
     of the same name in another realm vouched for a dead one. kourtv1's `parent`
     hid behind kourtv2's board `parent` for exactly this reason. An unexported
     field can only be touched inside its own package, so that is where to look.
  2. The struct-body walk stopped at a column-zero `}`, which a one-line
     `struct{}` never has -- so it ran on into the functions below and read
     `return out` as a field named `return`. Brace depth ends a struct; a
     guessed-at brace does not.
  3. The field pattern could not match a line with a trailing comment, because
     the type part cannot span `// 0 = top-level; a folder-claim's ...`. Every
     DOCUMENTED field was therefore skipped in silence. Fixing it took the census
     from 285 to 504 -- the scan had been ignoring nearly half the struct fields
     in the repo while reporting success.

The census floor below exists because of #3. A scan that quietly stops examining
things reports a clean tree indefinitely.
"""
import io
import gnosource
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import repolock
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent
REALM = ROOT

# STRUCT first on purpose: check-guards-blind.py blinds the first named pattern
# it finds, and blinding this one takes the census to zero, which the floor
# turns into a failure. A guard that cannot see is a guard that must not pass.
STRUCT = re.compile(r"^type\s+(\w+)\s+struct\s*\{", re.M)
FIELD = re.compile(r"^([a-zA-Z]\w*(?:\s*,\s*[a-zA-Z]\w*)*)\s+[\w\*\[\]\.\{\}\s]+$")
TRAILING_COMMENT = re.compile(r"\s*//.*$")

# Set to whatever the scan legitimately cannot fix. r/kourtv1 is
# behaviourally frozen (BRANCHING.md): its tests may be fixed, its source may
# not be rewritten for tidiness. These two are a folder feature that was
# declared and never built; kourtv2 shipped folders differently, in folders.gno.
# They are dead, they are known, and the freeze outranks the cleanup.
ALLOWED = {
    ("r/kourtv1/claim.gno", "claimState", "parent"),
    ("r/kourtv1/claim.gno", "claimState", "isFolder"),
}

# Below this, assume the patterns broke rather than that the repo shrank.
#
# RE-MEASURED WHEN kourtv3 WAS COPIED FROM kourtv2. Two realm generations double
# the struct census: 504 fields before the copy, 848 after. The floor exists to
# catch a blinded comment-stripper, and blinded the scan still finds 492 of the
# 848 — above the old 400, so the doubled tree let a blind guard pass and
# check-guards-blind said so. 700 sits between the blinded 492 and the honest
# 848 with room either way; retire a generation and this number comes back down
# with it, and the reason is written here so it is not mistaken for a target.
CENSUS_FLOOR = 700


def is_test(p):
    return p.name.endswith(("_test.gno", "_filetest.gno"))


def fields_of(text, lines, m):
    """Yield (lineno, name) for one struct, ending at its matching brace."""
    start = text[: m.start()].count("\n")
    depth = lines[start].count("{") - lines[start].count("}")
    in_block = False
    for i in range(start + 1, len(lines)):
        if depth <= 0:
            return
        line = lines[i]
        depth += line.count("{") - line.count("}")
        s = line.strip()
        # `/* ... */` prose inside a struct body reads exactly like `name type`.
        # Three fields named `rather`, `docket` and `the` came from not doing this.
        if in_block:
            in_block = "*/" not in s
            continue
        if s.startswith("/*"):
            in_block = "*/" not in s
            continue
        if not line.startswith("\t") or s.startswith("//") or not s:
            continue
        s = TRAILING_COMMENT.sub("", s).rstrip()
        if not s:
            continue
        fm = FIELD.match(s)
        if not fm:
            continue
        for name in (x.strip() for x in fm.group(1).split(",")):
            yield i + 1, name


def main():
    # selftest rewrites these very sources in place; reading them
    # mid-plant invents findings out of somebody else's control.
    repolock.refuse_if_held("check-dead-fields")

    files = [(p, io.open(p, encoding="utf-8").read()) for p in sorted(gnosource.realm_files(REALM))]
    everything = "\n".join(t for _, t in files)
    by_pkg = defaultdict(str)
    for p, t in files:
        by_pkg[p.parent] += "\n" + t

    census, dead = 0, []
    for p, text in files:
        if is_test(p):
            continue
        lines = text.split("\n")
        rel = str(p.relative_to(REALM))
        for m in STRUCT.finditer(text):
            for lineno, name in fields_of(text, lines, m):
                census += 1
                # Exported fields are reachable from any package; unexported ones
                # are not, and searching wider than the language allows is how a
                # dead field acquires a false witness.
                hay = everything if name[0].isupper() else by_pkg[p.parent]
                used = len(re.findall(r"\.%s\b" % re.escape(name), hay))
                used += len(re.findall(r"\b%s:\s" % re.escape(name), hay))
                if used == 0 and (rel, m.group(1), name) not in ALLOWED:
                    dead.append((rel, lineno, m.group(1), name))

    if dead:
        print("check-dead-fields: %d struct field(s) that nothing reads or writes.\n"
              % len(dead), file=sys.stderr)
        for rel, lineno, struct, name in sorted(dead):
            print("  %s:%d  %s.%s" % (rel, lineno, struct, name), file=sys.stderr)
        print("\nEither the field is wanted and something should use it, or it is not and\n"
              "the struct should not carry it. If it is genuinely frozen, add it to\n"
              "ALLOWED with the reason, the way kourtv1's two are.", file=sys.stderr)
        return 1

    if census < CENSUS_FLOOR:
        print("check-dead-fields: examined only %d field(s), below the floor of %d. The\n"
              "repo did not halve; the patterns stopped matching. See bug #3 in this\n"
              "file's docstring -- that is exactly how this failed before, and it\n"
              "reported a clean tree the whole time." % (census, CENSUS_FLOOR),
              file=sys.stderr)
        return 1

    print("check-dead-fields: %d struct field(s) examined, every one read or written "
          "somewhere (%d frozen exception(s) allowed)." % (census, len(ALLOWED)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
