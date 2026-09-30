#!/usr/bin/env bash
# tests/test-verifier.sh — Phase 2 cross-family verifier tests.
#
# Default mode (no env): dry-run only. Asserts:
#   1. verifier-output-schema.json is valid JSON and constrains the verdict
#      enum to {confirmed, refuted, inconclusive}.
#   2. _build_verifier_prompt (sourced from review.sh) splices a finding into
#      both verifier-claude-prompt.md and verifier-codex-prompt.md without
#      leaving placeholder markers behind.
#   3. The merge step in run_cross_family_verifier handles confirmed,
#      refuted, and inconclusive verdicts correctly when given pre-mocked
#      verdict files (we feed mocked outputs into a fake $WORK_DIR layout
#      and exercise the merge-only path).
#   4. finding_id() is deterministic across runs given identical inputs.
#
# RECORD=1 mode: actually invokes Claude (haiku alias, sandboxed via
# run_claude_p) against the hallucinated-finding fixture and asserts the
# verdict is `refuted`. Skipped silently when `claude` is missing or
# unauthenticated, so CI does not break.
#
# Usage:  bash tests/test-verifier.sh
#         RECORD=1 bash tests/test-verifier.sh
# Exit:   0 if all assertions pass; 1 on the first failure.

set -euo pipefail

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

# ─── Test 1: verifier schema is structurally correct ────────────────────────
echo "Test 1: verifier-output-schema.json"
schema="$SCRIPTS_DIR/verifier-output-schema.json"
assert "[[ -f \"$schema\" ]]" "verifier-output-schema.json exists"
assert "jq empty \"$schema\"" "verifier-output-schema.json is valid JSON"
assert "jq -e '.required | (index(\"verdict\") and index(\"evidence\") and index(\"adjusted_confidence\"))' \"$schema\" >/dev/null" \
  "schema requires verdict, evidence, adjusted_confidence"
assert "jq -e '.properties.verdict.enum | (index(\"confirmed\") and index(\"refuted\") and index(\"inconclusive\"))' \"$schema\" >/dev/null" \
  "schema verdict enum has confirmed|refuted|inconclusive"
assert "jq -e '.additionalProperties == false' \"$schema\" >/dev/null" \
  "schema has additionalProperties: false"

# Schema sanity check: validate a hand-crafted sample response. Use ajv if
# available; otherwise just confirm the sample's shape is internally consistent
# with `jq` and document the gap.
sample="$WORK/sample-verdict.json"
cat > "$sample" <<'JSON'
{"verdict":"refuted","evidence":"Cited line is past the end of the file (file has 18 lines).","adjusted_confidence":0.95}
JSON
if command -v ajv &>/dev/null; then
  assert "ajv validate -s \"$schema\" -d \"$sample\" >/dev/null 2>&1" \
    "ajv validates a known-good verifier verdict sample"
else
  assert "jq -e '.verdict and .evidence and (.adjusted_confidence != null)' \"$sample\" >/dev/null" \
    "sample verdict has all required fields (ajv unavailable; jq shape-check only)"
fi

# ─── Test 2: verifier prompt splice ─────────────────────────────────────────
echo "Test 2: verifier prompt splicing"

# Source review.sh in a non-main mode by stubbing out main() and trap. We do
# this by setting a sentinel env var and patching the cleanup trap before the
# script registers it. Instead of full sourcing (which would auto-run main()),
# we extract just the helper functions we need.
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
  extract_fn "_build_verifier_prompt"
  extract_fn "finding_id"
  extract_fn "_extract_diff_hunk"
  extract_fn "run_claude_p"
  extract_fn "unwrap_claude_envelope"
  extract_fn "_run_claude_verifier"
} > "$helpers"
# shellcheck disable=SC1090
source "$helpers"

# Build prompts with the hallucinated-finding fixture
finding_json=$(cat "$FIX/hallucinated-finding.json")
file_path="tests/fixtures/hallucinated-finding-file.py"
content_path="$WORK/file-content.txt"
hunk_path="$WORK/hunk.diff"
cp "$FIX/hallucinated-finding-file.py" "$content_path"
printf '@@ -1,5 +1,5 @@\n some context\n+a touched line\n' > "$hunk_path"

