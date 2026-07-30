/-
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
import LakeWorkspace.Toml
import LakeWorkspace.Diagnostics

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
  deriving Repr, Inhabited

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

/-- Extract the package name and `require` declarations from lakefile tokens.
    Unparseable `require` occurrences produce warnings, not failures.
    TODO: parse and compare `with` configuration options (currently ignored;
    conflicting options across members must become an error). -/
private def scanLakefile (toks : Array Tok) (origin : FilePath) :
    Diagnostics × Option String × Array RequireDecl := Id.run do
  let mut diags : Diagnostics := #[]
  let mut pkgName : Option String := none
  let mut requires : Array RequireDecl := #[]
  let mut i := 0
  let warn (msg : String) : Diagnostics := Diagnostics.warning s!"{origin.toString}: {msg}"
  while i < toks.size do
    match toks[i]! with
    | .ident "package" =>
      match toks[i + 1]? with
      | some (.ident n) =>
        if pkgName.isNone then pkgName := some n
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
      | some decl => requires := requires.push decl
      | none => diags := diags ++ warn "could not parse a `require` declaration"
      i := i + 1
    | _ => i := i + 1
  return (diags, pkgName, requires)

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
    let (scanDiags, name?, requires) := scanLakefile (tokenize lakeText) lakefile
    diags := diags ++ scanDiags
    match name? with
    | none =>
      diags := diags ++ Diagnostics.error s!"{lakefile.toString}: no `package` declaration found"
      return (diags, none)
    | some name =>
      let (roots, modules) ← scanModules dir
      if roots.isEmpty then
        diags := diags ++ Diagnostics.warning s!"member `{name}` at {relDir.toString} has no Lean modules"
      let toolchain? := (← readOptionalFile (dir / "lean-toolchain")).map fun t => t.trimAscii.toString
      return (diags, some {
        name, relDir, requires, moduleRoots := roots,
        modules := modules.insertionSort (· < ·), toolchain := toolchain? })

/-! ## Config parsing -/

private def knownKeys (_t : Toml.Table) (groupNames : Array String) : Array String :=
  #[ "workspace.members", "workspace.exclude", "workspace.default-members", "workspace.name"
   , "policy.single-package-version", "policy.unique-module-roots"
   , "policy.require-direct-import-edges", "policy.member-toolchains"
   , "policy.conflicting-package-options"
   , "cache.local", "cache.restore" ]
  ++ groupNames.map (s!"groups.{·}.members")

private def parseConfig (t : Toml.Table) : Diagnostics × WorkspaceConfig := Id.run do
  let mut diags : Diagnostics := #[]
  let groupNames := t.subsections "groups"
  for k in t.keys do
    if !(knownKeys t groupNames).contains k then
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
  return (diags, cfg)

/-! ## Validation -/

/-- Is this member a test/benchmark package (not production code)? -/
def isTestMember (name : String) : Bool :=
  let n := name.toLower
  #["test", "tests", "bench", "benchmarks", "testing"].any fun suf => n.endsWith suf

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
-/
def load (root : FilePath) : IO (Except Diagnostics Workspace) := do
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
  -- 2. Toolchain
  let toolchain ← match ← readOptionalFile (root / "lean-toolchain") with
    | some t => pure t.trimAscii.toString
    | none =>
      diags := diags ++ Diagnostics.warning "no root lean-toolchain file found"
      pure ""
  -- 3. Member discovery
  let mut relDirs : Array FilePath := #[]
  for pat in config.memberPatterns do
    relDirs := relDirs ++ (← expandPattern root pat)
  relDirs := relDirs.filter fun d =>
    !config.excludePatterns.any (matchPattern · d)
  relDirs := relDirs.map (·.toString) |>.insertionSort (· < ·) |>.toList.eraseDups.toArray.map (⟨·⟩)
  if relDirs.isEmpty then
    diags := diags ++ Diagnostics.error "workspace member patterns matched no packages"
  -- 4. Load members
  let mut members : Array MemberPkg := #[]
  for rel in relDirs do
    let (mDiags, m?) ← loadMember root rel
    diags := diags ++ mDiags
    if let some m := m? then members := members.push m
  members := members.insertionSort fun a b => a.name < b.name
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
  for m in members do
    for mod in m.modules do
      match moduleOwners.find? (·.1 == mod) with
      | some (_, o) =>
        diags := diags ++ Diagnostics.error
          s!"module `{mod}` is owned by both `{o}` and `{m.name}`"
      | none => moduleOwners := moduleOwners.push (mod, m.name)
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
  -- 10. External dependency conflicts (one canonical source+revision per name)
  let mut externals : Array ExternalRequire := #[]
  for m in members do
    for r in m.requires do
      if !names.contains r.name then
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
  -- 12. Architectural import checking
  if config.requireDirectImportEdges then
    for m in members do
      for mod in m.modules do
        let file : FilePath := root / m.relDir / (mod.replace "." "/" ++ ".lean")
        let text? ← readOptionalFile file
        if let some text := text? then
          for imp in parseImports text do
            match moduleOwners.find? (·.1 == imp) with
            | none => pure () -- external or generated module; not our concern
            | some (_, owner) =>
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
  if diags.hasErrors then
    return .error diags
  -- Warnings are still reported on success via the log; the model is complete.
  for d in diags do
    if d.severity == .warning then
      IO.eprintln (Diagnostics.render #[d])
  return .ok {
    root, config, members, edges, externals, moduleOwners, toolchain
  }

end Workspace

end LakeWorkspace
