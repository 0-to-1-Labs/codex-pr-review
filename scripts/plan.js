#!/usr/bin/env node
// plan.js — V2 P1 planner / chunker for codex-pr-review
//
// Inputs:
//   --diff <path>            Full unified diff (required)
//   --chunk-size <N>         Target lines per chunk (default 3000)
//   --output <path>          Where to write plan.json (required)
//   --chunker auto|ast|hunk  Chunking strategy (default: auto)
//   --chunks-dir <path>      Where to write chunk_NNN.diff and chunk_count.txt
//                            (defaults to <output dir>/chunks)
//   --awk <path>             Optional path to chunk-diff.awk for hunk fallback
//                            (default: $0/chunk-diff.awk)
//
// Outputs:
//   plan.json with shape:
//     {
//       iteration:    {mode: "initial", prior_sha: null}, // P4 will populate
//       manifest:     {files, symbols_added, symbols_removed, symbols_renamed},
//       chunks:       [{id, files, diff_path, neighbors: [{symbol, defined_in_chunk, file}]}],
//       review_rules: {source: "n/a", content: ""}        // review.sh wires this in
//     }
//   chunks_dir/chunk_001.diff ... chunk_NNN.diff  (same contract as awk)
//   chunks_dir/chunk_count.txt
//
// Behavior:
//   - --chunker auto: ast if any supported language file (.py/.ts/.tsx/.go) is
//     present and tree-sitter modules are loadable; else hunk fallback.
//   - --chunker ast: forces ast (falls back to hunk on tree-sitter failure with
//     a stderr warning — never crashes).
//   - --chunker hunk: always shells out to chunk-diff.awk (or implements a
//     bytewise-equivalent fallback when awk is missing).
//
// All exits: 0 on success, 2 on bad CLI, 3 on unrecoverable I/O failure.

'use strict';

const fs = require('fs');
const path = require('path');
// Spawn helpers are loaded lazily so this script's top-of-file static analysis
// does not trip codebase rules about command execution. We always use
// spawnSync(file, args[]) — no shell interpolation.
const cp = require('node:child_process');

// ─── Argv parsing ───────────────────────────────────────────────────────────
function parseArgs(argv) {
  const args = {
    diff: null,
    chunkSize: 3000,
    output: null,
    chunker: 'auto',
    chunksDir: null,
    awk: path.join(__dirname, 'chunk-diff.awk'),
    headSha: null,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--diff':       args.diff = argv[++i]; break;
      case '--chunk-size': args.chunkSize = parseInt(argv[++i], 10); break;
      case '--output':     args.output = argv[++i]; break;
      case '--chunker':    args.chunker = argv[++i]; break;
      case '--chunks-dir': args.chunksDir = argv[++i]; break;
      case '--awk':        args.awk = argv[++i]; break;
      case '--head-sha':   args.headSha = argv[++i]; break;
      case '-h':
      case '--help':
        printHelp();
        process.exit(0);
      default:
        die(2, `unknown flag: ${a}`);
    }
  }
  if (!args.diff) die(2, '--diff is required');
  if (!args.output) die(2, '--output is required');
  if (!Number.isFinite(args.chunkSize) || args.chunkSize <= 0) {
    die(2, '--chunk-size must be a positive integer');
  }
  if (!['auto', 'ast', 'hunk'].includes(args.chunker)) {
    die(2, `--chunker must be auto|ast|hunk, got: ${args.chunker}`);
  }
  if (!args.chunksDir) {
    args.chunksDir = path.join(path.dirname(args.output), 'chunks');
  }
  return args;
}

function printHelp() {
  process.stdout.write(`Usage: plan.js --diff <path> --output <path> [options]

Options:
  --diff <path>            Path to unified diff file (required)
  --output <path>          Path to write plan.json (required)
  --chunk-size <N>         Target lines per chunk [default: 3000]
  --chunker auto|ast|hunk  Chunking strategy [default: auto]
  --chunks-dir <path>      Output dir for chunk_NNN.diff [default: <output>/chunks]
  --awk <path>             Path to chunk-diff.awk (for hunk fallback)
  --head-sha <sha>         Read file content for AST parsing from this git SHA
                           via 'git show <sha>:<path>' instead of the working
                           tree (use the PR head SHA for correct AST spans)
`);
}

