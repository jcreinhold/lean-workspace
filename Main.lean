/-
`lakew` — the workspace command line.

Thin argument parsing over the LakeWorkspace API. No logic lives here that
isn't argument handling and output formatting.
-/
import LakeWorkspace
import LakeWorkspace.Backend.Git
import LakeWorkspace.Backend.LakeCli
import LakeWorkspace.Json

open LakeWorkspace

private def usage : String :=
  "lakew — Lean workspace orchestrator over Lake\n" ++
  "\n" ++
  "USAGE\n" ++
  "  lakew <command> [options]\n" ++
  "\n" ++
  "COMMANDS\n" ++
  "  sync      Validate the workspace, then atomically install the generated\n" ++
  "            virtual root lakefile.lean, package overrides and metadata,\n" ++
  "            and run one `lake update`.\n" ++
  "              --locked    fail if generated files would change\n" ++
  "              --offline   install generated files but do not resolve\n" ++
  "              --frozen    --locked + --offline\n" ++
  "  check     Fail if generated files are stale or architecture is violated.\n" ++
  "  build     One `lake build` for the selected targets.\n" ++
  "              -p, --package <name>   select a member (repeatable)\n" ++
  "              --group <name>         select a named group\n" ++
  "              --all                  select all members\n" ++
  "              --changed [<ref>]      select members changed since <ref>\n" ++
  "                                   (or the working tree), plus reverse deps\n" ++
  "              @pkg[/target]          package-qualified target passthrough\n" ++
  "              -- <args>              pass remaining args to lake verbatim\n" ++
  "  clean     `lake clean` for the selected targets.\n" ++
  "  graph     Print the member dependency graph.\n" ++
  "  metadata  Print canonical workspace metadata.\n" ++
  "\n" ++
  "COMMON OPTIONS\n" ++
  "  --root <dir>   workspace root (default: nearest lean-workspace.toml\n" ++
  "                 at or above the current directory)\n" ++
  "  --dry-run      print the plan instead of executing it\n" ++
  "  --json         machine-readable output (with --dry-run, graph, metadata)\n"

private structure CliOpts where
  root : Option FilePath := none
  dryRun : Bool := false
  json : Bool := false
  locked : Bool := false
  offline : Bool := false
  packages : Array String := #[]
  groups : Array String := #[]
  targets : Array String := #[]
  changed : Option (Option String) := none
  affected : Option (Option String) := none
  all : Bool := false
  writeDeps : Bool := false
  /-- Hidden flag: print `load` phase timings to stderr (`bench: <phase> <ms>`). -/
  bench : Bool := false
  passthrough : Array String := #[]
  deriving Inhabited

/-- Parse command arguments. Unknown `--flags` and everything after `--` is
    passed through to Lake (for build-like commands). -/
private def parseArgs (args : List String) : Except String CliOpts := Id.run do
  let mut o : CliOpts := {}
  let mut rest := args
  let mut passthroughMode := false
  repeat
    match rest with
    | [] => break
    | a :: as =>
      rest := as
      if passthroughMode then
        o := { o with passthrough := o.passthrough.push a }
      else match a with
        | "--" => passthroughMode := true
        | "--root" =>
          match rest with
          | r :: as' => o := { o with root := some ⟨r⟩ }; rest := as'
          | [] => return .error "--root requires a directory"
        | "--dry-run" => o := { o with dryRun := true }
        | "--json" => o := { o with json := true }
        | "--locked" => o := { o with locked := true }
        | "--offline" => o := { o with offline := true }
        | "--frozen" => o := { o with locked := true, offline := true }
        | "--write-deps" => o := { o with writeDeps := true }
        | "--bench" => o := { o with bench := true }
        | "--all" => o := { o with all := true }
        | "-p" | "--package" =>
          match rest with
          | p :: as' => o := { o with packages := o.packages.push p }; rest := as'
          | [] => return .error s!"{a} requires a package name"
        | "--group" =>
          match rest with
          | g :: as' => o := { o with groups := o.groups.push g }; rest := as'
          | [] => return .error "--group requires a group name"
        | "--changed" =>
          -- optional ref: consumed only if the next arg does not look like a flag
          match rest with
          | r :: as' =>
            if !r.startsWith "-" then
              o := { o with changed := some (some r) }; rest := as'
            else
              o := { o with changed := some none }
          | [] => o := { o with changed := some none }
        | "--affected" =>
          match rest with
          | r :: as' =>
            if !r.startsWith "-" then
              o := { o with affected := some (some r) }; rest := as'
            else
              o := { o with affected := some none }
          | [] => o := { o with affected := some none }
        | _ =>
          if a.startsWith "@" then
            o := { o with targets := o.targets.push a }
          else if a.startsWith "--" then
            o := { o with passthrough := o.passthrough.push a }
          else
            return .error s!"unexpected argument `{a}` (targets must be @-qualified; use -- to pass args to lake)"
  return .ok o

