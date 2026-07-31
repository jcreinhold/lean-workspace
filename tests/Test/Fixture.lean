/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test.Proc

/-!
# Filesystem fixtures

Scratch space discipline for suites (modeled on `lean-fmt/tests/Test/Fixture.lean`):
a suite's world — a copied fixture project, a synthetic workspace — lives in
an OS temp dir and is removed by `finally`, including on failure. Nothing a
suite does can dirty the working tree, which is what lets suites overlap.

The git helpers exist because `sync --locked` and the `--changed` and
`--affected` flags are git-diff features: their fixtures must be real
repositories.
-/

namespace Lakew.Test

/-- Create a temp directory, run `f` in it, remove it afterwards — including
on failure. -/
public def withTempDir (f : System.FilePath → IO α) : IO α := do
  let directory ← IO.FS.createTempDir
  try
    f directory
  finally
    IO.FS.removeDirAll directory

/-- The repository root, resolved through git so suites work from any working
directory the runner invokes them in. -/
public def repoRoot : IO System.FilePath := do
  let result ← runProc "git" #["rev-parse", "--show-toplevel"]
  ensure (result.exitCode == 0) s!"git rev-parse failed:\n{result.stderr}"
  return ⟨result.stdout.trimAscii.toString⟩

/-- The committed fixture projects, one directory per name. -/
public def fixturesDir : IO System.FilePath := do
  return (← repoRoot) / "tests" / "fixtures"

/-- The committed golden outputs. -/
public def goldenDir : IO System.FilePath := do
  return (← repoRoot) / "tests" / "golden"

/-- Recursively copy the tree at `src` to `dst`. -/
public partial def copyTree (src dst : System.FilePath) : IO Unit := do
  IO.FS.createDirAll dst
  for entry in (← src.readDir) do
    if (← entry.path.isDir) then
      copyTree entry.path (dst / entry.fileName)
    else
      IO.FS.writeBinFile (dst / entry.fileName) (← IO.FS.readBinFile entry.path)

/-- Copy the committed fixture `name` into `dst`. -/
public def copyFixture (name : String) (dst : System.FilePath) : IO Unit := do
  copyTree ((← fixturesDir) / name) dst

/-- Append `text` to the file at `path`. -/
public def appendFile (path : System.FilePath) (text : String) : IO Unit := do
  IO.FS.writeFile path ((← IO.FS.readFile path) ++ text)

/-- Make `dir` a git repository with one commit of everything in it. -/
public def initGitRepo (dir : System.FilePath) : IO Unit := do
  let _ ← expectExit "git init" 0 "git" #["init", "-q"] dir
  let _ ← expectExit "git add" 0 "git" #["add", "-A"] dir
  let _ ← expectExit "git commit" 0 "git"
    #["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"] dir

/-- Discard local changes to `paths` in the repository at `dir`
(`git checkout --`). -/
public def gitCheckout (dir : System.FilePath) (paths : Array String) : IO Unit := do
  let _ ← expectExit "git checkout" 0 "git" (#["checkout", "-q", "--"] ++ paths) dir

/-- The product binary every suite drives, building it first if missing. -/
public def lakewBinary : IO System.FilePath := do
  let root ← repoRoot
  let lakew := root / ".lake" / "build" / "bin" / "lakew"
  unless ← lakew.pathExists do
    let build ← runProc "lake" #["build", "lakew"] root
    ensure (build.exitCode == 0) s!"lake build lakew failed:\n{build.stderr}"
  return lakew

end Lakew.Test
