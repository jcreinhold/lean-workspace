/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

import LakeWorkspace.Toml
import Std.Data.HashMap
public import LakeWorkspace.Diagnostics

/-!
The workspace model: manifest parsing, member discovery, validation,
resolution conflict detection, and the module-owner index.

This module owns *what* the workspace is. How generated Lake files are spelled
lives in `LakeWorkspace.Backend.LakeCli`; this module never spawns processes.

Successful construction via `Workspace.load` guarantees: unique package names,
unique module roots, unique module ownership, matching member toolchains, an
acyclic member dependency graph, a single canonical source per external
package name, and (with default policy) that every cross-package import is a
declared direct dependency.
-/

public section

namespace LakeWorkspace

/-! ## Model -/

inductive RequireSrc where
  | path (dir : FilePath)
  | git (url : String) (rev : Option String)
  deriving Repr, BEq, Inhabited

def RequireSrc.describe : RequireSrc → String
  | .path dir => s!"path {dir.toString}"
  | .git url rev? => s!"git {url}" ++ (rev?.map (s!" @ {·}") |>.getD "")

structure RequireDecl where
  name : String
  src : RequireSrc
  deriving Repr, BEq, Inhabited

inductive TargetKind where
  | script | exe | lib
  deriving Repr, BEq, Inhabited

/-- A test or lint driver discovered in a member's lakefile. Mirrors Lake's
    `Package.test`/`Package.lint` resolution: a script (run via
    `lake script run pkg/name`), an executable (built, then run), or a
    library (built only — test drivers only). Verified against Lake
    v4.33.0-rc1 (`Lake/CLI/Actions.lean`). -/
structure DriverSpec where
  /-- `test` or `lint`. -/
  kind : String
  /-- Driver name, possibly `otherpkg/name`-qualified (Lake syntax). -/
  target : String
  args : Array String := #[]
  deriving Repr, BEq, Inhabited

def DriverSpec.withArgs (d : DriverSpec) (args : Array String) : DriverSpec :=
  { d with args := d.args ++ args }

