/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import Test.Proc

/-!
# Filesystem fixtures

Scratch space discipline for suites (modeled on `lean-fmt/tests/Test/Fixture.lean`):
a suite's world — synthetic workspaces, copied fixture projects — lives in an
OS temp dir and is removed by `finally`, including on failure. Nothing a suite
does can dirty the working tree, which is what lets suites overlap.

`copyTree` and the golden-file helpers of lean-fmt's fixture module arrive
with the migration of `test/run.sh`'s fixture suites; this module grows with
its callers, not ahead of them.
-/

namespace Lakew.Test

/-- Create a temp directory, run `f` in it, remove it afterwards — including
on failure. -/
public def withTempDir (f : System.FilePath → IO α) : IO α := do
  let directory ← IO.FS.createTempDir
  try
    f directory
  finally
    IO.FS.removeDirAll directory

/-- The repository root, resolved through git so suites work from any working
directory the runner invokes them in. -/
public def repoRoot : IO System.FilePath := do
  let result ← runProc "git" #["rev-parse", "--show-toplevel"]
  ensure (result.exitCode == 0) s!"git rev-parse failed:\n{result.stderr}"
  return ⟨result.stdout.trimAscii.toString⟩

end Lakew.Test