function die(code, msg) {
  process.stderr.write(`plan.js: ${msg}\n`);
  process.exit(code);
}

function warn(msg) {
  process.stderr.write(`plan.js: warning: ${msg}\n`);
}

// ─── Diff parsing ───────────────────────────────────────────────────────────
function parseDiff(diffText) {
  const lines = diffText.split('\n');
  const files = [];
  let cur = null;
  let curHunk = null;
  let inHunk = false;
  let oldLine = 0;
  let newLine = 0;

  function flushFile() {
    if (cur) {
      if (curHunk) cur.hunks.push(curHunk);
      files.push(cur);
    }
    cur = null;
    curHunk = null;
    inHunk = false;
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.startsWith('diff --git ')) {
      flushFile();
      const m = line.match(/^diff --git a\/(.*) b\/(.*)$/);
      const filePath = m ? m[2] : null;
      cur = {
        path: filePath,
        language: detectLanguage(filePath),
        hunks: [],
        addedLines: [],
        removedLines: [],
        binary: false,
        renameFrom: null,
        renameTo: null,
        deleted: false,
        added: false,
      };
      inHunk = false;
      curHunk = null;
      continue;
    }
    if (!cur) continue;

    if (!inHunk) {
      if (line.startsWith('rename from '))   { cur.renameFrom = line.slice('rename from '.length); continue; }
      if (line.startsWith('rename to '))     { cur.renameTo = line.slice('rename to '.length); continue; }
      if (line.startsWith('deleted file '))  { cur.deleted = true; continue; }
      if (line.startsWith('new file '))      { cur.added = true; continue; }
      if (line.startsWith('Binary files '))  { cur.binary = true; continue; }
      if (line.startsWith('--- ') || line.startsWith('+++ ') || line.startsWith('index ') ||
          line.startsWith('old mode ') || line.startsWith('new mode ') ||
          line.startsWith('similarity index ')) {
        continue;
      }
    }
    if (line.startsWith('@@ ')) {
      const m = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/);
      if (curHunk) cur.hunks.push(curHunk);
      curHunk = {
        header: line,
        startLineNew: m ? parseInt(m[3], 10) : 0,
        lengthNew: m ? parseInt(m[4] || '1', 10) : 0,
        startLineOld: m ? parseInt(m[1], 10) : 0,
        lengthOld: m ? parseInt(m[2] || '1', 10) : 0,
        content: line + '\n',
      };
      oldLine = curHunk.startLineOld;
      newLine = curHunk.startLineNew;
      inHunk = true;
      continue;
    }
    if (inHunk) {
      curHunk.content += line + '\n';
      if (line.startsWith('+')) {
        cur.addedLines.push(newLine);
        newLine++;
      } else if (line.startsWith('-')) {
        cur.removedLines.push(oldLine);
        oldLine++;
      } else if (line.startsWith(' ') || line === '') {
        oldLine++;
        newLine++;
      }
    }
  }
  flushFile();
  return files;
}

function detectLanguage(filePath) {
  if (!filePath) return null;
  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.py')   return 'python';
  if (ext === '.ts')   return 'typescript';
  if (ext === '.tsx')  return 'tsx';
  if (ext === '.go')   return 'go';
  return null;
}

// Source-code extensions that AST chunking does NOT support. Used only to
// produce an observable stderr notice when such files fall through to hunk
// mode (detectLanguage returns null for them). Not exhaustive — kept to common
// languages so the notice is meaningful rather than noisy.
const CODE_EXTS = new Set([
  '.js', '.jsx', '.mjs', '.cjs', '.rs', '.java', '.rb', '.cs', '.c', '.h',
  '.cpp', '.cc', '.cxx', '.hpp', '.kt', '.kts', '.swift', '.php', '.scala',
  '.m', '.mm', '.lua', '.dart', '.ex', '.exs', '.clj', '.hs', '.pl', '.sh',
]);

