/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The realistic-shaped suite

Pins the scanner against lakefiles shaped like large real projects
(proofs' in particular): `require «lean-fmt»`-style quoted names with
central `[deps]` alignment, `abbrev`-composed values the scanner must
tolerate, `plugins`/`version := v!"…"`/`fixedToolchain`/`platformIndependent`
assignments it must ignore, `@[default_target]`, driver config with args,
quoted script/exe names, and target-level `srcDir` overrides. Also pins the
two member-index behaviors the scanner owns: modules under a target `srcDir`
are indexed (unioned with the package default, not replacing it), and a
member with no default targets earns a plan note instead of a silent Lake
no-op.
-/

namespace Suites.RealisticShaped

open Lakew.Test

end Suites.RealisticShaped

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  let cases : Array Lakew.Test.Case := #[
    ⟨"sync: quoted requires align with central [deps], no scanner warnings", do
      Lakew.Test.withTempDir fun tmp => do
        let dir := tmp / "realistic-shaped"
        Lakew.Test.copyFixture "realistic-shaped" dir
        let result ← Lakew.Test.expectExit "sync --offline" 0 lakew.toString
          #["sync", "--offline"] dir
        let out := result.stdout ++ result.stderr
        Lakew.Test.ensureAbsent "no require parse failures" "could not parse" out
        Lakew.Test.ensureAbsent "no dep conflicts" "conflict" out
        Lakew.Test.ensureAbsent "base has modules" "no Lean modules" out⟩,
    ⟨"metadata: srcDir target modules indexed alongside package-default ones", do
      Lakew.Test.withTempDir fun tmp => do
        let dir := tmp / "realistic-shaped"
        Lakew.Test.copyFixture "realistic-shaped" dir
        _ ← Lakew.Test.expectExit "sync --offline" 0 lakew.toString
          #["sync", "--offline"] dir
        let result ← Lakew.Test.expectExit "metadata" 0 lakew.toString
          #["metadata", "--json"] dir
        let out := result.stdout
        Lakew.Test.ensureContains "package-default modules" "Proofs.Core" out
        Lakew.Test.ensureContains "srcDir lib root" "ShakeSafe" out
        Lakew.Test.ensureContains "srcDir lib submodule" "ShakeSafe.Basic" out
        Lakew.Test.ensureContains "srcDir exe root" "Tools.RunLinter" out⟩,
    ⟨"build plan: @[default_target] member builds; note for member without", do
      Lakew.Test.withTempDir fun tmp => do
        let dir := tmp / "realistic-shaped"
        Lakew.Test.copyFixture "realistic-shaped" dir
        _ ← Lakew.Test.expectExit "sync --offline" 0 lakew.toString
          #["sync", "--offline"] dir
        let result ← Lakew.Test.expectExit "build --all" 0 lakew.toString
          #["build", "--all", "--dry-run", "--json"] dir
        let out := result.stdout
        Lakew.Test.ensureContains "base in build step" "@Proofs" out
        Lakew.Test.ensureContains "aux in build step" "@aux" out
        Lakew.Test.ensureContains "no-default note"
          "aux: no default targets configured; `@aux` builds nothing" out
        Lakew.Test.ensureAbsent "no note for base"
          "Proofs: no default targets configured" out⟩,
    ⟨"lint plan: same-package exe driver with args, quoted script captured", do
      Lakew.Test.withTempDir fun tmp => do
        let dir := tmp / "realistic-shaped"
        Lakew.Test.copyFixture "realistic-shaped" dir
        _ ← Lakew.Test.expectExit "sync --offline" 0 lakew.toString
          #["sync", "--offline"] dir
        let result ← Lakew.Test.expectExit "lint" 0 lakew.toString
          #["lint", "--dry-run", "--json"] dir
        let out := result.stdout
        Lakew.Test.ensureContains "exe driver build target" "@Proofs/runLinter" out
        Lakew.Test.ensureContains "driver args" "Proofs" out
        Lakew.Test.ensureAbsent "no driver warnings" "not found" out⟩]
  Lakew.Test.runCases "realistic-shaped" cases args
