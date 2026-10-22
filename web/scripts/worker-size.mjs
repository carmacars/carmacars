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
const BUDGET_MIB = 40;

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

function check() {
  if (!fs.existsSync(HANDLER)) { console.error('worker-size: no server bundle; run opennextjs-cloudflare build first'); process.exit(1); }
  const bytes = fs.statSync(HANDLER).size;
  const mib = bytes / 1024 / 1024;
  const line = `worker-size: server bundle ${mib.toFixed(1)} MiB (budget ${BUDGET_MIB} MiB; Cloudflare's limit 64 MiB for the whole Worker)`;
  if (mib > BUDGET_MIB) { console.error(`${line}: over budget. web/README.md, Worker size, shows how to see what each input adds`); process.exit(1); }
  console.log(line);
}

const cmd = process.argv[2];
if (cmd === 'patch') patch();
else if (cmd === 'check') check();
else { console.error('usage: node scripts/worker-size.mjs patch|check'); process.exit(2); }
