/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/-!
A minimal TOML reader, scoped to the `lean-workspace.toml` manifest schema.

Supported: `[section]` and dotted `[a.b.c]` headers, `key = value` pairs with
string, boolean, integer and (possibly multi-line) array values, and `#`
comments. This is deliberately *not* a general TOML implementation — the
workspace manifest schema is the only caller, and the parser is private to
the workspace layer. If the schema ever outgrows it, swap the internals; the
`Table` query interface is the stable surface.
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

end Table

/-! ## Parser -/

private structure PState where
  cs : Array Char
  pos : Nat := 0

private def PState.eof (s : PState) : Bool := s.pos ≥ s.cs.size
private def PState.peek? (s : PState) : Option Char := s.cs[s.pos]?
private def PState.next (s : PState) : PState := { s with pos := s.pos + 1 }

private def isKeyChar (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '-'

/-- Skip spaces/tabs and (if `newlines`) newlines and `#` comments. -/
private partial def skipTrivia (s : PState) (newlines : Bool) : PState := Id.run do
  let mut s := s
  repeat
    match s.peek? with
    | some ' ' | some '\t' | some '\r' => s := s.next
    | some '\n' => if newlines then s := s.next else return s
    | some '#' =>
      repeat
        match s.peek? with
        | some '\n' | none => break
        | some _ => s := s.next
    | _ => return s
  return s

private partial def parseString (s : PState) : Except String (String × PState) := do
  -- assumes opening quote consumed
  let mut out := ""
  let mut s := s
  while true do
    match s.peek? with
    | none => throw "unterminated string literal"
    | some '"' => return (out, s.next)
    | some '\\' =>
      let s1 := s.next
      match s1.peek? with
      | some 'n' => out := out ++ "\n"; s := s1.next
      | some 't' => out := out ++ "\t"; s := s1.next
      | some 'r' => out := out ++ "\r"; s := s1.next
      | some '"' => out := out ++ "\""; s := s1.next
      | some '\\' => out := out ++ "\\"; s := s1.next
      | _ => throw "unsupported escape sequence"
    | some c => out := out ++ String.ofList [c]; s := s.next
  throw "unreachable"

private partial def parseValue (s : PState) : Except String (Value × PState) := do
  let s := skipTrivia s false
  match s.peek? with
  | none => throw "expected value"
  | some '"' => parseString (s.next) |>.map fun (v, s') => (.str v, s')
  | some '[' =>
    -- array; newlines and comments allowed inside
    let mut s := s.next
    let mut xs : Array Value := #[]
    while true do
      s := skipTrivia s true
      match s.peek? with
      | none => throw "unterminated array"
      | some ']' => return (.arr xs, s.next)
      | _ =>
        let (v, s') ← parseValue s
        xs := xs.push v
        s := skipTrivia s' true
        match s.peek? with
        | some ',' => s := s.next
        | some ']' => return (.arr xs, s.next)
        | _ => throw "expected ',' or ']' in array"
    throw "unreachable"
  | some c =>
    if c == 't' || c == 'f' then
      let word := String.ofList (s.cs.extract s.pos (s.pos + 5)).toList
      if word.startsWith "true" then return (.boolean true, { s with pos := s.pos + 4 })
      if word.startsWith "false" then return (.boolean false, { s with pos := s.pos + 5 })
      throw s!"unexpected value starting with '{c}'"
    else if c.isDigit || c == '-' then
      let start := s.pos
      let mut s := s
      repeat
        match s.peek? with
        | some c => if c.isDigit || c == '-' || c == '_' then s := s.next else break
        | none => break
      let raw := String.ofList (s.cs.extract start s.pos).toList
      let clean := String.ofList (raw.toList.filter (· != '_'))
      match clean.toInt? with
      | some n => return (.int n, s)
      | none => throw s!"invalid integer literal '{raw}'"
    else
      throw s!"unexpected value starting with '{c}'"

/-- Parse a dotted key (`a.b.c`), returning its components. -/
private partial def parseKey (s : PState) : Except String (Array String × PState) := do
  let mut comps : Array String := #[]
  let mut s := s
  while true do
    s := skipTrivia s false
    let start := s.pos
    repeat
      match s.peek? with
      | some c => if isKeyChar c then s := s.next else break
      | none => break
    if s.pos == start then throw "expected key"
    comps := comps.push (String.ofList (s.cs.extract start s.pos).toList)
    s := skipTrivia s false
    match s.peek? with
    | some '.' => s := s.next
    | _ => return (comps, s)
  throw "unreachable"

partial def parse (content : String) : Except String Table := do
  let mut t : Table := {}
  let mut curSection : Array String := #[]
  let mut s : PState := { cs := content.toList.toArray }
  while true do
    s := skipTrivia s true
    if s.eof then break
    match s.peek? with
    | some '[' =>
      s := s.next
      let (comps, s') ← parseKey s
      s := skipTrivia s' false
      match s.peek? with
      | some ']' =>
        s := s.next
        curSection := comps
      | _ => throw "expected ']' after section header"
    | some _ =>
      let (comps, s') ← parseKey s
      s := skipTrivia s' false
      match s.peek? with
      | some '=' => s := s.next
      | _ => throw s!"expected '=' after key '{".".intercalate comps.toList}'"
      let (v, s'') ← parseValue s
      s := s''
      let key := ".".intercalate (curSection ++ comps).toList
      if (t.entries.any fun (k, _) => k == key) then
        throw s!"duplicate key '{key}'"
      t := { t with entries := t.entries.push (key, v) }
    | none => break
  return t

end LakeWorkspace.Toml

end -- public section
