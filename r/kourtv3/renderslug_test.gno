package kourtv3

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

/* WHAT THE DEPLOYED REALM DOES WITH A PATH THAT NAMES NOTHING.

   render() dispatches on the path's SHAPE before anything knows whether the
   court or claim exists, so each arm must refuse for itself. SIX DO and FIVE DO
   NOT, and this pins both halves as they are on gnoland-1 — not as they ought to
   be. A package deploys exactly once, so the arms that panic will go on panicking
   for the life of this deployment, and a repo that quietly "fixed" them would
   have a reader reasoning about mainnet wrongly.

   COULD HAVE (v2): give the five panicking arms the same three lines the other
   six already have — `if !Exists(slug)` in renderStanding, renderStandingIndex,
   renderBoardIn, renderBoardHidden and renderBoardRow, plus
   `if claimID == 0 || claimID > c.nextID` in the board three. Each function
   carries the exact block in a comment.

   THE PANIC IS NOT A VULNERABILITY: Render is a read path, it costs the caller a
   query and yields a gnoweb error rather than data, and nothing is corrupted. It
   is a consistency wart on an immutable deployment, recorded here rather than
   hidden.

   MEASURED AGAINST gnoland-1, not inferred: eight attacker-shaped paths, then a
   real court with an id that is not a claim. */
func TestRenderRefusesOrPanicsExactlyAsDeployed(cur realm, t *testing.T) {
	const ghost = "nosuchcourt"
	if Exists(ghost) {
		t.Fatal("the fixture needs a slug no court uses")
	}
	probe := testutils.TestAddress("rs-probe").String()

	// The six arms that refuse: renderCourt, renderClaim, renderModLog,
	// renderElection, renderFolderPage, renderPositions.
	for _, p := range []string{
		ghost,
		ghost + "/mod",
		ghost + "/election",
		ghost + "/1",
		ghost + "/folder/1",
		metaSlug + "/999999",
		metaSlug + "/folder/999999",
	} {
		if got := Render(p); !strings.Contains(got, "Not found") {
			t.Fatalf("%q no longer says Not found: %q", p, got)
		}
	}

	// The five that do not. If one of these ever stops panicking, somebody has
	// changed the realm — which is a DEPLOY decision, not a cleanup, and this
	// test is where that shows up.
	for _, p := range []string{
		ghost + "/me",
		ghost + "/me/" + probe,
		ghost + "/1/board",
		ghost + "/1/board/top",
		ghost + "/1/board/hidden",
		ghost + "/1/board/7",
	} {
		path := p
		uassert.PanicsContains(t, cur, "no such court", func() { Render(path) })
	}

	// A REAL court with an id that is not a claim reaches mustClaim instead, so
	// the panic names the claim. Same missing guard, one layer down: the board
	// arms check neither the slug nor the id.
	for _, p := range []string{
		metaSlug + "/0/board",
		metaSlug + "/999999/board",
		metaSlug + "/999999/board/top",
		metaSlug + "/999999/board/hidden",
	} {
		path := p
		uassert.PanicsContains(t, cur, "no such claim", func() { Render(path) })
	}
}
