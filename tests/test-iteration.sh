#!/usr/bin/env bash
# tests/test-iteration.sh — Phase 4 iteration classifier tests.
#
# Verifies:
#   1. gather_prior_review_v2 against fixtures/prior-review-v2-comment.md
#      extracts prior_sha, iteration, and verdict from the v2 sentinel.
#   2. gather_prior_review_v2 against fixtures/prior-review-v1-comment.md
#      falls back to the legacy CODEX_REVIEW_DATA_START block; prior_sha
#      is empty (v1 never recorded it).
#   3. gather_prior_review_v2 against a plain comment with neither sentinel
#      returns found=false.
#   4. classify_iteration handles all six scenarios:
#      - empty git log → followup-after-fixes
#      - one fix-flavored commit → followup-after-fixes
#      - one feature commit → delta-since-prior
#      - many fix-flavored commits → followup-after-fixes
#      - mixed commits → delta-since-prior
#      - --mode initial forced → initial
#      - --mode delta with no prior → hard fail (exit non-zero)
#   5. compute_delta_diff substitutes the mocked git diff output into
#      delta-diff.txt.
#   6. format_comment renders Resolved-since-last-review and Persisting-from-
#      prior-review sections when iteration_meta and a synthesis output with a
#      delta block are provided.
#
# Usage:  bash tests/test-iteration.sh
# Exit:   0 if all assertions pass; 1 on the first failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
FIX="$SCRIPT_DIR/fixtures"

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

# ─── Source helper functions out of review.sh ────────────────────────────────
# Same approach test-verifier.sh uses: extract just the functions we need
# without running main().
extract_fn() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ "^"name"\\(\\) \\{" { in_fn=1 }
    in_fn { print }
    in_fn && /^}/ { in_fn=0; exit }
  ' "$SCRIPTS_DIR/review.sh"
}

helpers="$WORK/helpers.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  printf 'SCRIPT_DIR=%q\n' "$SCRIPTS_DIR"
  printf 'WORK_DIR=%q\n' "$WORK"
  extract_fn "_parse_v2_sentinel"
  extract_fn "_extract_prior_review_from_body"
  extract_fn "gather_prior_review_v2"
  extract_fn "classify_iteration"
  extract_fn "compute_delta_diff"
  extract_fn "render_prior_findings_summary"
  extract_fn "build_followup_context_v2"
} > "$helpers"
# shellcheck disable=SC1090
source "$helpers"

# ─── Test 1: v2 sentinel extraction ──────────────────────────────────────────
echo "Test 1: gather_prior_review_v2 on v2 fixture"
v2_fixture="$FIX/prior-review-v2-comment.md"
assert "[[ -f \"$v2_fixture\" ]]" "v2 fixture exists"

v2_json="$WORK/v2-out.json"
gather_prior_review_v2 "0" "$v2_fixture" > "$v2_json" 2>/dev/null || true
assert "[[ -s \"$v2_json\" ]]" "gather_prior_review_v2 wrote stdout"
assert "jq -e '.found == true' \"$v2_json\" >/dev/null" "v2 fixture: found == true"
v2_sha=$(jq -r '.prior_sha' "$v2_json")
v2_iter=$(jq -r '.iteration' "$v2_json")
v2_verdict=$(jq -r '.verdict' "$v2_json")
assert "[[ \"$v2_sha\" == 'abc123def456' ]]" "v2 fixture: prior_sha=abc123def456 (got: $v2_sha)"
assert "[[ \"$v2_iter\" == '2' ]]" "v2 fixture: iteration=2 (got: $v2_iter)"
assert "[[ \"$v2_verdict\" == 'needs-changes' ]]" "v2 fixture: verdict=needs-changes (got: $v2_verdict)"
v2_findings_count=$(jq '.findings | length' "$v2_json")
assert "[[ \"$v2_findings_count\" -ge 1 ]]" "v2 fixture: findings array populated (got $v2_findings_count)"

# ─── Test 2: v1 back-compat ──────────────────────────────────────────────────
echo "Test 2: gather_prior_review_v2 on v1 fixture (fallback)"
v1_fixture="$FIX/prior-review-v1-comment.md"
assert "[[ -f \"$v1_fixture\" ]]" "v1 fixture exists"