private def findRoot (start : FilePath) : IO (Option FilePath) := do
  let mut dir := start
  repeat
    if ← (dir / "lean-workspace.toml").pathExists then
      return some dir
    match dir.parent with
    | none => return none
    | some p =>
      if p == dir then return none
      dir := p
  return none

private def printDiags (ds : Diagnostics) : IO Unit :=
  IO.eprintln (Diagnostics.render ds)

private def findWsRoot (o : CliOpts) : IO (Option FilePath) := do
  let cwd ← IO.currentDir
  match o.root with
  | some r => pure (some r)
  | none => findRoot cwd

/-- Locate the root and load the workspace; on failure print and exit 1.
    `needsModuleImports := false` skips the per-module import index for
    commands that never consult it (see `Workspace.load`). -/
private def loadWs (o : CliOpts) (needsModuleImports : Bool := true) : IO (Option Workspace) := do
  let root? ← findWsRoot o
  match root? with
  | none =>
    IO.eprintln "error: no lean-workspace.toml found at or above the current directory"
    return none
  | some root =>
    match (← LakeWorkspace.load root (loadModuleImports := needsModuleImports) (bench := o.bench)) with
    | .error ds => printDiags ds; return none
    | .ok ws => return some ws

private def mkQuery (o : CliOpts) (root : FilePath) : IO (Option SelectionQuery) := do
  let gitPaths (flag : String) (ref? : Option String) : IO (Option (Array FilePath)) := do
    match (← Backend.Git.changedPaths root ref?) with
    | .error e =>
      IO.eprintln s!"error: {flag} failed: {e}"
      return none
    | .ok paths => return some paths
  let changedPaths? ← match o.changed with
    | none => pure (some none)
    | some ref? => do
      match (← gitPaths "--changed" ref?) with
      | none => return none
      | some ps => pure (some (some ps))
  let affectedPaths? ← match o.affected with
    | none => pure (some none)
    | some ref? => do
      match (← gitPaths "--affected" ref?) with
      | none => return none
      | some ps => pure (some (some ps))
  match changedPaths?, affectedPaths? with
  | some cp, some ap =>
    return some {
      packages := o.packages, groups := o.groups, targets := o.targets
      changedPaths := cp, affectedPaths := ap, all := o.all }
  | _, _ => return none

private def runPlanned (o : CliOpts) (p : BuildPlan) : IO UInt32 := do
  if o.dryRun then
    if o.json then
      IO.println (Json.pretty (Planner.toJson p))
    else
      IO.println (Planner.describe p)
    return 0
  for note in p.notes do
    IO.eprintln s!"note: {note}"
  let (code, report?) ← LakeWorkspace.execute p (capture := o.json)
  if let some r := report? then
    if o.json then
      IO.println (Json.pretty (Report.toJson r))
    else
      IO.println (Report.renderText r)
  return code

