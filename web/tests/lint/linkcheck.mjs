// Link checker: crawls the running site and fails on any internal link, anchor, image or script
// that does not resolve, and on any public path an email links to (emails/src/links.mjs).
//   BASE_URL=http://localhost:3000 node tests/lint/linkcheck.mjs
import { PATHS } from '../../../emails/src/links.mjs';
import { crawl } from './crawl.mjs';

const base = process.env.BASE_URL || 'http://localhost:3000';
const PORTAL = /^\/(account|owner|admin|va|field|staff)(\/|$)/;
const emailPaths = Object.values(PATHS).filter((p) => !PORTAL.test(p) && !p.includes('{{'));
const pages = await crawl(base, emailPaths.map((p) => p.split('#')[0]));
const problems = []; let links = 0; let anchors = 0; let assets = 0; let external = new Set();
const ids = (html) => new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]));

for (const [path, page] of pages) {
  if (page.status >= 400) problems.push(`${path}: HTTP ${page.status}`);
  if (!page.html) continue;
  const here = ids(page.html);
  for (const m of page.html.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)) {
    const h = m[1].replace(/&amp;/g, '&'); links++;
    if (/^https?:/.test(h) && !h.startsWith(base)) { external.add(h); continue; }
    if (/^(mailto:|tel:)/.test(h)) { if (!/^mailto:[^@\s]+@[^@\s]+\.[a-z]{2,}$|^tel:\+?\d{10,15}$/.test(h)) problems.push(`${path}: bad ${h}`); continue; }
    const u = new URL(h, base + path);
    const target = u.pathname + u.search;
    const t = pages.get(target);
    if (!t && pages.skipped?.has(target)) continue; // a place page outside the sample (same template)
    if (!t) problems.push(`${path}: link not crawled ${h}`);
    else if (t.status >= 400) problems.push(`${path}: broken link ${h} (${t.status})`);
    if (u.hash) { anchors++; const html = target === path ? page.html : t?.html ?? ''; if (!ids(html).has(decodeURIComponent(u.hash.slice(1)))) problems.push(`${path}: missing anchor ${h}`); }
  }
  for (const m of page.html.matchAll(/<(?:img|source|script|link)\b[^>]*\b(?:src|srcSet|srcset|href)="([^"]+)"/g)) {
    for (const part of m[1].split(',')) {
      const src = part.trim().split(' ')[0].replace(/&amp;/g, '&');
      if (!src || /^(data:|https?:)/.test(src)) continue;
      if (assets > 4000) break;
      const u = new URL(src, base + path); if (u.origin !== new URL(base).origin || pages.has(u.pathname)) continue;
      assets++;
      const r = await fetch(u, { method: 'GET' });
      if (r.status >= 400) problems.push(`${path}: asset ${src} (${r.status})`);
      pages.set(u.pathname, { status: r.status, html: '' });
    }
  }
  void here;
}
for (const p of emailPaths) {
  const [path, hash] = p.split('#');
  const t = pages.get(path);
  if (!t || t.status !== 200) problems.push(`email link ${p}: ${t ? t.status : 'not served'}`);
  else if (hash && !ids(t.html).has(hash)) problems.push(`email link ${p}: missing anchor #${hash}`);
}
const htmlPages = [...pages.values()].filter((p) => p.html).length;
console.log(`linkcheck: ${htmlPages} pages (${pages.skipped?.size ?? 0} more place pages not crawled: a sample of each term is), ${links} links, ${anchors} anchors, ${assets} assets checked, ${emailPaths.length} email paths, ${external.size} external links (not fetched)`);
if (problems.length) { console.log(problems.join('\n')); console.log(`FAILED: ${problems.length} broken`); process.exit(1); }
console.log('linkcheck: 0 broken');