v1_json="$WORK/v1-out.json"
gather_prior_review_v2 "0" "$v1_fixture" > "$v1_json" 2>/dev/null || true
assert "jq -e '.found == true' \"$v1_json\" >/dev/null" "v1 fixture: found == true"
v1_sha=$(jq -r '.prior_sha' "$v1_json")
v1_iter=$(jq -r '.iteration' "$v1_json")
assert "[[ -z \"$v1_sha\" ]]" "v1 fixture: prior_sha is empty (got: '$v1_sha')"
assert "[[ \"$v1_iter\" == '1' ]]" "v1 fixture: iteration=1 (got: $v1_iter)"

# ─── Test 2b: sentinel values are validated (CPR-02) ─────────────────────────
# `sha` reaches `git log`/`git diff` as a revision; a git option smuggled in
# must degrade to "no sha". Non-integer counters degrade to defaults.
echo "Test 2b: _parse_v2_sentinel rejects non-hex sha and non-integer counters"
bad_line='<!-- codex-pr-review:meta v=2 sha=--output=/tmp/pwned iteration=41x findings=abc verdict=correct mode=initial prior_sha=../../x -->'
bad_json=$(_parse_v2_sentinel "$bad_line")
assert "printf '%s' \"\$bad_json\" | jq -e '.sha == \"\"' >/dev/null" "sha=--output=... is dropped (got: $(printf '%s' "$bad_json" | jq -r .sha))"
assert "printf '%s' \"\$bad_json\" | jq -e '.prior_sha_inner == \"\"' >/dev/null" "prior_sha=../../x is dropped"
assert "printf '%s' \"\$bad_json\" | jq -e '.iteration == 1' >/dev/null" "iteration=41x falls back to 1"
assert "printf '%s' \"\$bad_json\" | jq -e '.findings_count == 0' >/dev/null" "findings=abc falls back to 0"
good_line='<!-- codex-pr-review:meta v=2 sha=abc123def456 iteration=3 findings=2 verdict=needs-changes mode=delta-since-prior prior_sha=deadbeef -->'
good_json=$(_parse_v2_sentinel "$good_line")
assert "printf '%s' \"\$good_json\" | jq -e '.sha == \"abc123def456\" and .iteration == 3 and .findings_count == 2 and .prior_sha_inner == \"deadbeef\" and .verdict == \"needs-changes\"' >/dev/null" \
  "well-formed sentinel parses unchanged"
# compute_delta_diff refuses a non-hex sha before touching git.
bad_delta="$WORK/bad-delta.txt"
rc=0
compute_delta_diff "--output=$WORK/pwned" "$bad_delta" 2>/dev/null || rc=$?
assert "[[ \"$rc\" -ne 0 ]]" "compute_delta_diff rejects a git-option sha (rc=$rc)"
assert "[[ ! -e \"$WORK/pwned..HEAD\" ]]" "no file written via --output"

# ─── Test 3: no sentinel ─────────────────────────────────────────────────────
echo "Test 3: gather_prior_review_v2 on comment with no sentinels"
plain_fixture="$WORK/plain-comment.md"
cat > "$plain_fixture" <<'EOF'
This is a regular PR comment with no Codex/Claude review sentinel.

Just a plain note.
EOF
plain_json="$WORK/plain-out.json"
gather_prior_review_v2 "0" "$plain_fixture" > "$plain_json" 2>/dev/null || true
assert "jq -e '.found == false' \"$plain_json\" >/dev/null" "plain comment: found == false"

# ─── Test 4: classify_iteration ──────────────────────────────────────────────
echo "Test 4a: empty git log → followup-after-fixes"
ITERATION_GIT_LOG_OVERRIDE="" out=$(classify_iteration "abc123" "true" "auto") || true
assert "[[ \"$out\" == 'followup-after-fixes' ]]" "empty git log → followup-after-fixes (got: $out)"

echo "Test 4b: one fix-flavored commit → followup-after-fixes"
ITERATION_GIT_LOG_OVERRIDE="abc1234 fix: address PR feedback" \
  out=$(classify_iteration "abc123" "true" "auto") || true
