#!/usr/bin/env bash
# tests/test-det-floor.sh — Phase 3 deterministic floor tests.
#
# Verifies:
#   1. det-output-schema.json shape (constants on source/verifier_verdict/agreement).
#   2. NO_DETERMINISTIC=1 short-circuits to [].
#   3. No config in repo → exits 0 with empty array and a note (no hard-fail).
#   4. Invalid TOML → exit 3.
#   5. Unknown key in [deterministic] → exit 3.
#   6. Unsafe character in command string → exit 3.
#   7. Each parser (ruff text, ruff json, eslint json, golangci json, tsc text)
#      produces correctly-shaped findings against its recorded fixture.
#   8. Changed-line filter: a finding on a line outside the diff is dropped.
#
# Tools (ruff, eslint, golangci-lint, tsc) are NOT actually invoked. We use
# DET_FLOOR_TEST_MODE=1 plus DET_FLOOR_FIXTURE_<TOOL>=<path> to feed recorded
# tool outputs into the parser.
#
# Usage:  bash tests/test-det-floor.sh
# Exit:   0 if all assertions pass; 1 on the first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
FIX="$SCRIPT_DIR/fixtures"
DET="$SCRIPTS_DIR/det-floor.sh"
SCHEMA="$SCRIPTS_DIR/det-output-schema.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
fail_messages=()

assert() {
  local cond="$1"; shift
  local msg="$*"
  if eval "$cond"; then
    pass=$((pass + 1))
    printf '  ok  %s\n' "$msg"
  else
    fail=$((fail + 1))
    fail_messages+=("$msg")
    printf '  FAIL %s (cond: %s)\n' "$msg" "$cond"
  fi
}

# ─── 1. Schema shape ────────────────────────────────────────────────────────
echo "Test 1: det-output-schema.json"
assert "[[ -f \"$SCHEMA\" ]]" "schema file exists"
assert "jq empty \"$SCHEMA\"" "schema is valid JSON"
assert "jq -e '.type == \"array\"' \"$SCHEMA\" >/dev/null" "schema is an array"
assert "jq -e '.items.properties.source.const == \"deterministic\"' \"$SCHEMA\" >/dev/null" \
  "source is const \"deterministic\""
assert "jq -e '.items.properties.verifier_verdict.const == \"n/a\"' \"$SCHEMA\" >/dev/null" \
  "verifier_verdict is const \"n/a\""
assert "jq -e '.items.properties.agreement.const == \"deterministic\"' \"$SCHEMA\" >/dev/null" \
  "agreement is const \"deterministic\""
assert "jq -e '.items.additionalProperties == false' \"$SCHEMA\" >/dev/null" \
  "additionalProperties false"
assert "jq -e '.items.required | (index(\"title\") and index(\"body\") and index(\"code_location\") and index(\"priority\") and index(\"confidence_score\") and index(\"source\") and index(\"verifier_verdict\") and index(\"agreement\") and index(\"category\"))' \"$SCHEMA\" >/dev/null" \
  "schema requires the full v2 finding shape"

# ─── 2. NO_DETERMINISTIC short-circuit ──────────────────────────────────────
echo "Test 2: NO_DETERMINISTIC=1"
w2="$WORK/t2"; mkdir -p "$w2"
NO_DETERMINISTIC=1 bash "$DET" "$w2" "$REPO_ROOT" /dev/null > "$w2/stdout.log" 2> "$w2/stderr.log" || rc=$?
assert "[[ -f \"$w2/det-findings.json\" ]]" "det-findings.json written"
assert "jq -e '. == []' \"$w2/det-findings.json\" >/dev/null" "det-findings.json is []"

