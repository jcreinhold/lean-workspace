/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test.Harness

/-!
# Golden files

`ensureGolden` compares a produced file against the committed expected file
(modeled on `lean-fmt/tests/Test/Golden.lean`). Regeneration is explicit:
run a suite with `UPDATE_GOLDEN=1` in the environment and a mismatch rewrites
the golden instead of failing, so the diff of that run's commit is the review
surface.
-/

namespace Lakew.Test

/-- Assert the file at `actual` equals the committed golden at `expected`,
byte for byte. With `UPDATE_GOLDEN=1`, a mismatch rewrites the golden
instead. -/
public def ensureGolden (label : String) (expected actual : System.FilePath) : IO Unit := do
  let expectedText ← IO.FS.readFile expected
  let actualText ← IO.FS.readFile actual
  unless actualText == expectedText do
    if (← IO.getEnv "UPDATE_GOLDEN").isSome then
      IO.FS.writeFile expected actualText
      IO.eprintln s!"{label}: updated golden {expected}"
    else
      throw <| IO.userError s!"{label}: drifted from {expected} \
        (re-run with UPDATE_GOLDEN=1 to regenerate)\n\
        --- expected ---\n{expectedText}\n--- actual ---\n{actualText}"

end Lakew.Test
