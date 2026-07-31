import Lake
open Lake DSL

package «shared» where

lean_exe runner where
  root := `Runner

script verify (args) := do
  IO.println s!"verify script ran with {args}"
  return 0
