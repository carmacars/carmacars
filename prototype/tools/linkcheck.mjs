#!/usr/bin/env node
// Link checker for the page files. No dependencies.
// Checks every href, src and srcset in every .html file: the target file must
// exist, and a #fragment must match an id in the target page. Also checks page
// names used by the scripts, and basic SEO shape (one h1, title, description, alt).
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const pages = fs.readdirSync(ROOT).filter((f) => f.endsWith('.html'));
const html = Object.fromEntries(pages.map((f) => [f, fs.readFileSync(path.join(ROOT, f), 'utf8')]));
const ids = Object.fromEntries(pages.map((f) => [f, new Set([...html[f].matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]))]));
const problems = []; let links = 0; let assets = 0; let external = 0; let anchors = 0;
for (const f of pages) {
  const src = html[f];
  for (const m of src.matchAll(/\s(href|src|srcset)="([^"]*)"/g)) {
    const [, attr, raw] = m; const url = raw.replace(/&amp;/g, '&');
    if (/^(data:|mailto:|tel:)/.test(url)) continue;
    if (/^https?:/.test(url)) { external++; continue; }
    if (url === '' || url === '#') { problems.push(`${f}: empty ${attr}`); continue; }
    const [beforeHash, frag] = url.split('#'); const file = beforeHash.split('?')[0];
    if (file === '') { anchors++; if (!ids[f].has(frag)) problems.push(`${f}: #${frag} has no matching id on the page`); continue; }
    if (!fs.existsSync(path.join(ROOT, file))) { problems.push(`${f}: ${attr} -> ${file} does not exist`); continue; }
    if (file.endsWith('.html')) { links++; if (frag && !ids[file].has(frag)) problems.push(`${f}: ${file}#${frag} has no matching id`); } else assets++;
  }
  // buttons must do something: a type, and either a data hook or a form
  for (const m of src.matchAll(/<button\b([^>]*)>/g)) if (!/type="(button|submit)"/.test(m[1]) && !/role="tab"/.test(m[1])) problems.push(`${f}: <button> without a type: ${m[0].slice(0, 80)}`);
  // SEO and accessibility shape
  const h1 = (src.match(/<h1[\s>]/g) || []).length; if (h1 !== 1) problems.push(`${f}: ${h1} h1 elements`);
  const title = (src.match(/<title>(.*?)<\/title>/) || [])[1] || ''; if (title.length < 10 || title.length > 75) problems.push(`${f}: title length ${title.length}`);
  const desc = (src.match(/<meta name="description" content="(.*?)">/) || [])[1] || ''; if (desc.length < 50 || desc.length > 260) problems.push(`${f}: description length ${desc.length}`);
  for (const m of src.matchAll(/<img\b[^>]*>/g)) { if (!/\salt="/.test(m[0])) problems.push(`${f}: img without alt`); if (!/\swidth="\d+"/.test(m[0]) || !/\sheight="\d+"/.test(m[0])) problems.push(`${f}: img without width/height (layout shift)`); }
  for (const m of src.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)) { try { JSON.parse(m[1]); } catch (e) { problems.push(`${f}: invalid JSON-LD`); } }
  if (/[\u2013\u2014]/.test(src)) problems.push(`${f}: contains an em or en dash`);
  for (const id of ids[f]) { if ((src.match(new RegExp(`\\sid="${id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`, 'g')) || []).length > 1) problems.push(`${f}: duplicate id ${id}`); }
}
// page names referenced from scripts
let jsRefs = 0;
for (const js of ['assets/js/app.js', 'assets/js/pages.js']) for (const m of fs.readFileSync(path.join(ROOT, js), 'utf8').matchAll(/'([a-z0-9-]+\.html)/g)) { jsRefs++; if (!html[m[1]] && m[1] !== 'index.html') problems.push(`${js}: refers to ${m[1]}, which does not exist`); }
const titles = pages.map((f) => (html[f].match(/<title>(.*?)<\/title>/) || [])[1]); const dup = titles.filter((t, i) => titles.indexOf(t) !== i); if (dup.length) problems.push('duplicate titles: ' + dup.join(' | '));
console.log(`pages: ${pages.length}; internal page links: ${links}; in-page anchors: ${anchors}; asset references: ${assets}; external links: ${external}; page names in scripts: ${jsRefs}`);
console.log(problems.length ? `PROBLEMS (${problems.length}):\n` + problems.join('\n') : 'broken links: 0; SEO shape problems: 0');
process.exit(problems.length ? 1 : 0);
