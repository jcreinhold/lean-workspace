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

echo
if [ "$failures" -eq 0 ]; then
  echo "ALL TESTS PASSED"
else
  echo "$failures TEST(S) FAILED"
  exit 1
fi
