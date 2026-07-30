import Lake
open Lake DSL

package «withexe» where

@[test_driver]
lean_exe runtests where
  root := `Runtests
