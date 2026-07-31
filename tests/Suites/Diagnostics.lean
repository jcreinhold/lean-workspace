/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The diagnostics suite

Port of `test/run.sh`'s violation fixtures: `lakew check` must reject each
broken workspace with exit code 1 and the specific, actionable diagnostic.
These cases pin the wording of the policy errors — a regression here is a
user-facing regression, not an internal one.

Each case owns an independent temp copy of its fixture, so the suite is
parallel-lane safe.
-/

namespace Suites.Diagnostics

open Lakew.Test

/-- One broken fixture and the diagnostic its check must produce. -/
structure Violation where
  fixture : String
  pattern : String

def violations : Array Violation := #[
  ⟨"conflict", "Conflicting dependency `batteries`"⟩,
  ⟨"undeclared-import", "does not declare a direct dependency on `liba`"⟩,
  ⟨"dup-root", "module root `Common` is claimed by both"⟩,
  ⟨"prod-imports-test", "production package `core` imports"⟩,
  ⟨"cycle", "package dependency cycle detected"⟩]

end Suites.Diagnostics

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  let cases : Array Lakew.Test.Case := Suites.Diagnostics.violations.map fun v =>
    ⟨s!"violation: {v.fixture}", do
      Lakew.Test.withTempDir fun tmp => do
        let dir := tmp / v.fixture
        Lakew.Test.copyFixture v.fixture dir
        let result ← Lakew.Test.expectExit s!"check {v.fixture}" 1 lakew.toString #["check"] dir
        Lakew.Test.ensureContains "diagnostic" v.pattern (result.stdout ++ result.stderr)⟩
  Lakew.Test.runCases "diagnostics" cases args
