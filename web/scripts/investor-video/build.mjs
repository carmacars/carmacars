// The investor video, step 1 (docs/investor-video/script.md): the plan.
//   node scripts/investor-video/build.mjs --figures figures.json --today 2026-10-23 --out <dir>
// Renders the deck with the figures (deck-entry.tsx, bundled with esbuild), reads the script, fills its {{tokens}} from
// the deck's own numbers, checks every scene against the deck (titles in order, every filled number on the deck), and
// writes <out>/plan.json (the scenes: narration, spoken text, slides) and <out>/stage.html (the slides, for render.mjs).
import { build } from 'esbuild';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const WEB = resolve(HERE, '../..');
const ROOT = resolve(WEB, '..');
const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const out = resolve(arg('out', join(WEB, '.video')));
const today = arg('today', new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()));
const raw = JSON.parse(readFileSync(resolve(arg('figures', join(HERE, 'figures.sample.json'))), 'utf8'));
// app.deck_figures() through the Management API comes back as [{ f: {...} }]; a plain object is used as it is
const figures = Array.isArray(raw) ? (raw[0]?.f ?? raw[0]?.deck_figures ?? raw[0]) : raw;
mkdirSync(out, { recursive: true });

// ---------------------------------------------------------------- the deck, rendered
const bundle = join(out, 'deck-entry.mjs');
await build({
  entryPoints: [join(HERE, 'deck-entry.tsx')], bundle: true, platform: 'node', format: 'esm', banner: { js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);" }, outfile: bundle, jsx: 'automatic', logLevel: 'error',
  alias: { '@': join(WEB, 'src') },
  plugins: [{ name: 'stubs', setup(b) {
    b.onResolve({ filter: /^next\/link$/ }, () => ({ path: 'next-link', namespace: 'stub' }));
    b.onLoad({ filter: /.*/, namespace: 'stub' }, () => ({ loader: 'jsx', resolveDir: WEB, contents: "export default function Link({ href, prefetch, children, ...p }) { void prefetch; return <a href={typeof href === 'string' ? href : '#'} {...p}>{children}</a>; }" }));
  } }],
  define: { 'process.env.NODE_ENV': '"production"' }
});
const { deckForVideo } = await import(pathToFileURL(bundle).href);
const { html, vars, groups } = deckForVideo({ viewer: 'investor', ...figures }, today);

// the slides, in order, with their titles (aria-label "Slide n: title")
const slideTitles = [...html.matchAll(/<section class="dk-slide[^"]*"[^>]*aria-label="Slide (\d+): ([^"]*)"/g)].map((m) => decode(m[2]));
function decode(s) { return s.replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&nbsp;/g, ' '); }
const deckText = decode(html.replace(/<!-- -->/g, '').replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ');

// ---------------------------------------------------------------- the script
const md = readFileSync(join(ROOT, 'docs/investor-video/script.md'), 'utf8');
const parts = md.split(/^## /m).slice(1);
const problems = [];
const fill = (s, where) => s.replace(/\{\{(\w+)\}\}/g, (_, k) => {
  const v = vars[k];
  if (v === undefined || v === '') { problems.push(`${where}: {{${k}}} has no value`); return ''; }
  if (!deckText.includes(v)) problems.push(`${where}: "${v}" ({{${k}}}) is not on the deck`);
  return v;
});
// the words as spoken: the same sentence, with the few things a voice reads badly spelled out
const spoken = (s) => s.replace(/(\d+(?:\.\d+)?)x\b/g, '$1 times').replace(/24\/7/g, 'twenty-four seven').replace(/\bHST\b/g, 'H.S.T.').replace(/\bVIN\b/g, 'V.I.N.');

let at = 0;
const scenes = parts.map((p, i) => {
  const [head = '', ...body] = p.split('\n');
  const group = /\(group\)\s*$/.test(head);
  const title = fill(head.replace(/\s*\(group\)\s*$/, '').trim(), `scene ${i + 1} title`);
  const text = fill(body.join(' ').replace(/\s+/g, ' ').trim(), `scene ${i + 1} (${title})`);
  const g = group ? groups.find((x) => x.kicker === title) : null;
  if (group && !g) problems.push(`scene ${i + 1}: no feature group "${title}"`);
  const count = g ? 1 + g.features : 1;
  const slides = Array.from({ length: count }, (_, k) => at + k);
  if (slideTitles[at] !== title) problems.push(`scene ${i + 1}: "${title}" but slide ${at + 1} is "${slideTitles[at]}"`);
  at += count;
  if (/[–—]/.test(text)) problems.push(`scene ${i + 1}: a long dash`);
  const sentences = text.split(/(?<=[.!?])\s+/).filter(Boolean);
  if (sentences.length > 4) problems.push(`scene ${i + 1}: ${sentences.length} sentences (at most 4)`);
  return { n: i + 1, title, group: g?.id ?? null, slides, text, say: spoken(text), words: text.split(/\s+/).length };
});
if (at !== slideTitles.length) problems.push(`the script covers ${at} slides; the deck has ${slideTitles.length}`);
if (problems.length) { console.error(problems.join('\n')); process.exit(1); }

// ---------------------------------------------------------------- the stage page
const css = ['tokens.css', 'core.css', 'deck.css'].map((f) => readFileSync(join(WEB, 'src/styles', f), 'utf8')).join('\n');
const font = (fam, w, file) => `@font-face{font-family:"${fam}";font-weight:${w};font-style:normal;font-display:block;src:url("/src/fonts/${file}") format("woff2")}`;
const fonts = [font('VInterDisplay', 600, 'inter-display-600.woff2'), font('VInterDisplay', 700, 'inter-display-700.woff2'), font('VInterDisplay', 800, 'inter-display-800.woff2'),
  font('VInter', 400, 'inter-400.woff2'), font('VInter', 500, 'inter-500.woff2'), font('VInter', '600 700', 'inter-600.woff2')].join('\n');
const page = `<!doctype html><html lang="en-CA"><head><meta charset="utf-8"><title>CarmaCars investor video stage</title>
<style>${fonts}\n:root{--ff-display:"VInterDisplay";--ff-text:"VInter"}\n${css}</style>
<link rel="stylesheet" href="/scripts/investor-video/stage.css"></head>
<body><div id="deck" hidden>${html.replace(/src="\/deck\//g, 'src="/public/deck/').replace(/ loading="lazy"/g, '')}</div><div id="stage"></div>
<script src="/scripts/investor-video/stage.js"></script></body></html>`;
writeFileSync(join(out, 'stage.html'), page);
writeFileSync(join(out, 'plan.json'), JSON.stringify({ today, vars, scenes, slides: slideTitles }, null, 2));
const words = scenes.reduce((a, s) => a + s.words, 0);
console.log(`plan: ${scenes.length} scenes over ${slideTitles.length} slides, ${words} words (about ${(words / 2.6 / 60).toFixed(1)} min spoken)`);
