// The facts the guides are held to (migration 0055), read from the code of this commit, never written by hand:
//   nav     each portal's menu, group by group (the admin and assistant groups, the owner, renter, investor and field tabs)
//   labels  every label the portals can show: the text of the screens (JSX), the strings of the code and the page
//           content, and the labels the database gives the screens (To do items, buttons, statuses)
//   pages   for each page address, the labels of that page's own code and the components it uses (one level down)
// The guide upkeep run sends a section's facts with its rewrite; the label check (guide-labels.mjs, the unit tests) uses
// the labels to find buttons a guide names that no screen shows any more.
//   node scripts/portal-facts.mjs [--out file.json]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = path.resolve(WEB, '..');
const SRC = path.join(WEB, 'src');

function walk(dir, ok, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!['node_modules', '.next', '__tests__'].includes(e.name)) walk(p, ok, out); }
    else if (ok(p)) out.push(p);
  }
  return out;
}
const read = (p) => fs.readFileSync(p, 'utf8');
const clean = (s) => s.replace(/\s+/g, ' ').replace(/&apos;|&#39;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, '&').trim();
const plausible = (s) => s.length >= 2 && s.length <= 90 && /[A-Za-z]/.test(s) && !/^[a-z0-9_.\-/:@#[\]]+$/.test(s) && !/[{}<>;=\\]|=>|&&|\?\?|\|\||\bfunction\b|^[\s(),.:?\]]|\/g\b/.test(s);

/** The strings a code file can show: JSX text, and string literals (a small scanner, so comments and code are skipped). */
export function labelsOfCode(code) {
  const out = new Set();
  const add = (raw) => { const t = clean(raw); if (plausible(t)) out.add(t); };
  let i = 0; const n = code.length;
  while (i < n) {
    const c = code[i], d = code[i + 1];
    if (c === '/' && d === '/') { i = code.indexOf('\n', i); if (i < 0) break; continue; }
    if (c === '/' && d === '*') { i = code.indexOf('*/', i + 2); if (i < 0) break; i += 2; continue; }
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1, buf = '', depth = 0, pattern = '', holes = 0;
      while (j < n) {
        const e = code[j];
        if (e === '\\') { buf += code[j + 1] ?? ''; j += 2; continue; }
        if (c === '`' && e === '$' && code[j + 1] === '{') { depth = 1; j += 2; add(buf); pattern += buf + '*'; holes++; buf = ''; while (j < n && depth) { if (code[j] === '{') depth++; else if (code[j] === '}') depth--; j++; } continue; }
        if (e === c) break;
        if (e === '\n' && c !== '`') break;
        buf += e; j++;
      }
      add(buf);
      // a label built from a template ("Invite to the ${role} portal"): kept as a pattern, ~invite to the * portal
      if (holes) { const pt = clean(pattern + buf); if (pt.replace(/\*/g, '').replace(/[^A-Za-z]/g, '').length >= 3 && pt.length <= 90 && !/[{}<>;=\\]/.test(pt)) out.add('~' + pt); }
      i = j + 1; continue;
    }
    // JSX text: after a tag closes (>) up to the next tag or expression
    if (c === '>' && code[i - 1] !== '=' && code[i - 1] !== '-') {
      const m = /^>([^<>{}=;]*?)(?=[<{])/.exec(code.slice(i, i + 200));
      if (m && /[A-Za-z]{2}/.test(m[1]) && !/^\s*[)\],.:?&|]/.test(m[1])) {
        add(m[1]);
        // text that runs into an expression ("All {n}", "Pay {amount}"): also a pattern
        const rest = code.slice(i + m[0].length, i + m[0].length + 1);
        if (rest === '{') { const pt = clean(m[1]); if (pt.length >= 2 && pt.length <= 80) out.add('~' + pt + ' *'); }
      }
    }
    i++;
  }
  return out;
}

