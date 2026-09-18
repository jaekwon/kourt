// PKGPATH: gno.land/r/kourt/readguilds
package readguilds

// guilds' read surface, from OUTSIDE the package, budgeted at None in
// check-storage.py — it must write nothing at all.
//
// The defect that budget guards against is a query that lazily ALLOCATES: the
// object is thrown away with the query and the only symptom is storage that
// grows on reads, months later, under load. Two of those had already happened in
// kourtv3 and both were found by hand rather than by a gate.
//
// It matters more here than the size of this realm suggests. kourt.xyz asks
// GuildOf for every court on every reconcile, forever, for courts that have
// never chosen a server — so the "not found" path is the hot one, and the one
// where a lazily-created empty node would be invisible and permanent.

import (
	"gno.land/r/kourt/guilds"
)

func main(cur realm) {
	// A fresh deploy: nothing has been chosen, and asking must not create it.
	println("guild(covid):  [" + guilds.GuildOf("covid") + "]")
	println("guild(absent): [" + guilds.GuildOf("no-such-court") + "]")
	println("guild(empty):  [" + guilds.GuildOf("") + "]")
	_, setter := guilds.Chosen("covid")
	println("setter(covid): [" + setter + "]")
	println("courts:        ", len(guilds.Courts()))
	println("renders:       ", len(guilds.Render("")) > 0)
	println("says so:       ", guilds.Render("") != guilds.Render("anything"))
}

// Output:
// guild(covid):  []
// guild(absent): []
// guild(empty):  []
// setter(covid): []
// courts:         0
// renders:        true
// says so:        false
