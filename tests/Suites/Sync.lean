/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The sync suite

Port of `test/run.sh`'s `basic` fixture: the generate → check → lock → build
lifecycle on one copied project, including the goldens that pin the generated
root byte-for-byte and the stock-`lake` interop check that proves the
generated root is a real Lake project.

Cases run in declaration order over one shared temp world and mutate it the
way the shell script did (a stale-check edit is re-synced away, `--locked`'s
model change is checked out before `--changed` starts). A failing case can
therefore cascade; the first failure is the one to read.
-/

namespace Suites.Sync

open Lakew.Test

/-- The suite's world: the copied fixture, its goldens, and the binary. -/
structure Ctx where
  lakew : System.FilePath
  dir : System.FilePath
  golden : System.FilePath

def lakew (ctx : Ctx) (label : String) (code : UInt32) (args : Array String) : IO ProcResult :=
  expectExit label code ctx.lakew.toString args ctx.dir

def cases (ctx : Ctx) : Array Case := #[
  ⟨"sync generates the root lakefile", do
    let _ ← lakew ctx "sync" 0 #["sync"]
    ensure (← (ctx.dir / "lakefile.lean").pathExists) "sync did not write lakefile.lean"⟩,
  ⟨"golden: lakefile.lean", do
    ensureGolden "lakefile.lean" (ctx.golden / "lakefile.lean") (ctx.dir / "lakefile.lean")⟩,
  ⟨"golden: package-overrides.json", do
    ensureGolden "package-overrides.json" (ctx.golden / ".lake" / "package-overrides.json")
      (ctx.dir / ".lake" / "package-overrides.json")⟩,
  ⟨"golden: metadata.json", do
    ensureGolden "metadata.json" (ctx.golden / ".lake" / "workspace" / "metadata.json")
      (ctx.dir / ".lake" / "workspace" / "metadata.json")⟩,
  ⟨"stock lake builds the generated root", do
    let _ ← expectExit "stock lake build" 0 "lake" #["build", "@core", "@tactics"] ctx.dir⟩,
  ⟨"check passes after sync", do
    let result ← lakew ctx "check" 0 #["check"]
    ensureContains "check output" "up to date" (result.stdout ++ result.stderr)⟩,
  ⟨"check fails on a stale generated root", do
    appendFile (ctx.dir / "lakefile.lean") "# hand edit\n"
    let result ← lakew ctx "check (stale)" 1 #["check"]
    ensureContains "stale diagnostic" "out of date" (result.stdout ++ result.stderr)⟩,
  ⟨"sync --locked passes when fresh", do
    initGitRepo ctx.dir
    -- Restore the generated root the stale check dirtied, then commit it.
    let _ ← lakew ctx "resync" 0 #["sync"]
    let _ ← expectExit "git add" 0 "git" #["add", "-A"] ctx.dir
    let _ ← expectExit "git commit" 0 "git"
      #["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "resync"] ctx.dir
    let _ ← lakew ctx "sync --locked" 0 #["sync", "--locked"]⟩,
  ⟨"sync --locked fails when the model changed", do
    appendFile (ctx.dir / "lean-workspace.toml")
      "\n[groups.extra]\nmembers = [\"core\"]\n"
    let _ ← lakew ctx "sync --locked (stale)" 1 #["sync", "--locked"]
    gitCheckout ctx.dir #["lean-workspace.toml"]⟩,
  ⟨"a build plan is exactly one lake invocation", do
    let plan ← lakew ctx "build plan" 0 #["build", "--group", "foundation", "--dry-run", "--json"]
    ensureCount "runLake steps" "\"kind\": \"runLake\"" 1 plan.stdout
    ensureContains "both targets in one argv" "\"@core\"," plan.stdout⟩,
  ⟨"the explanation trace names the selection reason", do
    let plan ← lakew ctx "build -p tactics" 0 #["build", "-p", "tactics", "--dry-run"]
    ensureContains "explanation" "tactics: selected via -p" (plan.stdout ++ plan.stderr)⟩,
  ⟨"--changed: a tactics file selects tactics only", do
    appendFile (ctx.dir / "packages" / "tactics" / "Tactic" / "Elab.lean")
      "\ndef Tactic.Elab.extra : Nat := 0\n"
    let plan ← lakew ctx "build --changed" 0 #["build", "--changed", "HEAD", "--dry-run"]
    ensureContains "tactics selected" "@tactics" plan.stdout
    ensureAbsent "core not selected" "@core" plan.stdout
    gitCheckout ctx.dir #["packages/tactics/Tactic/Elab.lean"]⟩,
  ⟨"--changed: a core change closes over reverse dependencies", do
    appendFile (ctx.dir / "packages" / "core" / "Core.lean") "\ndef Core.extra : Nat := 0\n"
    let plan ← lakew ctx "build --changed" 0 #["build", "--changed", "HEAD", "--dry-run"]
    ensureContains "syntax selected" "@syntax" plan.stdout
    ensureContains "tactics selected" "@tactics" plan.stdout
    ensureContains "explanation" "depends on a changed package" (plan.stdout ++ plan.stderr)
    gitCheckout ctx.dir #["packages/core/Core.lean"]⟩,
  ⟨"--changed: a toolchain change selects everything", do
    appendFile (ctx.dir / "lean-toolchain") "# touch\n"
    let plan ← lakew ctx "build --changed" 0 #["build", "--changed", "HEAD", "--dry-run"]
    ensureContains "global change" "globally affected" (plan.stdout ++ plan.stderr)
    gitCheckout ctx.dir #["lean-toolchain"]⟩]

end Suites.Sync

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  let golden ← Lakew.Test.goldenDir
  Lakew.Test.withTempDir fun tmp => do
    let dir := tmp / "basic"
    Lakew.Test.copyFixture "basic" dir
    Lakew.Test.runCases "sync" (Suites.Sync.cases ⟨lakew, dir, golden / "basic"⟩) args
