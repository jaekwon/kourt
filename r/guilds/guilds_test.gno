package guilds

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"

	kourt "gno.land/r/kourt/kourtv2"
)

// A real Discord snowflake — the one covid's moderators actually chose.
const covidGuild = "1550279172088143883"

// EVERY testing.SetRealm IS WRITTEN OUT IN THE TEST'S OWN BODY, and no helper
// wraps it. That is not repetition left untidied: a SetRealm made inside a
// called function does not reach the caller's crossing calls, so a
// `startCourt(cur, slug, who)` helper opened the court as THIS REALM rather than
// as who — and TestModeratorSetsAndReads still passed, because the Set that
// followed was made by the same wrong identity. The authorisation test was the
// one that noticed, by failing for the opposite of the real reason: it reported
// that a stranger could set, when in truth neither address was ever the caller.
// A helper here buys three lines and can hide the only thing this suite proves.

func TestModeratorSetsAndReads(cur realm, t *testing.T) {
	adm := testutils.TestAddress("g-adm1")
	testing.SetRealm(testing.NewUserRealm(adm))
	kourt.StartCourt(cross(cur), "gset", "Test Court")
	if !kourt.IsCourtMod("gset", adm) {
		t.Fatal("the court's creator moderates it — the suite's premise")
	}
	if GuildOf("gset") != "" {
		t.Fatal("a court that never chose has no server")
	}
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gset", covidGuild)
	if got := GuildOf("gset"); got != covidGuild {
		t.Fatal("the guild should read back, got " + got)
	}
	// AND WHO CHOSE IT. kourt.xyz records the publisher from this, so a binding
	// whose setter reads back empty is one the service attributes to nobody.
	if g, by := Chosen("gset"); g != covidGuild || by != adm.String() {
		t.Fatalf("Chosen read %q set by %q", g, by)
	}
	// BOTH EMPTY OR NEITHER, which is what the service refuses on: half an
	// answer would list a court's server with nobody recorded as its publisher,
	// and the heartbeat degrades exactly that on its next sweep.
	if g, by := Chosen("no-such-court"); g != "" || by != "" {
		t.Fatalf("a court that never chose read %q / %q", g, by)
	}
}

// THE ASSERTION THIS REALM EXISTS FOR. Anyone can send this transaction; only a
// moderator of that court may have it stick. If this ever passes for a stranger,
// a stranger's wallet can point the court page at a griefer's server.
func TestAStrangerCannotSet(cur realm, t *testing.T) {
	adm := testutils.TestAddress("g-adm2")
	testing.SetRealm(testing.NewUserRealm(adm))
	kourt.StartCourt(cross(cur), "gstr", "Test Court")

	str := testutils.TestAddress("g-stranger")
	if kourt.IsCourtMod("gstr", str) {
		t.Fatal("the stranger must not be a moderator, or this proves nothing")
	}
	testing.SetRealm(testing.NewUserRealm(str))
	uassert.AbortsContains(t, cur, "only a moderator", func() {
		Set(cross(cur), "gstr", covidGuild)
	})
	if GuildOf("gstr") != "" {
		t.Fatal("the refused call must leave nothing behind")
	}
}

// A moderator of ONE court is a stranger to every other. Courts are separate
// jurisdictions, and a shared realm is the obvious place for that to leak.
func TestAModeratorOfAnotherCourtCannotSet(cur realm, t *testing.T) {
	mine := testutils.TestAddress("g-mine")
	testing.SetRealm(testing.NewUserRealm(mine))
	kourt.StartCourt(cross(cur), "gmine", "Test Court")
	theirs := testutils.TestAddress("g-theirs")
	testing.SetRealm(testing.NewUserRealm(theirs))
	kourt.StartCourt(cross(cur), "gtheirs", "Test Court")

	testing.SetRealm(testing.NewUserRealm(mine))
	uassert.AbortsContains(t, cur, "only a moderator", func() {
		Set(cross(cur), "gtheirs", covidGuild)
	})
	if GuildOf("gtheirs") != "" {
		t.Fatal("one court's moderator must not bind another's server")
	}
}

// A court that does not exist has nothing to bind, and kourtv2 says so rather
// than this realm inventing an answer.
func TestNoSuchCourt(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("g-nocourt")))
	uassert.AbortsContains(t, cur, "court", func() {
		Set(cross(cur), "nosuchcourt", covidGuild)
	})
}

