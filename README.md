# Codex PR Review

A Claude Code skill that reviews pull requests using a **dual-family** AI pipeline — OpenAI Codex (`gpt-5.6-sol`) and Claude Opus run in parallel — with every LLM finding independently verified against source code by the *other* family before being posted. A deterministic floor (lint + typecheck + tests on changed lines) anchors the LLM panel in real tool exit codes.

## What It Does

When you run `/codex-pr-review`, the skill:

1. Detects the PR from your current branch (or takes a PR number/URL).
2. Builds an AST-aware plan + manifest of files, symbols, and per-chunk neighbors so the reviewers don't false-flag forward references.
3. Runs the deterministic floor (lint / typecheck / tests on changed lines) in parallel with the LLM fan-out.
4. For each chunk, runs Codex and Claude in parallel against identical prompts and a structured output schema.
5. For every LLM finding, runs the *other* family's grounded verifier (Claude — Opus 4.8 by default, override with `--model-verifier claude-haiku-4-5` — for Codex findings; Codex CLI for Claude findings). Refuted findings are dropped; inconclusive findings are escalated to Opus then posted with `[unconfirmed]`.
6. Synthesizes the merged finding list (deduplicate, label agreement, generate suggested fix per finding, compute v2 verdict).
7. Validates locations deterministically — drops findings whose `(file, line)` does not resolve in the diff (with a maintainability exception for unchanged-but-related lines).
8. Posts a single PR comment with three sections: **Resolved since last review** / **Findings** / **Persisting from prior review**.

