/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/
module

public import LakeWorkspace.Planner
public import LakeWorkspace.Report

/-!
The executor: runs plan steps.

Owns the single Lake subprocess, transactional generated-file installation,
and exit-code aggregation. It has no knowledge of manifests, members, or
dependency semantics — a `PlanStep` is self-contained.
-/

public section

namespace LakeWorkspace.Executor

open LakeWorkspace

/-- Write all files to temporary siblings, then rename them into place.
    Rename is atomic per file; all temps are written before any rename, so a
    failure mid-install never leaves a mix of old and new *contents* within a
    single file, and leaves recoverable `*.lakew-tmp` artifacts otherwise. -/
def installFiles (root : FilePath) (files : Array (FilePath × String)) : IO UInt32 := do
  let mut temps : Array (FilePath × FilePath) := #[]
  for (rel, contents) in files do
    let target := root / rel
    let tmp : FilePath := ⟨target.toString ++ ".lakew-tmp"⟩
    try
      if let some parent := target.parent then
        IO.FS.createDirAll parent
      IO.FS.writeFile tmp contents
      temps := temps.push (tmp, target)
    catch e =>
      IO.eprintln s!"error: failed to stage {rel.toString}: {e}"
      return 1
  for (tmp, target) in temps do
    try
      IO.FS.rename tmp target
      IO.println s!"installed {target.toString}"
    catch e =>
      IO.eprintln s!"error: failed to install {target.toString}: {e}"
      return 1
  return 0

/-- Verify on-disk files match expected contents exactly. -/
def verifyFiles (root : FilePath) (files : Array (FilePath × String)) : IO UInt32 := do
  let mut stale : Array String := #[]
  for (rel, expected) in files do
    let target := root / rel
    let actual? ← try pure (some (← IO.FS.readFile target)) catch _ => pure none
    match actual? with
    | none => stale := stale.push s!"{rel.toString} (missing)"
    | some actual =>
      if actual != expected then
        stale := stale.push s!"{rel.toString} (out of date)"
  if stale.isEmpty then
    return 0
  else
    IO.eprintln "error: generated files are stale; run `lakew sync`:"
    for s in stale do
      IO.eprintln s!"  {s}"
    return 1

/-- Run the pinned `lake` executable once, inheriting stdio. When
    `capture` is set, output is captured and forwarded to stderr instead, so
    stdout stays clean for machine-readable reports. -/
def runLake (root : FilePath) (args : Array String) (capture : Bool := false) : IO UInt32 := do
  IO.eprintln s!"+ lake {" ".intercalate args.toList}"
  if capture then
    let out ← IO.Process.output { cmd := "lake", args := args, cwd := some root }
    if !out.stdout.isEmpty then IO.eprint out.stdout
    if !out.stderr.isEmpty then IO.eprint out.stderr
    return out.exitCode
  else
    let child ← IO.Process.spawn {
      cmd := "lake"
      args := args
      cwd := some root
      stdin := .inherit
      stdout := .inherit
      stderr := .inherit
    }
    child.wait

/-- Maximum number of driver processes run concurrently (default inside;
    no CLI flag until a caller needs one). -/
def driverJobs : Nat := 4

/-- Run one driver, capturing output. Driver failure is data, never an
    exception. -/
def runOneDriver (root : FilePath) (cliArgs : Array String) (d : ResolvedDriver) :
    IO DriverResult := do
  let start ← IO.monoMsNow
  let args := d.spec.args ++ cliArgs
  let (exitCode, output) ← match d.targetKind with
    | .lib =>
      -- the preceding build step succeeded, which is the whole test
      pure (0, "")
    | .exe =>
      let exe := root / d.relDir / ".lake/build/bin" / d.spec.target
      try
        let out ← IO.Process.output { cmd := exe.toString, args := args }
        pure (out.exitCode, out.stdout ++ out.stderr)
      catch e =>
        pure (1, s!"failed to run {exe.toString}: {e}")
    | .script =>
      try
        let out ← IO.Process.output {
          cmd := "lake"
          args := #["script", "run", s!"{d.pkg}/{d.spec.target}"] ++ args
          cwd := some root }
        pure (out.exitCode, out.stdout ++ out.stderr)
      catch e =>
        pure (1, s!"failed to run lake script: {e}")
  let durationMs := (← IO.monoMsNow) - start
  return { pkg := d.pkg, kind := d.spec.kind, target := d.spec.target,
           targetKind := d.targetKind, exitCode, durationMs, output }

/-- Run drivers with bounded parallelism (waves of `driverJobs`), preserving
    selection order in the report. -/
def runDrivers (root : FilePath) (drivers : Array ResolvedDriver) (cliArgs : Array String) :
    IO Report := do
  let kind := drivers[0]?.map (·.spec.kind) |>.getD "test"
  let mut results : Array DriverResult := #[]
  let mut i := 0
  while i < drivers.size do
    let wave := drivers.extract i (i + driverJobs)
    let tasks ← wave.mapM fun d => IO.asTask (runOneDriver root cliArgs d)
    for t in tasks do
      let r ← IO.wait t
      match r with
      | .ok res => results := results.push res
      | .error e =>
        let res : DriverResult :=
          { pkg := "?", kind := kind, target := "?", targetKind := .script,
            exitCode := 1, durationMs := 0, output := toString e }
        results := results.push res
    i := i + driverJobs
  return { kind, results }

def runStep (root : FilePath) (capture : Bool) : PlanStep → IO (UInt32 × Option Report)
  | .installFiles files => return (← installFiles root files, none)
  | .verifyFiles files => return (← verifyFiles root files, none)
  | .runLake args => return (← runLake root args capture, none)
  | .runDrivers drivers cliArgs => do
    let report ← runDrivers root drivers cliArgs
    let failed := report.results.filter (·.exitCode != 0)
    let code := failed[0]?.map (·.exitCode) |>.getD 0
    return (code, some report)

/-- Execute steps in order; stop at the first failure and return its code.
    Driver steps always run every driver (aggregation, doc §7); their report
    is returned to the caller. With `capture`, subprocess output goes to
    stderr so stdout carries only the report. -/
def execute (plan : BuildPlan) (capture : Bool := false) : IO (UInt32 × Option Report) := do
  let mut report? : Option Report := none
  for step in plan.steps do
    let (code, r?) ← runStep plan.root capture step
    if r?.isSome then report? := r?
    if code != 0 then
      return (code, report?)
  return (0, report?)

end LakeWorkspace.Executor

end -- public section
