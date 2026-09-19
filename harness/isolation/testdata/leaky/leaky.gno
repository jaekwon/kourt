// Package leaky is the fixture for harness/isolation's own test: a realm
// whose one package-level variable is what a test can leak to its neighbour.
package leaky

var seen bool

func Mark(cur realm) { seen = true }

func Seen() bool { return seen }
