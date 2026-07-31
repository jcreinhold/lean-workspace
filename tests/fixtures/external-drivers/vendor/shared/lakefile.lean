import Lake
open Lake DSL

package «shared» where

lean_exe runner where

script verify (args) := do
  IO.println s!"verify script ran with {args}"
  return 0
