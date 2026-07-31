import Lake
open Lake DSL

package «failing» where

@[test_driver]
lean_exe boom where
  root := `Boom
