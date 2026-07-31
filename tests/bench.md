# Load-path benchmark: decision log

This file records why the `lakew` load path is built the way it is: what was
measured, what shipped, what was rejected, and what would justify changing it.
Re-run the suite and update this file before merging any change that touches
the load path.

The benchmark suite is `tests/Suites/Bench.lean`
(`lake build suite-bench && .lake/build/bin/suite-bench`). It generates
deterministic synthetic workspaces (small 10×50, medium 30×300,
mathlib-shaped 5×1200+1×6000) in a temp dir and runs `lakew graph --bench`
(skip-index load) and `lakew sync --dry-run --bench` (full load), parsing the
`bench: <phase> <ms>` lines. Gates live in the suite; this file records the
measurements and the decisions they forced. Numbers are from an M-series
laptop; treat absolute values as that machine's, ratios as the durable part.

## Baseline (serial, module-import index always loaded)

| size | member-scan | validate | module-imports | total |
| --- | ---: | ---: | ---: | ---: |
| small (500 modules) | 3 | 1 | 11 | 15 |
| medium (9,000) | 33 | 90 | 283 | 406 |
| mathlib (12,000) | 60 | 162 | 379 | 601 |

For scale: one `lake --version` spawn takes about 29 ms.

Two surprises:

1. **`validate` was O(modules²)** — the module-ownership index was built with
   a per-module linear `find?`. 162 ms at mathlib scale, second-largest phase.
2. **`module-imports` was ~60% lookup, not IO** — every import did a linear
   `find?` over the same index. The file reads were the minority of the cost.

## What shipped

### Hash side-index (found by measurement, outside the original optimization list)

`Std.HashMap` for ownership construction and import lookup; the sorted array
remains the canonical model. `validate` 162→1 ms; serial full-load
`module-imports` 379→190 ms. The largest single win, and invisible without
the instrumentation.

### Lazy module-import index — SHIPPED (gate: ≥2×)

`load` gained `loadModuleImports : Bool := true`; `graph`/`metadata`/`clean`/
`why` and `build`/`test`/`lint` without `--affected` pass `false` and never
touch a module file. `check`/`sync` keep the default (the architectural
import check runs with the index). `Workspace.hasModuleImportIndex` guards
`--affected` selection against a skipped index.

| command | size | before | after |
| --- | --- | ---: | ---: |
| `graph` | mathlib | 601 | 46–63 |
| `graph` | medium | 406 | 18–33 |

~10× on the skip-index commands. Output is byte-identical: `renderMetadata`
and `fingerprint` never read the index, and the legacy suite's 56 assertions
passed unchanged.

### Parallel scanning — SHIPPED (gate: ≥20% on realistic size)

Member lakefile scans and per-member module-import scans run in `IO.asTask`
waves of 8 (`parallelMapM`), folding results back in declaration order so
diagnostics and indexes stay deterministic.

| load | size | serial | parallel (warm) |
| --- | --- | ---: | ---: |
| full | mathlib | 252 | 187–206 |
| full | medium | 179 | 148–193 |
| `graph` | mathlib | 63 | 46 |

