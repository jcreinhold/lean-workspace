import Lake
open Lake DSL

package «lakew» where

@[default_target]
lean_lib LakeWorkspace where

lean_exe lakew where
  root := `Main
