/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/-!
# Test harness core

The assertion style and the runner every native suite in `tests/` shares,
modeled on `lean-fmt/tests/Test/Harness.lean`. A `Case` fails by throwing;
the runner catches it, prints it next to the test's name, keeps going, and
sets the exit code at the end — one failure costs exactly one test.

Deliberately smaller than lean-fmt's: `--shard` and timing decorations arrive
when a suite needs them, not before.
-/

namespace Lakew.Test

/-- One named test. `run` fails the test by throwing; anything it prints goes
to the suite's log, not the summary line. -/
public structure Case where
  name : String
  run : IO Unit

/-- The assertion every test is phrased in: fail with `message` unless
`condition`. -/
public def ensure (condition : Bool) (message : String) : IO Unit :=
  unless condition do
    throw <| IO.userError message

/-- Equality assertion that prints both sides on failure, so a regression
names the drift instead of naming a line number. -/
public def ensureEq [BEq α] [Repr α] (label : String) (expected actual : α) : IO Unit := do
  unless actual == expected do
    throw <| IO.userError s!"{label}\n  expected: {repr expected}\n  actual:   {repr actual}"

/-- Which tests a run should execute, parsed from the runner's command line. -/
public structure Selection where
  /-- Substring a test name must contain to run. -/
  filter : Option String := none
  /-- Print the selected names and exit without running anything. -/
  list : Bool := false

public def Selection.parse : List String → Except String Selection
  | [] => .ok {}
  | "--list" :: rest => do
    let selection ← Selection.parse rest
    .ok { selection with list := true }
  | "--filter" :: pattern :: rest => do
    let selection ← Selection.parse rest
    .ok { selection with filter := some pattern }
  | argument :: _ => .error s!"unknown argument: {argument}"

/-- The tests `selection` picks out of `cases`, in declaration order. -/
public def Selection.apply (selection : Selection) (cases : Array Case) : Array Case :=
  match selection.filter with
  | some pattern => cases.filter (·.name.contains pattern)
  | none => cases

/-- Run `cases` under the command line in `args`, printing one line per test
and a summary. Exit code 1 when any test failed, 2 when the arguments
themselves were rejected — the same convention the product binary uses. -/
public def runCases (label : String) (cases : Array Case) (args : List String) : IO UInt32 := do
  let selection ← match Selection.parse args with
    | .ok selection => pure selection
    | .error error => do
      IO.eprintln error
      IO.eprintln s!"usage: {label} [--list] [--filter SUBSTRING]"
      return 2
  let selected := selection.apply cases
  if selection.list then
    for test in selected do
      IO.println test.name
    return 0
  let mut failures : Array String := #[]
  for test in selected do
    let started ← IO.monoNanosNow
    try
      test.run
      let elapsedMs := ((← IO.monoNanosNow) - started) / 1000000
      IO.println s!"ok   {test.name}  ({elapsedMs}ms)"
    catch error =>
      IO.println s!"FAIL {test.name}\n  {error}"
      failures := failures.push test.name
  if failures.isEmpty then
    IO.println s!"{label}: {selected.size} test(s) passed"
    return 0
  else
    IO.eprintln s!"{label}: {failures.size} of {selected.size} test(s) failed: \
      {", ".intercalate failures.toList}"
    return 1

end Lakew.Test
