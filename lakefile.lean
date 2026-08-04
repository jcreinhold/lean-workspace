import Lake
open Lake DSL

package «lakew» where
  testDriver := "«test-suites»"

@[default_target]
lean_lib LakeWorkspace where

@[default_target]
lean_exe lakew where
  root := `Main

/- The shared test harness (`tests/Test`): assertions, process spawning,
filesystem fixtures, and golden files for the native suites
(`tests/Suites`). A library, so the harness compiles once and the suite
executables stay thin. Nothing in the product imports it. The globs are
explicit: `Test.Runner` is the orchestrator executable, not library code. -/
lean_lib TestSupport where
  srcDir := "tests"
  roots := #[`Test]
  globs := #[
    Glob.one `Test,
    Glob.one `Test.Harness,
    Glob.one `Test.Proc,
    Glob.one `Test.Fixture,
    Glob.one `Test.Golden
  ]

/- The suite orchestrator and the package's testDriver: `lake test` builds
the product and the selected suites in one invocation, then runs them.
`lake test -- --all` includes the slow benchmark suite. -/
lean_exe «test-suites» where
  srcDir := "tests"
  root := `Test.Runner
  supportInterpreter := true

/- The functional suites, one per concern, ported from `test/run.sh`. Each
drives the real `lakew` binary against a copied fixture in a temp dir. -/
lean_exe «suite-sync» where
  srcDir := "tests"
  root := `Suites.Sync
  supportInterpreter := true

lean_exe «suite-diagnostics» where
  srcDir := "tests"
  root := `Suites.Diagnostics
  supportInterpreter := true

lean_exe «suite-shared-deps» where
  srcDir := "tests"
  root := `Suites.SharedDeps
  supportInterpreter := true

lean_exe «suite-drivers» where
  srcDir := "tests"
  root := `Suites.Drivers
  supportInterpreter := true

lean_exe «suite-affected» where
  srcDir := "tests"
  root := `Suites.Affected
  supportInterpreter := true

lean_exe «suite-options-policy» where
  srcDir := "tests"
  root := `Suites.OptionsPolicy
  supportInterpreter := true

/- The TOML-lakefile suite (`tests/Suites/TomlLakefiles.lean`): members
may carry `lakefile.toml` instead of `lakefile.lean`; scanned with Lake's
own parser, they behave identically downstream (validation, drivers,
`[options]`, `[deps]`). -/
lean_exe «suite-toml-lakefiles» where
  srcDir := "tests"
  root := `Suites.TomlLakefiles
  supportInterpreter := true

/- The external-driver resolution suite
(`tests/Suites/ExternalDrivers.lean`). Builds and runs an exe driver borrowed
from a path dependency outside `members`, an external script driver, and a
git dependency materialized at test time. -/
lean_exe «suite-external-drivers» where
  srcDir := "tests"
  root := `Suites.ExternalDrivers
  supportInterpreter := true

/- The cache-policy suite (`tests/Suites/CachePolicy.lean`):
`[cache]` → generated-root cache knobs, `--try-cache` on sync, remote-service
validation, and the `lakew cache` pass-through/status command. -/
lean_exe «suite-cache-policy» where
  srcDir := "tests"
  root := `Suites.CachePolicy
  supportInterpreter := true

lean_exe «suite-realistic-shaped» where
  srcDir := "tests"
  root := `Suites.RealisticShaped
  supportInterpreter := true

/- The load-path benchmark suite (`tests/Suites/Bench.lean`). Slow: out of
the default `lake test` set, run via `lake test -- --all` or directly. Its
gates are wall-clock ratios meant for a human reading `tests/bench.md`; CI
builds it but does not time it. -/
lean_exe «suite-bench» where
  srcDir := "tests"
  root := `Suites.Bench
  supportInterpreter := true
