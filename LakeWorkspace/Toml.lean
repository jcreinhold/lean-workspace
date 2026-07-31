/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Lake.Toml

/-!
A TOML query layer over **Lake's own TOML reader** (`Lake.Toml.loadToml`,
the same parser that reads real `lakefile.toml` files — lakew drives `lake`
and pins the toolchain, so Lake is already an implicit dependency; delegating
guarantees we accept exactly what Lake accepts).

Consumers see a deliberately small *flat* model: dot-joined keys, the four
value kinds our schemas use, and by-name queries. The volatile decisions —
TOML syntax, `[[array-of-tables]]`, inline tables, Lake's tree-of-`Name`
representation — are hidden behind this module and this module only.

Two representation notes:

- Lake's `RBDict` iterates in insertion (= source) order on the pinned
  toolchain, so the flattened entries preserve source order; the golden
  suite pins that behavior.
- Values of kinds no consumer schema uses (floats, datetimes) parse fine but
  are invisible to queries. Arrays whose elements are all tables flatten to
  index-addressed entries (`require.0.name`, …) and are read back with
  `Table.tables`; any other array stays a scalar `.arr`.
-/
public section

namespace LakeWorkspace.Toml

inductive Value where
  | str (s : String)
  | boolean (b : Bool)
  | int (n : Int)
  | arr (xs : Array Value)
  deriving Repr, BEq, Inhabited

/-- A flat table: keys are dot-joined section paths, e.g. `workspace.members`. -/
structure Table where
  entries : Array (String × Value) := #[]
  deriving Repr, Inhabited

namespace Table

def get? (t : Table) (key : String) : Option Value :=
  t.entries.findSome? fun (k, v) => if k == key then some v else none

def getStr (t : Table) (key : String) : Option String :=
  match t.get? key with
  | some (.str s) => some s
  | _ => none

def getBool (t : Table) (key : String) : Option Bool :=
  match t.get? key with
  | some (.boolean b) => some b
  | _ => none

def getStrArray (t : Table) (key : String) : Option (Array String) :=
  match t.get? key with
  | some (.arr xs) => some <| xs.filterMap fun | .str s => some s | _ => none
  | _ => none

/-- Keys present under an immediate sub-table, e.g. `subsections "groups"` →
    the names `x` for which keys `groups.x.…` exist. -/
def subsections (t : Table) (pre : String) : Array String := Id.run do
  let mut out : Array String := #[]
  for (k, _) in t.entries do
    if k.startsWith (pre ++ ".") then
      let rest := k.drop (pre.length + 1)
      let head := (rest.takeWhile (· != '.')).toString
      if !head.isEmpty && !out.contains head then
        out := out.push head
  return out

def keys (t : Table) : Array String := t.entries.map Prod.fst

/-- The elements of an array-of-tables, in source order: `tables "require"`
    on `[[require]] name = "a" … [[require]] name = "b" …` gives two tables
    whose keys are `name`, … . -/
def tables (t : Table) (pre : String) : Array Table := Id.run do
  let mut indices : Array String := #[]
  for (k, _) in t.entries do
    if k.startsWith (pre ++ ".") then
      let idx := ((k.drop (pre.length + 1)).takeWhile (· != '.')).toString
      if !indices.contains idx then
        indices := indices.push idx
  indices.map fun idx =>
    let pfx := s!"{pre}.{idx}."
    { entries := t.entries.filterMap fun (k, v) =>
        if k.startsWith pfx then some ((k.drop pfx.length).toString, v) else none }

end Table

/-! ## Parsing (delegated to Lake) -/

/-- The string components of a TOML key `Name` (`a.b.c` → `#[a, b, c]`; a
    quoted segment with a dot inside stays one component). -/
private def nameComps : Lean.Name → Array String
  | .str pre s => (nameComps pre).push s
  | _ => #[]

/-- Flatten one Lake TOML value into dot-joined entries under `comps`. -/
private partial def flattenVal (comps : Array String) (v : Lake.Toml.Value) :
    Array (String × Value) :=
  let key := ".".intercalate comps.toList
  match v with
  | .string _ s => #[(key, .str s)]
  | .boolean _ b => #[(key, .boolean b)]
  | .integer _ n => #[(key, .int n)]
  | .array _ xs =>
    if !xs.isEmpty && xs.all (· matches .table ..) then
      -- array-of-tables: index-addressed entries, source order
      let indexed := xs.zipIdx
      indexed.flatMap fun (x, i) =>
        if let .table _ subt := x then
          subt.keys.flatMap fun k =>
            flattenVal (comps ++ #[toString i] ++ nameComps k) (subt.find? k).get!
        else #[]
    else
      let scalars := xs.filterMap fun
        | .string _ s => some (Value.str s)
        | .boolean _ b => some (Value.boolean b)
        | .integer _ n => some (Value.int n)
        | _ => none
      #[(key, .arr scalars)]
  | .table _ t =>
    t.keys.flatMap fun k => flattenVal (comps ++ nameComps k) (t.find? k).get!
  | .float _ _ | .dateTime _ _ => #[]

/-- Parse TOML text into the flat query model, using Lake's reader. -/
def parse (content : String) : IO (Except String Table) := do
  let ictx := Lean.Parser.mkInputContext content "<toml>"
  match (← (Lake.Toml.loadToml ictx).toBaseIO) with
  | .error log =>
    let mut msgs : Array String := #[]
    for msg in log.toList do
      msgs := msgs.push (← msg.data.format).pretty
    return .error ("\n".intercalate msgs.toList)
  | .ok t =>
    let entries := t.keys.flatMap fun k => flattenVal (nameComps k) (t.find? k).get!
    return .ok { entries }

end LakeWorkspace.Toml

end -- public section
