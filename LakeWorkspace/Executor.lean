/-
The executor: runs plan steps.

Owns the single Lake subprocess, transactional generated-file installation,
and exit-code aggregation. It has no knowledge of manifests, members, or
dependency semantics — a `PlanStep` is self-contained.
-/
import LakeWorkspace.Planner

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

/-- Run the pinned `lake` executable once, inheriting stdio. -/
def runLake (root : FilePath) (args : Array String) : IO UInt32 := do
  IO.println s!"+ lake {" ".intercalate args.toList}"
  let child ← IO.Process.spawn {
    cmd := "lake"
    args := args
    cwd := some root
    stdin := .inherit
    stdout := .inherit
    stderr := .inherit
  }
  child.wait

def runStep (root : FilePath) : PlanStep → IO UInt32
  | .installFiles files => installFiles root files
  | .verifyFiles files => verifyFiles root files
  | .runLake args => runLake root args

/-- Execute steps in order; stop at the first failure and return its code. -/
def execute (plan : BuildPlan) : IO UInt32 := do
  for step in plan.steps do
    let code ← runStep plan.root step
    if code != 0 then
      return code
  return 0

end LakeWorkspace.Executor
