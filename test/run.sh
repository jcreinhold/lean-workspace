#!/usr/bin/env bash
# Test suite for lakew. Run from the repo root: bash test/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAKEW="$ROOT/.lake/build/bin/lakew"
TMP="$(mktemp -d /tmp/lakew-tests.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

failures=0
check() { # check <name> <condition...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    "$@" 2>&1 | head -30
    failures=$((failures + 1))
  fi
}
check_grep() { # check_grep <name> <pattern> <file>
  local name="$1" pat="$2" file="$3"
  if grep -q "$pat" "$file"; then
    echo "ok   - $name"
  else
    echo "FAIL - $name (pattern: $pat)"
    cat "$file"
    failures=$((failures + 1))
  fi
}

echo "== building lakew =="
(cd "$ROOT" && lake build lakew) || { echo "build failed"; exit 1; }

echo "== basic fixture: sync + golden =="
cp -R "$ROOT/test/fixtures/basic" "$TMP/basic"
(cd "$TMP/basic" && "$LAKEW" sync >sync.log 2>&1)
check "sync succeeds" test -f "$TMP/basic/lakefile.lean"
check "golden: lakefile.lean" diff -u "$ROOT/test/golden/basic/lakefile.lean" "$TMP/basic/lakefile.lean"
check "golden: package-overrides.json" \
  diff -u "$ROOT/test/golden/basic/.lake/package-overrides.json" "$TMP/basic/.lake/package-overrides.json"
check "golden: metadata.json" \
  diff -u "$ROOT/test/golden/basic/.lake/workspace/metadata.json" "$TMP/basic/.lake/workspace/metadata.json"

echo "== basic fixture: stock lake works on the generated root =="
check "stock lake build @core @tactics" bash -c "cd '$TMP/basic' && lake build @core @tactics >lake-build.log 2>&1"

echo "== basic fixture: check =="
(cd "$TMP/basic" && "$LAKEW" check >check.log 2>&1)
check "check passes after sync" grep -q "up to date" "$TMP/basic/check.log"
echo "# hand edit" >> "$TMP/basic/lakefile.lean"
(cd "$TMP/basic" && "$LAKEW" check >check-stale.log 2>&1; test $? -eq 1)
check "check fails on stale generated root" grep -q "out of date" "$TMP/basic/check-stale.log"

