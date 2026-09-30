#!/usr/bin/env bash
# scripts/ensure-tree-sitter.sh — SessionStart hook: provision the tree-sitter
# native bindings that plan.js (the AST-aware chunker) needs.
#
# The plugin system copies a marketplace plugin into its cache but runs no
# install step for scripts/package.json (Claude Code's automatic dependency
# install only covers a package.json at the plugin ROOT, runs with
# --ignore-scripts, and has a 60 s cap — none of which suits native modules),
# so without this hook every marketplace install silently ran the hunk
# chunker.
#
# Behavior:
#   - Fast path: if a usable node_modules already exists (data dir or
#     scripts/), exit 0 immediately (one `test -d`).
#   - Installs into ${CLAUDE_PLUGIN_DATA}/node_modules when that variable is
#     set (the documented, update-surviving location) and links
#     scripts/node_modules to it so plan.js finds it with no env plumbing.
#     Falls back to scripts/node_modules (standalone installs, manual runs).
#   - `npm ci` when scripts/package-lock.json is present, else
#     `npm install --omit=dev`.
#   - Fails OPEN: every failure path logs a one-line reason to stderr and
#     exits 0. A SessionStart hook cannot block the session, and a missing
#     chunker only costs AST boundary snapping (plan.js falls back to hunks).
#
# Env: CLAUDE_PLUGIN_ROOT (set by Claude Code for hook processes; falls back
# to this script's parent dir), CLAUDE_PLUGIN_DATA (optional).

set -u

log() { printf 'codex-pr-review: %s\n' "$*" >&2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$script_dir/.." && pwd)}"
scripts_dir="$plugin_root/scripts"
data_dir="${CLAUDE_PLUGIN_DATA:-}"

# A "usable" install has the core binding's package.json in place.
usable() { [[ -f "$1/node_modules/tree-sitter/package.json" ]]; }

if usable "$scripts_dir"; then
  exit 0
fi
if [[ -n "$data_dir" ]] && usable "$data_dir"; then
  # Data dir already provisioned (e.g. after a plugin update replaced the
  # cache dir): just re-link.
  ln -sfn "$data_dir/node_modules" "$scripts_dir/node_modules" 2>/dev/null \
    || log "could not link $scripts_dir/node_modules -> $data_dir/node_modules; plan.js will use CLAUDE_PLUGIN_DATA when set"
  exit 0
fi

if [[ ! -f "$scripts_dir/package.json" ]]; then
  log "no $scripts_dir/package.json; nothing to install"
  exit 0
fi
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  log "node/npm not on PATH; AST chunker disabled (hunk chunker will be used)"
  exit 0
fi
node_major=$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
if [[ -z "$node_major" || "$node_major" -lt 20 ]]; then
  log "node $(node --version 2>/dev/null || echo unknown) is below 20; AST chunker disabled"
  exit 0
fi

# Choose the install directory.
if [[ -n "$data_dir" ]]; then
  install_dir="$data_dir"
  mkdir -p "$install_dir" 2>/dev/null || { log "cannot create $install_dir"; exit 0; }
  cp "$scripts_dir/package.json" "$install_dir/package.json" 2>/dev/null || { log "cannot copy package.json into $install_dir"; exit 0; }
  if [[ -f "$scripts_dir/package-lock.json" ]]; then
    cp "$scripts_dir/package-lock.json" "$install_dir/package-lock.json" 2>/dev/null || true
  fi
else
  install_dir="$scripts_dir"
fi

log_file="$install_dir/npm-install.log"
if [[ -f "$install_dir/package-lock.json" ]]; then
  cmd=(npm ci --no-audit --no-fund --omit=dev)
else
  cmd=(npm install --no-audit --no-fund --omit=dev)
fi

log "installing tree-sitter bindings into $install_dir (${cmd[*]}) ..."
if ! (cd "$install_dir" && "${cmd[@]}") >"$log_file" 2>&1; then
  log "npm install failed; AST chunker disabled (hunk chunker will be used). See $log_file"
  exit 0
fi

if [[ "$install_dir" != "$scripts_dir" ]]; then
  ln -sfn "$install_dir/node_modules" "$scripts_dir/node_modules" 2>/dev/null \
    || log "installed, but could not link $scripts_dir/node_modules -> $install_dir/node_modules"
fi

# Smoke-load the binding so a broken native build is reported now, not
# silently at review time.
if ! (cd "$install_dir" && node -e "require('tree-sitter'); require('tree-sitter-python')") >/dev/null 2>&1; then
  log "tree-sitter installed but failed to load on this platform; AST chunker disabled. See $log_file"
  exit 0
fi

log "tree-sitter bindings ready ($install_dir/node_modules)"
exit 0