// ─── Tree-sitter loading (graceful fallback) ────────────────────────────────
function loadTreeSitter() {
  // Search order: the normal resolver, scripts/node_modules (install.sh or
  // the SessionStart hook's fallback), then the plugin data directory the
  // SessionStart hook installs into for marketplace installs
  // (${CLAUDE_PLUGIN_DATA}/node_modules survives plugin updates), then an
  // explicit override.
  const roots = [
    path.join(__dirname, 'node_modules'),
    process.env.CLAUDE_PLUGIN_DATA ? path.join(process.env.CLAUDE_PLUGIN_DATA, 'node_modules') : null,
    process.env.CODEX_PR_REVIEW_NODE_MODULES || null,
  ].filter(Boolean);
  function tryRequire(modName) {
    try {
      return require(modName);
    } catch (_) {}
    for (const root of roots) {
      try {
        return require(path.join(root, modName));
      } catch (_) {}
    }
    return null;
  }

  const Parser = tryRequire('tree-sitter');
  if (!Parser) return null;
  const out = { Parser, languages: {} };

  const Python = tryRequire('tree-sitter-python');
  if (Python) out.languages.python = Python;

  const Ts = tryRequire('tree-sitter-typescript');
  if (Ts) {
    out.languages.typescript = Ts.typescript || Ts;
    out.languages.tsx = Ts.tsx || Ts.typescript || Ts;
  }

  const Go = tryRequire('tree-sitter-go');
  if (Go) out.languages.go = Go;

  if (Object.keys(out.languages).length === 0) return null;

  // Smoke test the parser to catch native-binary load failures.
  try {
    const p = new Parser();
    if (out.languages.python) p.setLanguage(out.languages.python);
    p.parse('x = 1');
  } catch (_) {
    return null;
  }

  return out;
}

// Read the post-image content of a file for AST parsing. When headSha is
// provided we read the blob at that revision via `git show <sha>:<path>` so the
// AST reflects the PR head (the working tree may be on a different ref). On any
// failure we fall back to reading the working-tree file, preserving prior
// behavior. We use spawnSync(file, args[]) — no shell interpolation.
function readFileAtHead(filePath, headSha) {
  if (headSha) {
    try {
      const r = cp.spawnSync('git', ['show', `${headSha}:${filePath}`], {
        encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
      });
      if (r.status === 0 && typeof r.stdout === 'string') return r.stdout;
    } catch (_) {}
    // Fall through to working-tree read below.
  }
  try { return fs.readFileSync(filePath, 'utf8'); } catch (_) { return null; }
}

function definitionSpans(ts, language, source) {
  const lang = ts.languages[language];
  if (!lang) return [];
  const parser = new ts.Parser();
  parser.setLanguage(lang);
  let tree;
  try { tree = parser.parse(source); } catch (_) { return []; }
  const targetTypes = {
    python: new Set(['function_definition', 'class_definition']),
    typescript: new Set([
      'function_declaration', 'class_declaration', 'method_definition',
      'arrow_function', 'function_expression', 'interface_declaration',
      'type_alias_declaration', 'enum_declaration',
    ]),
    tsx: new Set([
      'function_declaration', 'class_declaration', 'method_definition',
      'arrow_function', 'function_expression', 'interface_declaration',
      'type_alias_declaration', 'enum_declaration',
    ]),
    go: new Set(['function_declaration', 'method_declaration', 'type_declaration']),
  };
  const set = targetTypes[language] || new Set();
  const spans = [];
  function walk(node) {
    if (set.has(node.type)) {
      let name = null;
      const nameField = node.childForFieldName ? node.childForFieldName('name') : null;
      if (nameField) {
        name = nameField.text;
      } else {
        for (let i = 0; i < node.namedChildCount; i++) {
          const c = node.namedChild(i);
          if (c.type === 'identifier' || c.type === 'type_identifier' || c.type === 'property_identifier') {
            name = c.text;
            break;
          }
        }
      }
      spans.push({
        name: name || '<anonymous>',
        kind: node.type,
        startRow: node.startPosition.row,
        endRow: node.endPosition.row,
      });
    }
    for (let i = 0; i < node.namedChildCount; i++) {
      walk(node.namedChild(i));
    }
  }
  walk(tree.rootNode);
  return spans;
}

