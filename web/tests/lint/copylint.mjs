// Copy lint over the rendered pages: no em or en dashes, never the numbered company name, and the
// brand spelled CarmaCars (docs/blueprint/00-overview.md principle 10).
//   BASE_URL=http://localhost:3000 node tests/lint/copylint.mjs
import { crawl } from './crawl.mjs';

const base = process.env.BASE_URL || 'http://localhost:3000';
const pages = await crawl(base, ['/book', '/book/sent/R-000001', '/reset-password', '/update-password', '/create-account', '/investors', '/no-such-page']);
const RULES = [
  [/[—]|&mdash;/, 'em dash'], [/[–]|&ndash;/, 'en dash'],
  [/18122211|Canada Inc\b/i, 'numbered company name'],
  [/\bCarma[\s-]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled (CarmaCars)']
];
const problems = []; let checked = 0;
for (const [path, p] of pages) {
  if (!p.html) continue;
  checked++;
  // visible text and structured data; addresses (carmacars.ca, emails) are not copy
  const text = p.html
    .replace(/<script\b(?![^>]*application\/ld\+json)[^>]*>[\s\S]*?<\/script>/g, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/g, ' ')
    .replace(/\b(href|src|srcset|content|action)="[^"]*"/gi, ' ')
    .replace(/[\w.+-]+@[\w-]+\.carmacars\.ca|[\w.+-]+@carmacars\.ca|https?:\/\/[^\s"<]+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of RULES) {
    const m = text.match(re);
    if (m) problems.push(`${path}: ${what}: ...${text.slice(Math.max(0, m.index - 40), m.index + 40).replace(/\s+/g, ' ')}...`);
  }
}
console.log(`copylint: ${checked} pages checked`);
if (problems.length) { console.log(problems.join('\n')); console.log(`FAILED: ${problems.length}`); process.exit(1); }
console.log('copylint: 0 problems');