structure MemberPkg where
  name : String
  /-- Directory of the member, relative to the workspace root. -/
  relDir : FilePath
  requires : Array RequireDecl := #[]
  /-- Top-level Lean module roots (e.g. `Core`, `Tactic`). -/
  moduleRoots : Array String := #[]
  /-- All modules owned by this member (fully qualified, dot-separated). -/
  modules : Array String := #[]
  /-- Contents of the member's own `lean-toolchain`, if it has one. -/
  toolchain : Option String := none
  /-- Declared `script`/`lean_exe`/`lean_lib` target names and kinds. -/
  targets : Array (String × TargetKind) := #[]
  testDriver : Option DriverSpec := none
  lintDriver : Option DriverSpec := none
  /-- Canonical `⟨`name, value⟩` Lean-option tuples found in the lakefile
      (value rendered as a string: `true`/`false`, a numeral, or a quoted
      string). Used for `[options]` policy validation; see the phase-4 spike
      note in `scanLakefile`. -/
  declaredOptions : Array (String × String) := #[]
  /-- Whether the lakefile mentions `leanOptions`/`moreLeanOptions` at all. -/
  hasOptionAssignments : Bool := false
  deriving Repr, Inhabited

/-- A canonical external dependency declared centrally in `[deps.<name>]`. -/
structure CentralDep where
  name : String
  src : RequireSrc
  deriving Repr, BEq, Inhabited

structure WorkspaceConfig where
  /-- Name of the generated virtual root package. -/
  name : String := "repo"
  memberPatterns : Array String := #[]
  excludePatterns : Array String := #[]
  defaultMembers : Array String := #[]
  groups : Array (String × Array String) := #[]
  cacheLocal : Bool := true
  /-- `requested-only` | `package` | `workspace`. -/
  cacheRestore : String := "requested-only"
  uniqueModuleRoots : Bool := true
  requireDirectImportEdges : Bool := true
  memberToolchains : String := "must-match-root"
  /-- Central dependency declarations from `[deps.<name>]` (the
      `[workspace.dependencies]` analog): the canonical source every member's
      `require <name>` must match exactly. -/
  deps : Array CentralDep := #[]
  /-- Shared Lean options from `[options]` (the `[workspace.lints]` analog):
      `(name, valueRepr)` where valueRepr is `true`/`false`, a numeral, or a
      quoted string. Policy-validated, not propagated (Lake options do not
      propagate to dependency packages). -/
  options : Array (String × String) := #[]
  deriving Repr, Inhabited

/-- An external (non-member) dependency requirement, as declared by one member. -/
structure ExternalRequire where
  name : String
  src : RequireSrc
  requiredBy : String
  deriving Repr, Inhabited

structure Workspace where
  root : FilePath
  config : WorkspaceConfig
  /-- Members sorted by name. -/
  members : Array MemberPkg
  /-- Member→member dependency edges `(from, to)`, sorted. -/
  edges : Array (String × String)
  /-- External requirements across all members. -/
  externals : Array ExternalRequire
  /-- Module → owning member name, sorted by module. -/
  moduleOwners : Array (String × String)
  /-- Module → its imports (workspace modules and externals alike), for
      module-level affected analysis. Empty when the index was skipped
      (see `hasModuleImportIndex`); consumers must check that flag. -/
  moduleImports : Array (String × Array String)
  /-- Whether `moduleImports` was actually computed during `load`
      (`loadModuleImports := true`). `select`'s `--affected` path and the
      architectural import check require it; everything else ignores it. -/
  hasModuleImportIndex : Bool := true
  /-- The workspace toolchain (contents of the root `lean-toolchain`). -/
  toolchain : String
  deriving Repr, Inhabited

namespace Workspace

def memberNames (ws : Workspace) : Array String := ws.members.map MemberPkg.name

/-- A deterministic fingerprint of the canonical workspace model: membership,
    paths, dependency declarations, edges, and toolchain. Used in generated
    metadata and plan fingerprints. -/
def fingerprint (ws : Workspace) : String :=
  let reqStr (r : RequireDecl) : String := s!"{r.name}={r.src.describe}"
  let memStr (m : MemberPkg) : String :=
    String.intercalate ";" <|
      m.name :: m.relDir.toString :: (m.requires.map reqStr).toList
  let canon := String.intercalate "\n" <|
    ws.toolchain :: ws.config.name ::
      (ws.members.map memStr).toList ++
        (ws.edges.map fun e => s!"{e.1}->{e.2}").toList
  toString (hash canon)

/-- Reverse *module* import closure within the workspace: every workspace
    module that transitively imports one of `start`. -/
partial def reverseModuleClosure (ws : Workspace) (start : Array String) : Array String :=
  let rec go (frontier seen : Array String) : Array String :=
    if frontier.isEmpty then seen
    else
      let next := ws.moduleImports.filterMap fun (m, imps) =>
        if imps.any frontier.contains && !seen.contains m && !frontier.contains m
          then some m else none
      go next (seen ++ frontier)
  let all := go start #[]
  all.insertionSort (· < ·) |>.toList.eraseDups.toArray

/-- The module owned by member `m` at relative path `rel` (relative to the
    workspace root), if it is a `.lean` file under the member. -/
def moduleOfPath (ws : Workspace) (m : MemberPkg) (rel : FilePath) : Option String := do
  let ps := rel.toString
  let dir := m.relDir.toString
  if !ps.startsWith (dir ++ "/") then none
  let rest := (ps.drop (dir.length + 1)).toString
  if !rest.endsWith ".lean" then none
  let comps := rest.toList.take (rest.toList.length - 5)
  some (".".intercalate ((String.ofList comps).splitOn "/"))

/-- Shortest member-graph path from `from` to `to` through declared
    dependencies (for `lakew why`). -/
partial def whyPath (ws : Workspace) (from_ to : String) : Option (List String) :=
  go #[(from_, [from_])] #[]
where
  go (queue : Array (String × List String)) (seen : Array String) : Option (List String) :=
    match queue.toList with
    | [] => none
    | (cur, path) :: rest =>
      if cur == to then some path.reverse
      else
        let nexts := ws.edges.filterMap fun (a, b) =>
          if a == cur && !seen.contains b && b != cur then some (b, b :: path) else none
        go (rest.toArray ++ nexts) (seen.push cur)

def findMember? (ws : Workspace) (name : String) : Option MemberPkg :=
  ws.members.find? (·.name == name)

def moduleOwner? (ws : Workspace) (mod : String) : Option String :=
  ws.moduleOwners.findSome? fun (m, o) => if m == mod then some o else none

/-- Reverse member-dependency closure: everything that (transitively) depends on `start`. -/
partial def reverseClosure (ws : Workspace) (start : Array String) : Array String :=
  let rec go (frontier seen : Array String) : Array String :=
    if frontier.isEmpty then seen
    else
      let next := ws.edges.filterMap fun (a, b) =>
        if frontier.contains b && !seen.contains a && !frontier.contains a then some a else none
      go next (seen ++ frontier)
  let all := go start #[]
  all.insertionSort (· < ·) |>.toList.eraseDups.toArray

/-! ## Lakefile scanning (member package name + `require` declarations) -/

private inductive Tok where
  | ident (s : String)
  | str (s : String)
  | at
  | sym (c : Char)
  deriving BEq, Inhabited

/-- Tokenize a `lakefile.lean`, stripping line and (nested) block comments.
    Handles multi-line `require` declarations naturally. -/
private partial def tokenize (text : String) : Array Tok := Id.run do
  let cs := text.toList.toArray
  let mut i := 0
  let mut out : Array Tok := #[]
  let identChar (c : Char) := c.isAlphanum || c == '_' || c == '.' || c == '\''
  while i < cs.size do
    let c := cs[i]!
    if c.isWhitespace then
      i := i + 1
    else if c == '-' && i + 1 < cs.size && cs[i + 1]! == '-' then
      while i < cs.size && cs[i]! != '\n' do i := i + 1
    else if c == '/' && i + 1 < cs.size && cs[i + 1]! == '-' then
      i := i + 2
      let mut depth := 1
      while i < cs.size && depth > 0 do
        if cs[i]! == '/' && i + 1 < cs.size && cs[i + 1]! == '-' then depth := depth + 1; i := i + 2
        else if cs[i]! == '-' && i + 1 < cs.size && cs[i + 1]! == '/' then depth := depth - 1; i := i + 2
        else i := i + 1
    else if c == '«' then
      let mut j := i + 1
      while j < cs.size && cs[j]! != '»' do j := j + 1
      out := out.push (.ident (String.ofList (cs.extract (i + 1) j).toList))
      i := min (j + 1) cs.size
    else if c == '"' then
      let mut j := i + 1
      let mut s := ""
      while j < cs.size && cs[j]! != '"' do
        let c' := cs[j]!
        if c' == '\\' && j + 1 < cs.size then j := j + 1
        s := s ++ String.ofList [cs[j]!]
        j := j + 1
      out := out.push (.str s)
      i := min (j + 1) cs.size
    else if c == '@' then
      out := out.push .at
      i := i + 1
    else if identChar c then
      let mut j := i
      while j < cs.size && identChar cs[j]! do j := j + 1
      out := out.push (.ident (String.ofList (cs.extract i j).toList))
      i := j
    else
      out := out.push (.sym c)
      i := i + 1
  return out

/-- What `scanLakefile` extracts from a member `lakefile.lean`. -/
structure LakefileScan where
  pkgName : Option String := none
  requires : Array RequireDecl := #[]
  /-- Declared `script`/`lean_exe`/`lean_lib` names and kinds. -/
  targets : Array (String × TargetKind) := #[]
  testDriver : Option DriverSpec := none
  lintDriver : Option DriverSpec := none
  /-- Canonical `⟨`name, value⟩` Lean-option tuples found in the lakefile
      (value rendered as a string: `true`/`false`, a numeral, or a quoted
      string). Used for `[options]` policy validation; see the phase-4 spike
      note in `scanLakefile`. -/
  declaredOptions : Array (String × String) := #[]
  /-- Whether the lakefile mentions `leanOptions`/`moreLeanOptions` at all. -/
  hasOptionAssignments : Bool := false
  deriving Repr, Inhabited

