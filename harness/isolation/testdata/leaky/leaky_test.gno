package leaky

import "testing"

// TestMarks runs first in file order and leaves the package marked. Under
// `gno test .` every later test sees that mark.
func TestMarks(cur realm, t *testing.T) {
	Mark(cross(cur))
	if !Seen() {
		t.Fatal("Mark did not mark")
	}
}

// TestNeedsNeighbour passes only in TestMarks' company: it asserts a mark it
// never made. This is the shape scripts/check-isolation.py exists to catch,
// and the runner must fail it when it is the only test that runs.
func TestNeedsNeighbour(t *testing.T) {
	if !Seen() {
		t.Fatal("no neighbour marked the package")
	}
}
