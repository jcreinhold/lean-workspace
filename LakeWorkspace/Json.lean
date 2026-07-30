/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/
module

/-!
A minimal JSON writer.

`lakew` only ever *writes* JSON (generated `.lake/package-overrides.json`,
`.lake/workspace/metadata.json`, `--json` command output). Keeping a tiny
internal writer avoids importing `Lean.Data.Json` (and transitively a large
part of the Lean compiler) into the executable.
-/
public section

namespace LakeWorkspace

inductive Json where
  | null
  | boolean (b : Bool)
  | num (n : Int)
  | str (s : String)
  | arr (xs : Array Json)
  | obj (fields : Array (String × Json))
  deriving Repr, Inhabited

namespace Json

/-- Left-pad `s` with `c` to width `n` (Lean has `List.leftpad` but no `String.leftpad`). -/
def padLeft (n : Nat) (c : Char) (s : String) : String :=
  String.ofList (List.replicate (n - s.length) c ++ s.toList)

/-- Escape a string per RFC 8259 §7. -/
def escape (s : String) : String := Id.run do
  let mut out := ""
  for c in s.toList do
    out := out ++ match c with
      | '"' => "\\\""
      | '\\' => "\\\\"
      | '\n' => "\\n"
      | '\r' => "\\r"
      | '\t' => "\\t"
      | c =>
        if c.toNat < 0x20 then
          "\\u" ++ padLeft 4 '0' (String.ofList (Nat.toDigits 16 c.toNat))
        else
          String.ofList [c]
  return out

partial def renderCompact : Json → String
  | .null => "null"
  | .boolean b => toString b
  | .num n => toString n
  | .str s => "\"" ++ escape s ++ "\""
  | .arr xs =>
    "[" ++ String.intercalate "," (xs.toList.map renderCompact) ++ "]"
  | .obj fs =>
    let field (p : String × Json) := "\"" ++ escape p.1 ++ "\":" ++ renderCompact p.2
    "{" ++ String.intercalate "," (fs.toList.map field) ++ "}"

partial def renderPretty (indent : Nat) : Json → String
  | .null => "null"
  | .boolean b => toString b
  | .num n => toString n
  | .str s => "\"" ++ escape s ++ "\""
  | .arr xs =>
    if xs.isEmpty then "[]"
    else
      let pad := padLeft (indent + 1) ' ' ""
      let close := padLeft indent ' ' ""
      let items := xs.toList.map fun x => pad ++ renderPretty (indent + 1) x
      "[\n" ++ String.intercalate ",\n" items ++ "\n" ++ close ++ "]"
  | .obj fs =>
    if fs.isEmpty then "{}"
    else
      let pad := padLeft (indent + 1) ' ' ""
      let close := padLeft indent ' ' ""
      let field (p : String × Json) :=
        pad ++ "\"" ++ escape p.1 ++ "\": " ++ renderPretty (indent + 1) p.2
      "{\n" ++ String.intercalate ",\n" (fs.toList.map field) ++ "\n" ++ close ++ "}"

def pretty (j : Json) : String := renderPretty 0 j

end Json

end LakeWorkspace

end -- public section
