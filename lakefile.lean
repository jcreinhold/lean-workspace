import Lake
open Lake DSL

package «lakew» where

@[default_target]
lean_lib LakeWorkspace where

@[default_target]
lean_exe lakew where
  root := `Main

/- The shared test harness (`tests/Test`): assertions, process spawning, and
filesystem fixtures for the native suites (`tests/Suites`). A library, so the
harness compiles once and the suite executables stay thin. Nothing in the
product imports it; the legacy `test/run.sh` suites migrate onto it
incrementally. -/
lean_lib TestSupport where
  srcDir := "tests"
  roots := #[`Test]

/- The load-path benchmark suite (`tests/Suites/Bench.lean`). Not the package
test driver and not run in CI: its gates are wall-clock ratios meant for a
human reading `tests/bench.md`. Built in CI to keep it compiling. -/
lean_exe «suite-bench» where
  srcDir := "tests"
  root := `Suites.Bench
  supportInterpreter := true
