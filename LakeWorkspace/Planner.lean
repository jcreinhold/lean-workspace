/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/
module

public import LakeWorkspace.Selection
import LakeWorkspace.Backend.LakeCli
public import LakeWorkspace.Json

/-!
The planner: translate an action into a deterministic sequence of steps.

Planning is pure given a `Workspace`, a `Selection` and an action. The
planner decides *what* runs — one `lake` invocation per action, never one per
member — and the executor (`LakeWorkspace.Executor`) only knows how to run
steps, never why they exist.
-/

public section

namespace LakeWorkspace

inductive Action where
  /-- Validate → resolve → verify → atomically install generated files.
      `locked`: fail if generated files would change (no install, no update).
      `offline`: install, but do not run `lake update`. -/
  | sync (locked offline : Bool)
  /-- One `lake build` for all selected targets; extra args pass through. -/
  | build (extraArgs : Array String)
  /-- `lake clean` for the selected targets. -/
  | clean
  /-- Aggregate the selected members' test drivers: build every exe/lib
      driver in one graph, then run exe/script drivers with bounded
      parallelism (doc §7). -/
  | test (cliArgs : Array String)
  /-- Aggregate the selected members' lint drivers. -/
  | lint (cliArgs : Array String)
  deriving Repr, Inhabited

/-- A driver resolved against the workspace model: its kind is known and its
    owning member is identified. -/
structure ResolvedDriver where
  /-- The member whose driver this is. -/
  pkg : String
  /-- The member's directory relative to the workspace root — or, for a
      driver target owned by an external package, that package's
      root-relative directory (in place for path dependencies,
      `.lake/packages/<pkg>` for git dependencies). -/
  relDir : FilePath
  spec : DriverSpec
  targetKind : TargetKind
  deriving Repr, Inhabited

def ResolvedDriver.buildTarget (d : ResolvedDriver) : String :=
  s!"@{d.pkg}/{d.spec.target}"

inductive PlanStep where
  /-- Atomically install generated files (temp write + rename). -/
  | installFiles (files : Array (FilePath × String))
  /-- Verify on-disk files equal the expected contents (sync --locked). -/
  | verifyFiles (files : Array (FilePath × String))
  /-- Run the pinned `lake` executable once with these arguments. -/
  | runLake (args : Array String)
  /-- Execute resolved drivers with bounded parallelism, after any build
      steps have completed. -/
  | runDrivers (drivers : Array ResolvedDriver) (cliArgs : Array String)
  deriving Repr, Inhabited

structure BuildPlan where
  /-- Workspace root; steps with relative paths resolve against this. -/
  root : FilePath
  /-- Human-readable label for the action. -/
  label : String
  steps : Array PlanStep
  /-- Deterministic fingerprint of (workspace, selection, action). -/
  fingerprint : String
  /-- Explanation trace carried over from selection (may be empty). -/
  explanations : Array (String × String) := #[]
  /-- Human-readable notes (e.g. "no test drivers in selection"). -/
  notes : Array String := #[]
  deriving Repr, Inhabited

namespace Planner

/-- The outcome of checking one resolved driver target against Lake's driver
    rules; the member and external branches of `resolveDrivers` share it. -/
private inductive DriverCheck where
  | resolved (d : ResolvedDriver)
  | skipNote (msg : String)
  | err (msg : String)

/-- Apply Lake's driver rules: no arguments to library drivers, no library
    lint drivers. On success the driver is re-anchored to the target's owning
    package and directory. -/
private def checkDriverTarget (pkgName kind : String) (spec : DriverSpec)
    (targetPkg : String) (targetName : String) (relDir : FilePath) (tk : TargetKind) :
    DriverCheck :=
  if tk == .lib && (!spec.args.isEmpty) then
    .err s!"{pkgName}: arguments cannot be passed to library {kind} driver `{targetName}`"
  else if tk == .lib && kind == "lint" then
    .skipNote s!"{pkgName}: libraries cannot be lint drivers (skipped)"
  else
    .resolved { pkg := targetPkg, relDir, spec := { spec with target := targetName }
              , targetKind := tk }

/-- Resolve the selected members' drivers of the given kind against declared
    targets. Mirrors Lake's driver resolution: a driver names a script,
    executable, or library of the package (possibly `pkg/name`-qualified),
    and a qualified `pkg` may be an *external* package — Lake resolves
    drivers against the whole workspace, dependencies included (mathlib's
    `batteries/runLinter` is the motivating case). External targets are
    found by scanning the materialized package's own lakefile through the
    same scanner pair members use; one `lake scripts` probe covers script
    drivers invisible to target scanning. Unresolvable drivers produce
    diagnostics; lib drivers with arguments are an error (Lake semantics). -/
