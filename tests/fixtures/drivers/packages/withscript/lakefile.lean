import Lake
open Lake DSL

package «withscript» where
  testDriver := "check"
  testDriverArgs := #["--cfg"]
  lintDriver := "lintcheck"

script check (args) := do
  IO.println s!"script tests passed ({args})"
  return 0

script lintcheck (_args) := do
  IO.println "lint ok"
  return 0

lean_lib ScriptLib where
