# Changelog

## v2.1.0 — 2026-09-30

Security audit release. Every `claude -p` subprocess is now sandboxed, the
whole pipeline runs against a worktree at the PR head, the promised `tests`
and `mypy` floors exist, marketplace installs get the AST chunker, and the
models track the current generation. Also folds in the post-2.0.0 fixes
that shipped as 2.0.1 (listed under "2.0.1 fixes" below).

### Security

- **`claude -p` runs in restricted mode.** Every Claude call passes
  `--restricted --tools Read,Grep --disallowedTools "mcp__*"
  --strict-mcp-config --disable-slash-commands --permission-prompts none
  --no-session-persistence --max-budget-usd`. The reviewed repository's
  `.claude/settings.json` hooks, `.mcp.json` servers, and slash commands no
  longer run, and only Read/Grep exist in the model's tool set
  (`--allowedTools` only pre-approved; it did not restrict, and the default
  tool set omits Grep). Claude Code **2.1.259** is now the minimum; the
  script checks the version and exits 1 with an upgrade message.
- **PR-head worktree.** The PR head is checked out into a temporary
  `git worktree` (removed on exit) and the planner, deterministic floor, both
  reviewers, and both verifiers use it as their working directory. Reviews
  no longer depend on what is checked out locally.
- **Deterministic floor is no longer PR-controlled.** Lint/typecheck
  auto-detection is opt-in (`--deterministic-autodetect`) because
  `eslint.config.js`, `tsconfig.json`, and friends execute code from the PR.
  Cross-repository (fork) PRs skip the floor unless `--deterministic` is
  passed. `.codex-pr-review.toml` is read from the local checkout only.
- **Prior-review sentinel validated.** Only comments by the authenticated
  `gh` user (or, failing that, not by the PR author) are trusted;
  `sha`/`prior_sha` must match `^[0-9a-f]{7,40}$`, `iteration`/`findings`
  must be integers. Previously any commenter could set the iteration counter,
  inject "prior findings" into every prompt, and pass a git option such as
  `--output=<path>` as the revision.
- **Posted comment escaping.** `<!--` / `-->` in model-derived text are
  escaped in the rendered comment, and `-->` inside the embedded JSON block
  becomes `-->`, so a finding body cannot close the HTML comments that
  carry the sentinel and review data.
- **Untrusted-content rule in every prompt.** Reviewers and verifiers are told
  the diff, file contents, manifest, and rules are data, not instructions,
  and never to quote files outside the diff.
- **Private diagnostics.** Failure copies and `--dry-run` output go to
  `mktemp` paths created under `umask 077` instead of fixed world-readable
  `/tmp` names.

### Added

- **`tests` floor and `mypy` parser.** `tests = "<cmd>"` now runs: a non-zero
  exit posts one `[deterministic] [P3]` finding anchored on the diff's first
  changed line with the last 30 lines of output (so the `blocking` verdict
  rule for test failures can fire). `typecheck = "mypy ..."` output is
  parsed (`path:line: error: msg`). `test_files_only` is honored.
- **`SessionStart` hook installs tree-sitter.** `hooks/hooks.json` runs
  `scripts/ensure-tree-sitter.sh` (`npm ci` from the committed
  `scripts/package-lock.json` into `${CLAUDE_PLUGIN_DATA}`, linked from
  `scripts/node_modules`). Fast when already installed, fails open with a
  logged reason, never blocks the session. Marketplace installs previously
  never had the AST chunker, silently.
- **`category` on every finding** (`correctness` / `security` / `performance`
  / `maintainability` / `style`) in the output schema and prompts, so the
  location validator's documented maintainability exception is reachable.
- **Cost bounds.** `--max-budget-usd` (default 2.00) per `claude -p` call and
  `--max-verify-findings` (default 40) cap on the verifier fan-out.
- **Flags:** `--deterministic`, `--deterministic-autodetect`,
  `--max-budget-usd`, `--max-verify-findings`; env `CODEX_MODEL`.
- **CI** runs on Node 22, installs with `npm ci`, and asserts the AST chunker
  actually engages (`chunker_mode == "ast"`), plus `bash -n` / `node --check`
  / shellcheck.

### Changed

