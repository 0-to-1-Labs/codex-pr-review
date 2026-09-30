# Codex PR Review

A Claude Code plugin that reviews pull requests using a **dual-family** AI pipeline — OpenAI Codex (`gpt-6.1-sol`) and Claude (`opus`) run in parallel — with every LLM finding independently verified against source code by the *other* family before being posted. A deterministic floor (lint + typecheck + tests on changed lines) anchors the LLM panel in real tool exit codes.

## What It Does

When you run `/codex-pr-review`, the skill:

1. Detects the PR from your current branch (or takes a PR number/URL, including a URL for another repository).
2. Checks the PR head out into a temporary git worktree. Every later step reads files from that worktree, never from your local checkout.
3. Builds an AST-aware plan + manifest of files, symbols, and per-chunk neighbors so the reviewers don't false-flag forward references.
4. Runs the deterministic floor (lint / typecheck / tests on changed lines) in parallel with the LLM fan-out.
5. For each chunk, runs Codex and Claude in parallel against identical prompts and a structured output schema.
6. For every LLM finding, runs the *other* family's grounded verifier (Claude `opus` for Codex findings; Codex CLI for Claude findings). Refuted findings are dropped; inconclusive findings get one escalation (Claude `fable`, or Codex at high reasoning effort) and are posted as `[unconfirmed-by-X]` if still inconclusive.
7. Synthesizes the merged finding list on Codex (deduplicate, label agreement, generate a suggested fix per finding, compute the v2 verdict).
8. Validates locations deterministically — drops findings whose `(file, line)` does not resolve in the diff (with a `maintainability` exception for unchanged-but-related lines in touched files).
9. Posts a single PR comment with three sections: **Resolved since last review** / **Findings** / **Persisting from prior review**.

Findings are filtered by a configurable confidence threshold (default 0.8) so you only see issues the panel is genuinely certain about.

## Requirements

