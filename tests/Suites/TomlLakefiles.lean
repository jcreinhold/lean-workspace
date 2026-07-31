/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The lakefile.toml suite

PLAN-02's verification: members may carry `lakefile.toml` (the ecosystem
standard — batteries, Cli, Qq ship nothing else) and everything downstream
works unchanged: requires validated, drivers discovered, `[options]` policy
enforced *exactly* (TOML values are always literals — the "verify manually"
escape hatch never fires), `[deps]` mismatch diagnostics name the TOML file,
`--write-deps` declines TOML rewrites with a named manual edit, and a member
carrying both formats is a config error (Lake's own rule).

The `toml-verbatim` fixture's members carry byte-for-byte copies of
batteries' and Cli's real `lakefile.toml` files — the acceptance test that
our reading is Lake's reading.
-/

namespace Suites.TomlLakefiles

open Lakew.Test

def lakew (bin dir : System.FilePath) (label : String) (code : UInt32)
    (args : Array String) : IO ProcResult :=
  expectExit label code bin.toString args dir

/-- The mixed Lean+TOML workspace: exe-driver discovery and exact options. -/
def memberCases (bin dir : System.FilePath) : Array Case := #[
  ⟨"a TOML member loads, syncs, and checks clean", do
    let _ ← lakew bin dir "sync" 0 #["sync"]
    let result ← lakew bin dir "check" 0 #["check"]
    ensureContains "check output" "up to date" (result.stdout ++ result.stderr)⟩,
  ⟨"the exe driver of a TOML member joins the single build step", do
    let plan ← lakew bin dir "test --dry-run" 0 #["test", "--dry-run", "--json"]
    ensureCount "runLake steps" "\"kind\": \"runLake\"" 1 plan.stdout
    ensureContains "exe driver built" "\"@widgets/tool\"" plan.stdout⟩,
  ⟨"[options] verifies a TOML member's value exactly", do
    let file := dir / "packages" / "widgets" / "lakefile.toml"
    let original ← IO.FS.readFile file
    IO.FS.writeFile file (original.replace "linter.missingDocs = true" "linter.missingDocs = false")
    let result ← lakew bin dir "check (wrong value)" 1 #["check"]
    let out := result.stdout ++ result.stderr
    ensureContains "wrong-value diagnostic"
      "member `widgets` sets `linter.missingDocs` to false, but the workspace \
       [options] policy requires true" out
    ensureContains "names the TOML lakefile" "packages/widgets/lakefile.toml" out
    IO.FS.writeFile file original⟩,
  ⟨"[options] names the TOML fix when the option is absent", do
    let file := dir / "packages" / "widgets" / "lakefile.toml"
    let original ← IO.FS.readFile file
    IO.FS.writeFile file (original.replace "linter.missingDocs = true" "# removed")
    let result ← lakew bin dir "check (missing option)" 1 #["check"]
    let out := result.stdout ++ result.stderr
    ensureContains "missing-option diagnostic"
      "member `widgets` does not set required workspace option `linter.missingDocs`" out
    ensureContains "TOML-specific hint" "to its [leanOptions]" out
    IO.FS.writeFile file original⟩]

/-- The verbatim batteries/Cli workspace: our reading is Lake's reading. -/
def verbatimCases (bin dir : System.FilePath) : Array Case := #[
  ⟨"verbatim batteries and Cli lakefiles check clean", do
    let _ ← lakew bin dir "sync" 0 #["sync"]
    let result ← lakew bin dir "check" 0 #["check"]
    ensureContains "check output" "up to date" (result.stdout ++ result.stderr)⟩,
  ⟨"drivers are discovered from TOML keys", do
    let lint ← lakew bin dir "lint --dry-run" 0 #["lint", "--dry-run"]
    ensureContains "lint driver" "batteries/runLinter" (lint.stdout ++ lint.stderr)
    let plan ← lakew bin dir "test --dry-run" 0 #["test", "--dry-run", "--json"]
    ensureContains "batteries test lib" "\"@batteries/BatteriesTest\"" plan.stdout
    ensureContains "Cli test lib" "\"@Cli/CliTest\"" plan.stdout⟩]

/-- Central [deps]: the diagnostic names the TOML file; the rewrite declines. -/
def writeDepsCases (bin dir : System.FilePath) : Array Case := #[
  ⟨"a [deps] mismatch names the member's lakefile.toml", do
    let result ← lakew bin dir "check" 1 #["check"]
    let out := result.stdout ++ result.stderr
    ensureContains "central-declaration diagnostic"
      "does not match the workspace [deps] declaration" out
    ensureContains "names the TOML lakefile" "packages/server/lakefile.toml" out⟩,
  ⟨"--write-deps declines TOML rewrites with a named manual edit", do
    let result ← lakew bin dir "sync --write-deps" 1 #["sync", "--write-deps"]
    let out := result.stdout ++ result.stderr
    ensureContains "decline note" "TOML lakefiles are not rewritten automatically" out
    ensureContains "manual edit named" "git https://example.invalid/batteries @ b136111" out⟩]

end Suites.TomlLakefiles

public def main (args : List String) : IO UInt32 := do
  let bin ← Lakew.Test.lakewBinary
  let bothFormats : Array Lakew.Test.Case := #[
    ⟨"a member carrying both formats is a config error", do
      Lakew.Test.withTempDir fun tmp => do
        let dir := tmp / "toml-both-formats"
        Lakew.Test.copyFixture "toml-both-formats" dir
        let result ← Lakew.Test.expectExit "check" 1 bin.toString #["check"] dir
        Lakew.Test.ensureContains "both-formats diagnostic"
          "both lakefile.lean and lakefile.toml exist" (result.stdout ++ result.stderr)⟩]
  Lakew.Test.withTempDir fun tmp => do
    let members := tmp / "toml-members"
    let verbatim := tmp / "toml-verbatim"
    let writeDeps := tmp / "toml-write-deps"
    Lakew.Test.copyFixture "toml-members" members
    Lakew.Test.copyFixture "toml-verbatim" verbatim
    Lakew.Test.copyFixture "toml-write-deps" writeDeps
    let cases := Suites.TomlLakefiles.memberCases bin members
      ++ Suites.TomlLakefiles.verbatimCases bin verbatim
      ++ Suites.TomlLakefiles.writeDepsCases bin writeDeps
      ++ bothFormats
    Lakew.Test.runCases "toml-lakefiles" cases args