# ─── 3. No-config silent skip ──────────────────────────────────────────────
echo "Test 3: no-config repo"
w3="$WORK/t3"; mkdir -p "$w3"
fake_repo="$WORK/fake-repo-noconfig"; mkdir -p "$fake_repo"
bash "$DET" "$w3" "$fake_repo" /dev/null > "$w3/stdout.log" 2> "$w3/stderr.log"
rc=$?
assert "[[ \"$rc\" == \"0\" ]]" "exit code 0"
assert "jq -e '. == []' \"$w3/det-findings.json\" >/dev/null" "det-findings.json is []"
assert "grep -q 'no deterministic floor configured' \"$w3/stderr.log\"" "stderr note present"

# Also exercise the bundled no-config-repo fixture.
w3b="$WORK/t3b"; mkdir -p "$w3b"
bash "$DET" "$w3b" "$FIX/no-config-repo" /dev/null > "$w3b/stdout.log" 2> "$w3b/stderr.log"
assert "jq -e '. == []' \"$w3b/det-findings.json\" >/dev/null" \
  "fixtures/no-config-repo also yields []"

# ─── 4. Invalid TOML hard-fail ──────────────────────────────────────────────
echo "Test 4: invalid TOML"
w4="$WORK/t4"; mkdir -p "$w4"
bad_repo="$WORK/bad-toml-repo"; mkdir -p "$bad_repo"
cat > "$bad_repo/.codex-pr-review.toml" <<'EOF'
[deterministic
lint = "no closing bracket"
EOF
rc=0
bash "$DET" "$w4" "$bad_repo" /dev/null > "$w4/stdout.log" 2> "$w4/stderr.log" || rc=$?
assert "[[ \"$rc\" == \"3\" ]]" "exit code 3 on invalid TOML"

# ─── 5. Unknown TOML key hard-fail ──────────────────────────────────────────
echo "Test 5: unknown TOML key"
w5="$WORK/t5"; mkdir -p "$w5"
bad_key_repo="$WORK/bad-key-repo"; mkdir -p "$bad_key_repo"
cat > "$bad_key_repo/.codex-pr-review.toml" <<'EOF'
[deterministic]
lint = "ruff"
bogus_key = "x"
EOF
rc=0
bash "$DET" "$w5" "$bad_key_repo" /dev/null > "$w5/stdout.log" 2> "$w5/stderr.log" || rc=$?
assert "[[ \"$rc\" == \"3\" ]]" "exit code 3 on unknown key"
assert "grep -q 'bogus_key' \"$w5/stderr.log\"" "stderr names the offending key"

# ─── 6. Unsafe command string hard-fail ─────────────────────────────────────
echo "Test 6: unsafe command string"
w6="$WORK/t6"; mkdir -p "$w6"
unsafe_repo="$WORK/unsafe-repo"; mkdir -p "$unsafe_repo"
cat > "$unsafe_repo/.codex-pr-review.toml" <<'EOF'
[deterministic]
lint = "ruff; rm -rf /"
EOF
rc=0
bash "$DET" "$w6" "$unsafe_repo" /dev/null > "$w6/stdout.log" 2> "$w6/stderr.log" || rc=$?
assert "[[ \"$rc\" == \"3\" ]]" "exit code 3 on unsafe command"
assert "grep -q 'unsafe character' \"$w6/stderr.log\"" "stderr explains the rejection"

# ─── 7. Parser fixtures ────────────────────────────────────────────────────
# A diff that touches src/example.py:10, src/example.py:25, src/handler.ts:15,
# src/handler.ts:28, internal/handler.go:42, internal/handler.go:88. Lines 42
# (ruff text/json) is intentionally NOT in this diff so we can also exercise
# the changed-line filter in the same fixture set.
diff_file="$WORK/parser-diff.txt"
cat > "$diff_file" <<'EOF'
diff --git a/src/example.py b/src/example.py
index abc..def 100644
--- a/src/example.py
+++ b/src/example.py
@@ -10,1 +10,1 @@
-import sys
+import os
@@ -25,1 +25,1 @@
-x = 1
+x = "long line"
diff --git a/src/handler.ts b/src/handler.ts
index aaa..bbb 100644
--- a/src/handler.ts
+++ b/src/handler.ts
@@ -15,1 +15,1 @@
-old line 15
+new line 15
@@ -28,1 +28,1 @@
-old line 28
+new line 28
diff --git a/internal/handler.go b/internal/handler.go
index 111..222 100644
--- a/internal/handler.go
+++ b/internal/handler.go
@@ -42,1 +42,1 @@
-old line 42
+new line 42
@@ -88,1 +88,1 @@
-old line 88
+new line 88
EOF

# Test runner: drives det-floor with a TOML config and a single tool fixture
# via env vars. We use `env` to be portable across bash quoting rules.
run_tool_test_env() {
  local label="$1"
  local toml_body="$2"
  local fixture_var="$3"
  local fixture_path="$4"
  local expected_count="$5"

  local w="$WORK/t7-$label"; mkdir -p "$w"
  local r="$WORK/t7-$label-repo"; mkdir -p "$r"
  printf '%s\n' "$toml_body" > "$r/.codex-pr-review.toml"
  local rc=0
  env DET_FLOOR_TEST_MODE=1 "${fixture_var}=${fixture_path}" \
    bash "$DET" "$w" "$r" "$diff_file" > "$w/stdout.log" 2> "$w/stderr.log" || rc=$?
  assert "[[ \"$rc\" == \"0\" ]]" "[$label] exit code 0"
  assert "jq -e 'type == \"array\"' \"$w/det-findings.json\" >/dev/null" "[$label] output is array"
  local actual
  actual=$(jq 'length' "$w/det-findings.json" 2>/dev/null || echo 0)
  assert "[[ \"$actual\" == \"$expected_count\" ]]" "[$label] $actual findings (expected $expected_count)"
  assert "jq -e 'all(.source == \"deterministic\")' \"$w/det-findings.json\" >/dev/null" \
    "[$label] all findings tagged source=deterministic"
}

# 7a. ruff JSON parser. Diff touches lines 10 and 25; line 42 must be filtered.
echo "Test 7a: ruff JSON parser (3 findings → 2 after changed-line filter)"
run_tool_test_env "ruff-json" \
  $'[deterministic]\nlint = "ruff check"\n' \
  "DET_FLOOR_FIXTURE_RUFF_JSON" \
  "$FIX/ruff-output.json" \
  2

# Verify: the surviving findings have lines 10 and 25 (not 42).
w_rj="$WORK/t7-ruff-json"
assert "jq -e '[.[].code_location.start_line] | sort == [10, 25]' \"$w_rj/det-findings.json\" >/dev/null" \
  "[ruff-json] surviving lines are 10 and 25 (line 42 filtered out)"

# 7b. ruff text parser via fallback path: JSON fixture is empty (parse fails),
# so the runner falls back to invoking the text mode (DET_FLOOR_FIXTURE_RUFF).
echo "Test 7b: ruff text parser via JSON-fallback (3 findings → 2 after changed-line filter)"
empty_json="$WORK/empty.json"
printf '' > "$empty_json"
w_rt="$WORK/t7-ruff-text-fb"; mkdir -p "$w_rt"
r_rt="$WORK/t7-ruff-text-fb-repo"; mkdir -p "$r_rt"
printf '[deterministic]\nlint = "ruff check"\n' > "$r_rt/.codex-pr-review.toml"
env DET_FLOOR_TEST_MODE=1 \
  DET_FLOOR_FIXTURE_RUFF_JSON="$empty_json" \
  DET_FLOOR_FIXTURE_RUFF="$FIX/ruff-output.txt" \
  bash "$DET" "$w_rt" "$r_rt" "$diff_file" > "$w_rt/stdout.log" 2> "$w_rt/stderr.log"
assert "jq -e 'length == 2' \"$w_rt/det-findings.json\" >/dev/null" \
  "[ruff-text-fallback] 2 findings (line 42 filtered out)"
assert "jq -e '[.[].code_location.start_line] | sort == [10, 25]' \"$w_rt/det-findings.json\" >/dev/null" \
  "[ruff-text-fallback] surviving lines are 10 and 25"

# 7c. eslint json parser. Both lines (15, 28) are in the diff for src/handler.ts.
echo "Test 7c: eslint JSON parser (2 findings, both kept)"
run_tool_test_env "eslint" \
  $'[deterministic]\nlint = "eslint"\n' \
  "DET_FLOOR_FIXTURE_ESLINT" \
  "$FIX/eslint-output.json" \
  2

# 7d. golangci-lint JSON parser. Both lines (42, 88) are in the diff.
echo "Test 7d: golangci-lint JSON parser (2 findings, both kept)"
run_tool_test_env "golangci" \
  $'[deterministic]\nlint = "golangci-lint run"\n' \
  "DET_FLOOR_FIXTURE_GOLANGCI" \
  "$FIX/golangci-output.json" \
  2

# 7e. tsc text parser. Both lines (15, 28) are in the diff for src/handler.ts.
echo "Test 7e: tsc text parser (2 findings, both kept)"
run_tool_test_env "tsc" \
  $'[deterministic]\ntypecheck = "tsc --noEmit"\n' \
  "DET_FLOOR_FIXTURE_TSC" \
  "$FIX/tsc-output.txt" \
  2

# Verify priority/category mapping for tsc (should be priority 2, correctness).
w_tsc="$WORK/t7-tsc"
assert "jq -e 'all(.priority == 2)' \"$w_tsc/det-findings.json\" >/dev/null" \
  "[tsc] all findings priority=2"
assert "jq -e 'all(.category == \"correctness\")' \"$w_tsc/det-findings.json\" >/dev/null" \
  "[tsc] all findings category=correctness"

# 7f. mypy text parser. Diff touches src/example.py:10 and :25 (line 42 is
# filtered) and src/handler.ts:15 (a mypy warning → priority 1). The `note:`
# line must be ignored.
echo "Test 7f: mypy text parser (5 lines → 3 findings after changed-line filter)"
run_tool_test_env "mypy" \
  $'[deterministic]\ntypecheck = "mypy --strict"\n' \
  "DET_FLOOR_FIXTURE_MYPY" \
  "$FIX/mypy-output.txt" \
  3
w_mypy="$WORK/t7-mypy"
assert "jq -e '[.[] | select(.code_location.path == \"src/example.py\") | .code_location.start_line] | sort == [10, 25]' \"$w_mypy/det-findings.json\" >/dev/null" \
  "[mypy] example.py lines 10 and 25 survive (42 filtered)"
assert "jq -e '[.[] | select(.code_location.path == \"src/example.py\")] | all(.priority == 2 and .category == \"correctness\")' \"$w_mypy/det-findings.json\" >/dev/null" \
  "[mypy] errors are priority 2 / correctness"
assert "jq -e '.[] | select(.code_location.path == \"src/handler.ts\") | .priority == 1' \"$w_mypy/det-findings.json\" >/dev/null" \
  "[mypy] warning is priority 1"

# 7g. Generic tests runner: a non-zero exit produces exactly one priority-3
# finding anchored on the diff's first changed line, with the tail of the
# runner output in the body.
echo "Test 7g: tests runner (exit 1 → one P3 finding on the first changed line)"
w_t="$WORK/t7-tests"; mkdir -p "$w_t"
r_t="$WORK/t7-tests-repo"; mkdir -p "$r_t"
printf '[deterministic]\ntests = "pytest -x --tb=short"\n' > "$r_t/.codex-pr-review.toml"
env DET_FLOOR_TEST_MODE=1 \
  DET_FLOOR_FIXTURE_TESTS="$FIX/pytest-output.txt" DET_FLOOR_FIXTURE_TESTS_RC=1 \
  bash "$DET" "$w_t" "$r_t" "$diff_file" > "$w_t/stdout.log" 2> "$w_t/stderr.log"
assert "jq -e 'length == 1' \"$w_t/det-findings.json\" >/dev/null" "[tests] exactly one finding"
assert "jq -e '.[0].priority == 3 and .[0].category == \"correctness\" and .[0].source == \"deterministic\"' \"$w_t/det-findings.json\" >/dev/null" \
  "[tests] finding is priority 3 / correctness / deterministic"
assert "jq -e '.[0].code_location.path == \"src/example.py\" and .[0].code_location.start_line == 10' \"$w_t/det-findings.json\" >/dev/null" \
  "[tests] anchored on the diff's first changed line (src/example.py:10)"
assert "jq -e '.[0].body | contains(\"FAILED tests/test_example.py::test_three\")' \"$w_t/det-findings.json\" >/dev/null" \
  "[tests] body carries the runner output tail"
assert "jq -e '.[0].title | contains(\"pytest\")' \"$w_t/det-findings.json\" >/dev/null" \
  "[tests] title names the runner"

# 7h. Tests runner: exit 0 → no finding.
echo "Test 7h: tests runner (exit 0 → no finding)"
w_t0="$WORK/t7-tests-pass"; mkdir -p "$w_t0"
env DET_FLOOR_TEST_MODE=1 \
  DET_FLOOR_FIXTURE_TESTS="$FIX/pytest-output.txt" DET_FLOOR_FIXTURE_TESTS_RC=0 \
  bash "$DET" "$w_t0" "$r_t" "$diff_file" > "$w_t0/stdout.log" 2> "$w_t0/stderr.log"
assert "jq -e '. == []' \"$w_t0/det-findings.json\" >/dev/null" "[tests-pass] no findings"
assert "grep -q 'tests passed' \"$w_t0/stderr.log\"" "[tests-pass] stderr notes the pass"

# 7i. Trusted TOML root: the config in DET_TRUSTED_ROOT wins, and a TOML in
# REPO_ROOT (the PR tree) is ignored even when the trusted root has none.
echo "Test 7i: DET_TRUSTED_ROOT is the only TOML source"
w_tr="$WORK/t7-trusted"; mkdir -p "$w_tr"
pr_tree="$WORK/t7-pr-tree"; mkdir -p "$pr_tree"
trusted="$WORK/t7-trusted-root"; mkdir -p "$trusted"
printf '[deterministic]\ntests = "pytest"\n' > "$pr_tree/.codex-pr-review.toml"
env DET_FLOOR_TEST_MODE=1 DET_TRUSTED_ROOT="$trusted" \
  DET_FLOOR_FIXTURE_TESTS="$FIX/pytest-output.txt" DET_FLOOR_FIXTURE_TESTS_RC=1 \
  bash "$DET" "$w_tr" "$pr_tree" "$diff_file" > "$w_tr/stdout.log" 2> "$w_tr/stderr.log"
assert "jq -e '. == []' \"$w_tr/det-findings.json\" >/dev/null" \
  "[trusted-root] PR-tree TOML ignored when DET_TRUSTED_ROOT is set"
assert "grep -q 'no deterministic floor configured' \"$w_tr/stderr.log\"" \
  "[trusted-root] floor reports no config"

# 7j. Auto-detection is opt-in: a tsconfig.json in the tree does nothing
# without DET_AUTODETECT=1, and selects tsc with it.
echo "Test 7j: lint/typecheck auto-detection is opt-in"
auto_tree="$WORK/t7-auto-tree"; mkdir -p "$auto_tree"
printf '{}' > "$auto_tree/tsconfig.json"
w_a0="$WORK/t7-auto-off"; mkdir -p "$w_a0"
env DET_FLOOR_TEST_MODE=1 DET_FLOOR_FIXTURE_TSC="$FIX/tsc-output.txt" \
  bash "$DET" "$w_a0" "$auto_tree" "$diff_file" > "$w_a0/stdout.log" 2> "$w_a0/stderr.log"
assert "jq -e '. == []' \"$w_a0/det-findings.json\" >/dev/null" "[autodetect-off] tsconfig.json alone runs nothing"
w_a1="$WORK/t7-auto-on"; mkdir -p "$w_a1"
env DET_FLOOR_TEST_MODE=1 DET_AUTODETECT=1 DET_FLOOR_FIXTURE_TSC="$FIX/tsc-output.txt" \
  bash "$DET" "$w_a1" "$auto_tree" "$diff_file" > "$w_a1/stdout.log" 2> "$w_a1/stderr.log"
assert "jq -e 'length == 2' \"$w_a1/det-findings.json\" >/dev/null" "[autodetect-on] tsc selected from tsconfig.json"

# ─── 8. Changed-line filter: stronger assertion ─────────────────────────────
# Use a diff that only touches line 25 (omitting line 10) and re-run ruff JSON.
echo "Test 8: changed-line filter (only line 25 in diff → 1 finding survives)"
narrow_diff="$WORK/narrow-diff.txt"
cat > "$narrow_diff" <<'EOF'
diff --git a/src/example.py b/src/example.py
index abc..def 100644
--- a/src/example.py
+++ b/src/example.py
@@ -25,1 +25,1 @@
-x = 1
+x = "long line"
EOF
w8="$WORK/t8"; mkdir -p "$w8"
r8="$WORK/t8-repo"; mkdir -p "$r8"
printf '[deterministic]\nlint = "ruff check"\n' > "$r8/.codex-pr-review.toml"
env DET_FLOOR_TEST_MODE=1 \
  DET_FLOOR_FIXTURE_RUFF_JSON="$FIX/ruff-output.json" \
  bash "$DET" "$w8" "$r8" "$narrow_diff" > "$w8/stdout.log" 2> "$w8/stderr.log"
actual8=$(jq 'length' "$w8/det-findings.json")
assert "[[ \"$actual8\" == \"1\" ]]" "exactly 1 finding survives the narrower diff"
assert "jq -e '.[0].code_location.start_line == 25' \"$w8/det-findings.json\" >/dev/null" \
  "the surviving finding is on line 25"

# ─── 9. NO_DETERMINISTIC also short-circuits when TOML is present ───────────
echo "Test 9: NO_DETERMINISTIC overrides TOML"
w9="$WORK/t9"; mkdir -p "$w9"
r9="$WORK/t9-repo"; mkdir -p "$r9"
cat > "$r9/.codex-pr-review.toml" <<'EOF'
[deterministic]
lint = "ruff check"
EOF
NO_DETERMINISTIC=1 bash "$DET" "$w9" "$r9" "$diff_file" > "$w9/stdout.log" 2> "$w9/stderr.log"
assert "jq -e '. == []' \"$w9/det-findings.json\" >/dev/null" \
  "NO_DETERMINISTIC empties output even with TOML present"

# ─── 10. Tool not found on PATH (real mode) → silent skip ───────────────────
echo "Test 10: tool not found on PATH (no test mode) → skip with note"
w10="$WORK/t10"; mkdir -p "$w10"
r10="$WORK/t10-repo"; mkdir -p "$r10"
cat > "$r10/.codex-pr-review.toml" <<'EOF'
[deterministic]
lint = "ruff check"
EOF
# Hide everything from PATH except a few essentials. We cannot easily stub
# ruff missing in an environment that has it; instead, use an unusual command
# name that nobody has installed.
cat > "$r10/.codex-pr-review.toml" <<'EOF'
[deterministic]
lint = "definitelynotinstalled404"
EOF
rc=0
bash "$DET" "$w10" "$r10" "$diff_file" > "$w10/stdout.log" 2> "$w10/stderr.log" || rc=$?
assert "[[ \"$rc\" == \"0\" ]]" "[tool-missing] exit 0 (silent skip)"
assert "jq -e '. == []' \"$w10/det-findings.json\" >/dev/null" \
  "[tool-missing] empty findings"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "─── Summary ───"
printf 'Pass: %d\nFail: %d\n' "$pass" "$fail"
if [[ "$fail" -gt 0 ]]; then
  echo "Failures:"
  for m in "${fail_messages[@]}"; do printf '  - %s\n' "$m"; done
  exit 1
fi
exit 0