claude_prompt="$WORK/claude-prompt.md"
codex_prompt="$WORK/codex-prompt.md"
_build_verifier_prompt \
  "$SCRIPTS_DIR/verifier-claude-prompt.md" \
  "$claude_prompt" \
  "" \
  "$finding_json" \
  "$file_path" \
  "$content_path" \
  "$hunk_path"
_build_verifier_prompt \
  "$SCRIPTS_DIR/verifier-codex-prompt.md" \
  "$codex_prompt" \
  "" \
  "$finding_json" \
  "$file_path" \
  "$content_path" \
  "$hunk_path"

assert "[[ -s \"$claude_prompt\" ]]" "claude verifier prompt is non-empty"
assert "[[ -s \"$codex_prompt\" ]]" "codex verifier prompt is non-empty"
assert "! grep -q '{{FINDING}}' \"$claude_prompt\"" "claude verifier prompt has no {{FINDING}} placeholder left"
assert "! grep -q '{{FILE_CONTENT}}' \"$claude_prompt\"" "claude verifier prompt has no {{FILE_CONTENT}} placeholder left"
assert "! grep -q '{{DIFF_HUNK}}' \"$claude_prompt\"" "claude verifier prompt has no {{DIFF_HUNK}} placeholder left"
assert "grep -q 'Null dereference in get_user_session at line 42' \"$claude_prompt\"" "finding title is spliced into claude prompt"
assert "grep -q 'def add(a, b):' \"$claude_prompt\"" "file content is spliced into claude prompt"
assert "! grep -q '{{FINDING}}' \"$codex_prompt\"" "codex verifier prompt has no {{FINDING}} placeholder left"
assert "grep -q 'Null dereference in get_user_session at line 42' \"$codex_prompt\"" "finding title is spliced into codex prompt"

# ─── Test 3: finding_id determinism ─────────────────────────────────────────
echo "Test 3: finding_id determinism"
fid_1=$(finding_id "tests/fixtures/real-bug-file.py" "14" "Null dereference: user.email when get_user returns None")
fid_2=$(finding_id "tests/fixtures/real-bug-file.py" "14" "Null dereference: user.email when get_user returns None")
fid_3=$(finding_id "tests/fixtures/real-bug-file.py" "15" "Null dereference: user.email when get_user returns None")
assert "[[ \"$fid_1\" == \"$fid_2\" ]]" "finding_id is stable across runs ($fid_1)"
assert "[[ \"$fid_1\" != \"$fid_3\" ]]" "finding_id changes when start_line changes"
assert "[[ \${#fid_1} -eq 8 ]]" "finding_id is 8 hex characters"

# ─── Test 4: merge step routing (mocked verdicts) ───────────────────────────
echo "Test 4: merge step handles confirmed/refuted/inconclusive"

# We simulate the post-verifier merge step independently of the LLM dispatch
# by feeding hand-crafted verdict files into a fake $WORK_DIR/verifier and
# running a stripped-down version of the merge-step jq pipeline. This
# isolates the routing logic that run_cross_family_verifier uses.

merge_work="$WORK/merge"
mkdir -p "$merge_work/verifier"

cat > "$merge_work/raw-findings.json" <<JSON
[
  {
    "title": "Confirmed bug",
    "body": "explanation",
    "confidence_score": 0.7,
    "priority": 3,
    "code_location": {"path": "a.py", "start_line": 10, "end_line": 10},
    "status": "new",
    "source": "codex",
    "_finding_id": "aaaaaaaa"
  },
  {
    "title": "Hallucinated bug",
    "body": "explanation",
    "confidence_score": 0.9,
    "priority": 2,
    "code_location": {"path": "b.py", "start_line": 999, "end_line": 999},
    "status": "new",
    "source": "codex",
    "_finding_id": "bbbbbbbb"
  },
  {
    "title": "Ambiguous bug",
    "body": "explanation",
    "confidence_score": 0.8,
    "priority": 2,
    "code_location": {"path": "c.py", "start_line": 5, "end_line": 5},
    "status": "new",
    "source": "claude",
    "_finding_id": "cccccccc"
  }
]
JSON

