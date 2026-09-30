#!/usr/bin/env bash
# scripts/det-floor.sh — V2 P3 deterministic floor (lint + typecheck + tests on
# changed lines). Findings are grounded in tool output, not model inference,
# and skip the cross-family verifier.
#
# Inputs (positional):
#   $1  WORK_DIR     — work directory; we write det-findings.json + det-stderr.log here
#   $2  REPO_ROOT    — tree the tools run against (cwd for tool invocations;
#                     review.sh passes the PR-head worktree)
#   $3  DIFF_PATH    — path to full diff file (used to derive changed-line ranges
#                     when $WORK_DIR/plan.json is unavailable or lacks ranges)
#   $4  TOML_PATH    — optional path to .codex-pr-review.toml. If omitted, we
#                     try $DET_TRUSTED_ROOT/.codex-pr-review.toml, then
#                     $REPO_ROOT/.codex-pr-review.toml.
#
# Output:
#   $WORK_DIR/det-findings.json   — JSON array (matches det-output-schema.json)
#   $WORK_DIR/det-stderr.log      — concatenated tool stderr captures
#
# Env:
#   NO_DETERMINISTIC=1|true       — short-circuit: write [] and exit 0
#   DET_TRUSTED_ROOT=<dir>        — where .codex-pr-review.toml is read from
#                                   (review.sh passes the LOCAL checkout so the
#                                   PR cannot supply the `tests` command, which
#                                   runs an arbitrary executable). When set,
#                                   the TOML is never read from REPO_ROOT.
#   DET_AUTODETECT=1              — also run ruff/eslint/golangci-lint/tsc when
#                                   their config files exist in REPO_ROOT. Off
#                                   by default: those configs execute code from
#                                   the tree under review.
#   DET_FLOOR_TEST_MODE=1         — for unit tests: skip actually invoking lint
#                                   tools; we still run full TOML/sanitization
#                                   logic. Used by tests/test-det-floor.sh which
#                                   shims tool invocations via fixture files.
#   DET_FLOOR_FIXTURE_<TOOL>      — when DET_FLOOR_TEST_MODE=1, supply a path to
#                                   a recorded tool output fixture; the parser
#                                   reads from it instead of running the tool.
#                                   <TOOL> is one of RUFF, RUFF_JSON, ESLINT,
#                                   GOLANGCI, TSC, MYPY, TESTS.
#   DET_FLOOR_FIXTURE_TESTS_RC    — exit code the shimmed test runner reports
#                                   (default 1 when a TESTS fixture is set).
#
# Exit codes:
#   0  — wrote a (possibly empty) det-findings.json
#   2  — bad CLI invocation (missing args)
#   3  — hard fail (invalid TOML, unknown TOML key, unsafe tool command)
#
# All hard-fail messages go to stderr with prefix "det-floor: ".

set -euo pipefail

