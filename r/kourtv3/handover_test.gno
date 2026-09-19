package kourtv3

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE DEPLOYER'S SEATS ALL MOVE AT ONCE, and the old key is refused everywhere
// afterwards — handover.gno says why one verb. The package run founds meta at
// init with the test's origin caller, which makes that caller directoryAdmin
// and the DAO admin, exactly as AddPackage does on a chain; this hands over
// from there and hands BACK at the end, so neighbours meet the admin they
// expect and the hand-over's repeatability is exercised rather than asserted.
func TestHandOverMovesEverySeatTheDeployerHolds(cur realm, t *testing.T) {
	// In a package run the first founder becomes directoryAdmin, so found one
	// court and then ASK who the admin is — alone it is this founder, in
	// company it is whoever founded first — and give that admin a court of
	// their own to stand where meta stands on a chain (init's founding is not
	// part of a gno test run).
	first := testutils.TestAddress("ho-first")
	testCourt(cur, "hofirst", first, 1_000_000)
	admin := ensureGlobalDAO().admin
	heir := testutils.TestAddress("ho-heir")
	other := testutils.TestAddress("ho-other")
	stranger := testutils.TestAddress("ho-stranger")
	testCourt(cur, "hoadmin", admin, 1_000_000)
	testCourt(cur, "hoother", other, 1_000_000) // founded by somebody else: not the deployer's to hand over
	if DirectoryAdmin() != admin || mustCourt("hoadmin").admin != admin {
		t.Fatalf("setup: the admin founds hoadmin and is directoryAdmin: %s / %s / %s",
			admin, DirectoryAdmin(), mustCourt("hoadmin").admin)
	}
	ensureMod(mustCourt("hoadmin")) // a live moderator set, so the seat move is exercised on one
	if !IsCourtMod("hoadmin", admin) || IsCourtMod("hoadmin", heir) {
		t.Fatal("setup: the creator is the court's 1-of-1 moderator and the heir is not")
	}

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the global DAO admin hands over", func() {
		HandOver(cross(cur), heir)
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.AbortsContains(t, cur, "hand over to a different address", func() {
		HandOver(cross(cur), admin)
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.AbortsContains(t, cur, "not a valid address", func() {
		HandOver(cross(cur), address("nope"))
	})

	testing.SetRealm(testing.NewUserRealm(admin))
	HandOver(cross(cur), heir)

	if DirectoryAdmin() != heir {
		t.Fatalf("DirectoryAdmin must follow the seat: %s", DirectoryAdmin())
	}
	if ensureGlobalDAO().admin != heir {
		t.Fatalf("the DAO admin seat must move: %s", ensureGlobalDAO().admin)
	}
	if isGlobalMod(admin) {
		t.Fatal("the old key must not keep a DAO vote after handing over")
	}
	if !isGlobalMod(heir) {
		t.Fatal("the heir must be seated in the DAO")
	}
	if c := mustCourt("hoadmin"); c.admin != heir || !IsCourtMod("hoadmin", heir) || IsCourtMod("hoadmin", admin) {
		t.Fatalf("the founded court's creator and moderator seats must move: admin=%s heirMod=%v oldMod=%v",
			c.admin, IsCourtMod("hoadmin", heir), IsCourtMod("hoadmin", admin))
	}
	if mustCourt("hoother").admin != other {
		t.Fatal("a court founded by another is not the deployer's to hand over")
	}
	// The old key is refused at a global gate; the heir is accepted at the same one.
	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.AbortsContains(t, cur, "only the global DAO admin sets the burn share", func() {
		SetBurnBps(cross(cur), burnBpsInit)
	})
	testing.SetRealm(testing.NewUserRealm(heir))
	SetBurnBps(cross(cur), burnBpsInit)

	// And back, which is also the proof it is repeatable.
	testing.SetRealm(testing.NewUserRealm(heir))
	HandOver(cross(cur), admin)
	if DirectoryAdmin() != admin || ensureGlobalDAO().admin != admin || !IsCourtMod("hoadmin", admin) || isGlobalMod(heir) || IsCourtMod("hoadmin", heir) {
		t.Fatal("handing back must restore every seat and unseat the heir")
	}
}
