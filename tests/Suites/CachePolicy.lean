/-
Copyright (c) 2026 Jacob Reinhold. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Jacob Reinhold
-/

module

public import Test

/-!
# The cache-policy suite

PLAN-04: `[cache]` maps Cargo's `[profile.*]` row onto Lake's artifact
cache. `cache.local`/`cache.restore` are real *configuration* — the
generated root lakefile's `enableArtifactCache`/`restoreAllArtifacts`
propagate from the workspace root to every member and dependency (spiked:
a dependency's oleans land in the toolchain cache, and
`restoreAllArtifacts := true` restores the classic build-dir layout);
`cache.try-cache` appends `--try-cache` to sync's one `lake update`;
`cache.remote` is validation-only, checked against `lake cache services`
(lakew never writes `~/.lake/config.toml`). `lakew cache` is a thin
pass-through with a `status` addition.

The fixture carries `try-cache = true` and `remote = "reservoir"` (a
service every Lake installation has); the unknown-service error is
exercised by rewriting the config inside the world, last. Cases share one
synced temp world in declaration order.
-/

namespace Suites.CachePolicy

open Lakew.Test

def cases (lakew dir golden : System.FilePath) : Array Case := #[
  ⟨"sync the fixture; the generated lakefile matches the golden", do
    let _ ← expectExit "sync" 0 lakew.toString #["sync"] dir
    ensureGolden "lakefile.lean" (golden / "lakefile.lean") (dir / "lakefile.lean")⟩,
  ⟨"sync's update gets --try-cache exactly when configured", do
    let plan ← expectExit "sync --dry-run" 0 lakew.toString
      #["sync", "--dry-run", "--json"] dir
    ensureCount "update steps" "\"kind\": \"runLake\"" 1 plan.stdout
    ensureContains "try-cache in update argv" "\"--try-cache\"" plan.stdout⟩,
  ⟨"check passes with the configured service present", do
    let result ← expectExit "check" 0 lakew.toString #["check"] dir
    ensureContains "up to date" "up to date" (result.stdout ++ result.stderr)⟩,
  ⟨"cache status reports the effective policy and services", do
    let result ← expectExit "cache status" 0 lakew.toString #["cache", "status"] dir
    let out := result.stdout ++ result.stderr
    ensureContains "local policy" "cache.local     = true" out
    ensureContains "try-cache policy" "cache.try-cache = true" out
    ensureContains "remote policy" "cache.remote    = reservoir" out
    ensureContains "service present" "cache.remote service `reservoir` is configured" out⟩,
  ⟨"cache forwards unknown subcommands to lake verbatim", do
    let result ← expectExit "cache services" 0 lakew.toString #["cache", "services"] dir
    ensureContains "reservoir listed" "reservoir" result.stdout⟩,
  ⟨"check fails on an unknown remote service, naming it and the fix", do
    let cfg := dir / "lean-workspace.toml"
    let orig ← IO.FS.readFile cfg
    IO.FS.writeFile cfg (orig.replace "reservoir" "no-such-lakew-service")
    let result ← expectExit "check" 1 lakew.toString #["check"] dir
    let out := result.stdout ++ result.stderr
    ensureContains "service named"
      "cache.remote expects service `no-such-lakew-service`, but it is not configured" out
    ensureContains "fix named" "~/.lake/config.toml" out
    let status ← expectExit "cache status" 1 lakew.toString #["cache", "status"] dir
    ensureContains "status also fails" "is not configured"
      (status.stdout ++ status.stderr)
    IO.FS.writeFile cfg orig⟩]

end Suites.CachePolicy

public def main (args : List String) : IO UInt32 := do
  let lakew ← Lakew.Test.lakewBinary
  let golden ← Lakew.Test.goldenDir
  Lakew.Test.withTempDir fun tmp => do
    let dir := tmp / "cache-policy"
    Lakew.Test.copyFixture "cache-policy" dir
    Lakew.Test.runCases "cache-policy"
      (Suites.CachePolicy.cases lakew dir (golden / "cache-policy")) args
