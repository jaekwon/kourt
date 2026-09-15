package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

/* THE LAST TWO UNTESTED TRANSACTION ENTRY POINTS. Of 121 exported crossing
   functions in this realm, SetMediaHosts and ClearMediaHosts were the only pair
   no test or filetest ever called. Their SUBSTANCE was covered -- media_test.gno
   exercises parseMediaHosts, mediaHostAllowed and mirrorFault -- but the seat
   that may call them was not. Weakening the admin comparison in either one would
   have passed the whole suite.

   That matters more here than the arithmetic does. SetMediaHosts is the host
   kill switch: it decides where a claim's evidence may be mirrored, it takes
   effect on every existing claim at the next render, and check-media-hosts.py
   only verifies that the realm, the overlay and the CSP AGREE about the list --
   never who is allowed to change it.

   ONLY REFUSALS ARE ASSERTED THROUGH A CLOSURE, for the harness reason
   courtburn_test.gno sets out at length: a caller override does not survive into
   the closure uassert.AbortsContains takes, so an authorized call written that
   way arrives as somebody else and the admin guard fires first -- the assertion
   would pass for the wrong reason. The both-blank refusal inside SetMediaHosts
   needs an ADMIN caller to reach it, so it is deliberately not asserted here
   rather than asserted falsely. */

func TestMediaHostSettersAreAdminOnly(cur realm, t *testing.T) {
	// READ FROM THE GATE'S OWN SOURCE, as courtburn_test.gno does:
	// ensureGlobalDAO().admin is the field both guards compare against, and a
	// literal address would pass or fail depending on which test file created
	// the first court.
	// A COURT MUST EXIST FIRST, for the reason courtburn_test.gno records against
	// the same panic: ensureGlobalDAO builds from directoryAdmin, which the FIRST
	// StartCourt in the package sets. Without this the test passes only when some
	// other file happened to run before it, and `make isolation-test` -- which
	// runs every test ALONE -- is exactly what finds that out. Measured: run under
	// -run on its own it panicked "no court exists yet; the global DAO has no
	// admin".
	prevBurn := courtCreationBurn
	defer func() { courtCreationBurn = prevBurn }()
	courtCreationBurn = 0

	maker := testutils.TestAddress("mediahost-maker")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(maker))
	if !Exists("mh0") {
		StartCourt(cross(cur), "mh0", "Media Host Fixture Court")
	}

	admin := ensureGlobalDAO().admin
	stranger := testutils.TestAddress("mediahost-stranger")
	if stranger == admin {
		t.Fatal("the fixture needs a non-admin address")
	}

	beforeExact := strings.Join(mediaHostsExact, ",")
	beforeSuffix := strings.Join(mediaHostSuffixes, ",")
	if beforeExact == "" && beforeSuffix == "" {
		t.Fatal("the fixture needs a non-empty host list, or `unchanged` proves nothing")
	}

	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(stranger))

	uassert.AbortsContains(t, cur, "only the global DAO admin sets the media hosts", func() {
		SetMediaHosts(cross(cur), "evil.example", ".evil.example")
	})
	uassert.AbortsContains(t, cur, "only the global DAO admin sets the media hosts", func() {
		ClearMediaHosts(cross(cur))
	})

	// A REFUSED CALL MUST NOT MOVE THE LIST. The abort assertion alone would pass
	// against a guard that panicked AFTER assigning, which is the shape that
	// makes a kill switch useless: the hosts are already wrong and the caller
	// got an error.
	if strings.Join(mediaHostsExact, ",") != beforeExact {
		t.Fatal("a refused SetMediaHosts moved the exact list")
	}
	if strings.Join(mediaHostSuffixes, ",") != beforeSuffix {
		t.Fatal("a refused call moved the suffix list")
	}
}