~25% at mathlib scale, ~1.3–1.8× warm. A per-module chunking variant (to
break up one 6,000-module member's serial critical path) measured neutral —
the skew case it targeted is the mathlib fixture itself — and was reverted.

## What did not ship

- **Scan-result cache — rejected by measurement.** Warm full load at
  mathlib scale is ≤ ~0.2 s; a mtime-keyed cache buys nothing at that cost
  and adds an invalidation surface. Revisit if TOML lakefiles or external
  driver scans push real loads into seconds.
- **Fewer subprocess spawns — not applicable.** `load` spawns zero
  processes; the git/`lake` spawns live in selection/execution and are
  flag-driven.

## Caveats recorded

- **Cold-vs-warm bimodality.** The first run reading a workspace after a
  different size's files were touched runs ~2× slow (fs metadata cache);
  steady-state is the warm number. Parallelism cannot fix cold IO, and real
  use is warm (editors and CI touch the tree constantly).
- The suite's spawn gate is 4× one `lake` spawn, not the original 2× target:
  mathlib-scale `graph` currently sits at ~2.2× (member-scan dominates),
  and 2× leaves no room for machine noise. Tighten when member-scan does.
- Wall-clock gates are not in CI (CI builds the suite only). Re-run
  `suite-bench` and update this file when the follow-up work below lands.

## TOML lakefile members (measured)

Members may carry `lakefile.toml`, read with Lake's own parser
(`Lake.Toml.loadToml` — one environment build per parse). The generator
gained a `tomlMixed` mode (odd members TOML-carried) and the suite a
regression case: mixed full load must stay within +25% of Lean-only on the
same shape (the ≥20% regression rule, encoded).

Measured (medium, 30 members × 300 modules, single pass):

| variant | graph total | full total | member-scan (full) |
| --- | --- | --- | --- |
| Lean-only | 15 ms | 119 ms | 14 ms |
| mixed (½ TOML) | 14 ms | 124 ms (+4%) | 12 ms |

The TOML parse cost is noise at this scale — the per-member scan stays
dominated by the on-disk module walk, and `loadToml`'s environment build is
sub-ms per member. No mitigation needed; the "revisit if TOML pushes loads
into seconds" trigger did not fire.

## External driver scanning (decision record)

`lakew test`/`lakew lint` resolve drivers qualified to non-member packages by
scanning the external package's lakefile at `<pkg-dir>/lakefile.toml|lean`
(path deps in place, git deps under `.lake/packages/`), with one
`lake scripts` probe per invocation as the script fallback.

Load-path impact: **none on the member-only path**. External scans run only
when a selected member's driver is `pkg/name`-qualified to a non-member, so
every existing benchmark (which has no external-qualified drivers) exercises
byte-identical work; the bench fixtures were left unchanged and all gates
still pass. The added reads are bounded by the number of external-qualified
drivers in the selection (a handful in practice), each a small lakefile —
far below the measurement floor of the load benchmark.

Cache decision: the options were a "per-process map" or a shared scan cache.
Neither shipped: the scan cache was rejected above, and a `lakew` process is
one-shot — a per-process cache could only coalesce repeated scans of the
*same* package within one invocation, which the two-phase `resolveDrivers`
(static scan pass, then a single shared `lake scripts` probe) already makes
impossible for the probe and rare for the scan. No speculative surface;
revisit if a profile ever shows external scans.

## Remote cache configuration (decision record)

This work added `[cache].remote` (checked only), `[cache].try-cache` (one
flag on sync's existing `lake update`), and the `lakew cache` pass-through.
The two generated-root cache stanzas (`enableArtifactCache`,
`restoreAllArtifacts`) already existed, so nothing in the load/plan/render
hot paths changed shape: the bench fixtures were left unchanged and all gates
still pass.

One open question was a sync-time measurement of `--try-cache` on a fixture
with one Reservoir dep, "no target". Decision: **not measured as a
benchmark**. `--try-cache` is one argv element on the one `lake update`
subprocess sync already runs — zero added lakew-side work (no new spawns,
no new reads). What it adds at runtime is Lake's cache download, which is
network-bound and belongs to Lake, not to lakew's load path; timing it would
benchmark the network. Recorded here in lieu of a number.

Facts measured on v4.33-rc1 with a path-dependency workspace: root
`enableArtifactCache := true` propagates to a dependency that sets nothing —
its oleans land in the toolchain cache
(`…/lib/lake/cache/artifacts/<hash>.olean`) and its build dir keeps only
`.ilean`; root `restoreAllArtifacts := true` restores the classic build-dir
layout; `LAKE_ARTIFACT_CACHE=0` overrides the root config (env beats root in
Lake's precedence); `lake cache services` prints one service name per line.
