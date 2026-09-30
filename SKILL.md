---
name: codex-pr-review
description: Review a pull request using a dual-family pipeline (OpenAI Codex + Claude Opus) with a cross-family grounded verifier and a deterministic lint/typecheck/test floor. Use when the user wants a high-signal external AI code review, a second opinion on a PR, or a cross-model verified review. Supports auto-detection of current branch PR or explicit PR number/URL.
license: MIT
metadata:
  author: sasser
  version: 2.0.0
allowed-tools: Bash
argument-hint: "[PR_NUMBER|PR_URL] [--mode auto|initial|followup|delta] [--threshold FLOAT] [--model-codex MODEL] [--model-claude MODEL] [--model-verifier MODEL] [--chunker auto|ast|hunk] [--review-rules PATH] [--max-parallel INT] [--max-diff-lines INT] [--chunk-size INT] [--no-verify] [--no-deterministic] [--dry-run]"
---

# Codex PR Review (v2)

Review a pull request using a dual-family pipeline — Codex (`gpt-5.6-sol`) and Claude Opus run in parallel per chunk — with every LLM finding independently verified against source code by the *other* family before posting. A deterministic floor (lint + typecheck + tests on changed lines) anchors the LLM panel in real tool exit codes.

## Prerequisites

- `codex` CLI installed (`npm install -g @openai/codex`) and authenticated via OAuth (`codex login`)
- `claude` CLI installed (Claude Code) — required for the dual-family pipeline and the cross-family verifier
- `gh` CLI installed and authenticated
- `jq` installed
- Node.js ≥ 18 (used by the AST-aware chunker for Python / TypeScript / Go)
- Current directory must be a git repository

## Usage

```
/codex-pr-review                              # Auto-detect PR for current branch
/codex-pr-review 123                          # Review PR #123
/codex-pr-review --threshold 0.6              # Lower confidence threshold
/codex-pr-review --mode followup              # Force follow-up-after-fixes mode
/codex-pr-review --mode delta                 # Force delta-since-prior mode (review only new commits)
/codex-pr-review --chunker ast                # Force AST-aware chunking
/codex-pr-review --no-verify                  # Skip the cross-family verifier (debug only)
/codex-pr-review --no-deterministic           # Skip the lint/typecheck/test floor
/codex-pr-review --dry-run                    # Render the review but do NOT post it to the PR
```

## Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `PR_NUMBER` or `PR_URL` | auto-detect | PR to review |
| `--mode` | `auto` | `auto`, `initial`, `followup`, or `delta` (forces iteration mode) |
| `--threshold` | `0.8` | Confidence threshold (post-verifier) |
| `--model-codex` (alias `--model`) | `gpt-5.6-sol` | Codex reviewer model |
| `--model-claude` | `claude-opus-4-8` | Claude reviewer + synthesizer model |
| `--model-verifier` | `claude-opus-4-8` | Default cross-family verifier model. Override with `claude-haiku-4-5` for cheaper but more deferential verification |
| `--chunker` | `auto` | `auto` (AST when language is supported, hunk fallback), `ast`, or `hunk` |
| `--review-rules` | (auto) | Path to override REVIEW.md / CLAUDE.md discovery |
| `--chunk-size` | `3000` | Lines per chunk |
| `--max-parallel` | `4` | Concurrent slots; each slot runs Codex + Claude in parallel |
| `--max-diff-lines` | `0` | Safety truncation cap (0 = unlimited) |
| `--no-verify` | off | Skip the cross-family grounded verifier (debug only) |
| `--no-deterministic` | off | Skip the lint/typecheck/test floor |
| `--dry-run` | off | Render the review but do NOT post it; write to stdout and `/tmp/codex-pr-review-dry-run-*.md` |

## Large PR Support

PRs whose diff exceeds `--chunk-size` are split into chunks and reviewed in parallel:

1. The diff is split using **AST-aware chunking** for Python / TypeScript / Go (chunks snap to function/class boundaries) or hunk-aware AWK chunking for everything else. Set `--chunker hunk` to force the legacy AWK splitter; `--chunker ast` to force AST.
2. Each chunk is reviewed twice in parallel — once by Codex (`codex exec`) and once by Claude (`claude --print`). Both reviewers see the same chunk plus a per-chunk *neighbors* manifest (cross-chunk symbol index) so they don't false-flag forward references as "undefined."
3. Every LLM finding is then verified by the *other* family (Claude — Opus 4.8 by default, `--model-verifier claude-haiku-4-5` for a cheaper run — verifies Codex findings; Codex CLI verifies Claude findings). Refuted findings are dropped; inconclusive findings are escalated to Opus and posted as `[unconfirmed-by-X]` if the escalation also can't confirm.
4. A final synthesis step (Claude Opus by default) deduplicates, generates per-finding suggested fixes, and produces the merged comment.

