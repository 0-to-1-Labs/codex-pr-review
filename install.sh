#!/usr/bin/env bash
# Codex PR Review Installer
# Installs the Claude Code skill into ~/.claude/skills/

set -euo pipefail

SKILL_NAME="codex-pr-review"
SKILL_DIR="$HOME/.claude/skills/$SKILL_NAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat <<EOF
Usage: install.sh

  Standalone install (no plugin marketplace) into ~/.claude/skills/.
  Installs the dual-family Codex + Claude pipeline: cross-family verifier,
  deterministic floor, AST-aware chunker, iteration modes, location validator.
  Requires node>=20 and Claude Code >= 2.1.259. Copies plan.js, ast-chunk.sh,
  grammars/, location-validator.sh, det-floor.sh, claude-* prompts, verifier-*
  prompts, and .codex-pr-review.toml.example.
EOF
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            echo "Usage: install.sh [-h|--help]" >&2
            exit 1
            ;;
    esac
done

echo "=========================================="
echo "Codex PR Review Installer"
echo "=========================================="
echo

# Check if Claude Code skills directory exists
if [ ! -d "$HOME/.claude/skills" ]; then
    echo "Creating Claude Code skills directory..."
    mkdir -p "$HOME/.claude/skills"
fi

# Check if skill already exists.
if [ -d "$SKILL_DIR" ]; then
    echo "Skill already exists at $SKILL_DIR"
    if [ -t 0 ]; then
        read -p "Overwrite existing installation? (y/N) " -n 1 -r
        echo
        if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
            echo "Installation cancelled."
            exit 0
        fi
    else
        echo "Non-interactive shell detected; proceeding with overwrite."
    fi
fi

# Transactional install: stage everything into a temp dir and only swap it into
# place once every copy has succeeded. A partial failure must never leave the
# user with a half-deleted or half-copied installation.
STAGE_DIR="$SKILL_DIR.tmp.$$"

cleanup_stage() {
    if [ -n "${STAGE_DIR:-}" ] && [ -d "$STAGE_DIR" ]; then
        rm -rf "$STAGE_DIR"
    fi
}
trap cleanup_stage EXIT

# Start from a clean staging directory.
rm -rf "$STAGE_DIR"

# Copy skill files into the staging directory. The skill definition lives in
# skills/codex-pr-review/SKILL.md (the plugin-system location); a standalone
# install has no ${CLAUDE_PLUGIN_ROOT}, so rewrite that variable to the
# install path in the staged copy.
echo "Staging skill files for $SKILL_DIR..."
mkdir -p "$STAGE_DIR/scripts"
SKILL_DIR_VAL="$SKILL_DIR" perl -pe 's/\Q${CLAUDE_PLUGIN_ROOT}\E/$ENV{SKILL_DIR_VAL}/g' \
    "$SCRIPT_DIR/skills/codex-pr-review/SKILL.md" > "$STAGE_DIR/SKILL.md"
cp "$SCRIPT_DIR/scripts/review.sh" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/ensure-tree-sitter.sh" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-prompt.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-output-schema.json" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/chunk-diff.awk" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-chunk-prompt.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-synthesis-prompt.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/codex-followup-context.md" "$STAGE_DIR/scripts/"

echo "Staging helpers (plan.js, ast-chunk.sh, grammars/, det-floor.sh, location-validator.sh, claude-* / verifier-* prompts)..."
cp "$SCRIPT_DIR/scripts/plan.js" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/ast-chunk.sh" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/det-floor.sh" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/det-output-schema.json" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/location-validator.sh" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/claude-chunk-prompt.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/claude-prompt.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/claude-followup-context.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/verifier-codex-prompt.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/verifier-claude-prompt.md" "$STAGE_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/verifier-output-schema.json" "$STAGE_DIR/scripts/"
if [ -f "$SCRIPT_DIR/scripts/package.json" ]; then
    cp "$SCRIPT_DIR/scripts/package.json" "$STAGE_DIR/scripts/"
fi
if [ -f "$SCRIPT_DIR/scripts/package-lock.json" ]; then
    cp "$SCRIPT_DIR/scripts/package-lock.json" "$STAGE_DIR/scripts/"
fi
if [ -d "$SCRIPT_DIR/scripts/grammars" ]; then
    cp -R "$SCRIPT_DIR/scripts/grammars" "$STAGE_DIR/scripts/"
