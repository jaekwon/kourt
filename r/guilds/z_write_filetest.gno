// PKGPATH: gno.land/r/kourt/writeguilds
package writeguilds

// WHAT A BINDING COSTS, and the event that is its only public record.
//
// A None budget cannot reach any of this: Set is a write, so the read filetest
// beside this one is barred by construction from covering the thing the realm is
// for. This file opens a court and binds a server to it, so the ceiling in
// check-storage.py is over a real binding rather than over nothing.
//
// THE EVENT IS THE RECORD. Nothing else on chain says who chose a court's
// Discord server or when — the tree holds the current answer and no history —
// so an indexer, and anybody auditing a court after the fact, has this and only
// this. A change that dropped the "by" attribute would leave the page working
// and the audit trail gone, which is exactly the failure a filetest sees and a
// unit test does not.

import (
	"gno.land/r/kourt/guilds"
	"gno.land/r/kourt/kourtv2"
)

func main(cur realm) {
	// The courts have to exist and this caller has to moderate them — the first
	// court's creator is its admin, and IsCourtMod answers for the admin before
	// any moderator set materialises.
	kourtv2.StartCourt(cross(cur), "covid", "COVID")
	kourtv2.StartCourt(cross(cur), "atomone", "AtomOne")
	guilds.Set(cross(cur), "covid", "1550279172088143883")
	guilds.Set(cross(cur), "atomone", "1478455953715236886")
	println("covid:  ", guilds.GuildOf("covid"))
	_, setter := guilds.Chosen("covid")
	println("set by: ", setter != "")
	println("courts: ", len(guilds.Courts()))
	// TWO, not one, because the ceiling has to be over a per-court cost rather
	// than over the tree's first node — a binding that grew from tens of bytes
	// to hundreds would sit inside a one-court measurement unnoticed.
	//
	// And taking one away leaves nothing behind for the service to reconcile:
	// the court LEAVES the list rather than sitting in it with an empty id.
	guilds.Set(cross(cur), "atomone", "")
	println("cleared:", guilds.GuildOf("atomone") == "", len(guilds.Courts()))
}

// Output:
// covid:   1550279172088143883
// set by:  true
// courts:  2
// cleared: true 1

// Events:
// [
//   {
//     "type": "GuildSet",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "covid"
//       },
//       {
//         "key": "guild",
//         "value": "1550279172088143883"
//       },
//       {
//         "key": "by",
//         "value": "g1jmqe6pnath6pszw5a2urcdk8dfthuucm28tjgd"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/guilds"
//   },
//   {
//     "type": "GuildSet",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "atomone"
//       },
//       {
//         "key": "guild",
//         "value": "1478455953715236886"
//       },
//       {
//         "key": "by",
//         "value": "g1jmqe6pnath6pszw5a2urcdk8dfthuucm28tjgd"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/guilds"
//   },
//   {
//     "type": "GuildCleared",
//     "attrs": [
//       {
//         "key": "court",
//         "value": "atomone"
//       },
//       {
//         "key": "by",
//         "value": "g1jmqe6pnath6pszw5a2urcdk8dfthuucm28tjgd"
//       }
//     ],
//     "pkg_path": "gno.land/r/kourt/guilds"
//   }
// ]
