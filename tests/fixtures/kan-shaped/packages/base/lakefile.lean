import Lake
open Lake DSL

/-- Composed options (abbrev + `weak` prefix map), as in real projects that
    share an option set across the lakefile. The scanner must tolerate the
    composition; `[options]` policy needs literal tuples, which appear in the
    lib clause below. -/
abbrev myLeanOptions : Array LeanOption :=
  #[⟨`autoImplicit, false⟩] ++
    #[⟨`linter.allScriptsDocumented, true⟩].map fun opt => { opt with name := `weak ++ opt.name }

/-- Helper spawned by script shims. -/
def runTool (cmd : String) (args : List String) : ScriptM UInt32 := do
  (← IO.Process.spawn { cmd, args := args.toArray }).wait

require mathlib from git "https://example.invalid/mathlib4" @ "master"
require checkdecls from git "https://example.invalid/checkdecls.git"
require «lean-fmt» from git "https://example.invalid/lean-fmt" @ "v0.1.9"

package KanProofs where
  version := v!"0.1.0"
  lintDriver := "runLinter"
  lintDriverArgs := #["KanProofs"]
  plugins := #[`@«lean-fmt»/LeanFmtCompilerPlugin:shared]
  fixedToolchain := true
  platformIndependent := true

@[default_target] lean_lib KanProofs where
  leanOptions := #[⟨`autoImplicit, false⟩, ⟨`weak.linter.allScriptsDocumented, true⟩]

lean_lib ShakeSafe where
  srcDir := "scripts/lean"

lean_exe «runLinter» where
  srcDir := "scripts/lean"
  root := `Tools.RunLinter

/-- `lake run perf-report` collects timing reports. -/
script «perf-report» (args) do
  runTool "echo" args
