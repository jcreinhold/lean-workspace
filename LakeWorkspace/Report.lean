/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/
module

public import LakeWorkspace.Planner

/-!
The combined test/lint report model.

One deep module owning report structure, text rendering, and JSON rendering,
so the executor only produces data and the CLI only prints it (doc §7.5:
"a combined machine-readable report").
-/

public section

namespace LakeWorkspace

structure DriverResult where
  pkg : String
  /-- `test` or `lint`. -/
  kind : String
  target : String
  targetKind : TargetKind
  exitCode : UInt32
  durationMs : Nat
  /-- Combined stdout+stderr, captured to avoid interleaving. -/
  output : String
  deriving Repr, Inhabited

structure Report where
  /-- `test` or `lint`. -/
  kind : String
  results : Array DriverResult
  deriving Repr, Inhabited

namespace Report

def ok (r : Report) : Bool :=
  r.results.all (·.exitCode == 0)

def targetKindStr : TargetKind → String
  | .script => "script"
  | .exe => "exe"
  | .lib => "lib"

/-- Prefixed, package-qualified text rendering. -/
def renderText (r : Report) : String := Id.run do
  let mut out : Array String := #[]
  for res in r.results do
    if !res.output.isEmpty then
      for line in res.output.splitOn "\n" do
        if !line.isEmpty then
          out := out.push s!"[{res.pkg}] {line}"
    let status := if res.exitCode == 0 then "ok" else s!"FAILED ({res.exitCode})"
    out := out.push s!"[{res.pkg}] {res.kind} driver {res.target} \
      ({targetKindStr res.targetKind}): {status} in {res.durationMs}ms"
  let failed := r.results.filter (·.exitCode != 0)
  if failed.isEmpty then
    out := out.push s!"{r.kind}: all {r.results.size} driver(s) passed"
  else
    out := out.push s!"{r.kind}: {failed.size} of {r.results.size} driver(s) FAILED"
  return "\n".intercalate out.toList

def toJson (r : Report) : Json :=
  .obj #[
    ("kind", .str r.kind),
    ("ok", .boolean (ok r)),
    ("results", .arr (r.results.map fun res => .obj #[
      ("package", .str res.pkg),
      ("target", .str res.target),
      ("driverKind", .str (targetKindStr res.targetKind)),
      ("exitCode", .num res.exitCode.toNat),
      ("durationMs", .num res.durationMs),
      ("output", .str res.output) ])) ]

end Report

end LakeWorkspace

end -- public section
