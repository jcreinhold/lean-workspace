# LakeWorkspace / `lakew`

A workspace compiler and orchestrator over [Lake](https://lean-lang.org/doc/reference/latest/Build-Tools-and-Distribution/Lake/)
for Lean 4 monorepos.

Lake remains the build engine: it loads packages, constructs the module/facet dependency graph,
schedules compilation, decides staleness, and manages artifact caches. `lakew` adds what Lake
deliberately does not:

- **One membership model** — a declarative `lean-workspace.toml` at the repo root.
- **One authoritative resolution** — conflicting sources/revisions for the same package name are
  errors, never silent picks.
- **Architectural validation** — a module-owner index enforcing that cross-package imports are
  declared direct dependencies.
- **Package selection** — `-p`, `--group`, default members, and `--changed` git-based selection.
- **Cache policy** — generated into the virtual root; package-local build trees are preserved.

`lakew` compiles the manifest into an ordinary Lake **virtual root package** (a generated
`lakefile.lean` plus `.lake/package-overrides.json`), so the repository stays fully usable with
stock `lake` — no `lakew` installation required for contributors, editors, or CI.

## Commands

```bash
lakew sync        # validate → resolve → verify → atomically install generated files
lakew check       # fail on stale generated files or architectural violations (CI gate)
lakew build [-p tactics] [@tactics/Tactic.Elab] [--group foundation] [--changed origin/main]
lakew graph [--json]
lakew metadata --json
lakew clean -p tactics
```

`lakew build` issues exactly **one** underlying `lake build @…` invocation for all selected
targets; unrecognized flags pass through to Lake.

## Status

Milestone 1: `sync`, `check`, `build`, `graph`, `metadata`, `clean`, `--changed`.
See the design notes in `README` history for deferred work (test/lint aggregation, `--affected`
module closure, remote cache publication, `--frozen` materialization).

## Development

```bash
lake build          # builds lakew itself
```

Toolchain: `leanprover/lean4:v4.33.0-rc1`.
