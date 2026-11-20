// One host for search engines (release 48, docs/changes/2026-11-20-r48-seo.md). On the company's server the site
// answers on every hostname Caddy serves (carmacars.ca, www.carmacars.ca and the deploy's own new.carmacars.ca), each a
// full copy of the site with status 200. Every page names the canonical address, but a crawler still spends its visits on
// the copies and Search Console lists them as duplicates. So:
//   - www (or the bare domain, when www is the canonical one) answers a permanent redirect to the canonical host, for
//     pages people and crawlers read (GET and HEAD; never the API, which webhooks and the health check call by host);
//   - any other hostname of the same domain (new.carmacars.ca) keeps answering, for the deploy's checks, with
//     "X-Robots-Tag: noindex" on every response, so it never enters an index.
// Local addresses, IP addresses and other domains (a preview) are left alone. No imports: it runs in the server entry
// and in Node for the unit test.
export type HostAction = { kind: 'pass' } | { kind: 'redirect'; location: string } | { kind: 'noindex' };

const bare = (h: string) => h.toLowerCase().replace(/:\d+$/, '').replace(/\.$/, '');

export function hostAction(host: string | null | undefined, canonicalUrl: string | null | undefined, method: string, pathAndQuery: string): HostAction {
  let canon: URL;
  try { canon = new URL(canonicalUrl ?? ''); } catch { return { kind: 'pass' }; }
  const c = bare(canon.host); const h = bare(host ?? '');
  if (!h || !c || h === c || !c.includes('.') || /^(localhost|\d+\.\d+\.\d+\.\d+|\[.*\])$/.test(h) || /^(localhost|\d+\.\d+\.\d+\.\d+)$/.test(c)) return { kind: 'pass' };
  const apex = c.replace(/^www\./, '');
  if (h !== apex && !h.endsWith(`.${apex}`)) return { kind: 'pass' };
  const path = pathAndQuery.startsWith('/') ? pathAndQuery : `/${pathAndQuery}`;
  const twin = h === `www.${c}` || c === `www.${h}`;
  if (twin) {
    if ((method === 'GET' || method === 'HEAD') && !/^\/(api\/|_next\/|healthz$)/.test(path)) return { kind: 'redirect', location: `${canon.protocol}//${canon.host}${path}` };
    return { kind: 'pass' };
  }
  return { kind: 'noindex' };
}
