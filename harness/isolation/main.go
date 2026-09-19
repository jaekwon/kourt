// Command isolation runs every Test function of one gno package as the ONLY
// test that runs, without paying for one process per test.
//
// scripts/check-isolation.py proves that each realm test passes alone. It used
// to do that by spawning `gno test -run ^Name$ -v .` once per test, and each
// spawn re-type-checked and re-compiled the package and its imports and re-ran
// every init just to run one function: measured on r/kourtv3, a spawn was ~98%
// load and ~2% test, and the tree has ~1,600 tests. This program loads a
// package once, the way `gno test` does, and then runs each test in a fresh
// store layer over that base — see load.go for the load and run.go for what
// the layer isolates and what it does not.
//
// Usage:
//
//	go run ./harness/isolation -root <staged GNOROOT> -pkg <dir> [-run <re>] [-shard k/n] [-list] [-v] [-json]
//
// The package dir must be INSIDE the staged root's examples tree, staged the
// way scripts/gnoroot.py stages it, so its imports resolve the way `gno test`
// resolves them. Output, one record per test, in test order:
//
//	RESULT\t<Name>\t<PASS|FAIL|SKIP>\t<ms>
//	\t<captured line>                (FAIL only: every line the test printed)
//	SUMMARY\t<pkgPath>\tselected=<n>\tpass=<n>\tfail=<n>\tskip=<n>\tload_ms=<n>\ttests_ms=<n>
//
// -run is a Go regexp matched against harvested names here, not passed to
// gno. A filter that selects nothing runs nothing and exits 0 — deliberately
// the same shape as `gno test -run`, so the Python side owns the "never ran"
// verdict by noticing the missing RESULT line rather than trusting the exit.
//
// Exit 0: every selected test PASSed or SKIPped (including none selected).
// Exit 1: at least one FAIL. Exit 2: the package could not be loaded the way
// `gno test` loads it, or the runner refuses it (see harvest in load.go); the
// message and the load output go to stderr.
//
// No build tag, on purpose. The tags on harness/chain and harness/gnoland
// exist to keep `go test ./...` from running node-dependent suites; a main
// package has no tests to keep out, and `make vet` runs `go vet -tags ...
// ./...`, so a tag here would only hide this file from vet.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("isolation", flag.ContinueOnError)
	fs.SetOutput(stderr)
	root := fs.String("root", "", "the staged GNOROOT (required)")
	pkg := fs.String("pkg", "", "the package directory inside <root>/examples (required)")
	runRe := fs.String("run", "", "Go regexp over Test* names; nothing selected is exit 0")
	shard := fs.String("shard", "", "k/n: every n-th selected test starting at k")
	list := fs.Bool("list", false, "print the harvested names and exit")
	verbose := fs.Bool("v", false, "print the load phase's output and every test's output")
	asJSON := fs.Bool("json", false, "one JSON object per line instead of the tab form")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *root == "" || *pkg == "" {
		fmt.Fprintln(stderr, "isolation: -root and -pkg are required")
		return 2
	}
	var re *regexp.Regexp
	if *runRe != "" {
		var err error
		re, err = regexp.Compile(*runRe)
		if err != nil {
			fmt.Fprintf(stderr, "isolation: -run: %v\n", err)
			return 2
		}
	}
	shardK, shardN := 0, 1
	if *shard != "" {
		k, n, ok := strings.Cut(*shard, "/")
		var err1, err2 error
		shardK, err1 = strconv.Atoi(k)
		shardN, err2 = strconv.Atoi(n)
		if !ok || err1 != nil || err2 != nil || shardN <= 0 || shardK < 0 || shardK >= shardN {
			fmt.Fprintln(stderr, "isolation: -shard wants k/n with 0 <= k < n")
			return 2
		}
	}

	l, err := load(*root, *pkg)
	if err != nil {
		fmt.Fprintf(stderr, "isolation: %v\n", err)
		if l != nil && l.out.Len() > 0 {
			fmt.Fprint(stderr, l.out.String())
		}
		return 2
	}
	if *verbose && l.out.Len() > 0 {
		fmt.Fprint(stderr, l.out.String())
	}

	var selected []string
	for i, name := range l.tests {
		if re != nil && !re.MatchString(name) {
			continue
		}
		if i%shardN != shardK {
			continue
		}
		selected = append(selected, name)
	}
	if *list {
		for _, name := range selected {
			fmt.Fprintln(stdout, name)
		}
		return 0
	}

	counts := map[verdict]int{}
	var testsTook time.Duration
	for _, name := range selected {
		res := runOne(l, name)
		counts[res.v]++
		testsTook += res.took
		emit(stdout, res, *asJSON, *verbose)
	}
	summary(stdout, l, len(selected), counts, testsTook, *asJSON)
	if counts[fail] > 0 {
		return 1
	}
	return 0
}

// emit prints one RESULT record. Output is carried on FAIL only (or with -v):
// a passing test's println chatter is noise to the caller, and the failing
// test's output is the whole reason the caller is looking.
func emit(w io.Writer, res result, asJSON, verbose bool) {
	ms := res.took.Milliseconds()
	carry := res.v == fail || verbose
	if asJSON {
		rec := map[string]any{"name": res.name, "verdict": string(res.v), "ms": ms}
		if carry {
			rec["output"] = lines(res.output)
		}
		b, _ := json.Marshal(rec)
		fmt.Fprintln(w, string(b))
		return
	}
	fmt.Fprintf(w, "RESULT\t%s\t%s\t%d\n", res.name, res.v, ms)
	if carry {
		for _, line := range lines(res.output) {
			fmt.Fprintf(w, "\t%s\n", line)
		}
	}
}

func summary(w io.Writer, l *loaded, selected int, counts map[verdict]int, testsTook time.Duration, asJSON bool) {
	if asJSON {
		b, _ := json.Marshal(map[string]any{
			"summary": true, "pkg": l.pkgPath, "selected": selected,
			"pass": counts[pass], "fail": counts[fail], "skip": counts[skip],
			"load_ms": l.took.Milliseconds(), "tests_ms": testsTook.Milliseconds(),
		})
		fmt.Fprintln(w, string(b))
		return
	}
	fmt.Fprintf(w, "SUMMARY\t%s\tselected=%d\tpass=%d\tfail=%d\tskip=%d\tload_ms=%d\ttests_ms=%d\n",
		l.pkgPath, selected, counts[pass], counts[fail], counts[skip],
		l.took.Milliseconds(), testsTook.Milliseconds())
}
