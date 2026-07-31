# Load-path benchmark: decision log

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

Yardstick: one `lake --version` spawn ≈ 29 ms.

Two surprises against the plan's hypothesis:

1. **`validate` was O(modules²)** — the module-ownership index was built with
   a per-module linear `find?`. 162 ms at mathlib scale, second-largest phase.
2. **`module-imports` was ~60% lookup, not IO** — every import did a linear
   `find?` over the same index. The file reads were the minority of the cost.

## What shipped

### Hash side-index (found by measurement, outside the plan's O1–O4)

`Std.HashMap` for ownership construction and import lookup; the sorted array
remains the canonical model. `validate` 162→1 ms; serial full-load
`module-imports` 379→190 ms. The spike's largest single win, and invisible
without the instrumentation.

### O1 — lazy module-import index — SHIPPED (gate: ≥2×)

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

### O2 — parallel scanning — SHIPPED (gate: ≥20% on realistic size)

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

- **O3 scan-result cache — rejected by measurement.** Warm full load at
  mathlib scale is ≤ ~0.2 s; a mtime-keyed cache buys nothing at that cost
  and adds an invalidation surface. Revisit if plan 02 (TOML lakefiles) or
  plan 03 (external driver scans) push real loads into seconds.
- **O4 fewer subprocess spawns — moot.** `load` spawns zero processes; the
  git/`lake` spawns live in selection/execution and are flag-driven.

## Caveats recorded

- **Cold-vs-warm bimodality.** The first run reading a workspace after a
  different size's files were touched runs ~2× slow (fs metadata cache);
  steady-state is the warm number. Parallelism cannot fix cold IO, and real
  use is warm (editors and CI touch the tree constantly).
- The suite's spawn gate is 4× one `lake` spawn, not the plan's aspirational
  2×: mathlib-scale `graph` currently sits at ~2.2× (member-scan dominates),
  and 2× leaves no room for machine noise. Tighten when member-scan does.
- Wall-clock gates are not in CI (CI builds the suite only). Re-run
  `suite-bench` and update this file when plans 02–04 land.

## PLAN-02: TOML lakefile members (measured)

Plan 02 adds a second lakefile format: members may carry `lakefile.toml`,
read with Lake's own parser (`Lake.Toml.loadToml` — one environment build per
parse). The generator gained a `tomlMixed` mode (odd members TOML-carried)
and the suite a regression case: mixed full load must stay within +25% of
Lean-only on the same shape (PLAN-01's ≥20% regression rule, encoded).

Measured (medium, 30 members × 300 modules, single pass):

| variant | graph total | full total | member-scan (full) |
| --- | --- | --- | --- |
| Lean-only | 15 ms | 119 ms | 14 ms |
| mixed (½ TOML) | 14 ms | 124 ms (+4%) | 12 ms |

The TOML parse cost is noise at this scale — the per-member scan stays
dominated by the on-disk module walk, and `loadToml`'s environment build is
sub-ms per member. No mitigation needed; O3's "revisit if plan 02 pushes
loads into seconds" trigger did not fire.