// ---------------------------------------------------------------- navigation
function navFromGroups(code, constName) {
  const start = code.indexOf(constName);
  const body = code.slice(start);
  const groups = [];
  for (const g of body.matchAll(/\{\s*key: '([^']+)', label: '([^']+)', links: \[([\s\S]*?)\]\s*\}/g)) {
    groups.push({ group: g[2], links: [...g[3].matchAll(/label: '([^']+)'/g)].map((m) => m[1]) });
  }
  return groups;
}
function navFromLinks(code, group) {
  const links = [...code.matchAll(/href: '([^']+)', label: '([^']+)'/g)].map((m) => m[2]);
  const jsx = [...code.matchAll(/href="(\/[^"]*)">([^<{]+)</g)].map((m) => m[2].trim());
  const pairs = [...code.matchAll(/\['(\/[^']*)', '([^']+)'\]/g)].map((m) => m[2]);
  return [{ group, links: [...new Set([...links, ...pairs, ...jsx])] }];
}
function nav() {
  const f = (p) => read(path.join(SRC, p));
  const admin = navFromGroups(f('features/admin/AdminNav.tsx'), 'GROUPS');
  const vaCode = f('features/va/VaNav.tsx');
  // My work, and Sales' My work with My sales (0057)
  const work = [...vaCode.matchAll(/const \w*WORK[^=]*= (\{[\s\S]*?\] \});/g)].map((m) => m[1]).join(' ');
  const va = [];
  for (const g of navFromGroups(`X ${work} ${vaCode.slice(vaCode.indexOf('VA_GROUPS'))}`, 'X')) if (!va.some((x) => x.group === g.group && x.links.join() === g.links.join())) va.push(g);
  const inv = fs.existsSync(path.join(SRC, 'app/investor/layout.tsx')) ? f('app/investor/layout.tsx') : '';
  return {
    admin, va,
    owner: navFromLinks(f('features/owner/OwnerNav.tsx'), 'Owner portal'),
    renter: navFromLinks(f('features/portal/PortalNav.tsx'), 'Your account'),
    field: navFromLinks(f('features/field/FieldNav.tsx'), 'Field'),
    investor: navFromLinks(inv, 'Investor portal')
  };
}

// ---------------------------------------------------------------- labels the database gives the screens
function sqlLabels() {
  const out = new Set();
  const dir = path.join(ROOT, 'supabase/migrations');
  for (const file of fs.readdirSync(dir).filter((n) => n.endsWith('.sql'))) {
    const sql = read(path.join(dir, file));
    for (const m of sql.matchAll(/'(label|button|title|status_label|action|next_step|what)',\s*'((?:[^']|'')+)'/g)) { const t = clean(m[2].replace(/''/g, "'")); if (plausible(t)) out.add(t); }
    for (const m of sql.matchAll(/\(\s*'[a-z_]+',\s*'((?:[^']|''){2,60})',\s*'((?:[^']|''){2,40})',\s*'\/(?:admin|va|owner|account|investor|field)[^']*'/g)) {
      for (const t of [m[1], m[2]].map((x) => clean(x.replace(/''/g, "'")))) if (plausible(t)) out.add(t);
    }
  }
  return out;
}

// ---------------------------------------------------------------- pages
function pages() {
  const app = path.join(SRC, 'app');
  const files = walk(app, (p) => /\/page\.tsx$/.test(p));
  const out = {};
  const resolve = (from, spec) => {
    const base = spec.startsWith('@/') ? path.join(SRC, spec.slice(2)) : spec.startsWith('.') ? path.resolve(path.dirname(from), spec) : null;
    if (!base) return null;
    for (const c of [base, `${base}.tsx`, `${base}.ts`, path.join(base, 'index.tsx'), path.join(base, 'index.ts')]) if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
    return null;
  };
  for (const file of files) {
    const route = '/' + path.relative(app, path.dirname(file)).split(path.sep).filter((s) => !/^\(.*\)$/.test(s)).join('/');
    const labels = new Set();
    const seen = new Set();
    const take = (f, depth) => {
      if (!f || seen.has(f) || !/\.(tsx|ts)$/.test(f) || /\.test\./.test(f)) return;
      seen.add(f);
      const code = read(f);
      for (const l of labelsOfCode(code)) labels.add(l);
      if (depth > 1) return;
      for (const m of code.matchAll(/from '((?:@\/(?:features|app)|\.)[^']*)'/g)) take(resolve(f, m[1]), depth + 1);
    };
    take(file, 0);
    // the route's layout (the menu) belongs to every page under it
    out[route === '/' ? '/' : route.replace(/\/$/, '')] = [...labels].sort();
  }
  return out;
}

export function portalFacts() {
  const labels = new Set();
  for (const f of walk(SRC, (p) => /\.(tsx|ts)$/.test(p) && !/\.test\.tsx?$/.test(p) && !/\/types\/database\.ts$/.test(p))) for (const l of labelsOfCode(read(f))) labels.add(l);
  for (const f of walk(SRC, (p) => /\.json$/.test(p))) for (const m of read(f).matchAll(/"((?:[^"\\]|\\.){2,90})"/g)) { const t = clean(m[1]); if (plausible(t)) labels.add(t); }
  for (const l of sqlLabels()) labels.add(l);
  const n = nav();
  for (const portal of Object.values(n)) for (const g of portal) { labels.add(g.group); for (const l of g.links) labels.add(l); }
  return { nav: n, labels: [...labels].sort(), pages: pages() };
}

/** The labels of the pages at these addresses (/admin/owners/[id] matches the route /admin/owners/[id]), with the menu's. */
export function screenLabels(facts, addresses) {
  const out = new Set();
  const routes = Object.keys(facts.pages);
  for (const a of addresses) {
    const want = a.split('?')[0].replace(/\/$/, '') || '/';
    for (const r of routes) {
      const re = new RegExp('^' + r.replace(/\[[^\]]+\]/g, '[^/]+') + '$');
      if (re.test(want) || r === want) for (const l of facts.pages[r]) out.add(l);
    }
  }
  return [...out];
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const facts = portalFacts();
  const i = process.argv.indexOf('--out');
  const json = JSON.stringify(facts);
  if (i > 0) { fs.writeFileSync(process.argv[i + 1], json); console.log(`portal facts: ${facts.labels.length} labels, ${Object.keys(facts.pages).length} pages, admin menu ${facts.nav.admin.map((g) => g.group).join(' / ')}`); }
  else process.stdout.write(json);
}