func TestEmptyClears(cur realm, t *testing.T) {
	adm := testutils.TestAddress("g-adm3")
	testing.SetRealm(testing.NewUserRealm(adm))
	kourt.StartCourt(cross(cur), "gclr", "Test Court")
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gclr", covidGuild)
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gclr", "")
	if g, by := Chosen("gclr"); g != "" || by != "" {
		t.Fatal("an empty id clears the binding, setter and all")
	}
	// Clearing what is not there is not an error: a "remove" button pressed
	// twice is not a failure to report to a moderator.
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gclr", "")
	if GuildOf("gclr") != "" {
		t.Fatal("clearing twice is still cleared")
	}
}

// Whitespace is what a paste carries, and a trailing newline stored verbatim is
// a guild id that matches nothing and looks right in every view of it.
func TestPastedWhitespaceIsTrimmed(cur realm, t *testing.T) {
	adm := testutils.TestAddress("g-adm4")
	testing.SetRealm(testing.NewUserRealm(adm))
	kourt.StartCourt(cross(cur), "gtrim", "Test Court")
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gtrim", "  "+covidGuild+"\n")
	if GuildOf("gtrim") != covidGuild {
		t.Fatal("a pasted id is trimmed")
	}
	// ...and a field holding only whitespace is a clear, not a stored blank.
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gtrim", "   ")
	if GuildOf("gtrim") != "" {
		t.Fatal("whitespace alone clears")
	}
}

func TestMalformedIdsAreRefused(cur realm, t *testing.T) {
	adm := testutils.TestAddress("g-adm5")
	testing.SetRealm(testing.NewUserRealm(adm))
	kourt.StartCourt(cross(cur), "gbad", "Test Court")
	for _, bad := range []string{
		"1234",                      // too short
		"123456789012345678901",     // too long
		"15502791720881438o3",       // a letter where a digit belongs
		"1550279172088143883 extra", // a copied line, not an id
		"-550279172088143883",       // signed
	} {
		testing.SetRealm(testing.NewUserRealm(adm))
		uassert.AbortsContains(t, cur, "guilds:", func() {
			Set(cross(cur), "gbad", bad)
		})
	}
	if GuildOf("gbad") != "" {
		t.Fatal("nothing malformed is stored")
	}
	// The bounds are not off by one: 17 and 20 digits are both accepted.
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gbad", "12345678901234567")
	if GuildOf("gbad") != "12345678901234567" {
		t.Fatal("17 digits is a guild id")
	}
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "gbad", "12345678901234567890")
	if GuildOf("gbad") != "12345678901234567890" {
		t.Fatal("20 digits is a guild id")
	}
}

func TestCourtsListsWhatWasChosen(cur realm, t *testing.T) {
	a := testutils.TestAddress("g-adm6")
	testing.SetRealm(testing.NewUserRealm(a))
	kourt.StartCourt(cross(cur), "glst1", "Test Court")
	b := testutils.TestAddress("g-adm7")
	testing.SetRealm(testing.NewUserRealm(b))
	kourt.StartCourt(cross(cur), "glst2", "Test Court")

	testing.SetRealm(testing.NewUserRealm(a))
	Set(cross(cur), "glst1", covidGuild)
	testing.SetRealm(testing.NewUserRealm(b))
	Set(cross(cur), "glst2", covidGuild)

	seen := map[string]bool{}
	for _, c := range Courts() {
		seen[c] = true
	}
	if !seen["glst1"] || !seen["glst2"] {
		t.Fatal("both courts should be listed")
	}
	// A cleared court LEAVES the list rather than sitting in it with an empty
	// id — the service reconciles from this and would keep a dead server.
	testing.SetRealm(testing.NewUserRealm(a))
	Set(cross(cur), "glst1", "")
	for _, c := range Courts() {
		if c == "glst1" {
			t.Fatal("a cleared court is not listed")
		}
	}
}

func TestRenderSaysSomethingEitherWay(cur realm, t *testing.T) {
	if Render("") == "" {
		t.Fatal("Render is never empty")
	}
	adm := testutils.TestAddress("g-adm8")
	testing.SetRealm(testing.NewUserRealm(adm))
	kourt.StartCourt(cross(cur), "grnd", "Test Court")
	testing.SetRealm(testing.NewUserRealm(adm))
	Set(cross(cur), "grnd", covidGuild)
	if !strings.Contains(Render(""), covidGuild) {
		t.Fatal("Render shows a chosen server")
	}
}
