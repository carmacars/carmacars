// Worker size (web/README.md, Worker size; docs/changes/2026-10-22-worker-size.md).
//
//   node scripts/worker-size.mjs patch   before `opennextjs-cloudflare build`
//   node scripts/worker-size.mjs check   after it: the server bundle's size against the budget
//
// With `experimental.inlineCss` every page's client reference manifest carries the full text of each stylesheet
// its layouts use (entryCSSFiles[...].content). OpenNext compiles all of them into the Worker (its load-manifest
// plugin, evalManifest) and already moves identical values out into shared constants, but only the whole
// entryCSSFiles object of a page, which differs from page to page. The same 15 stylesheets were repeated about
// 2,600 times: 117 MB of the 120 MB of manifests, and the upload went over Cloudflare's 64 MiB (code 10027).
//
// `patch` adds one step to that plugin: each inlined stylesheet text becomes one shared constant, referenced by
// every page that uses it. What each page's manifest holds is unchanged (the same strings), only written once.
// `next start` (scripts/serve.mjs) reads the manifests from .next as before; this only changes the Worker bundle.
//
// The file is replaced (written next to it, then renamed), never edited in place: node_modules may be hard links
// shared with other checkouts. The patch stops the build when the plugin no longer has the expected code (an
// OpenNext upgrade): check that the upgrade does not already do this, then update ANCHOR.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PLUGIN = path.join(WEB, 'node_modules/@opennextjs/cloudflare/dist/cli/build/patches/plugins/load-manifest.js');
const HANDLER = path.join(WEB, '.open-next/server-functions/default/handler.mjs');
const MARKER = '/* carmacars worker-size: inlined css */';
// Cloudflare refuses a Worker over 64 MiB uncompressed (63.9 MiB in its message). The server bundle is most of the
// upload; the budget leaves room for the Worker entry, the middleware and route growth.
// r38: 42 -> 46 MiB (bundle 42.4). r42: 46 -> 50 MiB: the bundle reached 46.9 MiB (four new routes: Search Console,
// SES events), `check` stopped cf:build and every job of the full suite then had no server on :3000. The bundle grows
// about 1 MiB a release; the trim (handler.mjs.meta.json shows what each input adds) is still to do before 50.
const BUDGET_MIB = 50;

const ANCHOR = `    return edits.length === 0
        ? valueText
        : rootNode.commitEdits(edits.map((e) => e.match.replace(e.replacement)));`;

const ADDITION = `    ${MARKER}
    const contentRule = \`
rule:
  kind: pair
  all:
    - has:
        field: key
        pattern: '"content"'
    - has:
        field: value
        kind: string
        pattern: $CONTENT
\`;
    for (const match of applyRule(contentRule, rootNode, { once: false }).matches) {
        const contentNode = match.getMatch("CONTENT");
        if (!contentNode)
            continue;
        const contentText = contentNode.text();
        if (contentText.length <= 30)
            continue;
        const varName = getOrCreateVarName(contentText, prefixMap);
        sharedVars.set(varName, contentText);
        edits.push({ match, replacement: \`"content": \${varName}\` });
    }
`;