echo "== basic fixture: sync --locked =="
(cd "$TMP/basic" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
(cd "$TMP/basic" && "$LAKEW" sync >/dev/null 2>&1) # restore generated root
(cd "$TMP/basic" && git add -A && git -c user.email=t@t -c user.name=t commit -qm resync)
check "sync --locked passes when fresh" bash -c "cd '$TMP/basic' && '$LAKEW' sync --locked >locked.log 2>&1"
printf '\n# policy tweak\n' >> "$TMP/basic/lean-workspace.toml"
# regenerate expectations changed? no: toml comment does not change the model,
# but a real change does. Append a real change: exclude nothing, add a group.
cat >> "$TMP/basic/lean-workspace.toml" <<'EOF'

[groups.extra]
members = ["core"]
EOF
(cd "$TMP/basic" && "$LAKEW" sync --locked >locked-stale.log 2>&1; test $? -eq 1)
check "sync --locked fails when model changed" test $? -eq 0

echo "== basic fixture: one lake invocation per build =="
(cd "$TMP/basic" && "$LAKEW" build --group foundation --dry-run --json >plan.json 2>&1)
check_grep "exactly one runLake step" '"kind": "runLake"' "$TMP/basic/plan.json"
[ "$(grep -c '"kind": "runLake"' "$TMP/basic/plan.json")" = "1" ] || { echo "FAIL - more than one runLake step"; failures=$((failures + 1)); }
check_grep "both targets in one argv" '"@core",' "$TMP/basic/plan.json"
(cd "$TMP/basic" && "$LAKEW" build -p tactics --dry-run >plan.txt 2>&1)
check_grep "explanation trace" "tactics: selected via -p" "$TMP/basic/plan.txt"

echo "== basic fixture: --changed =="
cd "$TMP/basic"
git checkout -q lean-workspace.toml  # undo the --locked section's model change
printf '\ndef Tactic.Elab.extra : Nat := 0\n' >> packages/tactics/Tactic/Elab.lean
"$LAKEW" build --changed HEAD --dry-run >changed1.log 2>&1
check_grep "changed tactics file selects tactics" '@tactics' changed1.log
if grep -q '@core' changed1.log; then echo "FAIL - core wrongly selected"; failures=$((failures + 1)); fi
git checkout -q packages/tactics/Tactic/Elab.lean
printf '\ndef Core.extra : Nat := 0\n' >> packages/core/Core.lean
"$LAKEW" build --changed HEAD --dry-run >changed2.log 2>&1
check_grep "reverse dep closure: syntax" '@syntax' changed2.log
check_grep "reverse dep closure: tactics" '@tactics' changed2.log
check_grep "explanation: depends on changed" 'depends on a changed package' changed2.log
git checkout -q packages/core/Core.lean
printf '# touch\n' >> lean-toolchain
"$LAKEW" build --changed HEAD --dry-run >changed3.log 2>&1
check_grep "toolchain change selects everything" 'globally affected' changed3.log
git checkout -q lean-toolchain
cd "$ROOT"

echo "== violation fixtures =="
expect_violation() { # <fixture> <grep pattern>
  local f="$1" pat="$2"
  cp -R "$ROOT/test/fixtures/$f" "$TMP/$f"
  (cd "$TMP/$f" && "$LAKEW" check >diag.log 2>&1; test $? -eq 1)
  check "violation: $f fails" test $? -eq 0
  check_grep "violation: $f diagnostic" "$pat" "$TMP/$f/diag.log"
}
expect_violation conflict "Conflicting dependency \`batteries\`"
expect_violation undeclared-import "does not declare a direct dependency on \`liba\`"
expect_violation dup-root "module root \`Common\` is claimed by both"
expect_violation prod-imports-test "production package \`core\` imports"
expect_violation cycle "package dependency cycle detected"

echo "== phase 1: [deps] central declarations =="
cp -R "$ROOT/test/fixtures/shared-deps" "$TMP/shared-deps"
(cd "$TMP/shared-deps" && "$LAKEW" check >diag.log 2>&1; test $? -eq 1)
check "shared-deps: mismatch fails" test $? -eq 0
check_grep "shared-deps: central-declaration diagnostic" "does not match the workspace \[deps\] declaration" "$TMP/shared-deps/diag.log"
check_grep "shared-deps: names the member lakefile" "packages/server/lakefile.lean" "$TMP/shared-deps/diag.log"
(cd "$TMP/shared-deps" && "$LAKEW" sync --write-deps --offline >align.log 2>&1)
check "shared-deps: sync --write-deps aligns" grep -q "aligned" "$TMP/shared-deps/align.log"
check_grep "shared-deps: require rewritten to central rev" 'require batteries from git "https://example.invalid/batteries" @ "b136111"' "$TMP/shared-deps/packages/server/lakefile.lean"
(cd "$TMP/shared-deps" && "$LAKEW" check >check2.log 2>&1)
check "shared-deps: check passes after alignment" grep -q "up to date" "$TMP/shared-deps/check2.log"

echo "== phase 2: test/lint driver aggregation =="
cp -R "$ROOT/test/fixtures/drivers" "$TMP/drivers"
(cd "$TMP/drivers" && "$LAKEW" sync >/dev/null 2>&1)
(cd "$TMP/drivers" && "$LAKEW" test --dry-run --json >plan.json 2>&1)
[ "$(grep -c '"kind": "runLake"' "$TMP/drivers/plan.json")" = "1" ] && \
  echo "ok   - drivers: one build step" || { echo "FAIL - drivers: one build step"; failures=$((failures + 1)); }
check_grep "drivers: build step covers all exe/lib drivers" '"@withlib/TestLib"' "$TMP/drivers/plan.json"
check_grep "drivers: script driver not in build step" '"runDrivers"' "$TMP/drivers/plan.json"
(cd "$TMP/drivers" && "$LAKEW" test >test.log 2>&1; test $? -eq 3)
check "drivers: failing driver propagates exit code" test $? -eq 0
check_grep "drivers: config args reach script driver" 'script tests passed (\[--cfg\])' "$TMP/drivers/test.log"
check_grep "drivers: aggregated summary" "test: 1 of 4 driver(s) FAILED" "$TMP/drivers/test.log"
(cd "$TMP/drivers" && "$LAKEW" test -p withexe >test1.log 2>&1)
check "drivers: -p selection passes" grep -q "all 1 driver(s) passed" "$TMP/drivers/test1.log"
(cd "$TMP/drivers" && "$LAKEW" test -p failing --json >report.json 2>/dev/null)
check_grep "drivers: json report ok:false" '"ok": false' "$TMP/drivers/report.json"
check_grep "drivers: json report clean of build logs" '"exitCode": 3' "$TMP/drivers/report.json"
if head -c 1 "$TMP/drivers/report.json" | grep -q '{'; then echo "ok   - drivers: json report is pure json"; else echo "FAIL - json report polluted"; failures=$((failures + 1)); fi
(cd "$TMP/drivers" && "$LAKEW" lint >lint.log 2>&1)
check "drivers: lint aggregation" grep -q "lint: all 1 driver(s) passed" "$TMP/drivers/lint.log"
check_grep "drivers: lint notes skip driverless members" "no lint driver (skipped)" "$TMP/drivers/lint.log"

echo "== phase 3: --affected + why =="
cp -R "$ROOT/test/fixtures/affected" "$TMP/affected"
(cd "$TMP/affected" && "$LAKEW" sync >/dev/null 2>&1 && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
cd "$TMP/affected"
check "why: tactics → core path" bash -c "'$LAKEW' why tactics core | grep -q 'tactics → syntax → core'"
("$LAKEW" why util core >why2.log 2>&1; test $? -eq 1)
check "why: unreachable errors" test $? -eq 0
printf '\ndef Core.A.x2 := 1\n' >> packages/core/Core/A.lean
"$LAKEW" build --affected HEAD --dry-run >aff1.log 2>&1
check_grep "affected: reverse module closure selects importers" 'module Syntax.X imports a changed module' aff1.log
check_grep "affected: explanation names changed module" 'module Core.A changed' aff1.log
if grep -q 'util' aff1.log; then echo "FAIL - util wrongly selected by --affected"; failures=$((failures + 1)); else echo "ok   - affected: unrelated member excluded"; fi
git checkout -q packages/core/Core/A.lean
printf '\ndef Tactic.Z.v2 := 0\n' >> packages/tactics/Tactic/Z.lean
"$LAKEW" build --affected HEAD --dry-run >aff2.log 2>&1
check_grep "affected: leaf module selects own package only" '@tactics' aff2.log
if grep -q '@core' aff2.log; then echo "FAIL - core wrongly selected by --affected"; failures=$((failures + 1)); else echo "ok   - affected: no over-selection"; fi
git checkout -q packages/tactics/Tactic/Z.lean
"$LAKEW" build --affected HEAD --dry-run >aff3.log 2>&1
check_grep "affected: no changes is a graceful no-op" 'nothing to build' aff3.log
cd "$ROOT"

echo "== phase 4: [options] policy =="
cp -R "$ROOT/test/fixtures/options-policy" "$TMP/options-policy"
(cd "$TMP/options-policy" && "$LAKEW" check >diag.log 2>&1; test $? -eq 1)
check "options-policy: missing option fails" test $? -eq 0
check_grep "options-policy: names member and option" 'member `bad` does not set required workspace option `linter.missingDocs`' "$TMP/options-policy/diag.log"
if grep -q 'member `good`' "$TMP/options-policy/diag.log"; then echo "FAIL - compliant member flagged"; failures=$((failures + 1)); else echo "ok   - options-policy: compliant member passes"; fi

echo
if [ "$failures" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "$failures TEST(S) FAILED"
  exit 1
fi
