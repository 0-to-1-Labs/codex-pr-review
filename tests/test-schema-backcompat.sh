#!/usr/bin/env bash
# tests/test-schema-backcompat.sh — Phase 5 schema back-compat tests.
#
# Verifies:
#   1. format_comment() applies the v2 compatibility shim, mapping v1 verdict
#      strings to the v2 enum:
#        "patch is correct"   → "correct"
#        "patch is incorrect" → "needs-changes"
#   2. The jq paths used by format_comment do not error on a v1-shaped output
#      (no source/verifier_verdict/agreement/iteration_meta/suggested_fix).
#   3. The v2 sentinel rendered with a v1 input still uses the v2 verdict.
#
# Usage:  bash tests/test-schema-backcompat.sh

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

# Extract format_comment from review.sh (same pattern test-iteration uses).
extract_fn() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ "^"name"\\(\\) \\{" { in_fn=1 }
    in_fn { print }
    in_fn && /^}/ { in_fn=0; exit }
  ' "$SCRIPTS_DIR/review.sh"
}

fmt_helpers="$WORK/fmt-helpers.sh"
fmt_work="$WORK/fmt-work"
mkdir -p "$fmt_work"
# Iteration meta absent → format_comment defaults to mode="initial" so we don't
# render delta sections. That's the right shape for testing the v1→v2 verdict
# shim against a v1 output.
cat > "$fmt_work/iteration-meta.json" <<'JSON'
{"iteration":1,"mode":"initial","prior_sha":"","prior_findings":[]}
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

# ─── Test 1: v1 output ("patch is correct") → renders "Verdict: correct" ────
echo "Test 1: v1 'patch is correct' → 'correct' via shim"
v1_correct="$FIX/v1-codex-output.json"
assert "[[ -f \"$v1_correct\" ]]" "v1 fixture exists"

rendered1="$WORK/rendered1.md"
err1="$WORK/err1.log"
format_comment "$v1_correct" "https://example.invalid/pr/1" "1" "deadbeef" > "$rendered1" 2> "$err1" || {
  echo "format_comment exited non-zero. stderr:" >&2
  cat "$err1" >&2 || true
}
assert "[[ -s \"$rendered1\" ]]" "format_comment produced output"

# Verdict line should contain "correct" (the shim'd v2 enum) — NOT
# "patch is correct" verbatim.
assert "grep -qE '^\\*\\*Verdict:\\*\\*.*correct' \"$rendered1\"" \
  "Verdict line shows 'correct' (v2 enum)"
# Tighten: must NOT contain the v1 "patch is correct" string in the v2
# sentinel.
assert "grep -qE '<!-- codex-pr-review:meta v=2 .*verdict=correct' \"$rendered1\"" \
  "v2 sentinel verdict=correct (mapped from 'patch is correct')"

# ─── Test 2: v1 'patch is incorrect' → 'needs-changes' ──────────────────────
echo "Test 2: v1 'patch is incorrect' → 'needs-changes' via shim"
v1_incorrect="$WORK/v1-incorrect.json"
jq '.overall_correctness = "patch is incorrect"' "$v1_correct" > "$v1_incorrect"

rendered2="$WORK/rendered2.md"
format_comment "$v1_incorrect" "https://example.invalid/pr/2" "1" "deadbeef" > "$rendered2" 2> "$WORK/err2.log" || true
assert "grep -qE '<!-- codex-pr-review:meta v=2 .*verdict=needs-changes' \"$rendered2\"" \
  "v2 sentinel verdict=needs-changes (mapped from 'patch is incorrect')"

# ─── Test 3: jq paths do not error on v1-only fields ────────────────────────
echo "Test 3: format_comment does not produce jq errors on v1 input"
# The stderr should not contain any "jq: error" lines from missing fields.
assert "! grep -q 'jq: error' \"$err1\"" \
  "no jq errors in format_comment stderr (Test 1)"
assert "! grep -q 'jq: error' \"$WORK/err2.log\"" \
  "no jq errors in format_comment stderr (Test 2)"

# ─── Test 4: legacy CODEX_REVIEW_DATA_START block still emitted ─────────────
echo "Test 4: v1 rollback block still present"
assert "grep -q 'CODEX_REVIEW_DATA_START' \"$rendered1\"" \
  "CODEX_REVIEW_DATA_START present (v1 rollback)"
assert "grep -q 'CODEX_REVIEW_DATA_END' \"$rendered1\"" \
  "CODEX_REVIEW_DATA_END present (v1 rollback)"

# ─── Test 5: v2 sentinel includes mode=initial when iteration-meta says so ──
echo "Test 5: v2 sentinel emits mode=initial for v1-shaped output"
assert "grep -q 'mode=initial' \"$rendered1\"" \
  "v2 sentinel mode=initial"

# ─── Test 6: schema validation — sample v2 output validates ──────────────────
echo "Test 6: sample v2 output passes shape check"
v2_sample="$WORK/v2-sample.json"
cat > "$v2_sample" <<'JSON'
{
  "findings": [
    {
      "title": "Sample finding",
      "body": "Body text",
      "confidence_score": 0.9,
      "priority": 2,
      "code_location": {"path": "a.go", "start_line": 10, "end_line": 12},
      "status": "new",
      "source": "codex",
      "verifier_verdict": "confirmed",
      "agreement": "both",
      "suggested_fix": "Add a nil check."
    }
  ],
  "overall_correctness": "needs-changes",
  "overall_explanation": "One issue.",
  "overall_confidence_score": 0.85,
  "review_iteration": 1,
  "resolved_prior_findings": [],
  "iteration_meta": {
    "iteration": 1,
    "mode": "initial"
  },
  "delta": {
    "resolved": [],
    "persisting": [],
    "new": ["Sample finding"],
    "regressed": []
  }
}
JSON
assert "jq empty \"$v2_sample\" >/dev/null 2>&1" \
  "v2 sample is valid JSON"

# v2 enum is exactly one of the four allowed values.
v2_verdict=$(jq -r '.overall_correctness' "$v2_sample")
case "$v2_verdict" in
  correct|needs-changes|blocking|"insufficient information")
    pass=$((pass + 1)); echo "  ok  v2 verdict in v2 enum (got '$v2_verdict')" ;;
  *)
    fail=$((fail + 1)); echo "  FAIL v2 verdict not in v2 enum (got '$v2_verdict')" ;;
esac

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  echo "Failures:"
  for m in "${fail_messages[@]}"; do echo "  - $m"; done
  exit 1
fi
exit 0