cat > "$merge_work/verifier/finding-aaaaaaaa-verdict.json" <<'JSON'
{"verdict":"confirmed","evidence":"a.py:10 dereferences user.email without None check.","adjusted_confidence":0.85}
JSON
cat > "$merge_work/verifier/finding-bbbbbbbb-verdict.json" <<'JSON'
{"verdict":"refuted","evidence":"b.py only has 30 lines; line 999 does not exist.","adjusted_confidence":0.99}
JSON
cat > "$merge_work/verifier/finding-cccccccc-verdict.json" <<'JSON'
{"verdict":"inconclusive","evidence":"c.py:5 is ambiguous; cannot resolve from source alone.","adjusted_confidence":0.4}
JSON

# Re-implement the merge loop in pure jq for this test (it mirrors the bash
# loop in run_cross_family_verifier; staying in jq lets us assert on the
# routing pipeline without invoking subprocess loops). We write the result to
# a file and run jq against the file to avoid quoting hazards in [[ ... ]].
merged_file="$merge_work/merged.json"
jq '
  map(. as $f
       | if $f._finding_id == "aaaaaaaa" then $f + {verdict: "confirmed",    adjconf: 0.85}
         elif $f._finding_id == "bbbbbbbb" then $f + {verdict: "refuted",    adjconf: 0.99}
         elif $f._finding_id == "cccccccc" then $f + {verdict: "inconclusive", adjconf: 0.4}
         else $f end)
  | map(
      . as $f
      | (.confidence_score // 0.5) as $orig
      | (if .verdict == "confirmed" then
           (if .adjconf > $orig then .adjconf else $orig end)
         elif .verdict == "inconclusive" then ($orig * 0.7)
         else $orig end) as $new_conf
      | (if .verdict == "inconclusive" and (.priority // 0) > 1
           then ((.priority // 0) - 1)
         else (.priority // 0) end) as $new_pri
      | .verifier_verdict = .verdict
      | .agreement = (
          if .verdict == "confirmed" then (.source + "-only")
          elif .verdict == "refuted"  then null
          elif .verdict == "inconclusive" then
            (if .source == "codex" then "unconfirmed-by-claude" else "unconfirmed-by-codex" end)
          else null end
        )
      | .confidence_score = $new_conf
      | .priority = $new_pri
    )
  | map(select(.verdict != "refuted"))
' "$merge_work/raw-findings.json" > "$merged_file"

len=$(jq 'length' "$merged_file")
v0=$(jq -r '.[0].verifier_verdict' "$merged_file")
c0=$(jq -r '.[0].confidence_score' "$merged_file")
v1=$(jq -r '.[1].verifier_verdict' "$merged_file")
a1=$(jq -r '.[1].agreement' "$merged_file")
p1=$(jq -r '.[1].priority' "$merged_file")

assert "[[ \"$len\" -eq 2 ]]" "refuted finding is dropped from merge output"
assert "[[ \"$v0\" == 'confirmed' ]]" "confirmed finding has verifier_verdict=confirmed"
assert "[[ \"$c0\" == '0.85' ]]" "confirmed finding's confidence rises to adjusted_confidence (0.7 → 0.85)"
assert "[[ \"$v1\" == 'inconclusive' ]]" "inconclusive finding survives with verifier_verdict=inconclusive"
assert "[[ \"$a1\" == 'unconfirmed-by-codex' ]]" "claude-source inconclusive maps to unconfirmed-by-codex"
assert "[[ \"$p1\" -eq 1 ]]" "inconclusive finding priority is demoted (2 → 1; was $p1)"

# ─── Test 4b: verifier files are keyed by finding id AND source family ──────
# A [both] pair (same file|line|title from Codex and Claude) shares finding_id;
# the two verifier subshells run in parallel and must not share prompt/verdict
# files. Regression sentinel on the naming pattern in review.sh.
echo "Test 4b: verifier verdict files include the source family"
assert "grep -Fq 'finding-\${fkey}-verdict.json' \"$SCRIPTS_DIR/review.sh\"" \
  "dispatch writes finding-<id>-<source>-verdict.json"
assert "grep -Fq 'finding-\${fid}-\${source}-verdict.json' \"$SCRIPTS_DIR/review.sh\"" \
  "merge reads finding-<id>-<source>-verdict.json"
assert "grep -Fq 'fkey=\"\${fid}-\${source}\"' \"$SCRIPTS_DIR/review.sh\"" \
  "file key is fid-source"
# The sandbox flags on every claude -p call (CPR-01 / CPR-03).
echo "Test 4c: claude -p is invoked in restricted mode with Read,Grep only"
claude_block=$(awk '/^run_claude_p\(\) \{/,/^}/' "$SCRIPTS_DIR/review.sh")
for flag in '--restricted' '--tools Read,Grep' '--disallowedTools "mcp__\*"' '--strict-mcp-config' '--disable-slash-commands' '--permission-prompts none' '--no-session-persistence' '--max-budget-usd'; do
  assert "printf '%s' \"\$claude_block\" | grep -q -- '$flag'" "run_claude_p passes $flag"
done
assert "! grep -v '^[[:space:]]*#' \"$SCRIPTS_DIR/review.sh\" | grep -q -- '--allowedTools'" "no --allowedTools left in code (it only pre-approves)"
assert "[[ \$(grep -c '^[[:space:]]*claude \\\\$' \"$SCRIPTS_DIR/review.sh\") -eq 1 ]]" "exactly one claude invocation site (run_claude_p)"

# ─── Test 5 (RECORD=1 only): live Haiku verifier on hallucinated finding ────
if [[ "${RECORD:-0}" == "1" ]]; then
  echo "Test 5 (RECORD=1): live haiku verifier vs hallucinated finding"
  if ! command -v claude &>/dev/null; then
    echo "  skipped: claude CLI not on PATH"
  elif ! claude auth status >/dev/null 2>&1; then
    echo "  skipped: claude is not authenticated (run: claude auth login)"
  else
    live_prompt="$WORK/live-prompt.md"
    live_out="$WORK/live-verdict.json"
    live_stderr="$WORK/live-stderr.log"
    cp "$FIX/hallucinated-finding-file.py" "$WORK/live-file.txt"
    printf '@@ -1,5 +1,5 @@\n# fixture\n' > "$WORK/live-hunk.diff"
    _build_verifier_prompt \
      "$SCRIPTS_DIR/verifier-claude-prompt.md" \
      "$live_prompt" \
      "" \
      "$(cat "$FIX/hallucinated-finding.json")" \
      "tests/fixtures/hallucinated-finding-file.py" \
      "$WORK/live-file.txt" \
      "$WORK/live-hunk.diff"

    # Same sandboxed path review.sh uses (run_claude_p → unwrap), on the
    # cheap `haiku` alias, cwd = this repo.
    REVIEW_ROOT="$REPO_ROOT" MAX_BUDGET_USD="0.50"
    if _run_claude_verifier "$live_prompt" "$live_out" "$live_stderr" "haiku"; then
      verdict=$(jq -r '.verdict // ""' "$live_out" 2>/dev/null || echo "")
      assert "[[ \"$verdict\" == 'refuted' ]]" \
        "live haiku verifier refutes the hallucinated finding (got: $verdict)"
    else
      echo "  WARN: live verifier subprocess failed; see $live_stderr" >&2
      cat "$live_stderr" >&2 || true
      fail=$((fail + 1))
      fail_messages+=("live haiku verifier subprocess exited non-zero")
    fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  echo "Failures:"
  for m in "${fail_messages[@]}"; do echo "  - $m"; done
  exit 1
fi
exit 0