/-- Extract the package name, `require` declarations, target declarations and
    test/lint drivers from lakefile tokens. Unparseable `require` occurrences
    produce warnings, not failures.
    TODO: parse and compare `with` configuration options (currently ignored;
    conflicting options across members must become an error). -/
private def scanLakefile (toks : Array Tok) (origin : FilePath) :
    Diagnostics × LakefileScan := Id.run do
  let mut diags : Diagnostics := #[]
  let mut scan : LakefileScan := {}
  let mut taggedTest : Option String := none
  let mut taggedLint : Option String := none
  let mut i := 0
  let warn (msg : String) : Diagnostics := Diagnostics.warning s!"{origin.toString}: {msg}"
  while i < toks.size do
    match toks[i]! with
    | .ident "package" =>
      match toks[i + 1]? with
      | some (.ident n) =>
        if scan.pkgName.isNone then scan := { scan with pkgName := some n }
        i := i + 2
      | _ =>
        diags := diags ++ warn "could not parse `package` name"
        i := i + 1
    | .ident "require" =>
      let parsed : Option RequireDecl := do
        let .ident name ← toks[i + 1]? | none
        let .ident "from" ← toks[i + 2]? | none
        match toks[i + 3]? with
        | some (.str dir) => some { name, src := .path dir }
        | some (.ident "git") => do
          let .str url ← toks[i + 4]? | none
          match toks[i + 5]?, toks[i + 6]? with
          | some .at, some (.str rev) => some { name, src := .git url (some rev) }
          | _, _ => some { name, src := .git url none }
        | _ => none
      match parsed with
      | some decl => scan := { scan with requires := scan.requires.push decl }
      | none => diags := diags ++ warn "could not parse a `require` declaration"
      i := i + 1
    | .at =>
      -- possible @[test_driver] / @[lint_driver] tag before a target decl
      match toks[i + 1]?, toks[i + 2]?, toks[i + 3]? with
      | some (.sym '['), some (.ident attr), some (.sym ']') =>
        if attr == "test_driver" || attr == "lint_driver" then
          -- find the following target declaration
          let mut j := i + 4
          let mut found := false
          while j < toks.size && j < i + 8 && !found do
            match toks[j]! with
            | .ident kw =>
              if kw == "script" || kw == "lean_exe" || kw == "lean_lib" then
                match toks[j + 1]? with
                | some (.ident n) =>
                  if attr == "test_driver" then taggedTest := some n else taggedLint := some n
                  found := true
                | _ => found := true
            | _ => pure ()
            j := j + 1
        i := i + 1
      | _, _, _ => i := i + 1
    | .ident kw =>
      if kw == "leanOptions" || kw == "moreLeanOptions" then
        scan := { scan with hasOptionAssignments := true }
      if kw == "script" || kw == "lean_exe" || kw == "lean_lib" then
        let kind := if kw == "script" then TargetKind.script
          else if kw == "lean_exe" then TargetKind.exe else TargetKind.lib
        match toks[i + 1]? with
        | some (.ident n) =>
          scan := { scan with targets := scan.targets.push (n, kind) }
          i := i + 2
        | _ =>
          diags := diags ++ warn s!"could not parse `{kw}` declaration name"
          i := i + 1
      else if kw == "testDriver" || kw == "lintDriver" ||
              kw == "testDriverArgs" || kw == "lintDriverArgs" then
        -- config assignment `<key> := <value>`
        match toks[i + 1]?, toks[i + 2]? with
        | some (.sym ':'), some (.sym '=') =>
          if kw == "testDriver" || kw == "lintDriver" then
            match toks[i + 3]? with
            | some (.str s) =>
              let kind := if kw == "testDriver" then "test" else "lint"
              let prevArgs := match (if kw == "testDriver" then scan.testDriver
                  else scan.lintDriver) with
                | some d => d.args
                | none => #[]
              let spec : DriverSpec := { kind, target := s, args := prevArgs }
              if kw == "testDriver" then scan := { scan with testDriver := some spec }
              else scan := { scan with lintDriver := some spec }
              i := i + 4
            | _ =>
              diags := diags ++ warn s!"could not parse `{kw}` value"
              i := i + 1
          else
            -- args: `#["a", "b"]`
            match toks[i + 3]?, toks[i + 4]? with
            | some (.sym '#'), some (.sym '[') =>
              let mut j := i + 5
              let mut args : Array String := #[]
              let mut ok := true
              while j < toks.size && ok do
                match toks[j]! with
                | .str s => args := args.push s; j := j + 1
                | .sym ',' => j := j + 1
                | .sym ']' => ok := false
                | _ =>
                  diags := diags ++ warn s!"could not parse `{kw}` array"
                  ok := false
              if kw == "testDriverArgs" then
                scan := { scan with testDriver := (scan.testDriver.getD {
                  kind := "test", target := "" }).withArgs args }
              else
                scan := { scan with lintDriver := (scan.lintDriver.getD {
                  kind := "lint", target := "" }).withArgs args }
              i := j + 1
            | _, _ =>
              diags := diags ++ warn s!"could not parse `{kw}` value"
              i := i + 1
        | _, _ => i := i + 1
      else
        i := i + 1
    | .sym '⟨' =>
      -- canonical option tuple ⟨`name, value⟩; see phase-4 spike: real
      -- lakefiles also compose options programmatically (`weak ++`, abbrevs),
      -- which is deliberately out of scope for this scan.
      match toks[i + 1]?, toks[i + 2]?, toks[i + 3]? with
      | some (.sym '`'), some (.ident n), some (.sym ',') =>
        let valueEnd (j : Nat) : Option (String × Nat) :=
          match toks[j]? with
          | some (.ident ".ofNat") =>
            -- the common case: `.` is an ident char, so `.ofNat` is one token
            match toks[j + 1]?, toks[j + 2]? with
            | some (.ident num), some (.sym '⟩') => some (num, j + 3)
            | _, _ => none
          | some (.sym '.') =>
            -- `.ofNat n` (only if the dot lexed separately)
            match toks[j + 1]?, toks[j + 2]?, toks[j + 3]? with
            | some (.ident "ofNat"), some (.ident num), some (.sym '⟩') => some (num, j + 4)
            | _, _, _ => none
          | some (.ident v) =>
            match toks[j + 1]? with
            | some (.sym '⟩') => some (v, j + 2)
            | _ => none
          | some (.str v) =>
            match toks[j + 1]? with
            | some (.sym '⟩') => some (s!"\"{v}\"", j + 2)
            | _ => none
          | _ => none
        match valueEnd (i + 4) with
        | some (v, j') =>
          scan := { scan with declaredOptions := scan.declaredOptions.push (n, v) }
          i := j'
        | none => i := i + 1
      | _, _, _ => i := i + 1
    | _ => i := i + 1
  -- Fold tags into drivers (Lake forbids config+tag together; mirror as warning).
  let testPh := scan.testDriver.getD { kind := "test", target := "" }
  let lintPh := scan.lintDriver.getD { kind := "lint", target := "" }
  if let some n := taggedTest then
    if testPh.target.isEmpty then
      scan := { scan with testDriver := some { testPh with target := n } }
    else
      diags := diags ++ warn "both `testDriver` config and `@[test_driver]` tag are set \
        (Lake will reject this)"
  if let some n := taggedLint then
    if lintPh.target.isEmpty then
      scan := { scan with lintDriver := some { lintPh with target := n } }
    else
      diags := diags ++ warn "both `lintDriver` config and `@[lint_driver]` tag are set \
        (Lake will reject this)"
  -- Args without a driver name are meaningless; drop the placeholder.
  if scan.testDriver.any (·.target.isEmpty) then scan := { scan with testDriver := none }
  if scan.lintDriver.any (·.target.isEmpty) then scan := { scan with lintDriver := none }
  return (diags, scan)

/-! ## Import scanning -/

/-- Parse the leading `import` block of a Lean source file. -/
def parseImports (text : String) : Array String := Id.run do
  let mut out : Array String := #[]
  let modChar (c : Char) := c.isAlphanum || c == '_' || c == '.' || c == '\''
  for line in text.splitOn "\n" do
    let t := line.trimAscii.toString
    if t.isEmpty || t.startsWith "--" then
      continue
    else if t.startsWith "/-" && t.endsWith "-/" then
      continue
    else if t == "import" || t.startsWith "import " then
      let rest := String.ofList (t.toList.drop 6)
      for tok in rest.splitOn " " do
        let tok := tok.trimAscii.toString
        if !tok.isEmpty && tok.toList.all modChar && tok.toList.any Char.isAlpha then
          out := out.push tok
    else
      break
  return out

/-! ## Bounded parallel mapping -/

/-- Wave size for parallel file scanning. Lean core exposes no
    processor-count query, so like `Executor.driverJobs` this is a fixed
    bound: enough to overlap IO without hammering the filesystem. -/
private def scanJobs : Nat := 8

/-- `xs.mapM f` with bounded parallelism (waves of `scanJobs`),
    preserving input order in the output — diagnostics and indexes stay
    deterministic. Mirrors `Executor.runDrivers`' wave pattern. -/
private def parallelMapM (xs : Array α) (f : α → IO β) : IO (Array β) := do
  let mut out : Array β := #[]
  let mut i := 0
  while i < xs.size do
    let wave := xs.extract i (min (i + scanJobs) xs.size)
    let tasks ← wave.mapM fun x => IO.asTask (f x)
    for t in tasks do
      out := out.push (← IO.ofExcept (← IO.wait t))
    i := i + scanJobs
  return out

/-- Print a bench phase timing to stderr when `bench` is on. -/
private def benchMark (bench : Bool) (phase : String) (t0 : Nat) : IO Unit := do
  if bench then
    IO.eprintln s!"bench: {phase} {(← IO.monoMsNow) - t0}"

/-! ## Glob expansion -/

private def segMatch (pat seg : String) : Bool :=
  if pat == "*" then true
  else match pat.splitOn "*" with
    | [pre, suf] =>
      seg.startsWith pre && seg.endsWith suf && seg.length ≥ pre.length + suf.length
    | _ => pat == seg

/-- Expand one member pattern (e.g. `packages/*`) into directories relative to `root`. -/
private def expandPattern (root : FilePath) (pat : String) : IO (Array FilePath) := do
  let mut cands : Array FilePath := #[""]
  for seg in pat.splitOn "/" do
    let mut next : Array FilePath := #[]
    for cand in cands do
      if seg.contains '*' then
        let entries ← try (root / cand).readDir catch _ => pure #[]
        for e in entries do
          if !e.fileName.startsWith "." && segMatch seg e.fileName && (← e.path.isDir) then
            next := next.push (if cand.toString.isEmpty then e.fileName else cand / e.fileName)
      else
        let p : FilePath := if cand.toString.isEmpty then seg else cand / seg
        if ← (root / p).isDir then
          next := next.push p
    cands := next
  return cands

/-- Does `rel` match the (segment-wise) pattern? Used for `exclude`. -/
def matchPattern (pat : String) (rel : FilePath) : Bool :=
  let ps := pat.splitOn "/"
  let rs := rel.toString.splitOn "/"
  ps.length == rs.length && (ps.zip rs).all fun (p, s) => segMatch p s

/-! ## Member loading -/

private def isIdentComponent (s : String) : Bool :=
  !s.isEmpty && (s.toList.head!.isAlpha || s.toList.head! == '_') &&
    s.toList.all fun c => c.isAlphanum || c == '_' || c == '\''

/-- Top-level module roots and the full module list of a member directory. -/
private def scanModules (dir : FilePath) : IO (Array String × Array String) := do
  let skip : FilePath → IO Bool := fun p =>
    return !(p.fileName.getD "").startsWith "."
  let paths ← try dir.walkDir (enter := skip) catch _ => pure #[]
  let mut roots : Array String := #[]
  let mut modules : Array String := #[]
  for p in paths do
    let ps := p.toString
    if ps.endsWith ".lean" && p.fileName != some "lakefile.lean" then
      let rel0 := (ps.drop (dir.toString.length + 1)).toString.toList
      let rel := String.ofList (rel0.take (rel0.length - 5))
      let comps := rel.splitOn "/"
      if comps.all isIdentComponent then
        let modName := ".".intercalate comps
        modules := modules.push modName
        match comps with
        | [single] =>
          if !roots.contains single then roots := roots.push single
        | rootComp :: _ =>
          if !roots.contains rootComp then roots := roots.push rootComp
        | [] => pure ()
  return (roots, modules)

private def readOptionalFile (p : FilePath) : IO (Option String) :=
  try pure (some (← IO.FS.readFile p)) catch _ => pure none

private def loadMember (root relDir : FilePath) : IO (Diagnostics × Option MemberPkg) := do
  let dir := root / relDir
  let lakefile := dir / "lakefile.lean"
  let mut diags : Diagnostics := #[]
  let lakeText? ← readOptionalFile lakefile
  match lakeText? with
  | none =>
    diags := diags ++ Diagnostics.warning s!"skipping `{relDir.toString}`: no lakefile.lean"
    return (diags, none)
  | some lakeText =>
    let (scanDiags, scan) := scanLakefile (tokenize lakeText) lakefile
    diags := diags ++ scanDiags
    match scan.pkgName with
    | none =>
      diags := diags ++ Diagnostics.error s!"{lakefile.toString}: no `package` declaration found"
      return (diags, none)
    | some name =>
      let (roots, modules) ← scanModules dir
      if roots.isEmpty then
        diags := diags ++ Diagnostics.warning s!"member `{name}` at {relDir.toString} has no Lean modules"
      let toolchain? := (← readOptionalFile (dir / "lean-toolchain")).map fun t => t.trimAscii.toString
      return (diags, some {
        name, relDir, requires := scan.requires, moduleRoots := roots,
        modules := modules.insertionSort (· < ·), toolchain := toolchain?,
        targets := scan.targets, testDriver := scan.testDriver,
        lintDriver := scan.lintDriver, declaredOptions := scan.declaredOptions,
        hasOptionAssignments := scan.hasOptionAssignments })

/-! ## Config parsing -/

private def knownKeys (_t : Toml.Table) (groupNames depNames : Array String) : Array String :=
  #[ "workspace.members", "workspace.exclude", "workspace.default-members", "workspace.name"
   , "policy.single-package-version", "policy.unique-module-roots"
   , "policy.require-direct-import-edges", "policy.member-toolchains"
   , "policy.conflicting-package-options"
   , "cache.local", "cache.restore" ]
  ++ groupNames.map (s!"groups.{·}.members")
  ++ depNames.flatMap fun d => #[s!"deps.{d}.git", s!"deps.{d}.rev", s!"deps.{d}.path"]

