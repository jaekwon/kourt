// PKGPATH: gno.land/r/kourt/tcfiletest
package tcfiletest

// The one place the VIRGIN arming path can be tested: a fresh deploy, where
// init has just seated the meta court and nothing else has happened.
//
// The in-package suite cannot reach this — it shares one realm, and by the time
// any test runs an earlier one has started a court, which seals the latch by
// design. So the guard that matters most on a real chain is asserted here, from
// outside the package, exactly as a stranger's transaction would arrive.
//
// The caller here is NOT kourtv3's deployer (the harness deployed it), so the
// arming must ABORT — that refusal is the assertion, and it is the same one an
// attacker racing a mainnet deploy would meet.

import (
	"gno.land/r/kourt/kourtv3"
)

func main(cur realm) {
	println("clock active at deploy:", kourtv3.TestClockActive())
	println("skew at deploy:        ", kourtv3.TestClockSkew())
	kourtv3.EnableTestClock(cross(cur))
	println("stranger arming:        ALLOWED (bug)")
}

// Output:
// clock active at deploy: false
// skew at deploy:         0

// Error:
// kourtv3: only the deployer may drive the test clock
