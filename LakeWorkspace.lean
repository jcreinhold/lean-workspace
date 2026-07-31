/-
LakeWorkspace — the curated public surface.

Clients use exactly these operations. Successful construction of a
`Workspace` (via `load`) guarantees all workspace invariants; the internal
modules `LakeWorkspace.{Toml,Workspace,Selection,Planner,Executor,Backend.*}`
are implementation details and may change without notice.
-/

module

public import LakeWorkspace.Workspace
public import LakeWorkspace.Selection
public import LakeWorkspace.Planner
public import LakeWorkspace.Executor
public import LakeWorkspace.Report
import LakeWorkspace.Backend.LakeCli

public section

namespace LakeWorkspace

/-- Load, discover, resolve and validate the workspace rooted at `root`
    (the directory containing `lean-workspace.toml`). Spawns no processes. -/
def load (root : FilePath) (loadModuleImports : Bool := true) (bench : Bool := false) :
    IO (Except Diagnostics Workspace) :=
  Workspace.load root loadModuleImports bench

/-- Select a canonical set of package-qualified targets. Pure. -/
def select (workspace : Workspace) (query : SelectionQuery) : Except Diagnostics Selection :=
  Selection.select workspace query

/-- Plan an action. Pure except for driver actions (`test`/`lint`), which
    may read external packages' lakefiles and probe `lake scripts` to
    resolve drivers qualified to non-member packages. -/
def plan (workspace : Workspace) (selection : Selection) (action : Action) :
    IO (Except Diagnostics BuildPlan) :=
  Planner.plan workspace selection action

/-- Execute a plan: the single Lake subprocess, transactional installs,
    exit-code aggregation. Driver steps produce a combined report. With
    `capture`, subprocess output goes to stderr so stdout stays parseable. -/
def execute (plan : BuildPlan) (capture : Bool := false) : IO (UInt32 × Option Report) :=
  Executor.execute plan capture

/-- `lakew check`: regenerate all generated files in memory and diff against
    what is on disk. Empty array = up to date. -/
def staleFiles (ws : Workspace) : IO (Array String) := do
  let mut stale : Array String := #[]
  for (rel, expected) in Backend.LakeCli.generatedFiles ws do
    let target := ws.root / rel
    let actual? ← try pure (some (← IO.FS.readFile target)) catch _ => pure none
    match actual? with
    | none => stale := stale.push s!"{rel.toString} (missing)"
    | some actual =>
      if actual != expected then
        stale := stale.push s!"{rel.toString} (out of date)"
  return stale

end LakeWorkspace

end -- public section