- **Models.** Claude reviewer and verifier default to the floating `opus`
  alias, escalation to `fable`, cheap override `haiku`. Codex defaults to
  `gpt-6.1-sol` (Codex CLI's current default). Escalation is skipped when it
  names the same model as the primary verifier (it was a 2x-cost same-model
  retry); Codex-side escalation now passes `model_reasoning_effort=high`.
- **Synthesis runs on Codex** — the docs now say so; `--model-claude` never
  affected it.
- **Missing `claude` CLI** degrades to the raw union (`verifier_verdict:
  n/a`) instead of a failed verifier subprocess per finding that demoted
  every Codex finding to `[unconfirmed-by-claude]`.
- **PR URLs are passed to `gh` verbatim**, so a URL for another repository
  reviews (and comments on) that repository's PR.
- **Numeric flags are validated** (`--threshold`, `--chunk-size`,
  `--max-parallel`, `--max-diff-lines`, `--max-budget-usd`,
  `--max-verify-findings`) before any model call; a bad value exits 2.
- **Codex auth wording.** `codex exec` works with a ChatGPT login or
  `codex login --with-api-key`; the "requires OAuth, not an API key" claim
  was wrong.
- **`claude -p` prompt.** A short real prompt replaces the undocumented bare
  `-`; the prompt file still arrives on stdin and is refused above the
  documented 10 MB cap.
- **Verifier file names include the source family** so a `[both]` pair no
  longer races on the same verdict file.
- **`plan.js` gets `--head-sha`** on the main path and warns in `auto` mode
  when tree-sitter is not loadable; the run log reports the real chunker mode.
- **Root `SKILL.md` removed.** The single copy is
  `skills/codex-pr-review/SKILL.md` (trimmed to execution guidance;
  `allowed-tools` narrowed to the review script). `install.sh` copies it
  from there and rewrites `${CLAUDE_PLUGIN_ROOT}` for standalone installs.
- **Dependencies.** `scripts/package-lock.json` is committed; `npm ci`
  replaces `npm install --legacy-peer-deps`; Node floor is 20 (18 is
  end-of-life).
- **Repository moved** to `github.com/0-to-1-Labs/codex-pr-review`.

### 2.0.1 fixes (previously unreleased)

- **Default models bumped to the current generation.** The Codex reviewer
  defaulted to `gpt-5.6-sol` (was `gpt-5.3-codex`), and the Claude reviewer,
  verifier, and escalation verifier to `claude-opus-4-8` (was
  `claude-opus-4-7`). Superseded by the alias defaults above.
- **Plugin marketplace install** instructions and `${CLAUDE_PLUGIN_ROOT}` in
  the skill's run command.

#### Fixes

- **Verifier reads files at the PR head SHA, not local HEAD.** The cross-family
  grounded verifier now fetches the file contents at the PR's head commit rather
  than whatever happens to be checked out locally, so verification is grounded
  in the code under review.
- **Read `.structured_output` from the claude CLI envelope.** The Claude-side
  verifier/reviewer output is wrapped in a CLI envelope; the parser now reads
  `.structured_output` from it instead of mis-parsing the envelope itself.
- **Capture `verifier_evidence` on findings.** Each finding now carries the
  verifier's evidence string as a diagnostic so it's possible to see *why* a
  finding was confirmed, refuted, or left inconclusive.
- **Confidence threadthrough finished.** Rendering and the stdout summary now use
  `original_confidence_score` (the pre-penalty value) consistently, matching the
  threshold filter so unconfirmed-but-high-confidence findings still surface.
- **Threshold-vs-penalty double-jeopardy fixed; Opus is the default verifier.**
  The `0.7×` penalty for `[unconfirmed-by-X]` findings is now applied only for
  display, and the threshold filter checks the pre-penalty score (no double
  penalty). The default `--model-verifier` moved to the Opus tier
  (the Haiku tier remains a cheaper override).

#### Audit fixes (installer + docs)

- **Installer hardening.** `install.sh` now runs under `set -euo pipefail`,
  installs transactionally (stages into a temp dir and atomically swaps into
  place so a partial failure never destroys the existing install), guards the
  node major-version parse against empty/non-numeric output, and tees
  `npm install` output to `scripts/npm-install.log` for debuggability.
- **Removed the fictional v1 rollback.** `install.sh --version 1` previously
  claimed to roll back to a v1 pipeline but only copied the current (v2)
  `review.sh` after deleting its own backup; there is no v1 source in the repo.
  The `--version` flag and all rollback claims have been removed from the
  installer and docs.
- **Doc corrections.** README's `--model-verifier` default corrected; the
  "vendored grammars" claim corrected to "tree-sitter bindings installed via
  npm into `scripts/node_modules/`"; and "silently no-ops" corrected to
  "no-ops (with a note on stderr)" to match `det-floor.sh`.

## v2.0.0 — 2026-05-05

The v2 release ships the dual-family pipeline (Codex + Claude Opus), the cross-family grounded verifier, AST-aware chunking, the deterministic floor, three iteration modes (initial / followup-after-fixes / delta-since-prior), and the post-synthesis location validator.

### Breaking changes

- **`overall_correctness` enum changed.** The output schema's `overall_correctness` field now uses the v2 enum:
  - `correct`
  - `needs-changes`
  - `blocking`
  - `insufficient information`
  - The v1 values (`patch is correct` / `patch is incorrect`) are no longer accepted by the schema. Downstream callers that string-match the verdict must update their checks.
  - **Compatibility shim:** `format_comment()` maps any v1 verdict it sees to the v2 enum at render time, so a v1-shaped Codex output flowing through v2 (e.g., a `--no-verify` debug run) still produces correctly-rendered output.
- **`suggested_fix` is now required on every finding.** The synthesis step generates this field from the verifier metadata. Downstream callers that read findings and don't tolerate a new required field need to update.

### New features

- **Dual-family review.** Codex (`gpt-5.3-codex`) and Claude Opus (`claude-opus-4-7`) review every chunk in parallel. `--max-parallel` defaults to 4 (was 6 in v1) so the doubled per-chunk concurrency stays inside Codex CLI's process limits.
- **Cross-family grounded verifier.** Every LLM finding is verified by the *other* family's grounded verifier (Claude Haiku 4.5 verifies Codex findings; Codex CLI verifies Claude findings). Refuted findings are dropped; inconclusive findings escalate to Opus, then post as `[unconfirmed-by-X]` if escalation also can't confirm. `--no-verify` bypasses verification (debug only).
- **AST-aware chunker** for Python / TypeScript / Go via tree-sitter bindings installed via npm into `scripts/node_modules/` during install. Snaps chunk boundaries to function/class boundaries instead of mid-hunk. Hunk-aware AWK chunker remains the fallback.
- **Per-chunk neighbors manifest** — every symbol referenced in a chunk but defined elsewhere in the PR is listed for the reviewer, eliminating cross-chunk "undefined symbol" false positives.
- **Deterministic floor.** Lint / typecheck / test runs on changed lines, configurable via `.codex-pr-review.toml`. Findings tagged `[deterministic]`; skip the cross-family verifier (tools don't hallucinate).
- **Iteration modes.** `--mode auto|initial|followup|delta`. Default `auto` classifies each run via `git log $prior_sha..HEAD` commit messages. Delta mode reviews only commits since the prior review SHA.
- **Location validator.** Deterministic post-synthesis filter (`scripts/location-validator.sh`) drops findings whose `(file, line)` does not resolve in the diff, with a maintainability exception for findings that cite unchanged-but-related lines in touched files. Below-threshold and empty-body findings are also dropped.
- **Agreement labels** in the PR comment: `[both]` / `[codex-only]` / `[claude-only]` / `[deterministic]` / `[unconfirmed-by-codex]` / `[unconfirmed-by-claude]`.
- **v2 sentinel** `<!-- codex-pr-review:meta v=2 sha=... iteration=... findings=... verdict=... mode=... prior_sha=... -->` is the primary iteration-tracking signal. The legacy `CODEX_REVIEW_DATA_START/END` JSON block is preserved for back-compat with prior PR comments.
- **Synthesis prompt rewrite (P5).** Synthesis is now a pure merge/dedupe/label step — explicitly forbidden from re-reading the diff to discover new findings (the v1 hallucination root cause). The prompt's CRITICAL CONSTRAINT block enforces this.
- **stdout summary JSON** adds `verdict` (v2 enum), `verdict_raw` (pre-shim), `mode`, `agreement_summary` (per-label counts), and `delta` (for follow-up runs).

### Fixes

- `chunk-diff.awk` mid-hunk split bug: chunks produced by mid-hunk splits now correctly start with the `@@ -a,b +c,d @@` header so reviewers see line-number context.

### Migration path

- **Default install is v2.** `./install.sh` installs the v2 dual-family pipeline. There is no v1 rollback path — the repo no longer ships a v1 pipeline source.
- **PR comments remain bilingual.** v2 comments contain both the v2 sentinel and the legacy `CODEX_REVIEW_DATA_START` block, so older tooling that reads the legacy block still finds it.
- **Schema impact.** Downstream callers that string-match the v1 verdict (`patch is correct` / `patch is incorrect`) must add the v2 mapping (`correct` / `needs-changes` / `blocking` / `insufficient information`). The `tests/test-schema-backcompat.sh` test suite gates this.

## v1.x

See git log up to commit `c37d9d2` for the v1 history. v1 ships a single-Codex pipeline with hunk-aware chunking, a single synthesis call, and a self-verification pass.
