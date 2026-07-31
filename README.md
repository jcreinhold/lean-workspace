# LakeWorkspace / `lakew`

`lakew` adds a workspace layer over [Lake](https://lean-lang.org/doc/reference/latest/Build-Tools-and-Distribution/Lake/),
the Lean 4 build tool, for repositories that hold many Lean packages. Lake stays the build
engine; `lakew` adds what Lake does not: one lockfile and one dependency resolution for the
whole repository, checks on cross-package imports, package and target selection, affected
analysis, and combined test and lint reports.

`lakew` compiles a declarative `lean-workspace.toml` into a generated Lake root package (a
`lakefile.lean` plus `.lake/package-overrides.json`). Plain `lake` keeps working on the
result, so editors, contributors, and CI need no `lakew` install.

## Install

Download a prebuilt binary from the [releases
page](https://github.com/jcreinhold/lean-workspace/releases) (Linux x86_64 and aarch64,
macOS Intel and Apple silicon), unpack it, and put `lakew` on your `PATH`.

Or build from source. You need [elan](https://github.com/leanprover/elan); it installs the
pinned toolchain (`lean-toolchain`, currently `leanprover/lean4:v4.33.0-rc1`) on first build.

```bash
git clone https://github.com/jcreinhold/lean-workspace.git
cd lean-workspace
lake build
```

The binary lands at `.lake/build/bin/lakew`. Put it on your `PATH`, then run `lakew --help`.

Either way, `lakew` needs a Lean toolchain at run time — it drives `lake` and `git` as
subprocesses — so keep elan installed on every machine that runs it.

## Quick start

A workspace is a directory with a `lean-workspace.toml`, a `lean-toolchain`, and one package
per member:

```
my-repo/
  lean-toolchain
  lean-workspace.toml
  packages/
    core/
      lakefile.lean
      Core.lean
      Core/Basic.lean
    syntax/
      lakefile.lean
      Syntax.lean
```

```toml
# lean-workspace.toml
[workspace]
members = ["packages/*"]
default-members = ["core", "syntax"]
```

```lean
-- packages/core/lakefile.lean
import Lake
open Lake DSL

package «core» where

@[default_target]
lean_lib Core where
```

Then:

```bash
lakew sync     # validate, write the generated root files, resolve dependencies
lakew build    # build the default members in one `lake build`
lakew test     # build and run every member's test driver, one combined report
```

`lakew sync` writes three files at the root: `lakefile.lean`,
`.lake/package-overrides.json`, and `.lake/workspace/metadata.json`. Commit them:
that is what keeps plain `lake` working for editors, contributors, and CI without
`lakew`. `lakew sync` regenerates them and `lakew check` fails when they are stale.

## Commands

```bash
lakew sync [--locked|--offline|--frozen] [--write-deps]
lakew check
lakew build   [selection...] [-- lake-args]
lakew test    [selection...] [-- driver-args] [--json]
lakew lint    [selection...] [-- driver-args] [--json]
lakew clean   [selection...]
lakew graph [--json]
lakew why <from> <to>
lakew metadata [--json]
lakew cache <get|put|services|…> [args…]
lakew cache status
```

- `sync` validates the workspace, installs the generated files atomically, and runs one
  `lake update`. `--locked` fails instead of changing generated files; `--offline` installs
  but skips the resolve; `--frozen` is both. `--write-deps` first rewrites member Lean
  lakefiles so their `require`s match `[deps]` (TOML lakefiles are not rewritten; see
  below).
- `check` is the CI gate. It never writes. It fails on stale generated files, dependency
  conflicts, undeclared cross-package imports, dependency cycles, production code importing
  test code, duplicate module roots, `[deps]` mismatches, `[options]` violations, and a
  `cache.remote` service missing from `lake cache services`.
- `build` runs one `lake build` for the selection. Anything after `--` goes to `lake`
  unchanged.
- `test` finds each selected member's test driver, builds every driver in one `lake build`,
  runs them with bounded parallelism, and prints one package-qualified report. It exits
  nonzero if any driver failed. `--json` prints the report as JSON and sends build output
  to stderr. Arguments after `--` go to each driver.
- `lint` is `test` for lint drivers.
- `clean` runs `lake clean` for the selection.
- `graph` prints the member dependency graph.
- `why <from> <to>` shows the dependency path between two members.
- `metadata` prints the canonical workspace model.
- `cache` forwards to `lake cache` from the workspace root. `lakew cache status` prints the
  effective `[cache]` policy and the configured remote services.

Options shared by every command:

- `--root <dir>` — workspace root (default: nearest `lean-workspace.toml` at or above the
  current directory).
- `--dry-run` — print the plan instead of running it. With `--json`, print it as JSON.

## Selecting what to build

`build`, `test`, `lint`, and `clean` take the same selection flags:

- `-p <name>` / `--package <name>` — a member, repeatable.
- `--group <name>` — a named group from `lean-workspace.toml`.
- `--all` — every member.
- `@pkg/target` — a package-qualified Lake target, passed through unchanged.
- `--changed [<ref>]` — members that own files changed since `<ref>` (default: the working
  tree), plus every member that depends on them. Changes to the toolchain file, the
  workspace config, or the root `lakefile.lean` select everything.
- `--affected [<ref>]` — the module-level version: members whose modules changed or import
  a changed module. A changed non-module file selects its whole package.

With no selection, you get `default-members` (or all members, if none are configured).

Every plan prints why each package was selected, for example
`tactics: module Tactic.Simp changed`. Use `--dry-run` to see the selection without
building.

## `lean-workspace.toml`

```toml
[workspace]
members = ["packages/*", "tools/*"]     # globs allowed
exclude = ["packages/experimental-*"]
default-members = ["core", "syntax", "tactics"]

[deps.batteries]                        # shared dependency declarations;
git = "https://github.com/leanprover-community/batteries"   # members must match
rev = "v4.33.0-rc1"                     # exactly (`sync --write-deps` aligns them)

[policy]
unique-module-roots = true
require-direct-import-edges = true
member-toolchains = "must-match-root"

[cache]
local = true                      # enableArtifactCache in the generated root
restore = "requested-only"        # requested-only | package | workspace
try-cache = true                  # sync's `lake update` gets --try-cache
remote = "my-s3"                  # must exist in `lake cache services`
                                  # (checked only; services live in ~/.lake/config.toml)

[options]                         # shared Lean options, enforced by `lakew check`
"linter.missingDocs" = true
"maxSynthPendingDepth" = 3

[groups.foundation]
members = ["core", "syntax"]
```

One resolution, strictly: all members share one `lake-manifest.json`, and conflicting
revisions of a dependency are errors, never silently merged. Every workspace package name
resolves locally through the generated package overrides, even when a dependency asks for
it transitively.

## Member lakefiles

A member may carry `lakefile.lean` or `lakefile.toml` — batteries, Cli, and Qq ship TOML
only. A member with both is a config error, as it is in Lake itself. TOML lakefiles are
read with Lake's own parser (`Lake.Toml.loadToml`), so `lakew` accepts exactly what Lake
accepts. Validation, planning, drivers, `[options]`, and `[deps]` work the same for both
formats.

TOML-specific notes:

- **No script drivers.** Lake cannot declare scripts in TOML lakefiles, so a TOML member's
  test and lint drivers are always `lean_exe` or `lean_lib` targets.
- **`[options]` is checked exactly.** TOML option values are always literals, so the
  "options built in code, please verify by hand" warning never fires for TOML members.
- **`sync --write-deps` does not rewrite TOML.** A TOML member whose `[[require]]`
  disagrees with `[deps]` fails with an error that names the edit to make by hand.
- **Module discovery walks the source tree.** TOML `globs` restrict what Lake builds, not
  what is on disk; `lakew` indexes every module file it finds, for both formats. The walk
  honors `srcDir`: the package-level setting (or the member directory when unset) plus any
  per-target overrides, unioned.

## Cache policy

Lake's artifact-cache settings propagate from the workspace root to every member and
dependency that does not set its own value, so `[cache]` is real configuration, not just a
check. `local` and `restore` become `enableArtifactCache` and `restoreAllArtifacts` in the
generated root; `restore = "workspace"` restores the classic build-directory layout for
tools that hard-code paths. The environment variables `LAKE_ARTIFACT_CACHE` and
`LAKE_RESTORE_ARTIFACTS` override the root config, matching Lake's own precedence.
`try-cache` adds `--try-cache` to sync's one `lake update`.

Remote services (Reservoir, S3, …) live in the system config `~/.lake/config.toml`, never
in the repo; `lakew` neither writes nor validates credentials. `cache.remote` is checked
only: `lakew check` and `lakew cache status` fail when the named service is absent from
`lake cache services`, naming the service and the fix.

In CI, fetch the cache before building:

```bash
lakew cache get
lakew build --all
```

## Tests and lints

Members declare drivers exactly as Lake expects: `testDriver := "…"` and
`lintDriver := "…"` in the package config, or `@[test_driver]` / `@[lint_driver]` tags on a
script, `lean_exe`, or `lean_lib`. `lakew test` then:

1. finds each selected member's driver,
2. builds all `lean_exe`/`lean_lib` drivers in one `lake build`,
3. runs exe drivers (`<member>/.lake/build/bin/…`) and script drivers (`lake script run`,
   with the member's `testDriverArgs` first) with bounded parallelism,
4. prints one package-qualified report and exits nonzero if any driver failed.

A driver may also belong to a package outside the workspace — mathlib's
`lintDriver := "batteries/runLinter"` is the standard example. `lakew` resolves such a
driver in order:

1. the external package's own lakefile, scanned as a member's would be (path dependencies
   in place, git dependencies from their `.lake/packages/<pkg>` checkout),
2. one `lake scripts` probe, in case the driver is a script,
3. otherwise a note (`driver … not found in external package … (skipped)`) and the run
   continues. This is normal for an external package not yet fetched; run `lakew sync`
   first.

External exe drivers join the single build step and run from the external package's own
`.lake/build/bin`, with the member's `testDriverArgs`/`lintDriverArgs` applied the same
way.

## Options policy
Lake does not propagate a root package's `leanOptions` to other packages, so `[options]`
cannot be configuration Lake applies for you. It is a policy that `lakew check` enforces:

- each member must set every required option to the required value;
- a member that sets no options at all fails the check;
- a member that builds its options in code (shared `abbrev`s, `weak ++` prefixes) gets a
  "please verify by hand" warning, not a silent pass.

For one true source of shared options, make a small support package in the repo that
exports `def workspaceLeanOptions : Array LeanOption`. Members `require` it and splice its
value into their own `leanOptions`.

## Lake behavior notes

Facts about Lake itself that shape what `lakew` emits, so nobody "simplifies" a plan into
one of these traps:

- **`lake build <lib>` on a dependency package can fail spuriously.** If a `lean_lib`'s
  root module has no source file (e.g. `lean_lib A` with `A/` but no `A.lean`), Lake
  fails the lib build with `<lib>: some modules have bad imports` and hides the real
  error (a missing file) — even though module targets build fine
  ([leanprover/lean4#14619](https://github.com/leanprover/lean4/issues/14619)). `lakew`
  avoids this path: plans name `@<member>` package specs, `@<pkg>/<target>` driver
  specs, and module names, never bare lib names. Keep it that way. Give every lib a root
  file.
- **`@<member>` on a member with no default targets builds nothing.** Lake prints a
  "Nothing to build" note and exits successfully. `lakew` surfaces this as a plan note
  (`<member>: no default targets configured; `@<member>` builds nothing`) instead of
  letting it pass silently.
- **Bare `lake build` at the generated root builds nothing.** Default targets belong to
  packages, and the generated root declares none; use `lakew build` (or `make` verbs that
  call it) rather than bare `lake build`.
- **Member scripts are qualified.** A script declared in member `tools` runs as
  `lake run tools/<name>`, and script bodies inherit the caller's working directory
  (Lake does not `chdir`).
