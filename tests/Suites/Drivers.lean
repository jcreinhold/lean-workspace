/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The drivers suite

Port of `test/run.sh`'s test/lint driver aggregation phase: one `lake build`
step covers every exe/lib driver, script drivers execute through
`lake script run` with the workspace-configured args prepended, a failing
driver propagates its exit code into an aggregated summary, `-p` selection
restricts to one member, the `--json` report is pure JSON on stdout, and
`lint` aggregates separately while noting driverless members.

This suite really builds and runs the fixture's drivers, so it is the
slowest of the functional suites. Cases share one synced temp world in
declaration order.
-/

namespace Suites.Drivers

open Lakew.Test

def cases (lakew dir : System.FilePath) : Array Case := #[
  ⟨"sync the fixture", do
    let _ ← expectExit "sync" 0 lakew.toString #["sync"] dir⟩,
  ⟨"the test plan has exactly one build step covering every exe/lib driver", do
    let plan ← expectExit "test --dry-run" 0 lakew.toString
      #["test", "--dry-run", "--json"] dir
    ensureCount "runLake steps" "\"kind\": \"runLake\"" 1 plan.stdout
    ensureContains "lib driver in build step" "\"@withlib/TestLib\"" plan.stdout
    ensureContains "script driver step" "\"runDrivers\"" plan.stdout⟩,
  ⟨"a failing driver propagates its exit code", do
    let result ← expectExit "test" 3 lakew.toString #["test"] dir
    let out := result.stdout ++ result.stderr
    ensureContains "config args reach the script driver" "script tests passed ([--cfg])" out
    ensureContains "aggregated summary" "test: 1 of 4 driver(s) FAILED" out⟩,
  ⟨"-p selection runs only that member's drivers", do
    let result ← expectExit "test -p withexe" 0 lakew.toString #["test", "-p", "withexe"] dir
    ensureContains "selection summary" "all 1 driver(s) passed" (result.stdout ++ result.stderr)⟩,
  ⟨"the --json report is pure JSON on stdout", do
    let result ← runProc lakew.toString #["test", "-p", "failing", "--json"] dir
    ensureContains "ok:false" "\"ok\": false" result.stdout
    ensureContains "exit code recorded" "\"exitCode\": 3" result.stdout
    ensure (result.stdout.startsWith "{")
      s!"stdout does not start with JSON:\n{result.stdout.take 200}"⟩,
  ⟨"lint aggregates and notes driverless members", do
    let result ← expectExit "lint" 0 lakew.toString #["lint"] dir
    let out := result.stdout ++ result.stderr
    ensureContains "lint summary" "lint: all 1 driver(s) passed" out
    ensureContains "skip note" "no lint driver (skipped)" out⟩]

end Suites.Drivers

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  Lakew.Test.withTempDir fun tmp => do
    let dir := tmp / "drivers"
    Lakew.Test.copyFixture "drivers" dir
    Lakew.Test.runCases "drivers" (Suites.Drivers.cases lakew dir) args
