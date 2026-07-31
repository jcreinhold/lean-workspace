/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The load-path benchmark suite

Measures `Workspace.load` — the fixed cost every `lakew` command pays — on
synthetic workspaces of parameterized size, and pins the properties the
optimizations in `LakeWorkspace/Workspace.lean` were admitted under (see
`tests/bench.md` for the decision log):

- `graph`-class loads (no `--affected`) skip the module-import index entirely;
- full loads (`check`/`sync`) scale sub-quadratically in workspace size;
- a mathlib-scale skip-index load stays within a small multiple of one `lake`
  subprocess spawn, the design-doc budget.

The synthetic workspaces are deterministic (no RNG): member `memNNN` requires
one or two earlier members (a DAG), and each module imports 0–3 modules drawn
from its own member and its requires, so the architectural import check has
real, consistent work to do. Members build nothing; the suite stresses load
only. Generation and measurement happen before `runCases`, so the gates
compare numbers recorded in one pass; a generation or spawn failure is an
infrastructure error (the suite aborts), not a red test.

Run: `lake build suite-bench && .lake/build/bin/suite-bench [--list|--filter S]`.
Not wired into CI (wall-clock gates belong to a human reading `tests/bench.md`);
CI builds the suite to keep it compiling.
-/

namespace Suites.Bench

open Lakew.Test

/-- One benchmark size: member count × modules per member. -/
structure Size where
  name : String
  /-- Modules per member; `size` is also the member count. -/
  memberModules : Array Nat
  deriving Inhabited

def small : Size := ⟨"small", Array.replicate 10 50⟩
def medium : Size := ⟨"medium", Array.replicate 30 300⟩
/-- mathlib-shaped: five library members plus one monolith. -/
def mathlib : Size := ⟨"mathlib", Array.replicate 5 1200 ++ #[6000]⟩

def Size.totalModules (s : Size) : Nat := s.memberModules.foldl (· + ·) 0

/-! ## Synthetic workspace generation (deterministic) -/

/-- Earlier members required by member `i` (a DAG). -/
def memberRequires (i : Nat) : Array Nat :=
  if i == 0 then #[]
  else if i % 2 == 0 && i / 2 != i - 1 then #[i - 1, i / 2]
  else #[i - 1]

/-- Deterministic 0–3 imports for module `j` of member `i`. -/
def moduleImportsOf (sizes : Array Nat) (i j : Nat) : Array String := Id.run do
  let k := (i * 7 + j * 13) % 4
  let mut out : Array String := #[]
  let own := sizes[i]!
  let reqs := memberRequires i
  for t in [0:k] do
    if t == 0 && j > 0 then
      out := out.push s!"Mem{i}.M{(j * 31) % j}"
    else if !reqs.isEmpty then
      let r := reqs[t % reqs.size]!
      out := out.push s!"Mem{r}.M{(j * 17 + t) % sizes[r]!}"
    else if j > 1 then
      out := out.push s!"Mem{i}.M{(j * 11 + t) % (j - 1)}"
  return out

/-- Write one synthetic workspace of `size` under `dir`. With `tomlMixed`,
odd-numbered members carry a `lakefile.toml` instead of a `lakefile.lean`
(the PLAN-02 measurement: mixed members vs Lean-only on the same shape). -/
def generate (dir : System.FilePath) (size : Size) (tomlMixed : Bool := false) : IO Unit := do
  IO.FS.createDirAll (dir / "packages")
  IO.FS.writeFile (dir / "lean-toolchain") "leanprover/lean4:v4.33.0-rc1\n"
  IO.FS.writeFile (dir / "lean-workspace.toml")
    "[workspace]\nmembers = [\"packages/*\"]\n"
  for i in [0:size.memberModules.size] do
    let nModules := size.memberModules[i]!
    let name := s!"mem{i}"
    let root := s!"Mem{i}"
    let pkg := dir / "packages" / name
    IO.FS.createDirAll (pkg / root)
    if tomlMixed && i % 2 == 1 then
      let mut lakefile := s!"name = \"{name}\"\n"
      for r in memberRequires i do
        lakefile := lakefile ++ s!"\n[[require]]\nname = \"mem{r}\"\npath = \"../mem{r}\"\n"
      lakefile := lakefile ++ s!"\n[[lean_lib]]\nname = \"{root}\"\n"
      IO.FS.writeFile (pkg / "lakefile.toml") lakefile
    else
      let mut lakefile := s!"import Lake\nopen Lake DSL\n\npackage {name} where\n"
      for r in memberRequires i do
        lakefile := lakefile ++ s!"\nrequire mem{r} from \"../mem{r}\""
      IO.FS.writeFile (pkg / "lakefile.lean") (lakefile ++ "\n")
    for j in [0:nModules] do
      let imps := moduleImportsOf size.memberModules i j
      let body := (imps.map (s!"import {·}") |>.toList) ++ ["", s!"def {root}.M{j}.x : Nat := {j}"]
      IO.FS.writeFile (pkg / root / s!"M{j}.lean") ("\n".intercalate body ++ "\n")

/-! ## Measurement -/

/-- `bench: <phase> <ms>` lines from a `--bench` run's stderr. -/
def parseBench (stderr : String) : Array (String × Nat) := Id.run do
  let mut out : Array (String × Nat) := #[]
  for line in stderr.splitOn "\n" do
    match line.splitOn " " with
    | ["bench:", phase, ms] =>
      if let some n := ms.toNat? then out := out.push (phase, n)
    | _ => pure ()
  return out

