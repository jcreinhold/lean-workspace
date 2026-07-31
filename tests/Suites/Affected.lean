/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The affected suite

Port of `test/run.sh`'s `--affected` + `why` phase: module-granularity change
selection. `--affected` selects importers of changed modules through the
import graph (not the package-level reverse closure `--changed` uses), names
the changed module and the importing edge in its explanation, excludes
unrelated members, and treats zero changes as a graceful no-op. `why` prints
a dependency path or fails when none exists.

The fixture is a real git repository (selection diffs against `HEAD`); cases
share it in declaration order and check out each edit before the next.
-/

namespace Suites.Affected

open Lakew.Test

def lakew (bin dir : System.FilePath) (label : String) (code : UInt32)
    (args : Array String) : IO ProcResult :=
  expectExit label code bin.toString args dir

def cases (lakewBin dir : System.FilePath) : Array Case := #[
  ⟨"sync and commit the fixture", do
    let _ ← lakew lakewBin dir "sync" 0 #["sync"]
    initGitRepo dir⟩,
  ⟨"why prints the dependency path", do
    let result ← lakew lakewBin dir "why tactics core" 0 #["why", "tactics", "core"]
    ensureContains "path" "tactics → syntax → core" (result.stdout ++ result.stderr)⟩,
  ⟨"why errors when no path exists", do
    let _ ← lakew lakewBin dir "why util core" 1 #["why", "util", "core"]⟩,
  ⟨"--affected: reverse module closure selects importers", do
    appendFile (dir / "packages" / "core" / "Core" / "A.lean") "\ndef Core.A.x2 := 1\n"
    let plan ← lakew lakewBin dir "build --affected" 0
      #["build", "--affected", "HEAD", "--dry-run"]
    let out := plan.stdout ++ plan.stderr
    ensureContains "importer explanation" "module Syntax.X imports a changed module" out
    ensureContains "changed module named" "module Core.A changed" out
    ensureAbsent "unrelated member excluded" "util" out
    gitCheckout dir #["packages/core/Core/A.lean"]⟩,
  ⟨"--affected: a leaf module selects its own package only", do
    appendFile (dir / "packages" / "tactics" / "Tactic" / "Z.lean") "\ndef Tactic.Z.v2 := 0\n"
    let plan ← lakew lakewBin dir "build --affected" 0
      #["build", "--affected", "HEAD", "--dry-run"]
    ensureContains "own package selected" "@tactics" plan.stdout
    ensureAbsent "no over-selection" "@core" plan.stdout
    gitCheckout dir #["packages/tactics/Tactic/Z.lean"]⟩,
  ⟨"--affected: zero changes is a graceful no-op", do
    let plan ← lakew lakewBin dir "build --affected" 0
      #["build", "--affected", "HEAD", "--dry-run"]
    ensureContains "no-op note" "nothing to build" (plan.stdout ++ plan.stderr)⟩]

end Suites.Affected

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  Lakew.Test.withTempDir fun tmp => do
    let dir := tmp / "affected"
    Lakew.Test.copyFixture "affected" dir
    Lakew.Test.runCases "affected" (Suites.Affected.cases lakew dir) args
