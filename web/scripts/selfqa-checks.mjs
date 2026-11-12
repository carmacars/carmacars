// The pure checks of the live self-check after a deploy (web/scripts/verify-live.mjs --selfqa; migration 2400). No network:
// each takes what a page answered. Tested by src/lib/selfqa-checks.test.ts.

/** A server failure: any 5xx, or Cloudflare's "Error 1101" (the Worker threw) on a page that otherwise answered. */
export function serverFailure(status, body) {
  if (status >= 500) return `answered ${status}`;
  if (/Error 1101|Worker threw exception/i.test(String(body ?? '').slice(0, 20000))) return 'Error 1101 (the Worker threw)';
  return null;
}

const STANDIN = /\/sample-photos\/studio\/[a-z]+\/[a-z]+\/[a-z0-9]+\/[^"'\s)<>]+\.svg/g;
/** The stand-in images on a page (unique, as addresses). */
const decoded = (html) => String(html ?? '').replace(/%2F/gi, '/');
export function standinUrls(html) {
  return [...new Set(decoded(html).match(STANDIN) ?? [])];
}
/** The car pages whose card on a list page shows a stand-in: from a car's first link up to the next car's link. */
export function standinSlugs(html) {
  const s = decoded(html);
  const links = [...s.matchAll(/href="\/cars\/([a-z0-9]+(?:-[a-z0-9]+)+)"/g)];
  const out = new Set(), seen = new Set();
  for (let k = 0; k < links.length; k++) {
    const slug = links[k][1];
    if (seen.has(slug)) continue;
    seen.add(slug);
    let n = k + 1;
    while (n < links.length && links[n][1] === slug) n++;
    const to = n < links.length ? links[n].index : Math.min(s.length, links[k].index + 6000);
    if (s.slice(links[k].index, to).includes('/sample-photos/studio/')) out.add(slug);
  }
  return [...out];
}

/** The model's name on a stand-in's wall: each large centred line must sit inside the panel (x 380 to 1420) and must not
 *  be squeezed past readability (its letters at least 70% of their natural width). Returns the problems found. */
export const PANEL = { left: 380, right: 1420 };
export function letteringOverflow(svg) {
  const out = [];
  for (const m of String(svg ?? '').matchAll(/<text\b([^>]*)>([^<]*)<\/text>/g)) {
    const a = m[1], text = m[2].trim();
    const num = (k) => { const r = new RegExp(`\\b${k}="([0-9.]+)"`).exec(a); return r ? Number(r[1]) : null; };
    const size = num('font-size'), x = num('x');
    if (!size || size < 50 || x === null || !/text-anchor="middle"/.test(a) || !text) continue;   // the slate and small print
    const natural = text.length * size * 0.62;
    const len = num('textLength') ?? natural;
    const left = x - len / 2, right = x + len / 2;
    if (left < PANEL.left - 2 || right > PANEL.right + 2) out.push(`"${text}" runs off the wall panel (${Math.round(left)} to ${Math.round(right)})`);
    else if (len < natural * 0.7) out.push(`"${text}" is squeezed to ${Math.round((len / natural) * 100)}% of its width`);
  }
  return out;
}

/** Whether a page asks not to be indexed (a robots meta tag or the X-Robots-Tag header). */
export function noindex(html, headers) {
  const h = headers?.get ? headers.get('x-robots-tag') : headers?.['x-robots-tag'];
  if (h && /noindex/i.test(h)) return true;
  for (const m of String(html ?? '').matchAll(/<meta\b[^>]*>/gi)) {
    if (/name=["'](robots|googlebot)["']/i.test(m[0]) && /content=["'][^"']*noindex/i.test(m[0])) return true;
  }
  return false;
}

/** A sitemap's addresses (<loc>) and whether it is an index of other sitemaps. */
export function sitemapLocs(xml) {
  const s = String(xml ?? '');
  return { index: /<sitemapindex\b/i.test(s), locs: [...s.matchAll(/<loc>\s*([^<\s]+)\s*<\/loc>/gi)].map((m) => m[1].replace(/&amp;/g, '&')) };
}
