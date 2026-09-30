# scripts/grammars/

This directory is reserved for vendored tree-sitter grammar artifacts.

## Current state (P1)

We do **not** vendor `.wasm` grammar bytes today. Instead, `plan.js` relies on
the native tree-sitter bindings installed via `scripts/package.json`:

- `tree-sitter` (^0.21.0)
- `tree-sitter-python` (^0.21.0)
- `tree-sitter-typescript` (^0.23.0)
- `tree-sitter-go` (^0.23.0)

`scripts/ensure-tree-sitter.sh` provisions these with `npm ci` from the
committed `scripts/package-lock.json`. The plugin's `SessionStart` hook runs it
on first use (installing into `${CLAUDE_PLUGIN_DATA}` and linking
`scripts/node_modules` to it); `install.sh` runs it for standalone installs.
The native path is more portable than `npx tree-sitter` (no network call at
runtime, no global install required) and roughly 56 MB of node_modules is
acceptable for a developer-tooling skill.

If the install fails or the native binaries cannot load on a given machine,
`plan.js` emits a stderr warning and falls back to the AWK hunk chunker. Reviews
remain functional; only the AST-aware boundary snapping is lost.

## Future-proofing: WASM fallback

If we ever need the WASM path (air-gapped installs, exotic platforms, or
tree-sitter API incompatibilities), drop the following files in this directory:

- `tree-sitter-python.wasm`  (from https://github.com/tree-sitter/tree-sitter-python/releases)
- `tree-sitter-typescript.wasm`  (from https://github.com/tree-sitter/tree-sitter-typescript/releases)
- `tree-sitter-go.wasm`  (from https://github.com/tree-sitter/tree-sitter-go/releases)

`plan.js` does not yet wire WASM loading; the hook would be `web-tree-sitter` +
`Parser.Language.load(wasmPath)`. Add it here and update `loadTreeSitter()` to
prefer the WASM path when present.

Recommended one-liner to fetch grammars (when needed):

```bash
for lang in python typescript go; do
  curl -sLO "https://github.com/tree-sitter/tree-sitter-${lang}/releases/latest/download/tree-sitter-${lang}.wasm"
done
```
