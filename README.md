# LakeWorkspace / `lakew`

A workspace compiler and orchestrator over [Lake](https://lean-lang.org/doc/reference/latest/Build-Tools-and-Distribution/Lake/)
for Lean 4 monorepos — the Cargo-workspace experience, in Lean's idiom.

Lake remains the build engine: it loads packages, constructs the module/facet dependency graph,
schedules compilation, decides staleness, and manages artifact caches. `lakew` adds what Lake
deliberately does not: one membership model, one authoritative resolution, architectural
validation, package selection, affected analysis, test/lint aggregation, and cache policy.

`lakew` compiles a declarative `lean-workspace.toml` into an ordinary Lake **virtual root
package** (a generated `lakefile.lean` plus `.lake/package-overrides.json`), so the repository
stays fully usable with stock `lake` — no `lakew` installation required for contributors,
editors, or CI.

## The Cargo workspace mapping

Modeled on a mature Cargo workspace (e.g. [mdwright](https://github.com/jcreinhold/mdwright)):

| Cargo workspace | `lakew` | Notes |
| --- | --- | --- |
| `[workspace] members/exclude` | `[workspace] members/exclude` | globs supported (`packages/*`) |
| `resolver = "3"` (one resolution) | one `lake-manifest.json` + strict conflict errors | *stricter*: conflicting revisions are errors, never silently merged |
| `[workspace.dependencies]` | `[deps.<name>]` | central git/path+rev declarations; members must match exactly; `lakew sync --write-deps` aligns them |
| `[patch.crates-io]` | generated `.lake/package-overrides.json` | every workspace package name resolves locally, even transitively |
| `[workspace.lints]` | `[options]` | policy-validated shared Lean options (see caveats below) |
| `Cargo.lock` | `lake-manifest.json` | authoritative lockfile |
| `cargo build -p foo` | `lakew build -p foo` | also `--group`, `--all`, `@pkg/target` |
| `cargo test --workspace` | `lakew test` | aggregates per-member test drivers, one build graph, combined report |
| `cargo clippy --workspace` | `lakew lint` | aggregates per-member lint drivers |
| `cargo tree` | `lakew graph` | member dependency graph |
| `cargo metadata` | `lakew metadata --json` | canonical machine-readable model |
| `cargo clean -p foo` | `lakew clean -p foo` | |
| (nx/turborepo affected selection) | `lakew build/test --changed [--affected] <ref>` | not in Cargo itself; `--changed` is package-level, `--affected` uses the reverse module-import closure |
| `[workspace.package]` (shared version/license) | **N/A** | Lake packages carry no version metadata; toolchain+rev is the Lean versioning idiom |
| `[profile.*]` | **not yet** | Lake `buildType` is per-package and does not propagate; planned with the remote-cache milestone |

## Commands

```bash
lakew sync [--locked|--offline|--frozen] [--write-deps]
lakew check                      # CI gate: staleness + architecture + policy
lakew build [-p pkg] [--group g] [--all] [--changed [ref]] [--affected [ref]] [@pkg/target] [-- lake-args]
lakew test  [selection...] [-- driver-args] [--json]
lakew lint  [selection...]
lakew graph [--json]
lakew why <from> <to>            # explain a dependency path
lakew metadata --json
lakew clean -p pkg
```

Design rules that hold across all of them:

- **One Lake invocation per action.** `lakew build` issues a single `lake build @a @b …`;
  `lakew test` builds every exe/lib driver in one `lake build` before running any driver.
- **Selections explain themselves** (`tactics: module Tactic.Simp changed`).
- **Stock `lake` always works** on the generated root.
- **`lakew check` never writes**; it fails on stale generated files, dependency conflicts,
  undeclared cross-package imports, cycles, prod→test imports, duplicate module roots,
  `[deps]` mismatches, and `[options]` violations.

## `lean-workspace.toml`

```toml
[workspace]
members = ["packages/*", "tools/*"]
exclude = ["packages/experimental-*"]
default-members = ["core", "syntax", "tactics"]

[deps.batteries]                    # ≡ [workspace.dependencies]
git = "https://github.com/leanprover-community/batteries"
rev = "v4.33.0-rc1"

[policy]
unique-module-roots = true
require-direct-import-edges = true
member-toolchains = "must-match-root"

[cache]
local = true
restore = "requested-only"          # requested-only | package | workspace

[options]                           # ≡ [workspace.lints] (policy-validated)
"linter.missingDocs" = true
"maxSynthPendingDepth" = 3

[groups.foundation]
members = ["core", "syntax"]
```

## Tests and lints (doc §7 semantics)

Member packages declare drivers exactly as Lake expects — `testDriver := "…"` /
`lintDriver := "…"` config, or `@[test_driver]` / `@[lint_driver]` tags on a script,
`lean_exe`, or `lean_lib`. `lakew test` then:

1. discovers each selected member's driver,
2. builds **all** exe/lib driver targets in one `lake build` (one graph, against the one lockfile),
3. runs exe drivers (`<member>/.lake/build/bin/…`) and script drivers
   (`lake script run pkg/name`, with the member's `testDriverArgs` prepended) with bounded
   parallelism,
4. emits a package-qualified report (`--json` for a clean machine-readable form; all build
   output then goes to stderr), and exits nonzero if any driver failed.

Known limitation: drivers qualified to *non-member* packages (e.g. mathlib's
`batteries/runLinter` lint driver) are skipped with a warning, since driver-kind detection
scans member lakefiles only.

## `[options]` caveats (Lean ≠ Cargo here)

Cargo propagates `[workspace.lints]` to every crate; Lake `leanOptions` do **not** propagate
from a root package to dependencies. So `[options]` is *policy*, enforced by `lakew check`:

- members must set each required option in a canonical `⟨`name, value⟩` tuple;
- members with no options machinery at all fail the check;
- members that compose options programmatically (mathlib-style `abbrev`s, `weak ++` prefixes)
  get a "please verify manually" warning, not a silent pass.

For true single-source options, use the Lean-idiomatic escape hatch: a tiny in-repo support
package exporting `def workspaceLeanOptions : Array LeanOption` that members `require` and
splice into their own `leanOptions`.

## Development

```bash
lake build          # builds lakew itself (Lean module system, v4.33.0-rc1)
lake test           # the test suite: sync/goldens, diagnostics, deps, drivers, affected, options
```

Tests are native Lean suites in the `tests/` tree (lean-fmt style): a shared
`TestSupport` library (`tests/Test`: harness, process spawning, temp-dir
fixtures, golden files), one executable per concern (`tests/Suites`), and an
orchestrator (`tests/Test/Runner.lean`) as the package `testDriver`. Each
suite drives the real `lakew` binary against a copied fixture project in a
temp dir. Adding a suite is one `lean_exe «suite-<name>»` in the lakefile
plus one line in the runner's registry. Golden files regenerate with
`UPDATE_GOLDEN=1`.

```bash
lake test -- --list                    # suite registry
lake test -- --suites sync drivers     # a subset
lake test -- --all                     # include the slow benchmark suite
.lake/build/bin/suite-sync --filter golden   # one suite, filtered
```

The benchmark suite's measurements and optimization decisions live in
`tests/bench.md`.

Toolchain: `leanprover/lean4:v4.33.0-rc1`.

## Layout

```
LakeWorkspace.lean          # curated public surface: load / select / plan / execute / staleFiles
LakeWorkspace/
  Workspace.lean            # manifest schema, discovery, validation, resolution, policy
  Selection.lean            # selectors, changed/affected analysis, explanation traces
  Planner.lean              # pure action → plan (one build graph per action)
  Executor.lean             # single lake subprocess, transactional installs, driver runner
  Report.lean               # combined test/lint report model
  Backend/LakeCli.lean      # the only Lake-version-coupled module (generated-file formats)
  Backend/Git.lean          # changed-path gathering
Main.lean                   # the lakew CLI
tests/
  Test/                     # shared harness: assertions, processes, fixtures, goldens, runner
  Suites/                   # one executable suite per concern (+ the benchmark)
  fixtures/                 # committed fixture projects (copied to temp dirs by suites)
  golden/                   # committed expected outputs (UPDATE_GOLDEN=1 regenerates)
  bench.md                  # load-path benchmark decision log
```