- [Claude Code](https://code.claude.com/docs/en/overview) **2.1.259 or later** (also serves as the Claude reviewer + verifier; the script checks the version and exits 1 if it is older)
- [Codex CLI](https://github.com/openai/codex) installed (`npm install -g @openai/codex`) and authenticated with `codex login` (ChatGPT account) or `codex login --with-api-key`
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- [jq](https://jqlang.github.io/jq/) installed
- Node.js ≥ 20 (used by the AST-aware chunker for Python / TypeScript / Go)

## Installation

### Plugin marketplace (recommended)

In Claude Code:

```
/plugin marketplace add 0-to-1-Labs/claude-marketplace
/plugin install codex-pr-review@0-to-1-labs
```

Then restart Claude Code. On the first session start the plugin's `SessionStart` hook installs the tree-sitter bindings for the AST chunker (`npm ci` from the committed lockfile, into the plugin's persistent data directory). It exits immediately on later starts, and if the install fails it logs the reason and the review falls back to hunk-mode chunking — it never blocks the session.

### Keep the plugin updated

Claude Code can update this plugin automatically. Auto-update is off by default for third-party marketplaces, so turn it on once:

1. Run `/plugin`.
2. Open the **Marketplaces** tab and select `0-to-1-labs`.
3. Choose **Enable auto-update**.

Claude Code then checks for new versions after each session start and installs them. Restart Claude Code to load an update.

To update by hand:

```
claude plugin marketplace update 0-to-1-labs
claude plugin update codex-pr-review@0-to-1-labs
```

### Alternative: standalone install (no marketplace)

```bash
git clone https://github.com/0-to-1-Labs/codex-pr-review.git
cd codex-pr-review
./install.sh
```

Then restart Claude Code.

## Usage

```
/codex-pr-review                              # Auto-detect PR for current branch
/codex-pr-review 123                          # Review PR #123
/codex-pr-review https://github.com/o/r/pull/7  # Review a PR by URL (any repo you have cloned)
/codex-pr-review --threshold 0.6              # Lower confidence threshold
/codex-pr-review --mode followup              # Force follow-up-after-fixes mode
/codex-pr-review --mode delta                 # Review only commits since the prior review
/codex-pr-review --chunker ast                # Force AST-aware chunking
/codex-pr-review --no-verify                  # Skip the cross-family verifier (debug only)
/codex-pr-review --no-deterministic           # Skip the lint/typecheck/test floor
/codex-pr-review --deterministic-autodetect   # Also run ruff/eslint/golangci-lint/tsc found in the PR tree
/codex-pr-review --dry-run                    # Render the review without posting it
```

### Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `PR_NUMBER` or `PR_URL` | auto-detect | PR to review. A URL is passed to `gh` verbatim, so it may name another repository (the current directory must still be a clone that can fetch that PR's head) |
| `--mode` | `auto` | `auto`, `initial`, `followup`, or `delta` |
| `--threshold` | `0.8` | Confidence threshold (post-verifier) |
| `--model-codex` (alias `--model`) | `gpt-6.1-sol` | Codex reviewer, verifier, and synthesis model. Env: `CODEX_MODEL` |
| `--model-claude` | `opus` | Claude reviewer model (floating alias; pass a full ID to pin) |
| `--model-verifier` | `opus` | Cross-family verifier for Codex findings. `haiku` is the cheap override |
| env `MODEL_VERIFIER_ESCALATION` | `fable` | Model for the one escalation rerun of an inconclusive Claude-side verdict. Skipped when equal to `--model-verifier` |
| `--max-budget-usd` | `2.00` | Spend cap passed to every `claude -p` call |
| `--max-verify-findings` | `40` | Verifier fan-out cap. Findings past it (lowest priority first) post as `[unconfirmed-by-X]` without a verifier call |
| `--chunker` | `auto` | `auto`, `ast`, or `hunk` |
| `--review-rules` | (auto) | Path to override REVIEW.md / CLAUDE.md discovery |
| `--chunk-size` | `3000` | Lines per chunk |
| `--max-parallel` | `4` | Concurrent slots; each slot runs Codex + Claude in parallel |
| `--max-diff-lines` | `0` | Safety truncation cap (0 = unlimited; chunking handles any size) |
| `--no-verify` | off | Skip the cross-family verifier (debug only) |
| `--no-deterministic` | off | Skip the deterministic floor |
| `--deterministic` | off | Run the floor even for cross-repository (fork) PRs |
| `--deterministic-autodetect` | off | Also run ruff / eslint / golangci-lint / tsc when their config files exist in the PR tree |
| `--dry-run` | off | Render the review to stdout and a private temp file; do not post |

Numeric flags are validated before any model call; a bad value exits 2.

## Safety model

The repository under review is untrusted input. A PR can add `.claude/settings.json` hooks, an `.mcp.json`, slash commands, or an `eslint.config.js`. The pipeline is built so none of that runs on your machine:

- **PR-head worktree.** The PR head is checked out into a temporary `git worktree` under a private (0700) work directory and removed on exit. The planner, the deterministic floor, both reviewer families, and both verifiers use it as their working directory.
- **Sandboxed `claude -p`.** Every Claude call runs with `--restricted` (no command-running tools, no user/project/local settings, file tools confined to the worktree), `--tools Read,Grep` (the only built-in tools in context — `--allowedTools` would only pre-approve), `--disallowedTools "mcp__*" --strict-mcp-config` (no MCP servers), `--disable-slash-commands`, `--permission-prompts none` (anything that would prompt is denied), `--no-session-persistence`, and `--max-budget-usd`. This is why Claude Code 2.1.259 is the minimum.
- **Codex** runs with `--sandbox read-only` in the worktree.
- **Deterministic floor.** Tool *commands* come only from the `.codex-pr-review.toml` in your local checkout, never from the PR. Auto-detection of `ruff` / `eslint` / `golangci-lint` / `tsc` is opt-in (`--deterministic-autodetect`) because those tools execute configuration files from the PR tree. Cross-repository (fork) PRs skip the floor unless you pass `--deterministic`.
- **Prior-review state** (`<!-- codex-pr-review:meta ... -->` comments) is trusted only when posted by the authenticated `gh` user, and every value in it is validated (the `sha` must be hex) before it reaches `git`.
- **Posted output.** Model text is escaped so it cannot close the HTML comments that carry the review data, and the prompts instruct both families to treat diff and file contents as data, not instructions, and never to quote files outside the diff.
- Diagnostics (`KEEP_WORKDIR=1`, failure copies, `--dry-run` output) are written to private `mktemp` paths, not fixed world-readable `/tmp` names.

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
*Reviewed by codex-pr-review v2 (codex=gpt-6.1-sol, claude=opus) | Threshold: 0.8 | 4 total findings, 3 reported*

<!-- codex-pr-review:meta v=2 sha=abc123 iteration=2 findings=3 verdict=needs-changes mode=followup-after-fixes prior_sha=def456 -->
```

## v2 — Cross-family verification

**Agreement labels** appear next to every finding:

- `[both]` — both Codex and Claude flagged it AND the cross-family verifier confirmed.
- `[codex-only]` / `[claude-only]` — single-family finding that the other family's verifier confirmed.
- `[unconfirmed-by-codex]` / `[unconfirmed-by-claude]` — verifier could not confirm (inconclusive), or the finding was past the `--max-verify-findings` cap. Priority demoted by 1; `confidence_score *= 0.7` for display (the threshold filter uses the pre-penalty score).
- `[deterministic]` — produced by lint / typecheck / test runs (skips verification because tools don't hallucinate).

**Verdict enum:** `correct` / `needs-changes` / `blocking` / `insufficient information`.

Mapping: any priority-3 confirmed (or deterministic) finding → `blocking`; any priority-2 confirmed → `needs-changes`; otherwise → `correct`.

Every finding carries a `category` (`correctness`, `security`, `performance`, `maintainability`, `style`). The location validator drops findings that cite lines outside the diff, except `maintainability` findings in a touched file.

**Deterministic floor.** Configure via `.codex-pr-review.toml` at the root of your local checkout:

```toml
[deterministic]
lint = "ruff check"            # built-in parsers: ruff, eslint, golangci-lint
typecheck = "mypy --strict"    # built-in parsers: tsc, mypy
tests = "pytest -x --tb=short" # any command; non-zero exit → one priority-3 (blocking) finding
test_files_only = true         # append the diff's file paths to the test command
```

A failing `tests` command posts one `[deterministic] [P3]` finding anchored on the diff's first changed line, with the last 30 lines of runner output, which makes the verdict `blocking`. With no config (and no `--deterministic-autodetect`), the floor no-ops with a note on stderr.

## Iteration modes

`auto` (default) classifies each run as one of:

- `initial` — no prior review on this PR.
- `followup-after-fixes` — prior review exists; recent commits look like fixes (`fix:`, `address review feedback`, etc.). The reviewer assesses which prior findings have been resolved and which persist.
- `delta-since-prior` — prior review exists; new feature commits have arrived. The reviewer scopes to *only* commits since the prior review SHA and carries prior findings forward as `[persisting]` or `[resolved]`.

Force a mode with `--mode {initial|followup|delta}`.

## Large PR Support

PRs whose diff exceeds `--chunk-size` are split and reviewed in parallel:

1. **AST-aware chunking** for Python / TypeScript / Go (chunks snap to function/class boundaries; file content is read at the PR head SHA). The `tree-sitter` bindings are installed by the plugin's `SessionStart` hook (marketplace installs) or `install.sh` (standalone) — never by the plugin system itself. If they are missing, `plan.js` says so on stderr and uses the hunk-aware AWK chunker; the run log reports the mode actually used. Manual install: `cd "${CLAUDE_PLUGIN_ROOT}/scripts" && npm ci`.
2. Each chunk has a per-chunk **neighbors manifest** — every symbol referenced in this chunk but defined elsewhere in the PR — so reviewers don't flag forward references as "undefined."
3. Each chunk is reviewed twice in parallel — once by Codex, once by Claude. Failed chunks are retried up to 3 times with exponential backoff. Stderr and prompts of any chunks that ultimately fail are preserved in a private `codex-pr-review-failures.*` temp directory (path printed at exit).
4. The cross-family verifier dispatches per-finding verification jobs in parallel (pool capped at `min(--max-parallel * 2, 8)`, total capped at `--max-verify-findings`).
5. A final synthesis step (Codex) deduplicates, computes the verdict, and emits the merged comment. `--model-claude` does not affect synthesis.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success — review posted |
| 1 | Missing prerequisite (codex / gh / jq, auth not configured, or Claude Code older than 2.1.259) |
| 2 | PR not found, empty diff, bad flag value, or incompatible flag (e.g., `--mode delta` with no prior review) |
| 3 | Codex / Claude execution failed |
| 4 | Failed to post comment |

## Project Structure

```
codex-pr-review/
├── .claude-plugin/plugin.json            # Plugin manifest (v2.1.0)
├── skills/codex-pr-review/SKILL.md       # Claude Code skill definition
├── hooks/hooks.json                      # SessionStart hook → scripts/ensure-tree-sitter.sh
├── install.sh                            # Standalone installer (stages into a temp dir, then atomically swaps into place)
├── README.md
├── CHANGELOG.md
├── LICENSE
├── .codex-pr-review.toml.example         # Deterministic floor config example
├── tests/                                # Hermetic test suite (bash tests/run-all.sh)
└── scripts/
    ├── review.sh                         # Main orchestration script
    ├── ensure-tree-sitter.sh             # Installs tree-sitter bindings (hook + install.sh)
    ├── plan.js                           # AST-aware chunker + manifest builder
    ├── ast-chunk.sh                      # Bash wrapper for plan.js
    ├── chunk-diff.awk                    # Hunk-aware AWK chunker (fallback)
    ├── package.json / package-lock.json  # tree-sitter bindings (npm ci)
    ├── grammars/                         # WASM-fallback placeholder
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