private def cmdSync (o : CliOpts) : IO UInt32 := do
  if o.writeDeps then
    match (← findWsRoot o) with
    | none =>
      IO.eprintln "error: no lean-workspace.toml found at or above the current directory"
      return 1
    | some root =>
      match (← Workspace.alignDepsWithCentral root) with
      | .error ds => printDiags ds; return 1
      | .ok edited =>
        for f in edited do
          IO.println s!"aligned {f.toString}"
  let some ws ← loadWs o | return 1
  let emptySel : Selection := { packages := #[], targets := #[], explanations := #[] }
  match LakeWorkspace.plan ws emptySel (.sync o.locked o.offline) with
  | .error ds => printDiags ds; return 2
  | .ok p => runPlanned o p

private def cmdCheck (o : CliOpts) : IO UInt32 := do
  let some ws ← loadWs o | return 1
  let stale ← LakeWorkspace.staleFiles ws
  if stale.isEmpty then
    IO.println "workspace is up to date"
    return 0
  else
    IO.eprintln "error: generated files are stale; run `lakew sync`:"
    for s in stale do
      IO.eprintln s!"  {s}"
    return 1

private def cmdBuildLike (o : CliOpts) (needsModuleImports : Bool) (action : Selection → Action) :
    IO UInt32 := do
  let some ws ← loadWs o needsModuleImports | return 1
  let some q ← mkQuery o ws.root | return 1
  match LakeWorkspace.select ws q with
  | .error ds => printDiags ds; return 2
  | .ok sel =>
    match LakeWorkspace.plan ws sel (action sel) with
    | .error ds => printDiags ds; return 2
    | .ok p => runPlanned o p

private def cmdGraph (o : CliOpts) : IO UInt32 := do
  let some ws ← loadWs o false | return 1
  if o.json then
    let j := Json.obj #[
      ("members", .arr (ws.memberNames.map .str)),
      ("edges", .arr (ws.edges.map fun e => .arr #[.str e.1, .str e.2])) ]
    IO.println (Json.pretty j)
  else
    for m in ws.members do
      let deps := ws.edges.filterMap fun (a, b) => if a == m.name then some b else none
      if deps.isEmpty then
        IO.println m.name
      else
        IO.println s!"{m.name}: {" ".intercalate deps.toList}"
  return 0

private def cmdWhy (o : CliOpts) (args : List String) : IO UInt32 := do
  match args with
  | [from_, to] => do
    let some ws ← loadWs o false | return 1
    if (ws.findMember? from_).isNone then
      IO.eprintln s!"error: unknown member `{from_}`"
      return 2
    if (ws.findMember? to).isNone then
      IO.eprintln s!"error: unknown member `{to}`"
      return 2
    match ws.whyPath from_ to with
    | some path =>
      if o.json then
        IO.println (Json.pretty (.obj #[
          ("from", .str from_), ("to", .str to),
          ("path", .arr (path.toArray.map .str)) ]))
      else
        IO.println s!"{from_} depends on {to} via:"
        IO.println s!"  {" → ".intercalate path}"
      return 0
    | none =>
      IO.eprintln s!"`{from_}` does not depend on `{to}`"
      return 1
  | _ =>
    IO.eprintln "usage: lakew why <from> <to>"
    return 2

private def cmdMetadata (o : CliOpts) : IO UInt32 := do
  let some ws ← loadWs o false | return 1
  if o.json then
    IO.println (Json.pretty (Backend.LakeCli.renderMetadata ws))
  else
    IO.println s!"workspace root: {ws.root.toString}"
    IO.println s!"toolchain: {ws.toolchain}"
    IO.println s!"members: {ws.members.size}"
    for m in ws.members do
      IO.println s!"  {m.name} ({m.relDir.toString}): {m.modules.size} modules"
    IO.println s!"fingerprint: {Workspace.fingerprint ws}"
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | [] | ["help"] | ["--help"] | ["-h"] =>
    IO.println usage
    return 0
  | "why" :: rest =>
    -- why takes positional args; mini-parse only --root/--json here
    let mut o : CliOpts := {}
    let mut pos : List String := []
    let mut rs := rest
    repeat
      match rs with
      | [] => break
      | "--json" :: as' => o := { o with json := true }; rs := as'
      | "--root" :: r :: as' => o := { o with root := some ⟨r⟩ }; rs := as'
      | a :: as' => pos := pos ++ [a]; rs := as'
    cmdWhy o pos
  | cmd :: rest =>
    match parseArgs rest with
    | .error e =>
      IO.eprintln s!"error: {e}"
      return 2
    | .ok o =>
      match cmd with
      | "sync" => cmdSync o
      | "check" => cmdCheck o
      | "build" => cmdBuildLike o o.affected.isSome fun _ => .build o.passthrough
      | "clean" => cmdBuildLike o false fun _ => .clean
      | "test" => cmdBuildLike o o.affected.isSome fun _ => .test o.passthrough
      | "lint" => cmdBuildLike o o.affected.isSome fun _ => .lint o.passthrough
      | "graph" => cmdGraph o
      | "metadata" => cmdMetadata o
      | _ =>
        IO.eprintln s!"error: unknown command `{cmd}`\n"
        IO.eprintln usage
        return 2