assert "[[ \"$out\" == 'followup-after-fixes' ]]" "single fix commit → followup-after-fixes (got: $out)"

echo "Test 4c: one feature commit → delta-since-prior"
ITERATION_GIT_LOG_OVERRIDE="abc1234 feat: add new endpoint" \
  out=$(classify_iteration "abc123" "true" "auto") || true
assert "[[ \"$out\" == 'delta-since-prior' ]]" "single feature commit → delta-since-prior (got: $out)"

echo "Test 4d: multiple fix-flavored commits → followup-after-fixes"
ITERATION_GIT_LOG_OVERRIDE=$'abc1111 fix: nil deref\nabc2222 chore: lint pass\nabc3333 Address review feedback' \
  out=$(classify_iteration "abc123" "true" "auto") || true
assert "[[ \"$out\" == 'followup-after-fixes' ]]" "all fix-flavored commits → followup-after-fixes (got: $out)"

echo "Test 4e: mixed commits → delta-since-prior"
ITERATION_GIT_LOG_OVERRIDE=$'abc1111 fix: nil deref\nabc2222 feat: add new endpoint' \
  out=$(classify_iteration "abc123" "true" "auto") || true
assert "[[ \"$out\" == 'delta-since-prior' ]]" "mixed commits → delta-since-prior (got: $out)"

echo "Test 4f: --mode initial forced → initial"
out=$(classify_iteration "abc123" "true" "initial") || true
assert "[[ \"$out\" == 'initial' ]]" "--mode initial overrides prior (got: $out)"

echo "Test 4g: --mode followup forced → followup-after-fixes"
out=$(classify_iteration "" "false" "followup") || true
assert "[[ \"$out\" == 'followup-after-fixes' ]]" "--mode followup → followup-after-fixes (got: $out)"

echo "Test 4h: --mode delta with no prior → hard fail"
err_log="$WORK/delta-no-prior.err"
out=$(classify_iteration "" "false" "delta" 2> "$err_log")
rc=$?
assert "[[ \"$rc\" -ne 0 ]]" "--mode delta with no prior fails (rc=$rc)"
assert "grep -q 'requires a prior review' \"$err_log\"" "error message mentions 'requires a prior review'"

echo "Test 4i: auto mode, no prior found → initial"
out=$(classify_iteration "" "false" "auto") || true
assert "[[ \"$out\" == 'initial' ]]" "auto mode, no prior → initial (got: $out)"

echo "Test 4j: auto mode, v1 prior (empty sha) → followup-after-fixes"
out=$(classify_iteration "" "true" "auto") || true
assert "[[ \"$out\" == 'followup-after-fixes' ]]" "auto + v1 prior (no sha) → followup-after-fixes (got: $out)"

# ─── Test 5: compute_delta_diff ──────────────────────────────────────────────
echo "Test 5: compute_delta_diff writes delta-diff.txt from mocked git diff"
delta_out="$WORK/delta.txt"
ITERATION_GIT_DIFF_OVERRIDE='diff --git a/foo.py b/foo.py
@@ -1,2 +1,2 @@
-pass
+def foo(): pass
' compute_delta_diff "abc123" "$delta_out"
assert "[[ -s \"$delta_out\" ]]" "delta-diff written"
assert "grep -q '^diff --git ' \"$delta_out\"" "delta-diff contains diff header"
assert "grep -q '^+def foo' \"$delta_out\"" "delta-diff contains added line"

