package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"strings"
	"time"

	gno "github.com/gnolang/gno/gnovm/pkg/gnolang"
	"github.com/gnolang/gno/gnovm/pkg/test"
	"github.com/gnolang/gno/tm2/pkg/store"
)

// verdict is one test's outcome, in the vocabulary the RESULT line prints.
type verdict string

const (
	pass verdict = "PASS"
	fail verdict = "FAIL"
	skip verdict = "SKIP"
)

// result is one test's record: the verdict, what it printed, and how long the
// fresh layer plus the test took.
type result struct {
	name   string
	v      verdict
	output string
	took   time.Duration
}

// testBuffer is the Machine output for one test. It implements StderrWrite so
// the test stdlib's os.Stderr — where `=== RUN`, `--- FAIL`, t.Fatal text and
// panic stack traces go — lands in the same buffer as println output, in
// order. Without StderrWrite, gno's os.write falls back to Write, so the
// capture would still be complete, but the interface is what `gno test`
// provides and matching it keeps the two outputs comparable line for line.
type testBuffer struct{ bytes.Buffer }

func (b *testBuffer) StderrWrite(p []byte) (int, error) { return b.Write(p) }

// report mirrors the test stdlib's Report, the JSON RunTest returns.
type report struct {
	Failed  bool
	Skipped bool
}