Findings are filtered by a configurable confidence threshold (default 0.8) so you only see issues the panel is genuinely certain about.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed (also serves as the Claude reviewer + verifier)
- [Codex CLI](https://github.com/openai/codex) installed (`npm install -g @openai/codex`) and authenticated via OAuth (`codex login`)
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- [jq](https://jqlang.github.io/jq/) installed
- Node.js ≥ 18 (used by the AST-aware chunker for Python / TypeScript / Go)

## Installation

### Plugin marketplace (recommended)

In Claude Code:

```
/plugin marketplace add 0-to-1-Labs/claude-marketplace
/plugin install codex-pr-review@0-to-1-labs
```

Then restart Claude Code. `/plugin update codex-pr-review@0-to-1-labs` handles upgrades.

### Alternative: standalone install (no marketplace)

```bash
git clone https://github.com/johnpsasser/codex-pr-review.git
cd codex-pr-review
./install.sh
```

Then restart Claude Code.

## Usage

```
/codex-pr-review                              # Auto-detect PR for current branch
/codex-pr-review 123                          # Review PR #123
/codex-pr-review --threshold 0.6              # Lower confidence threshold
/codex-pr-review --mode followup              # Force follow-up-after-fixes mode
/codex-pr-review --mode delta                 # Review only commits since the prior review
/codex-pr-review --chunker ast                # Force AST-aware chunking
/codex-pr-review --no-verify                  # Skip the cross-family verifier (debug only)
/codex-pr-review --no-deterministic           # Skip the lint/typecheck/test floor
```

### Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `PR_NUMBER` or `PR_URL` | auto-detect | PR to review |
| `--mode` | `auto` | `auto`, `initial`, `followup`, or `delta` |
| `--threshold` | `0.8` | Confidence threshold (post-verifier) |
| `--model-codex` (alias `--model`) | `gpt-5.6-sol` | Codex reviewer model |
| `--model-claude` | `claude-opus-4-8` | Claude reviewer + synthesizer model |
| `--model-verifier` | `claude-opus-4-8` | Default cross-family verifier (override with `claude-haiku-4-5` for cheaper, more deferential verification) |
| `--chunker` | `auto` | `auto`, `ast`, or `hunk` |
| `--review-rules` | (auto) | Path to override REVIEW.md / CLAUDE.md discovery |
| `--chunk-size` | `3000` | Lines per chunk |
| `--max-parallel` | `4` | Concurrent slots; each slot runs Codex + Claude in parallel |
| `--max-diff-lines` | `0` | Safety truncation cap (0 = unlimited; chunking handles any size) |
| `--no-verify` | off | Skip the cross-family verifier (debug only) |
| `--no-deterministic` | off | Skip the deterministic floor |

## Output Format (v2 §4.7)

```markdown
## Codex PR Review v2 — Iteration 2 (follow-up)

**Verdict:** needs-changes (confidence 0.86)

### Resolved since last review (2)
- ~~`api/handler.go:142` — race condition on session map~~
- ~~`tests/test_auth.py:55` — assertion always true~~

### Findings (3)

#### [both] [P3] `api/handler.go:88` — unchecked nil deref
> Both Codex and Claude flagged this. Verifier confirmed against source.
>
> The `session` returned by `getSession` is dereferenced without nil-check at line 91.
>
> **Suggested fix:** add `if session == nil { return errSessionExpired }` immediately after the assignment.

#### [deterministic] [P2] `api/handler.go:142` — golangci-lint: ineffassign
> Variable `result` assigned but never used.
>
> **Suggested fix:** remove the assignment or use the value.

#### [unconfirmed-by-codex] [P1] `api/handler.go:201` — minor: redundant log statement
> Claude flagged this; Codex could not confirm against source.

### Persisting from prior review (1)
- [persisting] [P2] `api/handler.go:88` — same nil deref, not addressed.

---
*Reviewed by codex-pr-review v2 (codex=gpt-5.6-sol, claude=claude-opus-4-8) | Threshold: 0.8 | 4 total findings, 3 reported*

<!-- codex-pr-review:meta v=2 sha=abc123 iteration=2 findings=3 verdict=needs-changes mode=followup-after-fixes prior_sha=def456 -->
```

## v2 — Cross-family verification

**Agreement labels** appear next to every finding:

- `[both]` — both Codex and Claude flagged it AND the cross-family verifier confirmed.
- `[codex-only]` / `[claude-only]` — single-family finding that the other family's verifier confirmed.
- `[unconfirmed-by-codex]` / `[unconfirmed-by-claude]` — verifier could not confirm (inconclusive). Priority demoted by 1; `confidence_score *= 0.7`.
- `[deterministic]` — produced by lint / typecheck / test runs (skips verification because tools don't hallucinate).

**Verdict enum:** `correct` / `needs-changes` / `blocking` / `insufficient information`.

Mapping: any priority-3 confirmed (or deterministic) finding → `blocking`; any priority-2 confirmed → `needs-changes`; otherwise → `correct`.

**Deterministic floor.** Configure via `.codex-pr-review.toml` at the repo root:

```toml
[deterministic]
lint = "ruff check"
typecheck = "mypy --strict"
tests = "pytest -x --tb=short"
test_files_only = true
```

If no config is detectable, the floor no-ops (with a note on stderr) — no surprise tool runs.

## Iteration modes

`auto` (default) classifies each run as one of:

- `initial` — no prior review on this PR.
- `followup-after-fixes` — prior review exists; recent commits look like fixes (`fix:`, `address review feedback`, etc.). The reviewer assesses which prior findings have been resolved and which persist.
- `delta-since-prior` — prior review exists; new feature commits have arrived. The reviewer scopes to *only* commits since the prior review SHA and carries prior findings forward as `[persisting]` or `[resolved]`.

Force a mode with `--mode {initial|followup|delta}`.

## Large PR Support

PRs whose diff exceeds `--chunk-size` are split and reviewed in parallel:

1. **AST-aware chunking** for Python / TypeScript / Go (chunks snap to function/class boundaries; `tree-sitter` bindings installed via npm into `scripts/node_modules/` during install). Hunk-aware AWK chunking is the fallback for everything else.
2. Each chunk has a per-chunk **neighbors manifest** — every symbol referenced in this chunk but defined elsewhere in the PR — so reviewers don't flag forward references as "undefined."
3. Each chunk is reviewed twice in parallel — once by Codex, once by Claude. Failed chunks are retried up to 3 times with exponential backoff. Stderr and prompts of any chunks that ultimately fail are preserved in `/tmp/codex-pr-review-failures-*`.
4. The cross-family verifier dispatches per-finding verification jobs in parallel (capped at `min(--max-parallel * 2, 8)`).
5. A final synthesis step (Claude Opus) deduplicates, computes the verdict, and emits the merged comment.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success — review posted |
| 1 | Missing prerequisite (codex / claude / gh / jq, or auth not configured) |
| 2 | PR not found, empty diff, or incompatible flag (e.g., `--mode delta` with no prior review) |
| 3 | Codex / Claude execution failed |
| 4 | Failed to post comment |

## Project Structure

```
codex-pr-review/
├── SKILL.md                              # Claude Code skill definition (v2.0.0)
├── install.sh                            # Installer (stages into a temp dir, then atomically swaps into place)
├── README.md
├── CHANGELOG.md
├── LICENSE
├── SPEC_V2.md                            # Architecture spec
├── IMPLEMENTATION_PLAN.md                # Phased delivery plan
├── .codex-pr-review.toml.example         # Deterministic floor config example
└── scripts/
    ├── review.sh                         # Main orchestration script
    ├── plan.js                           # AST-aware chunker + manifest builder
    ├── ast-chunk.sh                      # Bash wrapper for plan.js
    ├── chunk-diff.awk                    # Hunk-aware AWK chunker (fallback)
    ├── grammars/                         # WASM-fallback placeholder; tree-sitter bindings install via npm into scripts/node_modules/
    ├── det-floor.sh                      # Deterministic lint/typecheck/test floor
    ├── det-output-schema.json
    ├── location-validator.sh             # Post-synthesis deterministic filter
    ├── codex-prompt.md
    ├── codex-chunk-prompt.md
    ├── codex-synthesis-prompt.md
    ├── codex-followup-context.md
    ├── codex-output-schema.json
    ├── claude-prompt.md
    ├── claude-chunk-prompt.md
    ├── claude-followup-context.md
    ├── verifier-codex-prompt.md
    ├── verifier-claude-prompt.md
    └── verifier-output-schema.json
```

## License

MIT
