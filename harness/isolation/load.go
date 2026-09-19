package main

import (
	"bytes"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	gno "github.com/gnolang/gno/gnovm/pkg/gnolang"
	"github.com/gnolang/gno/gnovm/pkg/gnomod"
	"github.com/gnolang/gno/gnovm/pkg/packages"
	"github.com/gnolang/gno/gnovm/pkg/test"
	"github.com/gnolang/gno/tm2/pkg/std"
	storetypes "github.com/gnolang/gno/tm2/pkg/store/types"
)

// loaded is everything the per-test loop needs from the one load of a package:
// the transaction store that holds the post-init object graph as BYTES, the
// byte store it wrote them into, and the harvested test names.
type loaded struct {
	pkgPath string
	// tcw is the cache-wrapped base store that the load wrote every object,
	// type and mempackage into. Each test layers its own CacheWrap on top of
	// it, so tcw is read by every test and written by none.
	tcw storetypes.Store
	// tgs is the transaction store the package was run into. Each test forks
	// it with BeginTransaction; tgs itself is never used to run a test.
	tgs gno.TransactionStore
	// tests are the Test* functions found in the package's own _test.gno
	// files, in file order then declaration order — the order `gno test`
	// runs them in, which the RESULT lines follow.
	tests []string
	// out is what the load phase printed (import inits, type-check chatter).
	// It is shown only with -v or when the load fails.
	out *bytes.Buffer
	// took is the wall-clock cost of the load, reported in the SUMMARY line
	// so a regression toward the old per-test cost is visible.
	took time.Duration
}

// loaderTrip is what the package getter panics with after the load. See the
// comment on load() for why any per-test call that reaches the getter is a
// defect the runner must report rather than absorb.
type loaderTrip struct{ path string }

// refusal is a load-phase error the runner turns into exit 2: the package
// could not be loaded the way `gno test` loads it, so nothing this process
// says about its tests could be trusted.
type refusal struct{ msg string }

func (r refusal) Error() string { return r.msg }

// load reads, type-checks and runs one package ONCE, exactly the way `gno test`
// does in gno v1.2.0 (gnovm/cmd/gno/test.go testPkg followed by gnovm/pkg/test
// Test), and leaves the result in a store whose contents are bytes.
//
// The order and the arguments are copied from those two functions call for
// call, and the copy is deliberate rather than a shared helper because the
// point of this program is to reproduce `gno test`'s verdict per test at a
// fraction of its cost; any place it differs is a place its verdict could
// differ. The differences that remain are named here and in run.go:
//
//   - `gno test` runs every test of a package against ONE transaction store
//     (tgs below), so a test sees every write the tests before it made. This
//     runner runs each test in a child of tgs that is thrown away afterwards.
//     That is the whole feature, and the base is still tgs.
//
//   - `gno test` fills the store's writers only inside Test(), so NewTestOptions
//     followed by anything else is a nil-pointer panic the first time an import's
//     init prints. StoreWithOptions is the exported half that takes the writer
//     directly, so that is what is called here.
//
// WHERE INIT RUNS, and why once is honest. Imports are pulled in during the
// TYPE CHECK: the type-checker's importer asks the store for each import's
// mempackage, the store misses, falls through to its package getter, and the
// getter runs the import with save=true into the root store — so by the time
// the package under test is run, govern, avl, testing and the rest are already
// bytes in the root memdb, with their inits done. The package under test is
// then run with save=true into tgs, whose byte store is tcw, so ITS init runs
// once too, and its post-init graph is bytes in tcw. Children of tgs read
// through tcw into the root memdb and see all of it. `gno test` does exactly
// this much init, once per process, before any test runs; this runner does the
// same, once per package, before any test runs.
//
// THE TRIPWIRE. After the load, tgs's package getter is replaced with one that
// panics. Children inherit the getter when they are forked. A child asks the
// getter for a package only when it finds neither a cached object nor bytes for
// it — which after this load can only mean the base held that package as a live
// object and not as bytes. Letting the getter answer would re-run that
// package's init inside the test, silently, once per test: exactly the cost
// this design exists to remove, and exactly the "init runs once" claim it
// makes. The per-test recover turns the panic into a FAIL that names the
// package, so it can never read as a pass or as a real isolation failure.
func load(root, pkgDir string) (*loaded, error) {
	start := time.Now()
	out := &bytes.Buffer{}
	w := test.OutputWithError(out, out)

	pkgDir, err := filepath.Abs(pkgDir)
	if err != nil {
		return nil, refusal{err.Error()}
	}
	// packages.Load and the store's package getter both consult gnoenv.RootDir,
	// which reads GNOROOT; the loader's workspace is the nearest gnowork.toml
	// above the current directory, which for a staged root is <root>/examples.
	// Both are process-wide, and this process loads one package, so setting
	// them is the plain way to get `gno test`'s view.
	os.Setenv("GNOROOT", root)
	if err := os.Chdir(pkgDir); err != nil {
		return nil, refusal{err.Error()}
	}
	pkgs, err := packages.Load(packages.LoadConfig{
		Deps: true, Test: true, AllowEmpty: true, GnoRoot: root,
	}, ".")
	if err != nil {
		return nil, refusal{err.Error()}
	}
	// The package the pattern matched, as testPkg selects it: by Match, not
	// by directory, because the loader spells a temp dir through its
	// symlinks (/private/var) while the caller spells it as given (/var).
	var pkg *packages.Package
	for _, p := range pkgs {
		if len(p.Match) != 0 {
			if pkg != nil {
				return nil, refusal{fmt.Sprintf("pattern . matched %s and %s", pkg.Dir, p.Dir)}
			}
			pkg = p
		}
	}
	if pkg == nil {
		return nil, refusal{fmt.Sprintf("packages.Load found no package at %s", pkgDir)}
	}
	if len(pkg.Errors) != 0 {
		var sb strings.Builder
		for _, e := range pkg.Errors {
			sb.WriteString(e.Error())
			sb.WriteString("\n")
		}
		return nil, refusal{strings.TrimSpace(sb.String())}
	}
	mod, err := gnomod.ParseFilepath(filepath.Join(pkgDir, "gnomod.toml"))
	if err != nil {
		// `gno test` would auto-generate one. Every staged kourt package has
		// one, and a runner that invented a module path would be testing a
		// package under a name its imports do not use.
		return nil, refusal{fmt.Sprintf("gnomod.toml: %v", err)}
	}
	pkgPath := mod.Module

	baseStore, testStore := test.StoreWithOptions(root, w, test.StoreOptions{
		Testing:  true,
		Packages: pkgs,
	})

	mpkg := gno.MustReadMemPackage(pkgDir, pkgPath, gno.MPAnyAll)
	if !mod.Ignore {
		_, err := gno.TypeCheckMemPackage(mpkg, gno.TypeCheckOptions{
			Getter:     testStore,
			TestGetter: testStore,
			Mode:       gno.TCLatestRelaxed,
			Cache:      gno.TypeCheckCache{},
		})
		if err != nil {
			// A package `gno test` rejects must not pass here.
			return nil, refusal{err.Error()}
		}
	}

	tcw := baseStore.CacheWrap()
	tgs := testStore.BeginTransaction(tcw, tcw, nil, nil)
	m2 := gno.NewMachineWithOptions(gno.MachineOptions{
		PkgPath: pkgPath,
		Output:  w,
		Store:   tgs,
		Context: test.Context("", pkgPath, nil),
		// Non-nil allocator so PkgID stamping fires during load, as Test()
		// says in its own comment on this option.
		MaxAllocBytes: math.MaxInt64,
		SkipPackage:   true,
	})
	// Prod files plus this package's own _test.gno files; drops _filetest.gno
	// and any xxx_test package file. save=true: init runs here, once, and
	// the result is bytes in tcw.
	tmpkg := gno.MPFTest.FilterMemPackage(mpkg)
	if !tmpkg.IsEmptyOf(".gno") {
		_, _ = m2.RunMemPackageWithOverrides(tmpkg, true)
	}
	if err := test.LoadImports(tgs, mpkg, true); err != nil {
		return nil, refusal{err.Error()}
	}
	// The test stdlib is pulled into bytes now rather than inside the first
	// test, so the first RESULT's ms is a test's cost and not a load's.
	if tgs.GetPackage("testing", false) == nil {
		return nil, refusal{"the testing stdlib did not load"}
	}

	tests, err := harvest(mpkg)
	if err != nil {
		return nil, err
	}

	tgs.SetPackageGetter(func(path string, _ gno.Store) (*gno.PackageNode, *gno.PackageValue) {
		panic(loaderTrip{path})
	})

	return &loaded{
		pkgPath: pkgPath,
		tcw:     tcw,
		tgs:     tgs,
		tests:   tests,
		out:     out,
		took:    time.Since(start),
	}, nil
}

