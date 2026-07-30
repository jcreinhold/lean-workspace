/-
The planner: translate an action into a deterministic sequence of steps.

Planning is pure given a `Workspace`, a `Selection` and an action. The
planner decides *what* runs — one `lake` invocation per action, never one per
member — and the executor (`LakeWorkspace.Executor`) only knows how to run
steps, never why they exist.
-/
import LakeWorkspace.Selection
import LakeWorkspace.Backend.LakeCli
import LakeWorkspace.Json

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
  deriving Repr, Inhabited

inductive PlanStep where
  /-- Atomically install generated files (temp write + rename). -/
  | installFiles (files : Array (FilePath × String))
  /-- Verify on-disk files equal the expected contents (sync --locked). -/
  | verifyFiles (files : Array (FilePath × String))
  /-- Run the pinned `lake` executable once with these arguments. -/
  | runLake (args : Array String)
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
  deriving Repr, Inhabited

namespace Planner

def plan (ws : Workspace) (sel : Selection) (action : Action) : Except Diagnostics BuildPlan := do
  let baseFp := Workspace.fingerprint ws
  match action with
  | .sync locked offline =>
    let files := Backend.LakeCli.generatedFiles ws
    let steps : Array PlanStep :=
      if locked then #[.verifyFiles files]
      else if offline then #[.installFiles files]
      else #[.installFiles files, .runLake #["update"]]
    .ok {
      root := ws.root
      label := if locked then "sync --locked" else if offline then "sync --offline" else "sync"
      steps
      fingerprint := toString (hash (baseFp, "sync", locked, offline))
      explanations := #[] }
  | .build extraArgs =>
    if sel.targets.isEmpty then
      .error (Diagnostics.error "empty selection: nothing to build")
    else
      .ok {
        root := ws.root
        label := "build"
        steps := #[.runLake (#["build"] ++ sel.targets ++ extraArgs)]
        fingerprint := toString (hash (baseFp, "build", sel.targets, extraArgs))
        explanations := sel.explanations }
  | .clean =>
    .ok {
      root := ws.root
      label := "clean"
      steps := #[.runLake (#["clean"] ++ sel.targets)]
      fingerprint := toString (hash (baseFp, "clean", sel.targets))
      explanations := sel.explanations }

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
  .obj #[
    ("label", .str p.label),
    ("fingerprint", .str p.fingerprint),
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
  if !p.explanations.isEmpty then
    out := out.push "  selected because:"
    for (pkg, reason) in p.explanations do
      out := out.push s!"    {pkg}: {reason}"
  return "\n".intercalate out.toList

end Planner

end LakeWorkspace