// runOne runs a single Test function in a fresh execution state layered on
// the loaded base, and discards the state afterwards.
//
// WHAT IS ISOLATED BY WHAT. A test can mutate three kinds of state, and each
// is reset by a different mechanism; the runner relies on all three and this
// is the record of why each holds.
//
//  1. Store state — package-level variables, avl and bptree trees, the coin
//     ledgers the realms keep, realm object counters, anything stored — is
//     isolated by the LAYER. BeginTransaction gives the child empty object,
//     type and realm caches and a read-through view of the parent's block
//     nodes; the child's GetPackage misses its cache and amino-decodes a
//     pristine PackageValue from the bytes the load wrote, and every child
//     object hydrates the same way on first touch. A realm's writes (the
//     finalize at each crossing return) go to the child's byte store, and that
//     byte store is a private CacheWrap of the load's, so the parent never
//     sees them. Nothing calls Write on either, so there is nothing to undo
//     when the layer is dropped. Two conditions make this true and both are
//     load()'s: the package was run with save=true, and the layer's byte
//     stores are a fresh CacheWrap rather than nil (nil would reuse the
//     parent's byte store and leak every write in serialized form). This is
//     the chain's own model of a transaction, and gnovm/pkg/test uses it for
//     filetests in the same shape.
//
//  2. Go-side test context — height and timestamp (testing.SkipHeights,
//     SetHeight), the origin caller and send, the realm overrides
//     testing.SetRealm installs, the test banker's coin table, params, and
//     the event logger — lives in the Machine's TestExecContext, which
//     test.Machine builds fresh through test.Context. So it is reset by
//     CONSTRUCTION, per Machine, and not by the store; `gno test` already
//     builds a fresh Machine per test and therefore already resets it. The
//     natives keep no other Go-side mutable state: the only package-level
//     variables in the test stdlibs are immutable tables.
//
//  3. `cur` — the realm value handed to a `TestXxx(cur realm, t *testing.T)`
//     — is a fresh origin (or concrete) realm per test, allocated with the
//     test's own allocator, because testing.SetRealm mutates the captured
//     realm struct in place. `gno test` does the same for the same reason.
//
// Shared on purpose: the preprocessed block nodes, read through from the
// parent (the VM treats them as immutable once preprocessed; the only writes
// after that are deterministic memo caches, and `gno test` shares them
// between filetests the same way), the uverse, and the amino type cache.
//
// One Gno-level global the layer isolates that `gno test` does NOT: the test
// stdlib's random number state (`var x uint64 = 42` in testing/random.gno).
// Under `gno test .` it advances from test to test; under this runner, and
// under the old one-process-per-test path, it is 42 for every test. Fast and
// slow agree with each other here and differ from the together-run, which is
// the correct direction: a test that depends on where a neighbour left the
// RNG is exactly the kind of company-dependence this guard exists to find.
//
// THE ONE PLACE THIS DOES NOT DO WHAT `gno test` DOES. A Gno panic inside a
// test body is recovered by the stdlib's tRunner (t.Fail plus `panic: ...`
// and a stack trace on stderr) and comes back as Failed:true — same as `gno
// test`. An abort that reaches a crossing frame with no revive escapes
// m.Eval as a Go panic (UnhandledPanicError); `gno test` recovers it once,
// in runTestFiles, and abandons the REST of the package. This runner
// recovers it per test, records FAIL with the panic text and the Gno stack
// traces, discards the layer and continues with the next test. That is what
// the one-process-per-test path already observed (that process failed, the
// others ran), and the fresh layer is what makes continuing safe. The
// recover wraps the WHOLE per-test body, not just the RunTest eval, because
// SetActivePackage, the layer's GetPackage (where the loader tripwire fires)
// and the Preprocess inside Eval can all panic too, and any of those must
// become a FAIL naming this test rather than the end of the process.
func runOne(l *loaded, name string) (res result) {
	start := time.Now()
	buf := &testBuffer{}
	res = result{name: name}
	var m *gno.Machine
	defer func() {
		res.took = time.Since(start)
		if r := recover(); r != nil {
			res.v = fail
			switch t := r.(type) {
			case loaderTrip:
				fmt.Fprintf(buf, "--- FAIL: %s [runner: package %s was not persisted by load-once; "+
					"the getter would have re-run its init inside this test]\n", name, t.path)
			default:
				fmt.Fprintf(buf, "--- FAIL: %s [escaped the test: %v]\n", name, r)
				// Read the machine's traces BEFORE Release zeroes it. After an
				// escaped abort m.Exception is still set, so the Gno trace is
				// available; for a plain Go panic it is empty and the text
				// above is all there is.
				if m != nil {
					if st := m.ExceptionStacktrace(); st != "" {
						fmt.Fprintln(buf, st)
					}
					fmt.Fprintln(buf, m.Stacktrace().String())
				}
			}
		}
		res.output = buf.String()
		if m != nil {
			m.Release()
		}
	}()

	// (1) A private byte store, and a child transaction that writes to it.
	layerKV := l.tcw.CacheWrap()
	gasMeter := store.NewInfiniteGasMeter()
	layer := l.tgs.BeginTransaction(layerKV, layerKV, nil, gasMeter)

	// (2) A fresh Machine with a fresh test context.
	m = test.Machine(layer, buf, l.pkgPath, false, gasMeter)
	m.Alloc = gno.NewAllocator(math.MaxInt64)
	pv := layer.GetPackage(l.pkgPath, false)
	if pv == nil {
		panic(fmt.Sprintf("package %s is not in the layer", l.pkgPath))
	}
	m.SetActivePackage(pv)
	// From the CHILD, never the parent's live pointer: the parent's testing
	// package would be the same object for every test.
	testingpv := layer.GetPackage("testing", false)
	testingcx := &gno.ConstExpr{TypedValue: gno.TypedValue{T: &gno.PackageType{}, V: testingpv}}

	// The dispatch below is gnovm/pkg/test runTestFiles' verbatim, including
	// the two entry points: RunTest for `TestXxx(t)` and the unexported
	// runTest_cur for `TestXxx(cur realm, t)`. Entering through one of those
	// two is mandatory — the test runtime's isOriginCall accepts only those
	// frame-0 names (or main) — and the gno test authors spell out why cur is
	// passed this way in that function's comment.
	testfv := m.Eval(gno.Nx(name))[0].GetFunc()
	var runTestX gno.Expr
	var runTest gno.TypedValue
	var runTestF string
	var runTestCur gno.Expr
	if testfv.IsCrossing() {
		m.SetActivePackage(testingpv)
		runTestX = gno.Nx("runTest_cur")
		runTest = m.Eval(runTestX)[0]
		runTestF = "F_cur"
		if gno.IsRealmPath(l.pkgPath) {
			runTestCur = gno.NewConstExpr(gno.Nx(".cur"), gno.NewConcreteRealm(m.Alloc, l.pkgPath, gno.NewOriginRealmTV(m.Alloc)))
		} else {
			runTestCur = gno.NewConstExpr(gno.Nx(".cur"), gno.NewOriginRealmTV(m.Alloc))
		}
		m.SetActivePackage(pv)
	} else {
		runTestX = gno.Sel(testingcx, "RunTest")
		runTest = m.Eval(runTestX)[0]
		runTestF = "F"
		runTestCur = gno.Nx("nil")
	}
	runTestCX := gno.NewConstExpr(runTestX, runTest)

	// runFlag is "" because the name filter is applied Go-side, in main;
	// verbose is TRUE because it is load-bearing for capture: t.Log prints
	// immediately only when verbose, and `=== RUN`/`--- FAIL` come from the
	// stdlib's tRunner on the same condition. The old per-process path ran
	// `gno test -v` for exactly this reason.
	eval := m.Eval(gno.Call(
		runTestCX,
		gno.Str(""),
		gno.Nx("true"),
		gno.Nx("false"),
		&gno.CompositeLitExpr{
			Type: gno.Sel(testingcx, "InternalTest"),
			Elts: gno.KeyValueExprs{
				{Key: gno.X("Name"), Value: gno.Str(name)},
				{Key: gno.X(runTestF), Value: gno.Nx(name)},
				{Key: gno.X("Cur"), Value: runTestCur},
			},
		},
	))
	ret := eval[0].GetString()
	if ret == "" {
		res.v = fail
		fmt.Fprintf(buf, "--- FAIL: %s [internal gno testing error]\n", name)
		return
	}
	var rep report
	if err := json.Unmarshal([]byte(ret), &rep); err != nil {
		res.v = fail
		fmt.Fprintf(buf, "--- FAIL: %s [internal gno testing error: %v]\n", name, err)
		return
	}
	switch {
	case rep.Failed:
		res.v = fail
	case rep.Skipped:
		res.v = skip
	default:
		res.v = pass
	}
	return
}

// lines splits captured output into the tab-prefixed lines the RESULT
// record carries, dropping a trailing empty line.
func lines(s string) []string {
	s = strings.TrimRight(s, "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}