def phaseMs (timings : Array (String × Nat)) (phase : String) : Nat :=
  timings.find? (·.1 == phase) |>.map (·.2) |>.getD 0

/-- One load measurement: `graph --bench` (skip-index load) and
`sync --dry-run --bench` (full load) against the workspace at `dir`. -/
def measure (lakew dir : System.FilePath) : IO (Array (String × Nat) × Array (String × Nat)) := do
  let graph ← expectExit "lakew graph" 0 lakew.toString #["graph", "--bench"] dir
  let full ← expectExit "lakew sync --dry-run" 0 lakew.toString
    #["sync", "--dry-run", "--bench"] dir
  return (parseBench graph.stderr, parseBench full.stderr)

/-- One size's recorded measurements. -/
structure Record where
  size : Size
  graph : Array (String × Nat)
  full : Array (String × Nat)
  deriving Inhabited

def renderRow (r : Record) : String :=
  let fmt (t : Array (String × Nat)) :=
    s!"total {phaseMs t "total"} ms \
       (member-scan {phaseMs t "member-scan"}, validate {phaseMs t "validate"}, \
        module-imports {phaseMs t "module-imports"})"
  s!"{r.size.name} ({r.size.memberModules.size} members, {r.size.totalModules} modules):\n" ++
    s!"  graph: {fmt r.graph}\n  full:  {fmt r.full}"

/-! ## The suite -/

/-- Everything measured in one pass, before any case runs. -/
structure Run where
  records : Array Record
  spawnMs : Nat

def collect (root : System.FilePath) : IO Run := do
  let lakew := root / ".lake" / "build" / "bin" / "lakew"
  unless ← lakew.pathExists do
    IO.eprintln "suite-bench: lakew binary missing; running `lake build lakew`"
    let build ← runProc "lake" #["build", "lakew"] root
    ensure (build.exitCode == 0) s!"lake build lakew failed:\n{build.stderr}"
  -- The spawn yardstick: one `lake` subprocess on this machine.
  let tSpawn ← IO.monoNanosNow
  let _spawn ← expectExit "lake --version" 0 "lake" #["--version"]
  let spawnMs := ((← IO.monoNanosNow) - tSpawn) / 1000000
  let sizes := #[small, medium, mathlib]
  let records ← withTempDir fun tmp => do
    let leanOnly ← sizes.mapM fun size => do
      let dir := tmp / size.name
      generate dir size
      let (graph, full) ← measure lakew dir
      pure ⟨size, graph, full⟩
    -- PLAN-02: the same medium shape with half the members TOML-carried.
    let mixedDir := tmp / "medium-mixed"
    generate mixedDir medium (tomlMixed := true)
    let (graph, full) ← measure lakew mixedDir
    pure (leanOnly.push ⟨{ medium with name := "medium-mixed" }, graph, full⟩)
  return { records, spawnMs }

def cases (run : Run) : Array Case :=
  let recordAt (name : String) : Record :=
    run.records.find? (·.size.name == name) |>.get!
  let tableCase (r : Record) : Case :=
    ⟨s!"{r.size.name}: {r.size.totalModules} modules measured", IO.println (renderRow r)⟩
  let cases : Array Case :=
    run.records.map tableCase ++ #[
    ⟨"graph load skips the module-import index", do
      ensureEq "module-imports phase in graph load" 0
        (phaseMs (recordAt "medium").graph "module-imports")⟩,
    ⟨"full load builds the module-import index", do
      ensure (phaseMs (recordAt "medium").full "module-imports" > 0)
        "sync --dry-run did no module-import work; the index is never being built"⟩,
    ⟨"full load scales sub-quadratically (small → medium)", do
      let ratio := (recordAt "medium").size.totalModules / (recordAt "small").size.totalModules
      -- 3× the linear bound; quadratic growth would be ~18× over it at this gap.
      let smallTotal := max 1 (phaseMs (recordAt "small").full "total")
      let mediumTotal := phaseMs (recordAt "medium").full "total"
      ensure (mediumTotal ≤ 3 * ratio * smallTotal)
        s!"full-load growth {smallTotal} → {mediumTotal} ms exceeds 3× the linear bound"⟩,
    ⟨"mathlib-scale graph load stays near one lake spawn", do
      let budget := 4 * max 1 run.spawnMs
      ensure (phaseMs (recordAt "mathlib").graph "total" ≤ budget)
        s!"graph total {(phaseMs (recordAt "mathlib").graph "total")} ms exceeds 4× one lake spawn \
           ({run.spawnMs} ms)"⟩,
    ⟨"mixed TOML members do not regress the full load (PLAN-02)", do
      let leanTotal := max 1 (phaseMs (recordAt "medium").full "total")
      let mixedTotal := phaseMs (recordAt "medium-mixed").full "total"
      -- PLAN-01's regression rule: a change must not cost ≥20% on the realistic fixture.
      ensure (mixedTotal ≤ leanTotal + leanTotal / 4)
        s!"mixed-TOML full load {mixedTotal} ms vs Lean-only {leanTotal} ms exceeds the +25% bound"⟩]
  cases

end Suites.Bench

public def main (args : List String) : IO UInt32 := do
  let root ← Lakew.Test.repoRoot
  let run ← Suites.Bench.collect root
  Lakew.Test.runCases "bench" (Suites.Bench.cases run) args