## v2 — Cross-family verification, deterministic floor, iteration modes

**Agreement labels** appear next to every finding:

- `[both]` — both Codex and Claude flagged it AND the cross-family verifier confirmed.
- `[codex-only]` / `[claude-only]` — single-family finding that the other family's verifier confirmed.
- `[unconfirmed-by-codex]` / `[unconfirmed-by-claude]` — verifier could not confirm or refute (inconclusive). These findings have their priority demoted by 1 and a 0.7× penalty applied to `confidence_score` for display, but the threshold filter checks the pre-penalty `original_confidence_score` so unconfirmed-but-high-confidence findings still surface.
- `[deterministic]` — produced by lint / typecheck / test runs (skips verification because tools don't hallucinate).

**Verdict enum (v2):**

- `correct` — no priority-2+ confirmed findings.
- `needs-changes` — at least one priority-2 confirmed finding.
- `blocking` — at least one priority-3 confirmed finding (or any priority-3 deterministic finding such as a test failure).
- `insufficient information` — synthesis could not compute a verdict (e.g., all chunks failed).

**Deterministic floor.** Reads `.codex-pr-review.toml` (optional), or auto-detects `ruff` / `eslint` / `golangci-lint` / `tsc` / `mypy` from project config files. Runs configured tools on the changed lines and emits findings tagged `[deterministic]`. Configure via:

```toml
# .codex-pr-review.toml at repo root
[deterministic]
lint = "ruff check"
typecheck = "mypy --strict"
tests = "pytest -x --tb=short"
test_files_only = true
```

If no config is detectable, the floor no-ops (with a note on stderr).

**Iteration modes (`--mode`):**

- `initial` — no prior review on this PR (or `--mode initial` forces a clean run).
- `followup-after-fixes` — prior review exists; recent commits look like fixes ("fix:", "address review feedback", etc.). The reviewer assesses which prior findings have been resolved and which persist.
- `delta-since-prior` — prior review exists; new feature commits have arrived. The reviewer scopes its diff to *only* commits since the prior review SHA and carries prior findings forward as `[persisting]` or `[resolved]`. The PR comment shows a `### Resolved since last review` section (struck-through) and a `### Persisting from prior review` section.

`auto` mode (the default) classifies based on `git log $prior_sha..HEAD` commit messages.

## How to Execute This Skill

When this skill is invoked, run the review script:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review.sh" [ARGS]
```

If the path above is not resolved (standalone skill install), use the absolute path:

```bash
bash ~/.claude/skills/codex-pr-review/scripts/review.sh [ARGS]
```

### Interpreting Results

The script outputs JSON to stdout on success containing:

- `verdict` — one of `correct` / `needs-changes` / `blocking` / `insufficient information` (v2 enum).
- `verdict_raw` — the model-emitted verdict before the v1→v2 shim (kept for back-compat).
- `agreement_summary` — counts of `both` / `codex_only` / `claude_only` / `deterministic` / `unconfirmed_by_codex` / `unconfirmed_by_claude`. A high `both` count signals strong cross-family agreement.
- `delta` — for follow-up runs, the `{resolved, persisting, new, regressed}` block.
- `mode` — the iteration mode used (`initial` / `followup-after-fixes` / `delta-since-prior`).
- `review_iteration` — 1 for initial, 2+ for follow-ups.
- `total_findings`, `reported_findings`, `resolved_findings`.

Read the JSON and present a formatted summary to the user. After a successful run, report:

- The verdict (and explain it: `blocking` means the PR shouldn't merge yet; `needs-changes` means fix before merging; `correct` means the patch is clean).
- The agreement summary (e.g., "3 findings flagged by both Codex and Claude, 1 by Claude only").
- The resolved / persisting counts on follow-up runs.
- The PR URL of the posted comment.

If the script exits non-zero, display the error message to the user.

### Error Handling

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success — review posted |
| 1 | Missing prerequisite (codex / claude / gh / jq, or auth not configured) |
| 2 | PR not found, empty diff, or incompatible flag (e.g., `--mode delta` with no prior review) |
| 3 | Codex / Claude execution failed |
| 4 | Failed to post comment |
