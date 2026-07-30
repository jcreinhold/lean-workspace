/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

/-! Structured diagnostics shared by all `lakew` layers. -/
-- v4.33 removed the root `FilePath` alias; restore it for the whole package.
export System (FilePath)

public section

namespace LakeWorkspace

inductive Severity where
  | error | warning
  deriving Repr, BEq, Inhabited

structure Diagnostic where
  severity : Severity
  message : String
  /-- Additional indented context lines (e.g. the two sides of a conflict). -/
  context : Array String := #[]
  deriving Repr, Inhabited

abbrev Diagnostics := Array Diagnostic

namespace Diagnostics

def error (message : String) (context : Array String := #[]) : Diagnostics :=
  #[{ severity := .error, message, context }]

def warning (message : String) (context : Array String := #[]) : Diagnostics :=
  #[{ severity := .warning, message, context }]

def hasErrors (ds : Diagnostics) : Bool :=
  ds.any fun d => d.severity == .error

def render (ds : Diagnostics) : String := Id.run do
  let mut out : Array String := #[]
  for d in ds do
    let tag := match d.severity with | .error => "error" | .warning => "warning"
    out := out.push s!"{tag}: {d.message}"
    for c in d.context do
      out := out.push s!"  {c}"
  return "\n".intercalate out.toList

end Diagnostics

end LakeWorkspace

end -- public section
