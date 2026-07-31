/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test.Harness

/-!
# Process spawning for suites

Every suite drives the real product binary — that is the point of a suite —
so the spawn wrapper lives here once instead of being re-derived per suite
from `IO.Process.output` (modeled on `lean-fmt/tests/Test/Proc.lean`).
`runProc` captures; `expectExit` captures and asserts, naming the label the
suite gave the invocation so a failure reads as the behavior that broke.

No timeout variant: lakew invocations are short-lived, and the kill switch
arrives with the first suite that needs it.
-/

namespace Lakew.Test

/-- The captured result of one child process. -/
public structure ProcResult where
  exitCode : UInt32
  stdout : String
  stderr : String

/-- Run `cmd` to completion, capturing both streams. -/
public def runProc (cmd : String) (args : Array String := #[])
    (cwd? : Option System.FilePath := none) : IO ProcResult := do
  let output ← IO.Process.output { cmd, args, cwd := cwd? }
  return { exitCode := output.exitCode, stdout := output.stdout, stderr := output.stderr }

/-- `runProc` plus an exit-code assertion; the error quotes both streams so a
failure is self-explanatory in the suite log. -/
public def expectExit (label : String) (code : UInt32) (cmd : String)
    (args : Array String := #[]) (cwd? : Option System.FilePath := none) : IO ProcResult := do
  let result ← runProc cmd args cwd?
  ensure (result.exitCode == code) s!"{label}: expected exit {code}, got {result.exitCode}\
    \n  stdout: {result.stdout}\n  stderr: {result.stderr}"
  return result

end Lakew.Test