function patch() {
  const src = fs.readFileSync(PLUGIN, 'utf8');
  if (src.includes(MARKER)) { console.log('worker-size: OpenNext load-manifest plugin already patched'); return; }
  const at = src.indexOf(ANCHOR);
  if (at < 0 || src.indexOf(ANCHOR, at + 1) >= 0) {
    console.error(`worker-size: the OpenNext load-manifest plugin changed (${path.relative(WEB, PLUGIN)}); see the notes in scripts/worker-size.mjs`);
    process.exit(1);
  }
  const tmp = `${PLUGIN}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, src.slice(0, at) + ADDITION + src.slice(at));
  fs.renameSync(tmp, PLUGIN);
  console.log('worker-size: OpenNext load-manifest plugin patched (inlined stylesheets written once)');
}

// r48: what each input adds, from esbuild's metafile, printed with every check so a CI log shows the cause of growth
// without a local build: the inputs grouped (a package, a route's files, the manifests, the shared chunks), then the files
function report() {
  const META = `${HANDLER}.meta.json`;
  if (!fs.existsSync(META)) { console.log('worker-size: no metafile next to the bundle; no breakdown'); return; }
  let out;
  try { out = Object.values(JSON.parse(fs.readFileSync(META, 'utf8')).outputs ?? {}).find((o) => o.inputs && Object.keys(o.inputs).length > 100) ?? null; } catch { out = null; }
  if (!out) { console.log('worker-size: the metafile has no bundle output; no breakdown'); return; }
  const group = (f) => {
    const nm = f.lastIndexOf('node_modules/');
    if (nm >= 0) { const rest = f.slice(nm + 13).split('/'); return `pkg ${rest[0].startsWith('@') ? `${rest[0]}/${rest[1]}` : rest[0]}`; }
    if (/client-reference-manifest/.test(f)) return 'manifests: client reference';
    if (/manifest/.test(f)) return 'manifests: other';
    const app = f.match(/\.next\/server\/app\/(.*)$/);
    if (app) return `app ${app[1].split('/').slice(0, 2).join('/')}`;
    if (/\.next\/server\/chunks\//.test(f)) return 'chunks (shared server code)';
    return f.split('/').slice(-3).join('/');
  };
  const groups = new Map();
  const files = [];
  for (const [f, v] of Object.entries(out.inputs)) {
    const b = v.bytesInOutput ?? 0;
    groups.set(group(f), (groups.get(group(f)) ?? 0) + b);
    files.push([f, b]);
  }
  const mb = (b) => `${(b / 1024 / 1024).toFixed(2)} MiB`;
  console.log('worker-size: the largest groups of inputs');
  for (const [g, b] of [...groups].sort((a, z) => z[1] - a[1]).slice(0, 30)) console.log(`  ${mb(b).padStart(10)}  ${g}`);
  // Turbopack's shared server chunks: by layer (ssr/ renders client components, the rest is the server layer) and by the
  // source their names start with (the hash left out), so a module copied into many chunks shows as one line with a count
  const chunks = files.filter(([f]) => /\.next\/server\/chunks\//.test(f));
  const ssr = chunks.filter(([f]) => /\/chunks\/ssr\//.test(f));
  const sum = (xs) => xs.reduce((a, [, b]) => a + b, 0);
  console.log(`worker-size: ${chunks.length} chunks, ${mb(sum(chunks))}: ssr layer ${ssr.length} (${mb(sum(ssr))}), server layer ${chunks.length - ssr.length} (${mb(sum(chunks) - sum(ssr))})`);
  const stems = new Map();
  for (const [f, b] of chunks) {
    const stem = f.replace(/^.*\/chunks\//, '').replace(/_[0-9a-z-]{6,9}\._\.js$/i, '').replace(/\.js$/, '');
    const s = stems.get(stem) ?? { n: 0, b: 0 };
    s.n += 1; s.b += b; stems.set(stem, s);
  }
  console.log('worker-size: the chunks by name');
  for (const [s, v] of [...stems].sort((a, z) => z[1].b - a[1].b).slice(0, 40)) console.log(`  ${mb(v.b).padStart(10)}  x${String(v.n).padEnd(4)} ${s}`);
  console.log('worker-size: the largest input files');
  for (const [f, b] of files.sort((a, z) => z[1] - a[1]).slice(0, 25)) console.log(`  ${mb(b).padStart(10)}  ${f.replace(/^.*?\.next\//, '.next/')}`);
}

// Turbopack writes each module into every chunk that needs it: the modules found in more than one chunk, by the bytes
// their extra copies add (the module's id string starts each definition in a chunk)
function duplicates() {
  const dir = path.join(WEB, '.next/server/chunks');
  if (!fs.existsSync(dir)) return;
  const mods = new Map();
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (!e.name.endsWith('.js')) continue;
      const src = fs.readFileSync(p, 'utf8');
      // named ids ("[project]/src/x.tsx [app-ssr] (ecmascript)") or, minified, numeric ids: [id,(a,b)=>{...},id,...]
      const named = /"\[project\]\/([^"]+?) \[([a-z-]+)\] \([^"]*\)",\s*(?:\(\(|function|\(__turbopack)/g;
      const numeric = /[,[](\d{1,7}),(?:\(\w*(?:,\w+)*\)|\w+)=>\{/g;
      const hits = [];
      // the chunk's index source map names each module's section: the exact source file of every copy
      try {
        const map = fs.existsSync(`${p}.map`) ? JSON.parse(fs.readFileSync(`${p}.map`, 'utf8')) : null;
        if (map?.sections?.length) {
          const lineAt = [0];
          for (let i = src.indexOf('\n'); i >= 0; i = src.indexOf('\n', i + 1)) lineAt.push(i + 1);
          for (const s of map.sections) {
            const name = (s.map?.sources ?? [])[0];
            if (!name) continue;
            const at = (lineAt[s.offset.line] ?? src.length) + s.offset.column;
            hits.push([at, `${String(name).replace(/^turbopack:\/\/\/?/, '').replace(/^\[project\]\//, '')} [${/\/ssr\//.test(p) ? 'ssr' : 'rsc'}]`]);
          }
        }
      } catch { hits.length = 0; }
      if (!hits.length) for (let m; (m = named.exec(src));) hits.push([m.index, `${m[1]} [${m[2]}]`]);
      if (!hits.length) for (let m; (m = numeric.exec(src));) hits.push([m.index, `#${m[1]} [${/\/ssr\//.test(p) ? 'ssr' : 'rsc'}]`]);
      hits.forEach(([at, id], i) => {
        const size = (i + 1 < hits.length ? hits[i + 1][0] : src.length) - at;
        const v = mods.get(id) ?? { n: 0, b: 0, peek: '' };
        if (!v.peek) v.peek = src.slice(at, at + 160).replace(/\s+/g, ' ');
        v.n += 1; v.b += size; mods.set(id, v);
      });
    }
  };
  walk(dir);
  const mb = (b) => `${(b / 1024 / 1024).toFixed(2)} MiB`;
  const rows = [...mods].map(([id, v]) => [id.startsWith('#') ? `${id} ${v.peek}` : id, v.n, v.b, v.b - v.b / v.n]).filter((r) => r[1] > 1);
  console.log(`worker-size: ${mods.size} modules; copies beyond the first add ${mb(rows.reduce((a, r) => a + r[3], 0))}`);
  const dirs = new Map();
  for (const [id, , , extra] of rows) { const parts = id.split(' ')[0].split('/'); const k = parts.slice(0, Math.min(3, parts.length - 1)).join('/') || parts[0]; dirs.set(k, (dirs.get(k) ?? 0) + extra); }
  console.log('worker-size: extra copies by folder');
  for (const [k, b] of [...dirs].sort((a, z) => z[1] - a[1]).slice(0, 20)) console.log(`  ${mb(b).padStart(10)}  ${k}`);
  console.log('worker-size: the modules whose extra copies add the most');
  for (const [id, n, , extra] of rows.sort((a, z) => z[3] - a[3]).slice(0, 30)) console.log(`  ${mb(extra).padStart(10)}  x${String(n).padEnd(4)} ${id}`);
}

function check() {
  if (!fs.existsSync(HANDLER)) { console.error('worker-size: no server bundle; run opennextjs-cloudflare build first'); process.exit(1); }
  const bytes = fs.statSync(HANDLER).size;
  const mib = bytes / 1024 / 1024;
  const line = `worker-size: server bundle ${mib.toFixed(1)} MiB (budget ${BUDGET_MIB} MiB; Cloudflare's limit 64 MiB for the whole Worker)`;
  try { report(); } catch (e) { console.log(`worker-size: no breakdown (${e.message})`); }
  try { duplicates(); } catch (e) { console.log(`worker-size: no duplicate count (${e.message})`); }
  // the browser's side of the same build, so a chunking change that saves server bytes is seen against what it costs pages
  try {
    const cdir = path.join(WEB, '.next/static/chunks');
    let n = 0, b = 0;
    const walkc = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const q = path.join(d, e.name); if (e.isDirectory()) walkc(q); else if (e.name.endsWith('.js')) { n += 1; b += fs.statSync(q).size; } } };
    if (fs.existsSync(cdir)) { walkc(cdir); console.log(`worker-size: browser chunks ${n} files, ${(b / 1024 / 1024).toFixed(2)} MiB`); }
  } catch { /* the breakdown is informative only */ }
  if (mib > BUDGET_MIB) {
    console.error(`${line}: over budget. web/README.md, Worker size, shows how to see what each input adds`);
    // in CI the cause gets its own annotation: without the build no server starts, and the later steps only say "connection refused"
    if (process.env.GITHUB_ACTIONS) console.log(`::error title=Worker size over budget (no server will start)::${line}`);
    process.exit(1);
  }
  console.log(line);
  if (process.env.GITHUB_ACTIONS && mib > BUDGET_MIB - 2) console.log(`::warning title=Worker size near its budget::${line}`);
}

const cmd = process.argv[2];
if (cmd === 'patch') patch();
else if (cmd === 'check') check();
else { console.error('usage: node scripts/worker-size.mjs patch|check'); process.exit(2); }