/-- Parse one `[deps.<name>]` table: `git` + optional `rev`, or `path`. -/
private def parseCentralDep (t : Toml.Table) (name : String) : Except Diagnostics CentralDep := do
  let git? := t.getStr s!"deps.{name}.git"
  let rev? := t.getStr s!"deps.{name}.rev"
  let path? := t.getStr s!"deps.{name}.path"
  match git?, path? with
  | some _, some _ =>
    .error (Diagnostics.error s!"[deps.{name}] sets both `git` and `path`; choose one")
  | some url, none =>
    .ok { name, src := .git url rev? }
  | none, some dir =>
    if rev?.isSome then
      .error (Diagnostics.error s!"[deps.{name}] sets `rev` but no `git` url")
    else
      .ok { name, src := .path dir }
  | none, none =>
    .error (Diagnostics.error s!"[deps.{name}] must set `git` (optionally `rev`) or `path`")

private def parseConfig (t : Toml.Table) : Diagnostics × WorkspaceConfig := Id.run do
  let mut diags : Diagnostics := #[]
  let groupNames := t.subsections "groups"
  let depNames := t.subsections "deps"
  for k in t.keys do
    if !k.startsWith "options." && !(knownKeys t groupNames depNames).contains k then
      diags := diags ++ Diagnostics.warning s!"lean-workspace.toml: ignoring unknown key `{k}`"
  let mut cfg : WorkspaceConfig := {}
  if let some n := t.getStr "workspace.name" then cfg := { cfg with name := n }
  match t.getStrArray "workspace.members" with
  | some ms => cfg := { cfg with memberPatterns := ms }
  | none =>
    diags := diags ++ Diagnostics.error "lean-workspace.toml: missing required `workspace.members`"
  if let some xs := t.getStrArray "workspace.exclude" then cfg := { cfg with excludePatterns := xs }
  if let some xs := t.getStrArray "workspace.default-members" then
    cfg := { cfg with defaultMembers := xs }
  for g in groupNames do
    match t.getStrArray s!"groups.{g}.members" with
    | some ms => cfg := { cfg with groups := cfg.groups.push (g, ms) }
    | none => diags := diags ++ Diagnostics.error s!"group `{g}` is missing `members`"
  if let some b := t.getBool "cache.local" then cfg := { cfg with cacheLocal := b }
  if let some r := t.getStr "cache.restore" then
    if #["requested-only", "package", "workspace"].contains r then
      cfg := { cfg with cacheRestore := r }
    else
      diags := diags ++ Diagnostics.error
        s!"cache.restore must be one of requested-only|package|workspace, got `{r}`"
  if let some b := t.getBool "policy.unique-module-roots" then
    cfg := { cfg with uniqueModuleRoots := b }
  if let some b := t.getBool "policy.require-direct-import-edges" then
    cfg := { cfg with requireDirectImportEdges := b }
  if let some m := t.getStr "policy.member-toolchains" then
    cfg := { cfg with memberToolchains := m }
  for d in depNames do
    match parseCentralDep t d with
    | .ok cd => cfg := { cfg with deps := cfg.deps.push cd }
    | .error ds => diags := diags ++ ds
  -- [options]: every key under the `options.` prefix; name is the dotted tail
  for (k, v) in t.entries do
    if k.startsWith "options." then
      let name := (k.drop 8).toString
      match v with
      | .boolean b => cfg := { cfg with options := cfg.options.push (name, toString b) }
      | .int n => cfg := { cfg with options := cfg.options.push (name, toString n) }
      | .str str => cfg := { cfg with options := cfg.options.push (name, s!"\"{str}\"") }
      | .arr _ =>
        diags := diags ++ Diagnostics.error
          s!"[options] `{name}`: array values are not supported for Lean options"
  return (diags, cfg)

