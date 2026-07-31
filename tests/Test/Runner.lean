/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The suite orchestrator

`test/run.sh`'s successor and the package's `testDriver`: `lake test` answers
"is the tree green". Modeled on `lean-fmt/tests/Test/Runner.lean`, kept
sequential — every suite owns a temp world, and at six functional suites the
lane pool lean-fmt runs has no caller here yet; the registry is the same
shape (name + `slow` tag) so adding lanes later is additive.

The contract, as lean-fmt's: every selected executable is built in **one**
up-front `lake build` (no builds during the run), one PASS/FAIL line per
suite with seconds, and a failing suite's full log is what gets printed.
-/

namespace Lakew.Test.Runner

open Lakew.Test

/-- One registered suite. The executable is `suite-<name>` by convention. -/
structure Suite where
  name : String
  /-- Slow suites (benchmarks, timing gates) are out of the default set;
  `--all` includes them and `--suites` names them explicitly. -/
  slow : Bool := false
  deriving Inhabited

def Suite.exeName (suite : Suite) : String := s!"suite-{suite.name}"

/-- The suite registry. Adding a suite is a `lean_exe «suite-<name>»` in the
lakefile plus one line here; a name in either place but not the other fails
loudly (the build step for the first, this list for the second). -/
private def registered : Array Suite := #[
  { name := "sync" },
  { name := "diagnostics" },
  { name := "shared-deps" },
  { name := "drivers" },
  { name := "affected" },
  { name := "options-policy" },
  { name := "toml-lakefiles" },
  { name := "external-drivers" },
  { name := "cache-policy" },
  { name := "bench", slow := true }]

/-- What a run was asked to do. -/
structure Options where
  /-- Include `slow` suites. -/
  all : Bool := false
  /-- Run exactly these suites, ignoring the slow tag. -/
  suites : Option (Array String) := none
  /-- Print the registry and exit. -/
  list : Bool := false

private def usage : String :=
  "usage: test-suites [--all] [--suites NAME...] [--list]"

private def parseArgs (args : List String) : Except String Options := do
  let arguments := args.toArray
  let mut options : Options := {}
  let mut index := 0
  while index < arguments.size do
    match arguments[index]! with
    | "--all" => options := { options with all := true }
    | "--list" => options := { options with list := true }
    | "--suites" =>
      index := index + 1
      let mut names : Array String := #[]
      while index < arguments.size && !(arguments[index]!.startsWith "--") do
        names := names.push arguments[index]!
        index := index + 1
      if names.isEmpty then
        throw "--suites expects at least one name"
      index := index - 1
      options := { options with suites := some (options.suites.getD #[] ++ names) }
    | argument => throw s!"unknown argument: {argument}"
    index := index + 1
  return options

/-- The suites `options` selects, in registry order. An unknown name is an
error, not a silent skip — a typo must not produce a green run of the wrong
set. -/
private def select (options : Options) : Except String (Array Suite) := do
  match options.suites with
  | some names =>
    let mut selected : Array Suite := #[]
    for name in names do
      match registered.find? (·.name == name) with
      | some suite => selected := selected.push suite
      | none => throw s!"unknown suite: {name} (registry: \
          {", ".intercalate (registered.map (·.name)).toList})"
    return selected
  | none =>
    return registered.filter fun suite => options.all || !suite.slow

/-- The recorded outcome of one suite run. -/
private structure Outcome where
  suite : Suite
  passed : Bool
  elapsedSec : Nat
  output : String

/-- Run one suite's executable, capturing everything it says. -/
private def runSuite (root : System.FilePath) (suite : Suite) : IO Outcome := do
  let started ← IO.monoNanosNow
  let result ← runProc (root / ".lake" / "build" / "bin" / suite.exeName).toString
    (cwd? := some root)
  let elapsedSec := ((← IO.monoNanosNow) - started) / 1000000000
  return { suite, passed := result.exitCode == 0, elapsedSec,
           output := result.stdout ++ result.stderr }

/-- Build every selected executable in one invocation, so the run itself
contains no builds. The product binary is built alongside: every suite drives
it, so a source edit that only rebuilds a suite would test a stale product. -/
private def buildSuites (root : System.FilePath) (suites : Array Suite) : IO Unit := do
  let result ← runProc "lake" (#["-q", "build", "lakew"] ++ suites.map (·.exeName))
    (cwd? := some root)
  ensure (result.exitCode == 0) s!"suite executables failed to build:\n{result.stderr}"

end Lakew.Test.Runner

public def main (args : List String) : IO UInt32 := do
  let root ← Lakew.Test.repoRoot
  let options ← match Lakew.Test.Runner.parseArgs args with
    | .ok options => pure options
    | .error error => do
      IO.eprintln error
      IO.eprintln Lakew.Test.Runner.usage
      return 2
  let suites ← match Lakew.Test.Runner.select options with
    | .ok suites => pure suites
    | .error error => do
      IO.eprintln error
      return 2
  if options.list then
    for suite in suites do
      IO.println s!"{suite.name}{if suite.slow then " (slow)" else ""}"
    return 0
  Lakew.Test.Runner.buildSuites root suites
  let mut failures : Array Lakew.Test.Runner.Outcome := #[]
  for suite in suites do
    let outcome ← Lakew.Test.Runner.runSuite root suite
    IO.println s!"{suite.name}  {if outcome.passed then "PASS" else "FAIL"}  {outcome.elapsedSec}s"
    unless outcome.passed do
      failures := failures.push outcome
  for failure in failures do
    IO.println s!"\n===== {failure.suite.name} log =====\n{failure.output}"
  if failures.isEmpty then
    IO.println s!"test-suites: {suites.size} suite(s) passed"
    return 0
  else
    IO.eprintln s!"test-suites: {failures.size} of {suites.size} suite(s) failed"
    return 1