fi
if [ -f "$SCRIPT_DIR/.codex-pr-review.toml.example" ]; then
    cp "$SCRIPT_DIR/.codex-pr-review.toml.example" "$STAGE_DIR/"
fi

# Make scripts executable in the staging directory.
chmod +x "$STAGE_DIR/scripts/review.sh"
chmod +x "$STAGE_DIR/scripts/ensure-tree-sitter.sh" 2>/dev/null || true
chmod +x "$STAGE_DIR/scripts/ast-chunk.sh" 2>/dev/null || true
chmod +x "$STAGE_DIR/scripts/det-floor.sh" 2>/dev/null || true
chmod +x "$STAGE_DIR/scripts/location-validator.sh" 2>/dev/null || true

# Atomically swap staged install into place now that every copy succeeded.
echo "Installing skill files to $SKILL_DIR..."
rm -rf "$SKILL_DIR"
mv "$STAGE_DIR" "$SKILL_DIR"

# Check prerequisites
echo
echo "Checking prerequisites..."

MISSING=()

if ! command -v codex &>/dev/null; then
    MISSING+=("codex CLI")
fi

if ! command -v gh &>/dev/null; then
    MISSING+=("gh CLI")
fi

if ! command -v jq &>/dev/null; then
    MISSING+=("jq")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo
    echo "=========================================="
    echo "Missing prerequisites:"
    echo "=========================================="
    for m in "${MISSING[@]}"; do
        case "$m" in
            "codex CLI")
                echo "  - codex CLI: npm install -g @openai/codex"
                ;;
            "gh CLI")
                echo "  - gh CLI: brew install gh"
                ;;
            "jq")
                echo "  - jq: brew install jq"
                ;;
        esac
    done
    echo
else
    echo "  All prerequisites found."
fi

# Soft prereqs for the AST chunker + dual-family pipeline.
echo
echo "Checking optional prerequisites..."
if command -v node &>/dev/null; then
    # Extract the node major version. A no-match leaves NODE_MAJOR empty
    # (sed succeeds with no substitution), so guard for empty / non-numeric
    # explicitly — mirroring scripts/review.sh's defensive check.
    NODE_MAJOR=$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
    if [[ -z "$NODE_MAJOR" || ! "$NODE_MAJOR" =~ ^[0-9]+$ ]]; then
        echo "  Warning: could not parse node version ($(node --version 2>/dev/null || echo 'unknown')); treating as below v20. plan.js may not work."
    elif [ "$NODE_MAJOR" -lt 20 ]; then
        echo "  Warning: node $(node --version) is below the required v20. plan.js may not work."
    else
        echo "  node $(node --version) OK."
    fi
else
    echo "  Warning: node not found. plan.js (AST chunker) will fall back to AWK."
fi
if command -v claude &>/dev/null; then
    echo "  claude CLI present ($(claude --version 2>/dev/null | head -1)). Minimum for this plugin: 2.1.259."
else
    echo "  Warning: claude CLI not found. The dual-family review will not work."
    echo "    Install: https://code.claude.com/docs/en/overview"
fi

# If node is present and we have a package.json, install dependencies into
# the skill directory so plan.js can require tree-sitter at runtime. Same
# script the plugin's SessionStart hook runs (fails open with a reason).
if command -v node &>/dev/null && [ -f "$SKILL_DIR/scripts/package.json" ]; then
    echo "  Installing tree-sitter native bindings (this may take a minute)..."
    CLAUDE_PLUGIN_ROOT="$SKILL_DIR" bash "$SKILL_DIR/scripts/ensure-tree-sitter.sh"
fi

# Check codex authentication
echo
echo "Checking Codex authentication..."
if command -v codex &>/dev/null; then
    if codex login status &>/dev/null 2>&1; then
        echo "  Codex is authenticated."
    else
        echo
        echo "=========================================="
        echo "Codex not authenticated"
        echo "=========================================="
        echo
        echo "Run: codex login                    (ChatGPT account)"
        echo "or:  codex login --with-api-key     (reads OPENAI_API_KEY from stdin)"
        echo
    fi
fi

# Success message
echo
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo
echo "The $SKILL_NAME skill is now installed."
echo "Restart Claude Code, then use it with:"
echo
echo "  /codex-pr-review                  # Auto-detect PR for current branch"
echo "  /codex-pr-review 123              # Review PR #123"
echo "  /codex-pr-review --threshold 0.6  # Lower confidence threshold"
echo
echo "Files installed to: $SKILL_DIR"
echo