/-! ## Validation -/

/-- Is this member a test/benchmark package (not production code)? -/
def isTestMember (name : String) : Bool :=
  let n := name.toLower
  #["test", "tests", "bench", "benchmarks", "testing"].any fun suf => n.endsWith suf

/-- Read the given module files of one member and check their imports against
    the ownership index. Returns diagnostics and import-map entries in module
    order; folded back in member order by the caller, so parallelism cannot
    reorder output. -/
private def memberImportScan (root : FilePath) (ownerMap : Std.HashMap String String)
    (checkEdges : Bool) (m : MemberPkg) : IO (Diagnostics × Array (String × Array String)) := do
  let mut diags : Diagnostics := #[]
  let mut entries : Array (String × Array String) := #[]
  for mod in m.modules do
    let file : FilePath := root / m.relDir / (mod.replace "." "/" ++ ".lean")
    let text? ← readOptionalFile file
    if let some text := text? then
      let imps := parseImports text
      entries := entries.push (mod, imps)
      if checkEdges then
        for imp in imps do
          match ownerMap.get? imp with
          | none => pure () -- external or generated module; not our concern
          | some owner =>
            if owner != m.name then
              let declared := m.requires.any (·.name == owner)
              if !declared then
                diags := diags ++ Diagnostics.error
                  s!"module `{mod}` in package `{m.name}` imports `{imp}` from package \
                     `{owner}`, but `{m.name}` does not declare a direct dependency on `{owner}`"
                  #[s!"add `require {owner} from \"...\"` to {m.relDir.toString}/lakefile.lean"]
              if isTestMember owner && !isTestMember m.name then
                diags := diags ++ Diagnostics.error
                  s!"production package `{m.name}` imports `{imp}` from test/benchmark \
                     package `{owner}`"
  return (diags, entries)

