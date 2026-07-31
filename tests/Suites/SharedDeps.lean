/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The shared-deps suite

Port of `test/run.sh`'s `[deps]` phase: central dependency declarations are
policy — a member whose require disagrees with the workspace declaration
fails `check` with a diagnostic that names the member lakefile, and
`sync --write-deps` (the explicit opt-in rewrite) aligns it to the central
rev, after which `check` passes.

Cases share one temp world in declaration order: the alignment case depends
on the mismatch having been diagnosed first.
-/

namespace Suites.SharedDeps

open Lakew.Test

def cases (lakew dir : System.FilePath) : Array Case := #[
  ⟨"a mismatched [deps] declaration fails check", do
    let result ← expectExit "check" 1 lakew.toString #["check"] dir
    let out := result.stdout ++ result.stderr
    ensureContains "central-declaration diagnostic"
      "does not match the workspace [deps] declaration" out
    ensureContains "names the member lakefile" "packages/server/lakefile.lean" out⟩,
  ⟨"sync --write-deps aligns the member to the central rev", do
    let result ← expectExit "sync --write-deps" 0 lakew.toString
      #["sync", "--write-deps", "--offline"] dir
    ensureContains "alignment note" "aligned" (result.stdout ++ result.stderr)
    let lakefile ← IO.FS.readFile (dir / "packages" / "server" / "lakefile.lean")
    ensureContains "rewritten require"
      "require batteries from git \"https://example.invalid/batteries\" @ \"b136111\"" lakefile⟩,
  ⟨"check passes after alignment", do
    let result ← expectExit "check" 0 lakew.toString #["check"] dir
    ensureContains "check output" "up to date" (result.stdout ++ result.stderr)⟩]

end Suites.SharedDeps

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  Lakew.Test.withTempDir fun tmp => do
    let dir := tmp / "shared-deps"
    Lakew.Test.copyFixture "shared-deps" dir
    Lakew.Test.runCases "shared-deps" (Suites.SharedDeps.cases lakew dir) args
