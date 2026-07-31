/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The external-drivers suite

Drivers qualified to **non-member** packages — mathlib's
`lintDriver := "batteries/runLinter"` is the motivating case — resolve
against the external package's own lakefile. The fixture's member `app`
borrows an exe (`shared/runner`) and a script (`shared/verify`) from a
*path* dependency living outside `members`; member `broken` exercises the
two unresolvable shapes (a missing target in a materialized package, a
package that was never required at all). A final case materializes a `git`
dependency from a runtime-created local repository and verifies the
`.lake/packages/<pkg>` scan path.

Cases 1–5 share one synced temp world in declaration order; the git case
uses its own world because its member lakefile embeds a commit hash that
only exists at test time.
-/

namespace Suites.ExternalDrivers

open Lakew.Test

/-- The shared world: app + broken + the vendor path dependency. -/
def sharedCases (lakew dir : System.FilePath) : Array Case := #[
  ⟨"sync the fixture, then check is clean", do
    let _ ← expectExit "sync" 0 lakew.toString #["sync"] dir
    let result ← expectExit "check" 0 lakew.toString #["check"] dir
    ensureContains "up to date" "up to date" (result.stdout ++ result.stderr)⟩,
  ⟨"the lint plan builds the external exe in the single build step", do
    let plan ← expectExit "lint --dry-run" 0 lakew.toString
      #["lint", "--dry-run", "--json"] dir
    ensureCount "runLake steps" "\"kind\": \"runLake\"" 1 plan.stdout
    ensureContains "external exe in build step" "\"@shared/runner\"" plan.stdout
    ensureContains "driver args in plan" "\"App\"" plan.stdout⟩,
  ⟨"lint runs the external exe driver with the member's args", do
    let result ← expectExit "lint" 0 lakew.toString #["lint"] dir
    let out := result.stdout ++ result.stderr
    ensureContains "external exe ran" "external runner ran with [App]" out
    ensureContains "lint summary" "lint: all 1 driver(s) passed" out
    ensureContains "unmaterialized package noted"
      "lint driver `ghost/tool` not found in external package `ghost` (skipped)" out⟩,
  ⟨"the test plan has no build step for a script-only external driver", do
    let plan ← expectExit "test --dry-run" 0 lakew.toString
      #["test", "--dry-run", "--json"] dir
    ensureCount "runLake steps" "\"kind\": \"runLake\"" 0 plan.stdout
    ensureContains "script driver step" "\"runDrivers\"" plan.stdout
    let out := plan.stdout ++ plan.stderr
    ensureContains "missing target noted"
      "test driver `shared/nope` not found in external package `shared` (skipped)" out⟩,
  ⟨"test runs the external script driver via lake script run", do
    let result ← expectExit "test" 0 lakew.toString #["test"] dir
    let out := result.stdout ++ result.stderr
    ensureContains "script ran" "verify script ran" out
    ensureContains "test summary" "test: all 1 driver(s) passed" out⟩]

/-- The git world: a runtime-created local repository required via `git`,
    so `lake update` materializes it under `.lake/packages/`. -/
def gitCases (lakew dir : System.FilePath) : Array Case := #[
  ⟨"a git dependency's driver resolves through .lake/packages", do
    -- Create the "upstream" package as a local git repository.
    let upstream := dir / "upstream" / "sharedgit"
    IO.FS.createDirAll upstream
    IO.FS.writeFile (upstream / "lakefile.lean")
      "import Lake\nopen Lake DSL\n\npackage «sharedgit» where\n\nlean_exe tool where\n  root := `Tool\n"
    IO.FS.writeFile (upstream / "Tool.lean")
      "def main : IO UInt32 := do IO.println \"git exe ran\"; return 0\n"
    initGitRepo upstream
    let sha ← runProc "git" #["-C", upstream.toString, "rev-parse", "HEAD"]
    let rev := sha.stdout.trimAscii.toString
    ensure (rev.length ≥ 7) s!"could not resolve HEAD of {upstream}"
    -- The member embeds the commit hash, so it can only be written now.
    let gapp := dir / "packages" / "gapp"
    IO.FS.createDirAll gapp
    IO.FS.writeFile (gapp / "lakefile.lean")
      s!"import Lake\nopen Lake DSL\n\npackage «gapp» where\n  testDriver := \"sharedgit/tool\"\n\nrequire sharedgit from git \"{upstream}\" @ \"{rev}\"\n\nlean_lib Gapp where\n"
    IO.FS.writeFile (gapp / "Gapp.lean") "def Gapp.x : Nat := 1\n"
    let _ ← expectExit "sync" 0 lakew.toString #["sync"] dir
    let plan ← expectExit "test --dry-run" 0 lakew.toString
      #["test", "-p", "gapp", "--dry-run", "--json"] dir
    ensureContains "git exe in build step" "\"@sharedgit/tool\"" plan.stdout⟩]

end Suites.ExternalDrivers

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  let code ← Lakew.Test.withTempDir fun tmp => do
    let dir := tmp / "external-drivers"
    Lakew.Test.copyFixture "external-drivers" dir
    Lakew.Test.runCases "external-drivers"
      (Suites.ExternalDrivers.sharedCases lakew dir) args
  if code != 0 then return code
  Lakew.Test.withTempDir fun tmp => do
    let dir := tmp / "external-drivers-git"
    Lakew.Test.copyFixture "external-drivers" dir
    Lakew.Test.runCases "external-drivers-git"
      (Suites.ExternalDrivers.gitCases lakew dir) args
