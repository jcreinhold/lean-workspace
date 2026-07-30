/-
Git backend: gathering changed paths for `--changed` selection.

Kept behind one small module so the git invocation strategy (merge-base
diffs, untracked files, subdirectory workspaces) can change without touching
selection logic.
-/
import LakeWorkspace.Diagnostics

namespace LakeWorkspace.Backend.Git

open LakeWorkspace

private def git (root : FilePath) (args : Array String) : IO (Except String String) := do
  try
    let out ← IO.Process.output { cmd := "git", args := #["-C", root.toString] ++ args }
    if out.exitCode == 0 then
      return .ok out.stdout
    else
      return .error out.stderr.trimAscii.toString
  catch e =>
    return .error (toString e)

private def lines (s : String) : Array String :=
  ((s.splitOn "\n").filterMap fun l =>
    let l := l.trimAscii.toString
    if l.isEmpty then none else some l).toArray

/--
Paths changed relative to `ref?` (or the working tree if `none`), relative to
`root`. Includes staged, unstaged and untracked changes; with a ref, diffs the
merge base of `ref` and `HEAD` (doc §8: "Ask Git for changed paths").
-/
def changedPaths (root : FilePath) (ref? : Option String) : IO (Except String (Array FilePath)) := do
  -- Anchor everything at the git toplevel so workspaces in subdirectories work.
  let topStr ← match ← git root #["rev-parse", "--show-toplevel"] with
    | .error e => return .error s!"not a git repository (or git failed): {e}"
    | .ok t => pure t.trimAscii.toString
  let top : FilePath := ⟨topStr⟩
  -- Workspace root relative to the git toplevel ("" if same).
  let rootStr := root.toString
  let pre : String :=
    if rootStr == topStr then ""
    else if rootStr.startsWith (topStr ++ "/") then
      (rootStr.drop (topStr.length + 1)).toString
    else "" -- symlinked/aliased paths; fall back to no filtering
  let mut paths : Array String := #[]
  let diffArgs ← match ref? with
    | none => pure #["diff", "--name-only", "HEAD"]
    | some ref =>
      let mb ← match ← git root #["merge-base", ref, "HEAD"] with
        | .error e =>
          return .error s!"could not find merge base of `{ref}` and HEAD: {e}"
        | .ok m => pure m.trimAscii.toString
      pure #["diff", "--name-only", mb]
  match ← git root diffArgs with
  | .error e => return .error s!"git diff failed: {e}"
  | .ok out => paths := paths ++ lines out
  match ← git root #["ls-files", "--others", "--exclude-standard"] with
  | .error _ => pure () -- untracked listing is best-effort
  | .ok out => paths := paths ++ lines out
  -- Restrict to the workspace root and re-relativize.
  let rel := paths.filterMap fun p =>
    if pre.isEmpty then some p
    else if p.startsWith (pre ++ "/") then
      some ((p.drop (pre.length + 1)).toString)
    else none
  return .ok (rel.insertionSort (· < ·) |>.toList.eraseDups.toArray.map (⟨·⟩))

end LakeWorkspace.Backend.Git