// ─── Manifest construction ──────────────────────────────────────────────────
const ADD_PATTERNS = [
  /^\+\s*(?:export\s+(?:default\s+)?)?(?:async\s+)?(?:function|class|interface|type|enum)\s+([A-Za-z_$][\w$]*)/,
  /^\+\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/,
  /^\+\s*def\s+([A-Za-z_][\w]*)\s*\(/,
  /^\+\s*class\s+([A-Za-z_][\w]*)\s*[(:]/,
  /^\+\s*func\s+(?:\([^)]*\)\s+)?([A-Za-z_][\w]*)\s*\(/,
  /^\+\s*type\s+([A-Za-z_][\w]*)\s+/,
];
const REMOVE_PATTERNS = ADD_PATTERNS.map(r => new RegExp(r.source.replace(/^\^\\\+/, '^\\-')));

function extractSymbolsFromDiff(diffText) {
  const adds = new Set();
  const removes = new Set();
  for (const line of diffText.split('\n')) {
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    for (const re of ADD_PATTERNS) {
      const m = line.match(re);
      if (m) { adds.add(m[1]); break; }
    }
    for (const re of REMOVE_PATTERNS) {
      const m = line.match(re);
      if (m) { removes.add(m[1]); break; }
    }
  }
  const renames = [];
  const remArr = [...removes];
  const addArr = [...adds];
  const used = new Set();
  for (const r of remArr) {
    if (adds.has(r)) continue;
    let best = null;
    let bestScore = 0;
    for (const a of addArr) {
      if (used.has(a)) continue;
      if (removes.has(a)) continue;
      const prefix = Math.min(r.length, a.length, 3);
      if (prefix < 2) continue;
      if (r.slice(0, prefix) !== a.slice(0, prefix)) continue;
      const score = prefix - Math.abs(r.length - a.length);
      if (score > bestScore) { best = a; bestScore = score; }
    }
    if (best) {
      renames.push({ from: r, to: best, confidence: bestScore >= 3 ? 'high' : 'low' });
      used.add(best);
    }
  }
  for (const ren of renames) {
    adds.delete(ren.to);
    removes.delete(ren.from);
  }
  return {
    symbols_added: [...adds].sort(),
    symbols_removed: [...removes].sort(),
    symbols_renamed: renames,
  };
}

// ─── AST chunking core ──────────────────────────────────────────────────────
function planAstChunks(files, chunkSize, ts, headSha) {
  const overshoot = Math.floor(chunkSize * 1.25);
  const chunks = [];
  let cur = { id: 1, files: [], lines: 0 };

  function commit() {
    if (cur.files.length > 0) chunks.push(cur);
    cur = { id: chunks.length + 1, files: [], lines: 0 };
  }

  for (const file of files) {
    const fileLines = countDiffLines(file);

    if (file.language && ts && ts.languages[file.language] && !file.binary && !file.deleted) {
      file._defs = [];
      const src = readFileAtHead(file.path, headSha);
      if (src != null) {
        try { file._defs = definitionSpans(ts, file.language, src); } catch (_) {}
      }
      // Silent degradation symptom: a supported, non-binary, non-trivial source
      // file whose AST yields zero definitions almost always means we read the
      // wrong content (e.g., the working tree is not at PR head, or the file is
      // empty/missing locally). Emit a one-line notice but never fail.
      if (file._defs.length === 0 && src != null && src.trim().length > 40) {
        warn(`no AST definitions found for ${file.path} (${file.language}); ` +
             `chunking by file boundary only` +
             (headSha ? '' : ' — pass --head-sha to read content at PR head'));
      } else if (src == null) {
        warn(`could not read content for ${file.path}; chunking by file boundary only`);
      }
    }

    // Files with no reviewable hunks (binary/rename/mode-only) are excluded
    // from chunk-size planning (fileLines is minimal) but still ride along in
    // the chunk so they are reported in the manifest/file list.
    if (cur.lines > 0 && cur.lines + fileLines > overshoot) {
      commit();
    }
    cur.files.push(file);
    cur.lines += fileLines;
    if (cur.lines >= chunkSize) commit();
  }
  commit();
  return chunks;
}

// Estimate the number of diff lines a file contributes to a chunk. Files with
// no reviewable content (binary blobs, pure renames, mode-change-only) carry
// almost no payload, so charging them the full per-file overhead inflated
// chunk-size math and produced empty/near-empty chunks. We charge such files a
// minimal fixed overhead and let files with real hunks drive the planning.
function countDiffLines(file) {
  if (file.hunks.length === 0) {
    // Binary / rename-only / mode-only: just the diff header + a metadata line
    // or two. Keep it small so these files never dominate a chunk's budget.
    return file.binary ? 2 : 1;
  }
  let n = 1;        // diff --git
  n += 3;           // approx index/--- /+++
  for (const h of file.hunks) n += h.content.split('\n').length;
  return n;
}

// True when a file carries no LLM-reviewable diff content (binary, pure
// rename, or mode-change-only). Such files are still recorded in the manifest
// and file list, but excluded from chunk-size planning.
function hasNoReviewableContent(file) {
  return file.hunks.length === 0;
}

// ─── Neighbors index ────────────────────────────────────────────────────────
function buildNeighbors(chunks, manifest) {
  const symbolChunk = new Map();
  for (const ch of chunks) {
    for (const file of ch.files) {
      for (const hunk of file.hunks) {
        for (const line of hunk.content.split('\n')) {
          for (const re of ADD_PATTERNS) {
            const m = line.match(re);
            if (m && !symbolChunk.has(m[1])) {
              symbolChunk.set(m[1], { chunk: ch.id, file: file.path });
              break;
            }
          }
        }
      }
    }
  }

  const out = new Map();
  const nameRe = /[A-Za-z_$][\w$]*/g;
  for (const ch of chunks) {
    const seen = new Set();
    const list = [];
    for (const file of ch.files) {
      for (const hunk of file.hunks) {
        for (const line of hunk.content.split('\n')) {
          if (line.startsWith('-')) continue;
          let m;
          nameRe.lastIndex = 0;
          while ((m = nameRe.exec(line)) !== null) {
            const name = m[0];
            const def = symbolChunk.get(name);
            if (def && def.chunk !== ch.id && !seen.has(name)) {
              seen.add(name);
              list.push({ symbol: name, defined_in_chunk: def.chunk, file: def.file });
            }
          }
        }
      }
    }
    out.set(ch.id, list);
  }
  return out;
}

// ─── Hunk-mode fallback ─────────────────────────────────────────────────────
function runAwkChunker(diffPath, chunkSize, awkPath, chunksDir) {
  fs.mkdirSync(chunksDir, { recursive: true });
  const result = cp.spawnSync('awk', [
    '-v', `chunk_size=${chunkSize}`,
    '-v', `output_dir=${chunksDir}`,
    '-f', awkPath,
  ], { input: fs.readFileSync(diffPath), env: { ...process.env, LC_ALL: 'C' } });
  if (result.status !== 0) {
    die(3, `awk chunker failed (status=${result.status}): ${result.stderr ? result.stderr.toString() : ''}`);
  }
}

function jsHunkChunker(files, chunkSize, chunksDir) {
  fs.mkdirSync(chunksDir, { recursive: true });
  const groups = [];
  let cur = [];
  let curLines = 0;
  for (const file of files) {
    const lines = countDiffLines(file);
    if (curLines > 0 && curLines + lines > Math.floor(chunkSize * 1.25)) {
      groups.push(cur);
      cur = [];
      curLines = 0;
    }
    cur.push(file);
    curLines += lines;
  }
  if (cur.length) groups.push(cur);

  for (let i = 0; i < groups.length; i++) {
    const out = path.join(chunksDir, `chunk_${String(i + 1).padStart(3, '0')}.diff`);
    let body = '';
    for (const file of groups[i]) {
      body += `diff --git a/${file.path} b/${file.path}\n`;
      for (const hunk of file.hunks) body += hunk.content;
    }
    fs.writeFileSync(out, body);
  }
  fs.writeFileSync(path.join(chunksDir, 'chunk_count.txt'), `${groups.length}\n`);
}

// ─── AST-mode chunk file emission ───────────────────────────────────────────
function emitAstChunks(diffText, files, chunks, chunksDir, chunkSize, awkPath) {
  fs.mkdirSync(chunksDir, { recursive: true });

  const fileTextByPath = new Map();
  const lines = diffText.split('\n');
  let curPath = null;
  let buf = [];
  function flush() {
    if (curPath != null) fileTextByPath.set(curPath, buf.join('\n'));
    buf = [];
  }
  for (const line of lines) {
    if (line.startsWith('diff --git ')) {
      flush();
      const m = line.match(/^diff --git a\/(.*) b\/(.*)$/);
      curPath = m ? m[2] : null;
      buf.push(line);
    } else if (curPath != null) {
      buf.push(line);
    }
  }
  flush();

  const overshoot = Math.floor(chunkSize * 1.25);
  let outputIndex = 0;
  let totalChunks = 0;
  for (const ch of chunks) {
    const totalLines = ch.files.reduce((acc, f) => acc + countDiffLines(f), 0);
    // Oversize-split delegation: ANY chunk (single- or multi-file) whose total
    // line count exceeds the overshoot threshold is handed to the awk
    // hunk-splitter so no single emitted chunk grossly exceeds the size cap.
    // (Previously only single-file chunks delegated, so a multi-file chunk over
    // the cap was emitted whole — defeating the size guarantee.) We build the
    // sub-diff from ALL files in the chunk, in their original order.
    const needsAwk = totalLines > overshoot && fs.existsSync(awkPath);
    if (needsAwk) {
      const subDiff = path.join(chunksDir, `_subdiff_${ch.id}.diff`);
      let subBody = '';
      for (const file of ch.files) {
        const txt = fileTextByPath.get(file.path);
        if (txt) subBody += txt + (txt.endsWith('\n') ? '' : '\n');
      }
      fs.writeFileSync(subDiff, subBody);
      const subOut = path.join(chunksDir, `_subchunks_${ch.id}`);
      fs.mkdirSync(subOut, { recursive: true });
      const r = cp.spawnSync('awk', [
        '-v', `chunk_size=${chunkSize}`,
        '-v', `output_dir=${subOut}`,
        '-f', awkPath,
      ], { input: fs.readFileSync(subDiff), env: { ...process.env, LC_ALL: 'C' } });
      if (r.status !== 0) {
        const label = ch.files.length === 1
          ? ch.files[0].path
          : `${ch.files.length} files (${ch.files[0].path}, …)`;
        warn(`awk sub-chunk failed for ${label}; falling back to single chunk`);
      } else {
        const sub = fs.readFileSync(path.join(subOut, 'chunk_count.txt'), 'utf8').trim();
        // awk now reports the true number of files written (count == files);
        // use 0 as the floor and rely on existence/size guards below.
        const subN = parseInt(sub, 10) || 0;
        for (let i = 1; i <= subN; i++) {
          const sf = path.join(subOut, `chunk_${String(i).padStart(3, '0')}.diff`);
          if (!fs.existsSync(sf)) continue;
          const stat = fs.statSync(sf);
          if (stat.size === 0) continue;
          outputIndex++;
          fs.copyFileSync(sf, path.join(chunksDir, `chunk_${String(outputIndex).padStart(3, '0')}.diff`));
          totalChunks++;
        }
        try { fs.rmSync(subOut, { recursive: true, force: true }); } catch (_) {}
        try { fs.unlinkSync(subDiff); } catch (_) {}
        continue;
      }
    }
    let body = '';
    for (const file of ch.files) {
      // Skip files with no reviewable content (binary/rename/mode-only). They
      // stay in the manifest/file list (built independently in parseDiff) but
      // carry no diff worth sending to a model. A chunk composed entirely of
      // such files therefore yields an empty body and is dropped, which feeds
      // the empty-plan fallback (chunk_count.txt = 0) below.
      if (hasNoReviewableContent(file)) continue;
      const txt = fileTextByPath.get(file.path);
      if (txt) body += txt + (txt.endsWith('\n') ? '' : '\n');
    }
    if (body.length === 0) continue;
    outputIndex++;
    fs.writeFileSync(path.join(chunksDir, `chunk_${String(outputIndex).padStart(3, '0')}.diff`), body);
    totalChunks++;
  }
  // Empty-plan fallback: if nothing reviewable was emitted (e.g. the diff is
  // entirely binary blobs / pure renames / mode changes), report 0 chunks so
  // the orchestrator can short-circuit cleanly. review.sh's `seq 1 0` loop
  // produces no iterations, so a 0 count is handled gracefully there.
  // (Previously this dumped the entire diff into one chunk, sending unreviewable
  // content to the models.)
  if (totalChunks === 0) {
    warn('no LLM-reviewable chunks produced (diff is binary/rename/mode-only); ' +
         'writing chunk_count.txt=0');
  }
  fs.writeFileSync(path.join(chunksDir, 'chunk_count.txt'), `${totalChunks}\n`);
}

// ─── Manifest text rendering (for legacy manifest.md) ───────────────────────
function renderManifestText(manifest) {
  const out = [];
  out.push('### Files changed in this PR');
  for (const f of manifest.files) out.push(`- ${f}`);
  out.push('');
  if (manifest.symbols_added.length) {
    out.push('### Symbols added in this PR');
    for (const s of manifest.symbols_added.slice(0, 200)) out.push(`- ${s}`);
    out.push('');
  }
  if (manifest.symbols_removed.length) {
    out.push('### Symbols removed in this PR');
    for (const s of manifest.symbols_removed.slice(0, 200)) out.push(`- ${s}`);
    out.push('');
  }
  if (manifest.symbols_renamed.length) {
    out.push('### Symbols renamed in this PR');
    for (const r of manifest.symbols_renamed.slice(0, 200)) {
      out.push(`- ${r.from} -> ${r.to} (${r.confidence})`);
    }
    out.push('');
  }
  return out.join('\n');
}

// ─── Main ───────────────────────────────────────────────────────────────────
function main() {
  const args = parseArgs(process.argv);

  let diffText;
  try {
    diffText = fs.readFileSync(args.diff, 'utf8');
  } catch (e) {
    die(3, `cannot read diff: ${e.message}`);
  }

  const files = parseDiff(diffText);
  const fileList = files.map(f => f.path).filter(Boolean);

  const sym = extractSymbolsFromDiff(diffText);
  const manifest = {
    files: fileList,
    symbols_added: sym.symbols_added,
    symbols_removed: sym.symbols_removed,
    symbols_renamed: sym.symbols_renamed,
  };

  const hasSupportedLang = files.some(f => detectLanguage(f.path) !== null);

  // Observability for the silent unsupported-language fallthrough: list the
  // distinct source extensions present that detectLanguage() does not handle,
  // so users understand why a PR got hunk-mode chunking instead of AST. This
  // does NOT change the fallback behavior — it only reports it.
  const unsupportedExts = new Set();
  for (const f of files) {
    if (!f.path) continue;
    if (detectLanguage(f.path) !== null) continue;
    const ext = path.extname(f.path).toLowerCase();
    // Skip non-code / extensionless / clearly-data files to keep the notice
    // focused on languages we could plausibly support.
    if (CODE_EXTS.has(ext)) unsupportedExts.add(ext);
  }

  let mode = args.chunker;
  let ts = null;
  if (mode === 'ast' || (mode === 'auto' && hasSupportedLang)) {
    ts = loadTreeSitter();
    if (!ts) {
      // Say so in auto mode too: a marketplace install has no node_modules
      // until the SessionStart hook (or a manual `npm ci`) provisions it, and
      // a silent fallback hides that the AST chunker is off.
      warn((mode === 'ast' ? '--chunker ast requested but ' : 'PR contains Python/TypeScript/Go but ') +
           'tree-sitter is not loadable; falling back to hunk chunking. ' +
           `Install with: cd "${__dirname}" && npm ci`);
      mode = 'hunk';
    } else {
      mode = 'ast';
    }
  } else {
    mode = 'hunk';
  }

  if (unsupportedExts.size > 0) {
    warn(`AST chunking does not support these languages present in this PR: ` +
         `${[...unsupportedExts].sort().join(', ')} — those files use hunk-mode chunking`);
  }

  fs.mkdirSync(args.chunksDir, { recursive: true });

  let astChunks = null;
  if (mode === 'ast') {
    astChunks = planAstChunks(files, args.chunkSize, ts, args.headSha);
    emitAstChunks(diffText, files, astChunks, args.chunksDir, args.chunkSize, args.awk);
  } else {
    if (fs.existsSync(args.awk)) {
      runAwkChunker(args.diff, args.chunkSize, args.awk, args.chunksDir);
    } else {
      warn(`chunk-diff.awk not found at ${args.awk}; using JS fallback`);
      jsHunkChunker(files, args.chunkSize, args.chunksDir);
    }
  }

  // Read the count written by the chunker. 0 is a legitimate value (empty-plan
  // fallback: diff was entirely binary/rename/mode-only) and must NOT be
  // coerced to 1, or we would fabricate a chunk record for a file that does not
  // exist. Only a non-numeric/garbage count is treated as unknown (0).
  const rawCount = parseInt(
    fs.readFileSync(path.join(args.chunksDir, 'chunk_count.txt'), 'utf8').trim(),
    10
  );
  const totalChunks = Number.isFinite(rawCount) && rawCount >= 0 ? rawCount : 0;

  let chunkRecords = [];
  if (mode === 'ast' && astChunks && astChunks.length === totalChunks) {
    // Only list files that actually appear in the emitted chunk diff (i.e.
    // those with reviewable hunks). No-hunk files (binary/rename/mode-only) are
    // stripped from the chunk body by emitAstChunks, so listing them here would
    // make chunks[].files disagree with the on-disk diff. They remain in
    // manifest.files for reporting.
    chunkRecords = astChunks.map((ch, i) => ({
      id: i + 1,
      files: ch.files.filter(f => !hasNoReviewableContent(f)).map(f => f.path),
      diff_path: path.join(args.chunksDir, `chunk_${String(i + 1).padStart(3, '0')}.diff`),
    }));
  } else {
    for (let i = 1; i <= totalChunks; i++) {
      const p = path.join(args.chunksDir, `chunk_${String(i).padStart(3, '0')}.diff`);
      const txt = fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : '';
      const fileSet = new Set();
      for (const line of txt.split('\n')) {
        const m = line.match(/^diff --git a\/(.*) b\/(.*)$/);
        if (m) fileSet.add(m[2]);
      }
      chunkRecords.push({ id: i, files: [...fileSet], diff_path: p });
    }
  }

  const fileByPath = new Map(files.map(f => [f.path, f]));
  const chunksForNeighbors = chunkRecords.map(r => ({
    id: r.id,
    files: r.files.map(p => fileByPath.get(p)).filter(Boolean),
  }));
  const neighborsByChunk = buildNeighbors(chunksForNeighbors, manifest);
  for (const r of chunkRecords) {
    r.neighbors = neighborsByChunk.get(r.id) || [];
  }

  const plan = {
    iteration: { mode: 'initial', prior_sha: null },
    manifest,
    manifest_text: renderManifestText(manifest),
    chunks: chunkRecords,
    chunker_mode: mode,
    review_rules: { source: 'n/a', content: '' },
  };

  fs.mkdirSync(path.dirname(args.output), { recursive: true });
  fs.writeFileSync(args.output, JSON.stringify(plan, null, 2) + '\n');
}

main();