def resolveDrivers (ws : Workspace) (sel : Selection) (kind : String) :
    IO (Except Diagnostics (Array ResolvedDriver × Array String)) := do
  let mut diags : Diagnostics := #[]
  let mut notes : Array String := #[]
  let mut out : Array ResolvedDriver := #[]
  -- Drivers qualified to a non-member package that the external lakefile
  -- scan could not settle; a single `lake scripts` probe settles them below.
  let mut pending : Array (String × DriverSpec × String × String) := #[]
  for pkgName in sel.packages do
    let some m := ws.findMember? pkgName | continue
    let spec? := if kind == "test" then m.testDriver else m.lintDriver
    match spec? with
    | none => notes := notes.push s!"{pkgName}: no {kind} driver (skipped)"
    | some spec =>
      -- A driver target may be `otherpkg/name`-qualified.
      let (targetPkg, targetName) := match spec.target.splitOn "/" with
        | [p, n] => (p, n)
        | _ => (pkgName, spec.target)
      match ws.findMember? targetPkg with
      | some tm =>
        match tm.targets.find? (·.1 == targetName) with
        | none =>
          notes := notes.push
            s!"{pkgName}: {kind} driver `{targetName}` is not a declared \
               script, executable, or library of `{targetPkg}` (skipped)"
        | some (_, tk) =>
          match checkDriverTarget pkgName kind spec targetPkg targetName tm.relDir tk with
          | .resolved d => out := out.push d
          | .skipNote msg => notes := notes.push msg
          | .err msg => diags := diags ++ Diagnostics.error msg
      | none =>
        -- External package: same rules, against the dependency's own
        -- lakefile (in place for path dependencies, materialized under
        -- `.lake/packages/` for git dependencies).
        match (← Workspace.scanExternalDrivers ws targetPkg) with
        | some (relDir, scan) =>
          match scan.targets.find? (·.1 == targetName) with
          | some (_, tk) =>
            match checkDriverTarget pkgName kind spec targetPkg targetName relDir tk with
            | .resolved d => out := out.push d
            | .skipNote msg => notes := notes.push msg
            | .err msg => diags := diags ++ Diagnostics.error msg
          | none => pending := pending.push (pkgName, spec, targetPkg, targetName)
        | none => pending := pending.push (pkgName, spec, targetPkg, targetName)
  if !pending.isEmpty then
    let scripts ← Backend.LakeCli.lakeScripts ws.root
    for (pkgName, spec, targetPkg, targetName) in pending do
      if scripts.any (· == (targetPkg, targetName)) then
        let relDir := Workspace.externalRelDir? ws targetPkg |>.getD ("." : FilePath)
        out := out.push { pkg := targetPkg, relDir
                        , spec := { spec with target := targetName }
                        , targetKind := .script }
      else
        notes := notes.push
          s!"{pkgName}: {kind} driver `{spec.target}` not found in external \
             package `{targetPkg}` (skipped)"
  if diags.hasErrors then
    return .error diags
  else
    return .ok (out, notes)

