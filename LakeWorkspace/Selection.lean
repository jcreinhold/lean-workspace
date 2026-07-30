/-
Package and target selection.

Pure: given a `Workspace` and a `SelectionQuery` (whose `changedPaths`, if
any, have already been gathered by the caller — git subprocesses live in the
backend layer), produce a canonical, sorted, deduplicated set of
package-qualified Lake targets plus an explanation trace (doc §8: "The
selection result should explain itself").
-/
import LakeWorkspace.Workspace

namespace LakeWorkspace

structure SelectionQuery where
  /-- Explicit `-p` / `--package` member names. -/
  packages : Array String := #[]
  /-- Named `--group` selectors. -/
  groups : Array String := #[]
  /-- Raw `@pkg/...` target specs, passed through verbatim. -/
  targets : Array String := #[]
  /-- Paths changed relative to some git ref, relative to the workspace root.
      `none` = no changed-selection; `some #[]` = nothing changed. -/
  changedPaths : Option (Array FilePath) := none
  /-- Explicitly request all members. -/
  all : Bool := false
  deriving Repr, Inhabited

structure Selection where
  /-- Selected member names, sorted. -/
  packages : Array String
  /-- Canonical sorted Lake target specs (`@pkg`, plus raw passthroughs). -/
  targets : Array String
  /-- `(package, reason)` explanation pairs. -/
  explanations : Array (String × String)
  deriving Repr, Inhabited

namespace Selection

/-- Paths whose change globally affects every member (doc §8 step 4). -/
def isGlobalTrigger (rel : FilePath) : Bool :=
  let s := rel.toString
  s == "lean-toolchain" || s == "lean-workspace.toml" || s == "lakefile.lean" ||
    s == "lake-manifest.json" || s == ".lake/package-overrides.json" ||
    s.startsWith ".lake/workspace/"

/-- The member owning a path, by longest root-prefix match. -/
def ownerOfPath (ws : Workspace) (rel : FilePath) : Option MemberPkg := Id.run do
  let comps := rel.toString.splitOn "/"
  let mut best : Option MemberPkg := none
  for m in ws.members do
    let mc := m.relDir.toString.splitOn "/"
    if mc.length ≤ comps.length && (mc.zip comps).all fun (a, b) => a == b then
      let better := match best with
        | none => true
        | some b => b.relDir.toString.length < m.relDir.toString.length
      if better then best := some m
  return best

/-- The name of the package a raw `@pkg[/…]` target spec refers to. -/
def targetPackage (spec : String) : Option String :=
  if !spec.startsWith "@" then none
  else
    let rest := (spec.drop 1).toString
    some ((rest.splitOn "/").head?.getD rest)

def select (ws : Workspace) (q : SelectionQuery) : Except Diagnostics Selection := do
  let names := ws.memberNames
  -- Validation pre-pass.
  let mut diags : Diagnostics := #[]
  for p in q.packages do
    if !names.contains p then
      diags := diags ++ Diagnostics.error s!"unknown workspace member `{p}`"
  for g in q.groups do
    if (ws.config.groups.find? (·.1 == g)).isNone then
      diags := diags ++ Diagnostics.error s!"unknown workspace group `{g}`"
  for t in q.targets do
    match targetPackage t with
    | none =>
      diags := diags ++ Diagnostics.error
        s!"target `{t}` is not package-qualified; use @pkg or @pkg/target"
    | some pkg =>
      if !names.contains pkg then
        diags := diags ++ Diagnostics.error s!"target `{t}` does not name a workspace member"
  if diags.hasErrors then
    throw diags
  -- Selection proper.
  Id.run do
    let mut st : Array String × Array (String × String) := (#[], #[])
    let add (st : Array String × Array (String × String)) (p reason : String) :=
      let (pkgs, expls) := st
      let pkgs := if pkgs.contains p then pkgs else pkgs.push p
      let expls := if expls.any (· == (p, reason)) then expls else expls.push (p, reason)
      (pkgs, expls)
    for p in q.packages do
      st := add st p "selected via -p"
    for g in q.groups do
      let ms := (ws.config.groups.find? (·.1 == g)).map (·.2) |>.getD #[]
      for m in ms do
        st := add st m s!"member of group {g}"
    if q.all then
      for m in ws.members do
        st := add st m.name "selected via --all"
    if let some paths := q.changedPaths then
      if paths.any isGlobalTrigger then
        for m in ws.members do
          st := add st m.name "globally affected (toolchain/manifest/policy changed)"
      else
        let owners := (paths.filterMap (ownerOfPath ws ·)).map MemberPkg.name
          |>.toList.eraseDups
        for o in owners do
          st := add st o "contains changed files"
        for c in ws.reverseClosure owners.toArray do
          if !owners.contains c then
            st := add st c "depends on a changed package"
    let rawOk := q.targets.filter fun t =>
      match targetPackage t with
      | some pkg => names.contains pkg
      | none => false
    if st.1.isEmpty && rawOk.isEmpty && !q.all then
      let defs := if ws.config.defaultMembers.isEmpty then names else ws.config.defaultMembers
      let reason := if ws.config.defaultMembers.isEmpty
        then "all members (no default-members configured)"
        else "default member"
      for d in defs do
        st := add st d reason
    let pkgsSorted := st.1.insertionSort (· < ·)
    let targets := (pkgsSorted.map (s!"@{·}") ++ rawOk).insertionSort (· < ·)
      |>.toList.eraseDups.toArray
    return .ok { packages := pkgsSorted, targets := targets, explanations := st.2 }

def renderExplanations (sel : Selection) : String := Id.run do
  let mut out : Array String := #[]
  for (p, r) in sel.explanations do
    out := out.push s!"  {p}: {r}"
  return "\n".intercalate out.toList

end Selection

end LakeWorkspace
