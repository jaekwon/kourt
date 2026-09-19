package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	gno "github.com/gnolang/gno/gnovm/pkg/gnolang"
	"github.com/gnolang/gno/gnovm/pkg/packages"
	gnotest "github.com/gnolang/gno/gnovm/pkg/test"
)

// gnoRoot is the gno module this build depends on, which is a complete
// GNOROOT: stdlibs, test stdlibs and examples. It is read-only, and nothing
// here writes to it — the fixture is loaded in single-package mode from
// testdata, so no staging into examples/ is needed.
func gnoRoot(t *testing.T) string {
	t.Helper()
	out, err := exec.Command("go", "list", "-m", "-f", "{{.Dir}}", "github.com/gnolang/gno").Output()
	if err != nil {
		t.Fatalf("go list -m github.com/gnolang/gno: %v", err)
	}
	return strings.TrimSpace(string(out))
}

// fixtureDir is resolved at init, before any test runs, because load()
// changes the process's working directory (it has to: packages.Load reads
// its context from Getwd) and a relative path read after that would be
// resolved against the fixture itself.
var fixtureDir, fixtureErr = filepath.Abs("testdata/leaky")

func fixture(t *testing.T) string {
	t.Helper()
	if fixtureErr != nil {
		t.Fatal(fixtureErr)
	}
	return fixtureDir
}

// The runner's whole claim, on the smallest package that can make it: two
// tests, the second passing only in the first's company. The fast path must
// fail the leaky one when it runs alone, pass the honest one, and the same
// package must be green under gno's own together-run — otherwise the runner
// is reporting an ordinary failure, not an isolation failure.
func TestLeakyTestFailsAloneAndPassesTogether(t *testing.T) {
	root := gnoRoot(t)
	dir := fixture(t)

	var out, errOut bytes.Buffer
	code := run([]string{"-root", root, "-pkg", dir}, &out, &errOut)
	if code != 1 {
		t.Fatalf("exit %d, want 1 (one FAIL)\nstdout:\n%s\nstderr:\n%s", code, out.String(), errOut.String())
	}
	got := out.String()
	for _, want := range []string{
		"RESULT\tTestMarks\tPASS\t",
		"RESULT\tTestNeedsNeighbour\tFAIL\t",
		"\tno neighbour marked the package",
		"selected=2\tpass=1\tfail=1\tskip=0",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("stdout lacks %q:\n%s", want, got)
		}
	}
	// A passing test's output is not carried: the RESULT line for TestMarks
	// must be followed directly by the next record.
	if strings.Contains(got, "=== RUN   TestMarks") {
		t.Errorf("a PASS carried its output:\n%s", got)
	}

	// Together, the way `gno test .` runs them: one shared transaction store,
	// file order. gnovm/pkg/test's Test is what the gno CLI calls after the
	// type check, so a nil error here is the CLI's `ok`.
	os.Setenv("GNOROOT", root)
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	pkgs, err := packages.Load(packages.LoadConfig{Deps: true, Test: true, AllowEmpty: true, GnoRoot: root}, ".")
	if err != nil {
		t.Fatal(err)
	}
	var together bytes.Buffer
	opts := gnotest.NewTestOptions(root, &together, &together, pkgs)
	mpkg := gno.MustReadMemPackage(dir, "gno.land/r/isolationfixture/leaky", gno.MPAnyAll)
	if err := gnotest.Test(mpkg, dir, opts); err != nil {
		t.Fatalf("the fixture must pass together, or the runner has caught an ordinary failure: %v\n%s", err, together.String())
	}
}

// -run selecting nothing is exit 0 with no RESULT line, deliberately the same
// shape as `gno test -run`: the Python caller owns the "never ran" verdict
// and finds it by the missing RESULT, not by the exit code. -list prints the
// harvested names in test order.
func TestNothingSelectedIsSilentExitZero(t *testing.T) {
	root := gnoRoot(t)
	dir := fixture(t)

	var out, errOut bytes.Buffer
	code := run([]string{"-root", root, "-pkg", dir, "-run", "^TestNoSuchTest$"}, &out, &errOut)
	if code != 0 {
		t.Fatalf("exit %d, want 0\n%s%s", code, out.String(), errOut.String())
	}
	if strings.Contains(out.String(), "RESULT") || !strings.Contains(out.String(), "selected=0") {
		t.Errorf("unexpected output:\n%s", out.String())
	}

	out.Reset()
	code = run([]string{"-root", root, "-pkg", dir, "-list"}, &out, &errOut)
	if code != 0 || out.String() != "TestMarks\nTestNeedsNeighbour\n" {
		t.Errorf("-list: exit %d, output %q", code, out.String())
	}
}