# ─── Test 6: format_comment delta rendering ──────────────────────────────────
# We can't realistically extract format_comment in isolation (it's ~200 lines
# and depends on multiple sibling functions). Instead, drive the full script
# in a sandboxed mode by calling the fragment of the rendering logic via jq
# directly: we assert that a synthesis output with a `delta` block contains
# the keys we expect, and that the bash rendering (smoke-tested via the
# rendered comment fragment) emits both "Resolved since last review" and
# "Persisting from prior review" sections.
echo "Test 6: synthesis output delta block + rendering"
synth_out="$WORK/synth-output.json"
cat > "$synth_out" <<'JSON'
{
  "findings": [
    {
      "title": "New issue from delta",
      "body": "introduced by recent commit",
      "code_location": {"path": "a.py", "start_line": 5, "end_line": 5},
      "category": "correctness",
      "priority": 2,
      "confidence_score": 0.9,
      "status": "new",
      "source": "codex",
      "verifier_verdict": "confirmed",
      "agreement": "both"
    }
  ],
  "overall_correctness": "patch is incorrect",
  "overall_confidence_score": 0.85,
  "overall_explanation": "One new issue.",
  "review_iteration": 2,
  "resolved_prior_findings": [],
  "iteration_meta": {
    "iteration": 2,
    "mode": "delta-since-prior",
    "prior_sha": "abc123",
    "delta": {
      "resolved": ["Old race condition was fixed"],
      "persisting": [
        {"title": "Unchecked nil deref", "code_location": {"path": "b.go", "start_line": 88}, "priority": 3}
      ],
      "new": ["New issue from delta"],
      "regressed": []
    }
  }
}
JSON

# Sanity: synthesis output's delta block has the expected shape.
assert "jq -e '.iteration_meta.delta.resolved | length == 1' \"$synth_out\" >/dev/null" \
  "synthesis: delta.resolved has 1 entry"
assert "jq -e '.iteration_meta.delta.persisting | length == 1' \"$synth_out\" >/dev/null" \
  "synthesis: delta.persisting has 1 entry"
assert "jq -e '.iteration_meta.delta.new | length == 1' \"$synth_out\" >/dev/null" \
  "synthesis: delta.new has 1 entry"

# Smoke test the bash rendering. We invoke the format_comment-equivalent
# fragments by running the full review.sh in a stub environment with a
# pre-populated WORK_DIR. We do this by extracting format_comment and
# calling it via the helpers source. format_comment also depends on a
# WORK_DIR/iteration-meta.json file, which we provide.
fmt_helpers="$WORK/fmt-helpers.sh"
fmt_work="$WORK/fmt-work"
mkdir -p "$fmt_work"
cat > "$fmt_work/iteration-meta.json" <<'JSON'
{"iteration":2,"mode":"delta-since-prior","prior_sha":"abc123","prior_findings":[]}
JSON

{
  echo '#!/usr/bin/env bash'
  echo 'set -uo pipefail'
  printf 'SCRIPT_DIR=%q\n' "$SCRIPTS_DIR"
  printf 'WORK_DIR=%q\n' "$fmt_work"
  echo 'MODEL="gpt-6.1-sol"'
  echo 'MODEL_CODEX="gpt-6.1-sol"'
  echo 'MODEL_CLAUDE="opus"'
  echo 'THRESHOLD="0.8"'
  extract_fn "escape_md_field"
  extract_fn "format_comment"
} > "$fmt_helpers"
# shellcheck disable=SC1090
source "$fmt_helpers"

rendered="$WORK/rendered-comment.md"
format_comment "$synth_out" "https://example.invalid/pr/1" "2" "deadbeef" > "$rendered" 2> "$WORK/fmt-stderr.log" || {
  cat "$WORK/fmt-stderr.log" >&2 || true
}

assert "grep -q '^## Codex PR Review v2 — Iteration 2 (delta)' \"$rendered\"" \
  "header is mode-aware (delta)"
assert "grep -q '^### Resolved since last review' \"$rendered\"" \
  "Resolved-since-last-review section rendered"
assert "grep -q '^- ~~Old race condition was fixed~~' \"$rendered\"" \
  "resolved title is struck-through"
assert "grep -q '^### Persisting from prior review' \"$rendered\"" \
  "Persisting-from-prior-review section rendered"
assert "grep -q '\\[persisting\\]' \"$rendered\"" \
  "persisting line is tagged [persisting]"
assert "grep -qE '<!-- codex-pr-review:meta v=2 .*mode=delta-since-prior.*prior_sha=abc123' \"$rendered\"" \
  "v2 sentinel includes mode= and prior_sha="
assert "grep -q 'CODEX_REVIEW_DATA_START' \"$rendered\"" \
  "legacy CODEX_REVIEW_DATA_START block still present"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  echo "Failures:"
  for m in "${fail_messages[@]}"; do echo "  - $m"; done
  exit 1
fi
exit 0
