#!/usr/bin/env python3
"""Reading Gno source the way a guard needs to read it.

Not a guard. A guard is `check-*.py`, is named in selftest-checks.py, and is run
by a target; this is a library three of them share, the way repolock.py is.

WHY IT EXISTS. strip_comments was written three times in one sitting -- in
check-interrealm, check-getcoins and check-inert-flags -- and the three copies
had ALREADY diverged before anybody read them together: two spelled the quote
set `"\\"'`"` and the third `'"\\'`'`. That divergence happened to be cosmetic.
The next one would not announce itself, and a guard that mis-reads a comment as
code fails in the direction that looks like success.
"""


def strip_comments(src):
    """Comment text out, code left in place, string literals respected.

    WITHOUT THIS A GUARD READS PROSE AS CODE, and every guard here has been
    caught by it. kourtv1/buy.gno carries the sentence "flags is
    unsafe.PreviousRealm (which skips frame verification) -- NOT this", a
    comment saying the code does NOT do the thing, which a naive scan reported
    as doing the thing. buy.gno documents the GetCoins rule in a comment that
    names GetCoins. And "Unequal on purpose:" in a test reads as a
    composite-literal write of a field called `purpose`.

    STRING LITERALS ARE TRACKED, NOT MERELY SKIPPED. A `//` inside a quoted URL
    would otherwise swallow the rest of the line, hiding real code from the
    guard -- and that failure is SILENT, which is the one direction a guard must
    never fail in. Raw backtick strings take no escapes, hence the `q != "`"`.
    """
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'`":
            q = c
            out.append(c)
            i += 1
            while i < n:
                if src[i] == "\\" and q != "`":
                    out.append("  ")
                    i += 2
                    continue
                out.append(src[i])
                if src[i] == q:
                    i += 1
                    break
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            # Keep the newlines so line numbers downstream stay true.
            out.append("\n" * src[i:j].count("\n"))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def realm_files(root):
    """Every non-vendored .gno file in the tree, as sorted pathlib Paths.

    WHY A HELPER AND NOT `root.rglob("*.gno")`. Four guards scanned the whole
    repository from its root, which was harmless while the realms sat under a
    single `realm/` directory and became two bugs the moment they did not:

    IT WALKS INTO THINGS THAT ARE NOT THE REALM. The root now also holds
    harness/, scenarios/ and docs/, so a .gno fixture committed under any of them
    would be scanned as if it were deployed code -- and a guard that reports a
    violation in a fixture is a guard people learn to ignore.

    AND IT MISSES THE REALM ENTIRELY UNDER A SYMLINK. check-guards-blind proves a
    guard still fails when blinded by running it from a SHADOW: a temporary
    directory whose top-level entries are symlinks back to the real tree. pathlib
    does not descend into a symlinked directory while globbing, so `ROOT.rglob`
    from that shadow matched nothing -- and every one of the four then reported
    the tree CLEAN. Four guards proving nothing, each of them announcing success.
    Naming the two package roots means the glob starts AT the symlink rather than
    having to cross one, which pathlib is happy to do.
    """
    out = []
    for kind in ("r", "p"):
        out.extend((root / kind).rglob("*.gno"))
    return sorted(out)