def plan (ws : Workspace) (sel : Selection) (action : Action) :
    IO (Except Diagnostics BuildPlan) := do
  let baseFp := Workspace.fingerprint ws
  match action with
  | .sync locked offline =>
    let files := Backend.LakeCli.generatedFiles ws
    let steps : Array PlanStep :=
      if locked then #[.verifyFiles files]
      else if offline then #[.installFiles files]
      else #[.installFiles files, .runLake (#["update"] ++
        if ws.config.cacheTryCache then #["--try-cache"] else #[])]
    return .ok {
      root := ws.root
      label := if locked then "sync --locked" else if offline then "sync --offline" else "sync"
      steps
      fingerprint := toString (hash (baseFp, "sync", locked, offline))
      explanations := #[] }
  | .build extraArgs =>
    if sel.targets.isEmpty then
      -- e.g. `--changed` with no changes: a graceful no-op, not an error
      return .ok {
        root := ws.root
        label := "build"
        steps := #[]
        fingerprint := toString (hash (baseFp, "build", sel.targets, extraArgs))
        explanations := sel.explanations
        notes := #["empty selection: nothing to build"] }
    else
      return .ok {
        root := ws.root
        label := "build"
        steps := #[.runLake (#["build"] ++ sel.targets ++ extraArgs)]
        fingerprint := toString (hash (baseFp, "build", sel.targets, extraArgs))
        explanations := sel.explanations }
  | .clean =>
    return .ok {
      root := ws.root
      label := "clean"
      steps := #[.runLake (#["clean"] ++ sel.targets)]
      fingerprint := toString (hash (baseFp, "clean", sel.targets))
      explanations := sel.explanations }
  | .test cliArgs => planDrivers ws sel "test" cliArgs baseFp
  | .lint cliArgs => planDrivers ws sel "lint" cliArgs baseFp
where
  /-- Shared planning for `test`/`lint`: one build step for every exe/lib
      driver across the whole selection, then one driver-execution step. -/
  planDrivers (ws : Workspace) (sel : Selection) (kind : String)
      (cliArgs : Array String) (baseFp : String) : IO (Except Diagnostics BuildPlan) := do
    let (drivers, notes) ← match (← resolveDrivers ws sel kind) with
      | .error ds => return .error ds
      | .ok r => pure r
    let buildTargets := drivers.filterMap fun d =>
      if d.targetKind == .script then none else some d.buildTarget
    let buildTargets := buildTargets.insertionSort (· < ·) |>.toList.eraseDups.toArray
    let mut steps : Array PlanStep := #[]
    if !buildTargets.isEmpty then
      steps := steps.push (.runLake (#["build"] ++ buildTargets))
    if !drivers.isEmpty then
      steps := steps.push (.runDrivers drivers cliArgs)
    let notes := if drivers.isEmpty then
        notes.push s!"no {kind} drivers in the selection"
      else notes
    return .ok {
      root := ws.root
      label := kind
      steps
      fingerprint := toString (hash (baseFp, kind, drivers.map (·.buildTarget), cliArgs))
      explanations := sel.explanations
      notes }

/-- Render a plan as JSON for `--dry-run --json`. -/
def toJson (p : BuildPlan) : Json :=
  let stepJson : PlanStep → Json
    | .installFiles files => .obj #[
        ("kind", .str "installFiles"),
        ("files", .arr (files.map fun f => .str f.1.toString)) ]
    | .verifyFiles files => .obj #[
        ("kind", .str "verifyFiles"),
        ("files", .arr (files.map fun f => .str f.1.toString)) ]
    | .runLake args => .obj #[
        ("kind", .str "runLake"),
        ("argv", .arr (#["lake"] ++ args |>.map .str)) ]
    | .runDrivers drivers cliArgs => .obj #[
        ("kind", .str "runDrivers"),
        ("cliArgs", .arr (cliArgs.map .str)),
        ("drivers", .arr (drivers.map fun d => .obj #[
          ("package", .str d.pkg),
          ("target", .str d.spec.target),
          ("driverKind", .str d.spec.kind),
          ("args", .arr (d.spec.args.map .str)) ])) ]
  .obj #[
    ("label", .str p.label),
    ("fingerprint", .str p.fingerprint),
    ("notes", .arr (p.notes.map .str)),
    ("steps", .arr (p.steps.map stepJson)),
    ("explanations", .arr (p.explanations.map fun e =>
      .obj #[("package", .str e.1), ("reason", .str e.2)])) ]

/-- Render a plan as text for `--dry-run`. -/
def describe (p : BuildPlan) : String := Id.run do
  let mut out : Array String := #[s!"plan {p.label} (fingerprint {p.fingerprint})"]
  for step in p.steps do
    match step with
    | .installFiles files =>
      for (path, _) in files do
        out := out.push s!"  install {path.toString}"
    | .verifyFiles files =>
      for (path, _) in files do
        out := out.push s!"  verify {path.toString}"
    | .runLake args =>
      out := out.push s!"  + lake {" ".intercalate args.toList}"
    | .runDrivers drivers cliArgs =>
      for d in drivers do
        let args := " ".intercalate (d.spec.args ++ cliArgs).toList
        out := out.push s!"  run {d.spec.kind} driver {d.pkg}/{d.spec.target} {args}"
  for note in p.notes do
    out := out.push s!"  note: {note}"
  if !p.explanations.isEmpty then
    out := out.push "  selected because:"
    for (pkg, reason) in p.explanations do
      out := out.push s!"    {pkg}: {reason}"
  return "\n".intercalate out.toList

end Planner

end LakeWorkspace

end -- public section