# ─── Argument parsing ───────────────────────────────────────────────────────
if [[ $# -lt 3 ]]; then
  echo "det-floor: usage: det-floor.sh WORK_DIR REPO_ROOT DIFF_PATH [TOML_PATH]" >&2
  exit 2
fi

WORK_DIR="$1"
REPO_ROOT="$2"
DIFF_PATH="$3"
TOML_PATH="${4:-}"

mkdir -p "$WORK_DIR"
DET_OUT="$WORK_DIR/det-findings.json"
DET_STDERR="$WORK_DIR/det-stderr.log"
: > "$DET_STDERR"

# Append a note to det-stderr.log AND mirror to real stderr so the orchestrator
# logs it.
note() {
  printf 'det-floor: %s\n' "$*" >> "$DET_STDERR"
  printf 'det-floor: %s\n' "$*" >&2
}

# Hard-fail with a message and exit 3.
hardfail() {
  printf 'det-floor: %s\n' "$*" >> "$DET_STDERR"
  printf 'det-floor: %s\n' "$*" >&2
  exit 3
}

# ─── NO_DETERMINISTIC short-circuit ─────────────────────────────────────────
if [[ "${NO_DETERMINISTIC:-0}" == "1" || "${NO_DETERMINISTIC:-0}" == "true" ]]; then
  printf '[]' > "$DET_OUT"
  note "NO_DETERMINISTIC set; writing empty det-findings.json and exiting."
  exit 0
fi

# ─── Locate config TOML ─────────────────────────────────────────────────────
# DET_TRUSTED_ROOT wins when set: the config decides which executables run,
# so it must come from the reviewer's own checkout, not the tree under review.
if [[ -z "$TOML_PATH" ]]; then
  if [[ -n "${DET_TRUSTED_ROOT:-}" ]]; then
    if [[ -f "$DET_TRUSTED_ROOT/.codex-pr-review.toml" ]]; then
      TOML_PATH="$DET_TRUSTED_ROOT/.codex-pr-review.toml"
    fi
  elif [[ -f "$REPO_ROOT/.codex-pr-review.toml" ]]; then
    TOML_PATH="$REPO_ROOT/.codex-pr-review.toml"
  fi
fi

# ─── Sanitize a tool command string ─────────────────────────────────────────
# Only [a-zA-Z0-9 ./_=-] allowed. Hard-fail on any other character so a
# .codex-pr-review.toml cannot smuggle shell metacharacters into our command
# invocation.
sanitize_command() {
  local key="$1"
  local cmd="$2"
  if [[ -z "$cmd" ]]; then return 0; fi
  # The set [a-zA-Z0-9 ./_=-] — note: '-' must be last in the char class.
  if [[ ! "$cmd" =~ ^[a-zA-Z0-9\ ./_=-]+$ ]]; then
    hardfail "unsafe character in [deterministic].$key from $TOML_PATH: $(printf '%q' "$cmd")"
  fi
}

# ─── TOML parsing ───────────────────────────────────────────────────────────
# Documented path: prefer Python with tomllib (≥3.11) or `tomli` (3.7+). Fall
# back to a small awk parser limited to the [deterministic] section keys we
# actually care about. The fallback intentionally parses only:
#   [deterministic]
#   key = "value"   |   key = value (bare)   |   key = true|false
# Comments (#…) on the line tail are stripped. Anything more exotic in
# [deterministic] is rejected by the unknown-key validator below.
TOML_LINT=""
TOML_TYPECHECK=""
TOML_TESTS=""
TOML_TEST_FILES_ONLY="false"

# `parse_toml_python_path` is set to "tomllib" or "tomli" if Python parsing is
# available, else empty. Documented in the report.
TOML_PARSE_PATH=""

parse_toml_via_python() {
  local toml="$1"
  local mod=""
  if python3 -c "import tomllib" 2>/dev/null; then
    mod="tomllib"
  elif python3 -c "import tomli" 2>/dev/null; then
    mod="tomli"
  else
    return 1
  fi
  TOML_PARSE_PATH="$mod"
  local json
  if ! json=$(python3 -c "
import sys, json
import ${mod} as toml_mod
with open(sys.argv[1], 'rb') as f:
    print(json.dumps(toml_mod.load(f)))
" "$toml" 2>>"$DET_STDERR"); then
    hardfail "failed to parse $toml as TOML (python ${mod})"
  fi
  # Validate that .deterministic is an object (or absent).
  local is_table
  is_table=$(printf '%s' "$json" | jq -r 'if has("deterministic") then (.deterministic | type) else "absent" end' 2>/dev/null || echo "error")
  if [[ "$is_table" == "error" ]]; then
    hardfail "invalid JSON produced from $toml; cannot parse"
  fi
  if [[ "$is_table" != "absent" && "$is_table" != "object" ]]; then
    hardfail "[deterministic] in $toml must be a table"
  fi
  # Validate keys.
  if [[ "$is_table" == "object" ]]; then
    local unknown
    unknown=$(printf '%s' "$json" | jq -r '
      .deterministic
      | keys[]
      | select(. != "lint" and . != "typecheck" and . != "tests" and . != "test_files_only")
    ' 2>/dev/null || true)
    if [[ -n "$unknown" ]]; then
      hardfail "unknown key(s) in [deterministic] of $toml: $(echo "$unknown" | tr '\n' ' ')(allowed: lint, typecheck, tests, test_files_only)"
    fi
    TOML_LINT=$(printf '%s' "$json" | jq -r '.deterministic.lint // ""')
    TOML_TYPECHECK=$(printf '%s' "$json" | jq -r '.deterministic.typecheck // ""')
    TOML_TESTS=$(printf '%s' "$json" | jq -r '.deterministic.tests // ""')
    TOML_TEST_FILES_ONLY=$(printf '%s' "$json" | jq -r '.deterministic.test_files_only // false | tostring')
  fi
  return 0
}

parse_toml_via_awk() {
  local toml="$1"
  TOML_PARSE_PATH="awk"
  # awk parser: walks the file, tracks current section, captures key=value pairs
  # under [deterministic]. Outputs four lines: lint|typecheck|tests|test_files_only
  # in shell-friendly form. Unknown keys → exit code 4 (hard-fail upstream).
  # Designed to work with BSD awk (no match-with-array, no gensub).
  local result
  if ! result=$(awk '
    BEGIN { section = ""; lint=""; typecheck=""; tests=""; tfo="false"; ok=1; bad="" }
    {
      line = $0
      # Strip leading whitespace.
      sub(/^[ \t]+/, "", line)
      # Skip blank and full-line comments.
      if (line == "" || substr(line, 1, 1) == "#") next
      # Section header?
      if (substr(line, 1, 1) == "[") {
        # strip trailing comment
        sub(/[ \t]*#.*$/, "", line)
        sub(/[ \t]+$/, "", line)
        # Match [<name>]
        end = index(line, "]")
        if (end > 1 && substr(line, 1, 1) == "[") {
          section = substr(line, 2, end - 2)
        } else {
          section = ""
        }
        next
      }
      # key=value line
      if (index(line, "\"") == 0) {
        sub(/[ \t]*#.*$/, "", line)
      }
      sub(/[ \t]+$/, "", line)
      if (line == "") next
      if (section != "deterministic") next
      eq = index(line, "=")
      if (eq == 0) next
      key = substr(line, 1, eq - 1)
      val = substr(line, eq + 1)
      sub(/[ \t]+$/, "", key); sub(/^[ \t]+/, "", key)
      sub(/[ \t]+$/, "", val); sub(/^[ \t]+/, "", val)
      # Strip surrounding double quotes from val.
      if (length(val) >= 2 && substr(val, 1, 1) == "\"" && substr(val, length(val), 1) == "\"") {
        val = substr(val, 2, length(val) - 2)
      }
      if (key == "lint")            { lint = val }
      else if (key == "typecheck")  { typecheck = val }
      else if (key == "tests")      { tests = val }
      else if (key == "test_files_only") { tfo = val }
      else { ok = 0; bad = bad " " key }
    }
    END {
      if (!ok) { printf("UNKNOWN_KEYS:%s\n", bad); exit 4 }
      printf("LINT=%s\n", lint)
      printf("TYPECHECK=%s\n", typecheck)
      printf("TESTS=%s\n", tests)
      printf("TFO=%s\n", tfo)
    }
  ' "$toml" 2>>"$DET_STDERR"); then
    if printf '%s' "$result" | grep -q '^UNKNOWN_KEYS:'; then
      local unknown
      unknown="${result#UNKNOWN_KEYS:}"
      hardfail "unknown key(s) in [deterministic] of $toml:$unknown (allowed: lint, typecheck, tests, test_files_only)"
    fi
    hardfail "failed to parse $toml (awk fallback parser)"
  fi
  TOML_LINT=$(printf '%s\n' "$result" | sed -n 's/^LINT=//p')
  TOML_TYPECHECK=$(printf '%s\n' "$result" | sed -n 's/^TYPECHECK=//p')
  TOML_TESTS=$(printf '%s\n' "$result" | sed -n 's/^TESTS=//p')
  TOML_TEST_FILES_ONLY=$(printf '%s\n' "$result" | sed -n 's/^TFO=//p')
  return 0
}

if [[ -n "$TOML_PATH" && -f "$TOML_PATH" ]]; then
  if ! parse_toml_via_python "$TOML_PATH"; then
    parse_toml_via_awk "$TOML_PATH"
  fi
  note "parsed config from $TOML_PATH (parser: $TOML_PARSE_PATH)"
fi

# Sanitize each command. (Boolean test_files_only is not a command.)
sanitize_command "lint" "$TOML_LINT"
sanitize_command "typecheck" "$TOML_TYPECHECK"
sanitize_command "tests" "$TOML_TESTS"

# ─── Auto-detect tools if not configured (opt-in) ───────────────────────────
# Only fill in tools that the user did NOT specify, and only when
# DET_AUTODETECT=1: every one of these tools executes configuration from the
# tree under review (eslint.config.js is JavaScript; tsc / golangci-lint read
# their config from the tree), so detection must not run on PR content by
# default.
#   ruff check       if pyproject.toml contains [tool.ruff]
#   eslint           if .eslintrc.* or eslint.config.* exists
#   golangci-lint    if .golangci.yml or .golangci.yaml exists
#   tsc --noEmit     if tsconfig.json exists
LINT_CMD="$TOML_LINT"
TYPECHECK_CMD="$TOML_TYPECHECK"
TESTS_CMD="$TOML_TESTS"

if [[ "${DET_AUTODETECT:-0}" == "1" ]]; then
  if [[ -z "$LINT_CMD" ]]; then
    if [[ -f "$REPO_ROOT/pyproject.toml" ]] && grep -q '^\[tool\.ruff\]' "$REPO_ROOT/pyproject.toml" 2>/dev/null; then
      LINT_CMD="ruff check"
    elif compgen -G "$REPO_ROOT/.eslintrc.*" >/dev/null 2>&1 || compgen -G "$REPO_ROOT/eslint.config.*" >/dev/null 2>&1; then
      LINT_CMD="eslint"
    elif [[ -f "$REPO_ROOT/.golangci.yml" || -f "$REPO_ROOT/.golangci.yaml" ]]; then
      LINT_CMD="golangci-lint run"
    fi
  fi
  if [[ -z "$TYPECHECK_CMD" ]]; then
    if [[ -f "$REPO_ROOT/tsconfig.json" ]]; then
      TYPECHECK_CMD="tsc --noEmit"
    fi
  fi
fi

# Decide which of the 4 named tools we're actually running.
TOOL_LIST=()
[[ -n "$LINT_CMD" ]]      && TOOL_LIST+=("lint:$LINT_CMD")
[[ -n "$TYPECHECK_CMD" ]] && TOOL_LIST+=("typecheck:$TYPECHECK_CMD")
[[ -n "$TESTS_CMD" ]]     && TOOL_LIST+=("tests:$TESTS_CMD")

if [[ ${#TOOL_LIST[@]} -eq 0 ]]; then
  printf '[]' > "$DET_OUT"
  note "no deterministic floor configured; skipping"
  exit 0
fi

# ─── Build changed-line ranges ───────────────────────────────────────────────
# We need: for each (file, line) reported by a tool, is line within a hunk
# touched by the diff? Per spec, we accept findings whose line is within ±0
# of any added/context line in any hunk for that file (i.e., within
# [hunk.startLineNew, hunk.startLineNew + hunk.lengthNew - 1]).
# We persist the ranges to a small TSV: <path>\t<startLine>\t<endLine>.
RANGES_FILE="$WORK_DIR/det-changed-ranges.tsv"
: > "$RANGES_FILE"

# Try plan.json first (P1 produces it; it has files and hunks via parseDiff).
PLAN_JSON="$WORK_DIR/plan.json"
_ranges_awk_program='
  /^diff --git / {
    path = ""
    if (match($0, /b\/[^ ]+/)) {
      path = substr($0, RSTART + 2, RLENGTH - 2)
    }
    next
  }
  /^@@ / {
    # Parse +start,length from "+a,b" segment.
    if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
      seg = substr($0, RSTART + 1, RLENGTH - 1)
      n = split(seg, parts, ",")
      s = parts[1] + 0
      if (n >= 2) { l = parts[2] + 0 } else { l = 1 }
      if (l < 1) l = 1
      printf "%s\t%d\t%d\n", path, s, s + l - 1
    }
    next
  }
'

ranges_from_plan() {
  [[ -f "$PLAN_JSON" ]] || return 1
  jq empty "$PLAN_JSON" 2>/dev/null || return 1
  local chunks_dir="$WORK_DIR/chunks"
  [[ -d "$chunks_dir" ]] || return 1
  if compgen -G "$chunks_dir/chunk_*.diff" >/dev/null 2>&1; then
    awk "$_ranges_awk_program" "$chunks_dir"/chunk_*.diff > "$RANGES_FILE" 2>/dev/null
  fi
  [[ -s "$RANGES_FILE" ]]
}

ranges_from_diff() {
  [[ -f "$DIFF_PATH" ]] || return 1
  awk "$_ranges_awk_program" "$DIFF_PATH" > "$RANGES_FILE" 2>/dev/null
}

if ! ranges_from_plan; then
  ranges_from_diff || true
fi

# Returns 0 if (path, line) is within any changed-line range. Pure bash so we
# do not pay an exec per finding.
in_changed_range() {
  local path="$1"
  local line="$2"
  [[ -s "$RANGES_FILE" ]] || return 1
  # Read TSV; bail on first match.
  local p s e
  while IFS=$'\t' read -r p s e; do
    if [[ "$p" == "$path" ]] && (( line >= s && line <= e )); then
      return 0
    fi
  done < "$RANGES_FILE"
  return 1
}

# ─── Findings accumulator (one JSON object per line) ────────────────────────
RAW_FINDINGS="$WORK_DIR/det-raw-findings.ndjson"
: > "$RAW_FINDINGS"

emit_finding() {
  local tool="$1"   # call-site label only; the tool name is already in title/body
  : "$tool"
  local path="$2"
  local start_line="$3"
  local end_line="$4"
  local priority="$5"
  local category="$6"
  local title="$7"
  local body="$8"

  # Drop findings outside changed ranges. (Always drop if we have ranges; if
  # ranges are empty — e.g. binary-only diff — drop everything since the floor
  # is "changed lines only".)
  if ! in_changed_range "$path" "$start_line"; then
    return 0
  fi

  jq -nc \
    --arg title "$title" \
    --arg body "$body" \
    --arg path "$path" \
    --argjson start "$start_line" \
    --argjson end "$end_line" \
    --argjson priority "$priority" \
    --arg category "$category" '
    {
      title: $title,
      body: $body,
      code_location: { path: $path, start_line: $start, end_line: $end },
      priority: $priority,
      confidence_score: 1.0,
      category: $category,
      source: "deterministic",
      verifier_verdict: "n/a",
      agreement: "deterministic"
    }
  ' >> "$RAW_FINDINGS"
}

# ─── Per-tool runner with PATH check ────────────────────────────────────────
# Stub-friendly: when DET_FLOOR_TEST_MODE=1 and DET_FLOOR_FIXTURE_<TOOL> is set,
# we read the fixture rather than invoking the binary. The shim is intentional
# — tests do NOT install ruff/eslint/etc. just to drive the parser.
det_floor_run_tool() {
  # $1 = tool key (RUFF|RUFF_JSON|ESLINT|GOLANGCI|TSC|MYPY|TESTS)
  # $2 = output capture file
  # $3.. = command + args
  local tool_key="$1"; shift
  local out_file="$1"; shift
  local fix_var="DET_FLOOR_FIXTURE_${tool_key}"
  if [[ "${DET_FLOOR_TEST_MODE:-0}" == "1" ]]; then
    if [[ -n "${!fix_var:-}" && -f "${!fix_var}" ]]; then
      cp "${!fix_var}" "$out_file"
      if [[ "$tool_key" == "TESTS" ]]; then
        # The generic test runner keys off the exit code, so the shim needs
        # one too.
        return "${DET_FLOOR_FIXTURE_TESTS_RC:-1}"
      fi
      return 0
    fi
    # In test mode without a fixture, treat as "tool not found".
    return 127
  fi

  local exe="$1"
  if ! command -v "$exe" &>/dev/null; then
    return 127
  fi

  # Run from REPO_ROOT. Stderr concatenated to det-stderr.log so the parser sees
  # only stdout. Exit code passed through (lint tools exit nonzero on findings).
  local rc=0
  ( cd "$REPO_ROOT" && "$@" ) > "$out_file" 2>>"$DET_STDERR" || rc=$?
  return "$rc"
}

# Run the test command with stdout AND stderr captured together (test runners
# put the failure summary on either stream).
det_floor_run_tests() {
  local out_file="$1"; shift
  if [[ "${DET_FLOOR_TEST_MODE:-0}" == "1" ]]; then
    det_floor_run_tool "TESTS" "$out_file" "$@"
    return $?
  fi
  local exe="$1"
  if ! command -v "$exe" &>/dev/null; then
    return 127
  fi
  local rc=0
  ( cd "$REPO_ROOT" && "$@" ) > "$out_file" 2>&1 || rc=$?
  return "$rc"
}

# First (path, line) of the first changed range — the anchor location for a
# whole-run finding such as a test failure, which has no line of its own.
first_changed_location() {
  [[ -s "$RANGES_FILE" ]] || return 1
  head -n 1 "$RANGES_FILE" | awk -F'\t' '{ printf "%s\t%s\n", $1, $2 }'
}

# Unique file paths touched by the diff (for test_files_only).
changed_files() {
  [[ -s "$RANGES_FILE" ]] || return 0
  awk -F'\t' '{ print $1 }' "$RANGES_FILE" | awk '!seen[$0]++'
}

# ─── Parsers ────────────────────────────────────────────────────────────────
parse_ruff_text() {
  local out="$1"
  # Format:  path:line:col: CODE  message
  local re='^([^:]+):([0-9]+):([0-9]+): ([A-Z][A-Z0-9]+) (.+)$'
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ $re ]]; then
      local file="${BASH_REMATCH[1]}"
      local lno="${BASH_REMATCH[2]}"
      local code="${BASH_REMATCH[4]}"
      local msg="${BASH_REMATCH[5]}"
      # ruff treats E* and F* as errors; W* as warnings. Conservative: treat
      # everything as priority 1 (lint warning) unless prefix is E (lint error).
      local priority=1
      local category="style"
      if [[ "$code" == E* || "$code" == F* ]]; then
        priority=2
        category="correctness"
      fi
      emit_finding "ruff" "$file" "$lno" "$lno" "$priority" "$category" \
        "ruff $code: $msg" "ruff reported \`$code\` at \`$file:$lno\`: $msg"
    fi
  done < "$out"
}

parse_ruff_json() {
  local out="$1"
  jq -c '.[]?' "$out" 2>/dev/null | while IFS= read -r row; do
    local path lno code msg
    path=$(printf '%s' "$row" | jq -r '.filename // .filename // ""')
    lno=$(printf '%s' "$row" | jq -r '.location.row // 0')
    code=$(printf '%s' "$row" | jq -r '.code // ""')
    msg=$(printf '%s' "$row" | jq -r '.message // ""')
    [[ -z "$path" || "$lno" == "0" ]] && continue
    local priority=1 category="style"
    if [[ "$code" == E* || "$code" == F* ]]; then
      priority=2; category="correctness"
    fi
    emit_finding "ruff" "$path" "$lno" "$lno" "$priority" "$category" \
      "ruff $code: $msg" "ruff reported \`$code\` at \`$path:$lno\`: $msg"
  done
}

parse_eslint_json() {
  local out="$1"
  jq -c '.[]?' "$out" 2>/dev/null | while IFS= read -r filerow; do
    local fpath
    fpath=$(printf '%s' "$filerow" | jq -r '.filePath // ""')
    [[ -z "$fpath" ]] && continue
    # Make path relative to REPO_ROOT if absolute (eslint reports absolute).
    local rel="$fpath"
    if [[ "$fpath" == "$REPO_ROOT"/* ]]; then
      rel="${fpath#$REPO_ROOT/}"
    fi
    while IFS= read -r m; do
      local lno rule sev msg
      lno=$(printf '%s' "$m" | jq -r '.line // 0')
      rule=$(printf '%s' "$m" | jq -r '.ruleId // ""')
      sev=$(printf '%s' "$m" | jq -r '.severity // 0')
      msg=$(printf '%s' "$m" | jq -r '.message // ""')
      [[ "$lno" == "0" ]] && continue
      local priority=1 category="style"
      if [[ "$sev" == "2" ]]; then priority=2; category="correctness"; fi
      emit_finding "eslint" "$rel" "$lno" "$lno" "$priority" "$category" \
        "eslint $rule: $msg" "eslint rule \`$rule\` flagged \`$rel:$lno\`: $msg"
    done < <(printf '%s' "$filerow" | jq -c '.messages[]?' 2>/dev/null)
  done
}

parse_golangci_json() {
  local out="$1"
  jq -c '.Issues[]?' "$out" 2>/dev/null | while IFS= read -r row; do
    local fpath lno linter msg
    fpath=$(printf '%s' "$row" | jq -r '.Pos.Filename // ""')
    lno=$(printf '%s' "$row" | jq -r '.Pos.Line // 0')
    linter=$(printf '%s' "$row" | jq -r '.FromLinter // ""')
    msg=$(printf '%s' "$row" | jq -r '.Text // ""')
    [[ -z "$fpath" || "$lno" == "0" ]] && continue
    emit_finding "golangci-lint" "$fpath" "$lno" "$lno" 2 "correctness" \
      "golangci-lint $linter: $msg" "golangci-lint linter \`$linter\` flagged \`$fpath:$lno\`: $msg"
  done
}

parse_tsc_text() {
  local out="$1"
  # Format:  path(line,col): error TS#### : message
  # Build regex in a variable so bash does not stumble on the literal parens.
  local re='^([^(]+)\(([0-9]+),([0-9]+)\): (error|warning) (TS[0-9]+): (.+)$'
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ $re ]]; then
      local file="${BASH_REMATCH[1]}"
      local lno="${BASH_REMATCH[2]}"
      local sev="${BASH_REMATCH[4]}"
      local code="${BASH_REMATCH[5]}"
      local msg="${BASH_REMATCH[6]}"
      local priority=2 category="correctness"
      if [[ "$sev" == "warning" ]]; then priority=1; category="style"; fi
      emit_finding "tsc" "$file" "$lno" "$lno" "$priority" "$category" \
        "tsc $code: $msg" "tsc reported \`$code\` at \`$file:$lno\`: $msg"
    fi
  done < "$out"
}

parse_mypy_text() {
  local out="$1"
  # Formats:  path:line: error: msg [code]
  #           path:line:col: error: msg [code]
  #           (also `note:` lines, which are skipped)
  local re='^([^:]+):([0-9]+)(:[0-9]+)?: (error|warning): (.+)$'
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ $re ]]; then
      local file="${BASH_REMATCH[1]}"
      local lno="${BASH_REMATCH[2]}"
      local sev="${BASH_REMATCH[4]}"
      local msg="${BASH_REMATCH[5]}"
      local priority=2 category="correctness"
      if [[ "$sev" == "warning" ]]; then priority=1; category="style"; fi
      emit_finding "mypy" "$file" "$lno" "$lno" "$priority" "$category" \
        "mypy: $msg" "mypy reported at \`$file:$lno\`: $msg"
    fi
  done < "$out"
}

# ─── Generic test runner ────────────────────────────────────────────────────
# `tests` has no per-line parser: any non-zero exit is one priority-3
# (blocking) finding anchored on the diff's first changed line, with the last
# 30 lines of runner output as the body. Exit 127 (runner not installed) is a
# skip, not a failure.
run_tests_cmd() {
  local cmd="$1"
  local argv=()
  read -r -a argv <<<"$cmd"
  local exe="${argv[0]:-}"
  [[ -z "$exe" ]] && return 0

  if [[ "$TOML_TEST_FILES_ONLY" == "true" ]]; then
    local f
    while IFS= read -r f; do
      [[ -n "$f" ]] && argv+=("$f")
    done < <(changed_files)
  fi

  local out_file="$WORK_DIR/det-tests-output.txt"
  local rc=0
  det_floor_run_tests "$out_file" "${argv[@]}" || rc=$?
  if [[ "$rc" == "127" ]]; then
    note "tests runner '$exe' not found on PATH; skipping"
    return 0
  fi
  if [[ "$rc" == "0" ]]; then
    note "tests passed ($cmd)"
    return 0
  fi

  local anchor path lno
  anchor=$(first_changed_location || true)
  if [[ -z "$anchor" ]]; then
    note "tests failed (rc=$rc) but the diff has no changed lines to anchor the finding on; skipping"
    return 0
  fi
  IFS=$'\t' read -r path lno <<< "$anchor"
  local tail_out
  tail_out=$(tail -n 30 "$out_file" 2>/dev/null || true)
  local body
  body="Test command \`$cmd\` exited with status $rc. Last lines of output:"$'\n\n```\n'"$tail_out"$'\n```'
  emit_finding "tests" "$path" "$lno" "$lno" 3 "correctness" \
    "tests: \`$exe\` failed (exit $rc)" "$body"
}

# ─── Tool dispatch ──────────────────────────────────────────────────────────
# We choose the parser by the first token of the configured/detected command.
# Unknown lint/typecheck tools are skipped with a stderr note (the floor is
# best-effort: missing parser support should not block a review). The `tests`
# tag takes the generic exit-code runner regardless of executable.
run_tool() {
  local tag="$1"   # lint | typecheck | tests
  local cmd="$2"
  [[ -z "$cmd" ]] && return 0

  if [[ "$tag" == "tests" ]]; then
    run_tests_cmd "$cmd"
    return 0
  fi

  # Split into argv.
  local argv=()
  read -r -a argv <<<"$cmd"
  local exe="${argv[0]:-}"
  [[ -z "$exe" ]] && return 0

  local out_file="$WORK_DIR/det-${tag}-output.txt"
  local rc=0
  case "$exe" in
    mypy)
      # mypy text output: path:line: error: msg. Keep the user's flags; add
      # --no-color-output / --no-error-summary so the parser sees plain lines.
      local margv=("${argv[@]}" --no-color-output --no-error-summary)
      det_floor_run_tool "MYPY" "$out_file" "${margv[@]}" || rc=$?
      if [[ "$rc" == "127" ]]; then
        note "$tag tool 'mypy' not found on PATH; skipping"
        return 0
      fi
      if [[ -s "$out_file" ]]; then
        parse_mypy_text "$out_file"
      else
        note "$tag tool 'mypy' produced no output (rc=$rc); nothing to report"
      fi
      ;;
    ruff)
      # Prefer JSON output if available.
      local json_argv=("${argv[@]}" --output-format json)
      det_floor_run_tool "RUFF_JSON" "$out_file" "${json_argv[@]}" || rc=$?
      if [[ "$rc" == "127" ]]; then
        note "$tag tool 'ruff' not found on PATH; skipping"
        return 0
      fi
      if [[ -s "$out_file" ]] && jq empty "$out_file" 2>/dev/null; then
        parse_ruff_json "$out_file"
      else
        # JSON failed; rerun text mode.
        rc=0
        det_floor_run_tool "RUFF" "$out_file" "${argv[@]}" || rc=$?
        if [[ "$rc" == "127" ]]; then
          note "$tag tool 'ruff' not found on PATH; skipping"
          return 0
        fi
        if [[ -s "$out_file" ]]; then
          parse_ruff_text "$out_file"
        else
          note "$tag tool 'ruff' produced no parseable output (rc=$rc); skipping (see det-stderr.log)"
        fi
      fi
      ;;
    eslint)
      local jargv=("${argv[@]}" --format json)
      det_floor_run_tool "ESLINT" "$out_file" "${jargv[@]}" || rc=$?
      if [[ "$rc" == "127" ]]; then
        note "$tag tool 'eslint' not found on PATH; skipping"
        return 0
      fi
      if [[ -s "$out_file" ]] && jq empty "$out_file" 2>/dev/null; then
        parse_eslint_json "$out_file"
      else
        note "$tag tool 'eslint' produced no parseable output (rc=$rc); skipping (see det-stderr.log)"
      fi
      ;;
    golangci-lint)
      local gargv=("${argv[@]}" --out-format json)
      det_floor_run_tool "GOLANGCI" "$out_file" "${gargv[@]}" || rc=$?
      if [[ "$rc" == "127" ]]; then
        note "$tag tool 'golangci-lint' not found on PATH; skipping"
        return 0
      fi
      if [[ -s "$out_file" ]] && jq empty "$out_file" 2>/dev/null; then
        parse_golangci_json "$out_file"
      else
        note "$tag tool 'golangci-lint' produced no parseable output (rc=$rc); skipping (see det-stderr.log)"
      fi
      ;;
    tsc)
      # tsc text output: path(line,col): error TS####: msg.
      local targv=("${argv[@]}" --pretty false)
      det_floor_run_tool "TSC" "$out_file" "${targv[@]}" || rc=$?
      if [[ "$rc" == "127" ]]; then
        note "$tag tool 'tsc' not found on PATH; skipping"
        return 0
      fi
      if [[ -s "$out_file" ]]; then
        parse_tsc_text "$out_file"
      else
        note "$tag tool 'tsc' produced no parseable output (rc=$rc); skipping (see det-stderr.log)"
      fi
      ;;
    *)
      note "$tag tool '$exe' has no built-in parser; skipping (configure ruff/eslint/golangci-lint/tsc/mypy for native support)"
      return 0
      ;;
  esac
}

for entry in "${TOOL_LIST[@]}"; do
  tag="${entry%%:*}"
  cmd="${entry#*:}"
  run_tool "$tag" "$cmd" || true
done

# ─── Assemble final JSON array ──────────────────────────────────────────────
if [[ ! -s "$RAW_FINDINGS" ]]; then
  printf '[]' > "$DET_OUT"
else
  jq -s '.' "$RAW_FINDINGS" > "$DET_OUT"
fi

count=$(jq 'length' "$DET_OUT" 2>/dev/null || echo 0)
note "wrote $count deterministic findings to $DET_OUT"

exit 0