partial def findCycle (names : Array String) (edges : Array (String × String))
    (start cur : String) (path : List String) : Option (List String) :=
  let nexts := edges.filterMap fun (a, b) => if a == cur then some b else none
  nexts.toList.findSome? fun nxt =>
    if nxt == start then some (nxt :: path)
    else if path.contains nxt || !names.contains nxt then none
    else findCycle names edges start nxt (nxt :: path)

/-- Find one package dependency cycle, if any. -/
def findAnyCycle (names : Array String) (edges : Array (String × String)) : Option (List String) :=
  names.toList.findSome? fun start => findCycle names edges start start [start]

/-! ## Loading -/

/--
Load, discover and fully validate the workspace rooted at `root`
(the directory containing `lean-workspace.toml`). No processes are spawned;
the only IO is reading files under `root`.

`loadModuleImports := false` skips the per-module import index (step 12):
consumers that never need it (`graph`, `metadata`, `clean`, `why`, builds
without `--affected`) avoid one file read per module. The architectural
import check runs with the index, so `check`/`sync` must keep the default.
`bench := true` prints per-phase timings to stderr as `bench: <phase> <ms>`. -/
def load (root : FilePath) (loadModuleImports : Bool := true) (bench : Bool := false) :
    IO (Except Diagnostics Workspace) := do
  let tStart ← IO.monoMsNow
  let mut diags : Diagnostics := #[]
  -- 1. Manifest
  let manifestPath := root / "lean-workspace.toml"
  let manifestText? ← readOptionalFile manifestPath
  let manifestText ← match manifestText? with
    | none => return .error (Diagnostics.error s!"no lean-workspace.toml found at {root.toString}")
    | some t => pure t
  let table ← match Toml.parse manifestText with
    | .error e => return .error (Diagnostics.error s!"{manifestPath.toString}: {e}")
    | .ok t => pure t
  let (cfgDiags, config) := parseConfig table
  diags := diags ++ cfgDiags
  benchMark bench "manifest" tStart
  -- 2. Toolchain
  let tTool ← IO.monoMsNow
  let toolchain ← match ← readOptionalFile (root / "lean-toolchain") with
    | some t => pure t.trimAscii.toString
    | none =>
      diags := diags ++ Diagnostics.warning "no root lean-toolchain file found"
      pure ""
  benchMark bench "toolchain" tTool
  -- 3. Member discovery
  let tDisc ← IO.monoMsNow
  let mut relDirs : Array FilePath := #[]
  for pat in config.memberPatterns do
    relDirs := relDirs ++ (← expandPattern root pat)
  relDirs := relDirs.filter fun d =>
    !config.excludePatterns.any (matchPattern · d)
  relDirs := relDirs.map (·.toString) |>.insertionSort (· < ·) |>.toList.eraseDups.toArray.map (⟨·⟩)
  if relDirs.isEmpty then
    diags := diags ++ Diagnostics.error "workspace member patterns matched no packages"
  benchMark bench "discovery" tDisc
  -- 4. Load members (parallel waves; diagnostics folded back in relDir order)
  let tMem ← IO.monoMsNow
  let loaded ← parallelMapM relDirs (loadMember root)
  let mut members : Array MemberPkg := #[]
  for (mDiags, m?) in loaded do
    diags := diags ++ mDiags
    if let some m := m? then members := members.push m
  members := members.insertionSort fun a b => a.name < b.name
  benchMark bench "member-scan" tMem
  let tVal ← IO.monoMsNow
  -- 5. Unique package names
  let names0 := members.map MemberPkg.name |>.toList.eraseDups
  let dupNames := names0.filter fun n => (members.filter (·.name == n)).size > 1
  for n in dupNames do
    let claimants := members.filter (·.name == n) |>.map fun m => s!"{m.relDir.toString}"
    diags := diags ++ Diagnostics.error s!"duplicate package name `{n}`" claimants
  -- 6. Toolchain policy
  for m in members do
    if let some mt := m.toolchain then
      if config.memberToolchains == "must-match-root" && !toolchain.isEmpty && mt != toolchain then
        diags := diags ++ Diagnostics.error
          s!"member `{m.name}` has a toolchain that does not match the root"
          #[s!"member: {mt}", s!"root:   {toolchain}"]
  -- 7. Unique module roots
  if config.uniqueModuleRoots then
    for m in members do
      for r in m.moduleRoots do
        let others := members.filter fun m' => m.name < m'.name && m'.moduleRoots.contains r
        for o in others do
          diags := diags ++ Diagnostics.error
            s!"module root `{r}` is claimed by both `{m.name}` and `{o.name}`"
            #[s!"{m.name}: {m.relDir.toString}", s!"{o.name}: {o.relDir.toString}"]
  -- 8. Module ownership + unique modules
  let mut moduleOwners : Array (String × String) := #[]
  -- Hash side-index for O(1) lookup; the sorted array remains the model.
  let mut ownerMap : Std.HashMap String String := {}
  for m in members do
    for mod in m.modules do
      match ownerMap.get? mod with
      | some o =>
        diags := diags ++ Diagnostics.error
          s!"module `{mod}` is owned by both `{o}` and `{m.name}`"
      | none =>
        ownerMap := ownerMap.insert mod m.name
        moduleOwners := moduleOwners.push (mod, m.name)
  moduleOwners := moduleOwners.insertionSort fun a b => a.1 < b.1
  -- 9. Member edges + cycles
  let names := members.map MemberPkg.name
  let mut edges : Array (String × String) := #[]
  for m in members do
    for r in m.requires do
      if names.contains r.name && r.name != m.name && !edges.contains (m.name, r.name) then
        edges := edges.push (m.name, r.name)
  edges := edges.insertionSort fun a b => a.1 < b.1 || (a.1 == b.1 && a.2 < b.2)
  if let some cyc := findAnyCycle names edges then
    diags := diags ++ Diagnostics.error
      "package dependency cycle detected"
      #[String.intercalate " → " (cyc.reverse.map toString)]
  -- 10. External dependency resolution: centrally declared names must match
  -- [deps] exactly; the rest must agree across members.
  let mut externals : Array ExternalRequire := #[]
  for m in members do
    for r in m.requires do
      if !names.contains r.name then
        match config.deps.find? (·.name == r.name) with
        | some cd =>
          if cd.src != r.src then
            diags := diags ++ Diagnostics.error
              s!"member `{m.name}` requires `{r.name}` from a source that does not match \
                 the workspace [deps] declaration"
              #[ s!"{m.relDir.toString}/lakefile.lean:  {r.src.describe}"
               , s!"lean-workspace.toml [deps.{cd.name}]:  {cd.src.describe}"
               , s!"align the member with the central declaration \
                  (or run `lakew sync --write-deps`)" ]
        | none =>
          externals := externals.push { name := r.name, src := r.src, requiredBy := m.name }
  let extNames := externals.map ExternalRequire.name |>.toList.eraseDups
  for n in extNames do
    let rs := externals.filter (·.name == n)
    let distinct := rs.map ExternalRequire.src |>.toList.eraseDups
    if distinct.length > 1 then
      let mut ctx : Array String := #[]
      for r in rs do
        ctx := ctx.push s!"{r.requiredBy} requires:"
        ctx := ctx.push s!"  {r.src.describe}"
      ctx := ctx.push "No deterministic workspace resolution exists."
      diags := diags ++ Diagnostics.error s!"Conflicting dependency `{n}`\n" ctx
  -- 11. default-members / groups reference existing members
  for d in config.defaultMembers do
    if !names.contains d then
      diags := diags ++ Diagnostics.error s!"default-member `{d}` is not a workspace member"
  for (g, gs) in config.groups do
    for d in gs do
      if !names.contains d then
        diags := diags ++ Diagnostics.error s!"group `{g}` references unknown member `{d}`"
  benchMark bench "validate" tVal
  -- 12. Module import map + architectural import checking
  let tImports ← IO.monoMsNow
  let mut moduleImports : Array (String × Array String) := #[]
  if loadModuleImports then
    let scanned ← parallelMapM members
      (memberImportScan root ownerMap config.requireDirectImportEdges)
    for (sDiags, entries) in scanned do
      diags := diags ++ sDiags
      moduleImports := moduleImports ++ entries
  benchMark bench "module-imports" tImports
  -- 13. [options] shared-option policy (validation, not propagation)
  for (optName, optVal) in config.options do
    for m in members do
      match m.declaredOptions.find? (·.1 == optName) with
      | some (_, v) =>
        if v != optVal then
          diags := diags ++ Diagnostics.error
            s!"member `{m.name}` sets `{optName}` to {v}, but the workspace [options] \
               policy requires {optVal}"
            #[s!"{m.relDir.toString}/lakefile.lean", s!"lean-workspace.toml [options]"]
      | none =>
        if !m.hasOptionAssignments then
          diags := diags ++ Diagnostics.error
            s!"member `{m.name}` does not set required workspace option `{optName}`"
            #[s!"add `⟨`{optName}, {optVal}⟩` to its leanOptions/moreLeanOptions"]
        else
          diags := diags ++ Diagnostics.warning
            s!"could not verify `{optName}` in `{m.name}` (options composed beyond \
               canonical ⟨name, value⟩ tuples; please verify manually)"
  if diags.hasErrors then
    return .error diags
  -- Warnings are still reported on success via the log; the model is complete.
  for d in diags do
    if d.severity == .warning then
      IO.eprintln (Diagnostics.render #[d])
  benchMark bench "total" tStart
  return .ok {
    root, config, members, edges, externals, moduleOwners, moduleImports, toolchain
    hasModuleImportIndex := loadModuleImports
  }

/-! ## Dependency alignment (`lakew sync --write-deps`) -/

/-- Extract the package-name field (preserving any `«»` quoting) from a line
    whose first token is `require`. -/
private def requireNameField (line : String) : Option String := Id.run do
  let t := line.trimAscii.toString
  if !t.startsWith "require " then return none
  let rest := (t.drop 8).toString
  if rest.startsWith "«" then
    let close := (rest.toList.drop 1).findIdx? (· == '»')
    return close.map fun i => String.ofList (rest.toList.take (i + 2))
  else
    let name := String.ofList (rest.toList.takeWhile fun c =>
      c.isAlphanum || c == '_' || c == '.' || c == '\'')
    return if name.isEmpty then none else some name

/-- Render the canonical single-line require for a central declaration,
    preserving the original indentation and name spelling of `line`. -/
private def renderAlignedRequire (line : String) (cd : CentralDep) : Option String := do
  let nameField ← requireNameField line
  let indent := String.ofList (line.toList.takeWhile Char.isWhitespace)
  match cd.src with
  | .path dir =>
    some s!"{indent}require {nameField} from \"{dir.toString}\""
  | .git url rev? =>
    match rev? with
    | some rev => some s!"{indent}require {nameField} from git \"{url}\" @ \"{rev}\""
    | none => some s!"{indent}require {nameField} from git \"{url}\""

/-- Rewrite member `require` declarations to match the central `[deps]`
    declarations. Only canonical single-line requires in `lakefile.lean` are
    rewritten; anything else is an error naming the file and the edit to make
    by hand. Returns the files that were modified. -/
def alignDepsWithCentral (root : FilePath) : IO (Except Diagnostics (Array FilePath)) := do
  let manifestText? ← readOptionalFile (root / "lean-workspace.toml")
  let manifestText ← match manifestText? with
    | none => return .error (Diagnostics.error s!"no lean-workspace.toml found at {root.toString}")
    | some t => pure t
  let table ← match Toml.parse manifestText with
    | .error e => return .error (Diagnostics.error s!"lean-workspace.toml: {e}")
    | .ok t => pure t
  let (cfgDiags, config) := parseConfig table
  if cfgDiags.hasErrors then
    return .error cfgDiags
  if config.deps.isEmpty then
    return .ok #[]
  let mut relDirs : Array FilePath := #[]
  for pat in config.memberPatterns do
    relDirs := relDirs ++ (← expandPattern root pat)
  relDirs := relDirs.filter fun d => !config.excludePatterns.any (matchPattern · d)
  let mut diags : Diagnostics := #[]
  let mut edited : Array FilePath := #[]
  for rel in relDirs do
    let lakefile := root / rel / "lakefile.lean"
    if let some text ← readOptionalFile lakefile then
      let mut out : Array String := #[]
      let mut changed := false
      let mut lineNo := 0
      for line in text.splitOn "\n" do
        lineNo := lineNo + 1
        match requireNameField line with
        | none => out := out.push line
        | some nameField =>
          -- strip «» quoting to get the package name
          let name :=
            if nameField.startsWith "«" && nameField.endsWith "»" then
              String.ofList (nameField.toList.drop 1 |>.dropLast)
            else nameField
          match config.deps.find? (·.name == name) with
          | none => out := out.push line -- not centrally managed; leave alone
          | some cd =>
            let toks := tokenize line
            let current? : Option RequireSrc := match toks.toList with
              | [.ident "require", .ident _, .ident "from", .str dir] =>
                some (.path dir)
              | [.ident "require", .ident _, .ident "from", .ident "git", .str url] =>
                some (.git url none)
              | [.ident "require", .ident _, .ident "from", .ident "git", .str url, .at, .str rev] =>
                some (.git url (some rev))
              | _ => none
            match current? with
            | none =>
              diags := diags ++ Diagnostics.error
                s!"{lakefile.toString}:{lineNo}: cannot rewrite this `require {nameField}` \
                   automatically (multi-line or non-canonical form)"
                #[s!"edit it by hand to match [deps.{cd.name}]: {cd.src.describe}"]
              out := out.push line
            | some current =>
              if current == cd.src then
                out := out.push line
              else
                match renderAlignedRequire line cd with
                | some newLine =>
                  out := out.push newLine
                  changed := true
                | none => out := out.push line
      if changed then
        IO.FS.writeFile lakefile ("\n".intercalate out.toList)
        edited := edited.push lakefile
  if diags.hasErrors then
    return .error diags
  return .ok edited

end Workspace

end LakeWorkspace

end -- public section
