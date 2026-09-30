---
name: codex-pr-review
description: Review a pull request with a dual-family pipeline (OpenAI Codex + Claude) where every LLM finding is verified against source by the other family, plus a deterministic lint/typecheck/test floor. Use when the user wants a high-signal external AI code review, a second opinion on a PR, or a cross-model verified review. Accepts a PR number or URL, or auto-detects the current branch's PR.
license: MIT
metadata:
  author: sasser
  version: 2.1.0
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/review.sh *)
argument-hint: "[PR_NUMBER|PR_URL] [--mode auto|initial|followup|delta] [--threshold FLOAT] [--model-codex MODEL] [--model-claude MODEL] [--model-verifier MODEL] [--max-budget-usd USD] [--max-verify-findings N] [--chunker auto|ast|hunk] [--review-rules PATH] [--max-parallel INT] [--max-diff-lines INT] [--chunk-size INT] [--no-verify] [--no-deterministic] [--deterministic] [--deterministic-autodetect] [--dry-run]"
---

# Codex PR Review (v2)

Reviews a pull request with Codex (`gpt-6.1-sol`) and Claude (`opus`) in parallel per chunk. Every LLM finding is verified against source by the other family before posting. A deterministic floor (lint / typecheck / tests on changed lines) adds tool-grounded findings. Codex also runs the final synthesis (merge, dedupe, label). Full reference: the plugin README.

## How to execute

Run the review script from the repository that contains the PR:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/review.sh [ARGS]
```

Pass the user's PR number or URL and any flags through unchanged. With no PR argument the script auto-detects the PR for the current branch. Do not run a review from a directory that is not a git checkout of the PR's repository.

Prerequisites the script checks itself: `codex` (authenticated with `codex login` or `codex login --with-api-key`), `claude` (Claude Code >= 2.1.259), `gh` (authenticated), `jq`, and Node.js >= 20 for the AST chunker. The tree-sitter bindings for the AST chunker are installed by this plugin's `SessionStart` hook on first use; if the run reports "tree-sitter is not loadable", run `cd "${CLAUDE_PLUGIN_ROOT}/scripts" && npm ci`.

## Safety model

- The reviewed repository is untrusted input. The script checks the PR head out into a temporary git worktree and runs every `claude -p` call with `--restricted`, `--tools Read,Grep`, no MCP servers, no slash commands, and `--permission-prompts none`, so hooks, MCP servers, or commands added by the PR cannot run. Each call is capped by `--max-budget-usd` (default 2.00).
- The deterministic floor runs only the commands in the local checkout's `.codex-pr-review.toml`. `--deterministic-autodetect` also runs ruff / eslint / golangci-lint / tsc when their config files exist in the PR tree; those configs execute code from the PR. Cross-repository (fork) PRs skip the floor unless `--deterministic` is passed.
- `--dry-run` renders the comment without posting it.

## Interpreting results

On success the script prints one JSON object to stdout:

- `verdict` — `correct` / `needs-changes` / `blocking` / `insufficient information`.
- `agreement_summary` — counts of `both`, `codex_only`, `claude_only`, `deterministic`, `unconfirmed_by_codex`, `unconfirmed_by_claude`. A high `both` count signals strong cross-family agreement.
- `mode`, `review_iteration`, `delta` (follow-up runs: `{resolved, persisting, new, regressed}`).
- `total_findings`, `reported_findings`, `resolved_findings`, `pr_url`.

Report to the user: the verdict and what it means (`blocking` = do not merge yet; `needs-changes` = fix before merging; `correct` = clean), the agreement summary in one sentence, the resolved / persisting counts on follow-up runs, and the PR URL of the posted comment. If the script exits non-zero, show its stderr message to the user.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success — review posted (or rendered, with `--dry-run`) |
| 1 | Missing prerequisite, auth not configured, or Claude Code older than 2.1.259 |
| 2 | PR not found, empty diff, or bad flag value |
| 3 | Codex / Claude execution failed |
| 4 | Failed to post comment |