// harvest lists the Test* functions the way gnovm/pkg/test loadTestFuncs does:
// every non-method FuncDecl whose name starts with "Test", in each _test.gno
// file that belongs to the package itself.
//
// Two shapes are REFUSED rather than skipped, because `gno test` runs them and
// a runner that dropped them would report on less than `gno test -run` does
// while printing the same summary shape:
//
//   - `package xxx_test` files. `gno test` runs those with save=false, since an
//     integration mempackage is not storable, so a child layer could never see
//     them. kourt has none; this is a fence.
//   - Example functions with an output comment. `gno test` runs them and
//     compares the output. kourt has none; this is a fence.
func harvest(mpkg *std.MemPackage) ([]string, error) {
	var names []string
	var m *gno.Machine // (*Machine)(nil).ParseFile is how gno test parses too
	for _, f := range mpkg.Files {
		if !strings.HasSuffix(f.Name, "_test.gno") || strings.HasSuffix(f.Name, "_filetest.gno") {
			continue
		}
		n, err := m.ParseFile(f.Name, f.Body)
		if err != nil {
			return nil, refusal{err.Error()}
		}
		switch string(n.PkgName) {
		case mpkg.Name:
		case mpkg.Name + "_test":
			return nil, refusal{fmt.Sprintf(
				"%s declares package %s_test: gno test runs such files without saving them, "+
					"so a per-test store layer cannot see them and this runner refuses the package",
				f.Name, mpkg.Name)}
		default:
			return nil, refusal{fmt.Sprintf("%s declares package %s, expected %s", f.Name, n.PkgName, mpkg.Name)}
		}
		for _, d := range n.Decls {
			fd, ok := d.(*gno.FuncDecl)
			if !ok || fd.IsMethod {
				continue
			}
			name := string(fd.Name)
			if strings.HasPrefix(name, "Test") {
				names = append(names, name)
			}
			if strings.HasPrefix(name, "Example") && fd.Attributes.HasAttribute(gno.ATTR_EXAMPLE_OUTPUT) {
				return nil, refusal{fmt.Sprintf(
					"%s has an Example with an output comment (%s): gno test runs those and "+
						"this runner does not, so it refuses the package rather than cover less",
					f.Name, name)}
			}
		}
	}
	return names, nil
}
