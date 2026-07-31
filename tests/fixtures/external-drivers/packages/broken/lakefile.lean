import Lake
open Lake DSL

package «broken» where
  testDriver := "shared/nope"
  lintDriver := "ghost/tool"

lean_lib Broken where
