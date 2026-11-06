// Who sends the site's requests (2026-11-06, hotfix r27b): the zone's request log for a window, grouped by user agent,
// by cache status, by network (ASN) and by the first segment of the path, with the crawler family of each user agent.
// The cf-logs workflow prints it. No personal data: user agents and paths without query strings, no addresses.
//   CLOUDFLARE_API_TOKEN=... node scripts/cf-traffic.mjs [--hours 1] [--domain carmacars.ca] [--out file.json]
import fs from 'node:fs';

const token = process.env.CLOUDFLARE_API_TOKEN;
const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const hours = Math.min(Math.max(Number(arg('hours', '1')) || 1, 1), 24);
const domain = arg('domain', 'carmacars.ca');
const out = arg('out', null);
const to = new Date(Date.now() - 60_000), from = new Date(to.getTime() - hours * 3600_000);
const H = { Authorization: `Bearer ${token}`, 'content-type': 'application/json' };

/** The crawler family a user agent names (the token its company publishes), or people / other. */
export function family(ua) {
  const s = String(ua ?? '');
  const m = s.match(/(Googlebot-Image|Googlebot|Google-InspectionTool|Google-Extended|GoogleOther|Storebot-Google|AdsBot-Google|bingbot|BingPreview|DuckDuckBot|DuckAssistBot|Applebot-Extended|Applebot|YandexBot|YandexImages|Baiduspider|SeznamBot|Yeti|OAI-SearchBot|ChatGPT-User|GPTBot|ClaudeBot|Claude-User|Claude-SearchBot|PerplexityBot|Perplexity-User|meta-externalagent|meta-externalfetcher|meta-webindexer|facebookexternalhit|FacebookBot|Amazonbot|Amzn-SearchBot|Bytespider|CCBot|cohere-ai|MistralAI-User|YouBot|AhrefsBot|SemrushBot|MJ12bot|DotBot|PetalBot|DataForSeoBot|BLEXBot|serpstatbot|Barkrowler|ImagesiftBot|Timpibot|TikTokSpider|SeekportBot|MegaIndex)/i);
  if (m) return m[1];
  if (/bot\b|bot\/|crawler|spider|slurp/i.test(s)) return 'other crawler';
  if (/HeadlessChrome|python|curl|wget|Go-http|node-fetch|axios|okhttp|Java\//i.test(s)) return 'script';
  if (!s) return '(none)';
  return 'browser';
}

async function gql(query, variables) {
  const r = await fetch('https://api.cloudflare.com/client/v4/graphql', { method: 'POST', headers: H, body: JSON.stringify({ query, variables }) });
  const j = await r.json().catch(() => ({}));
  if (j.errors?.length) throw new Error(j.errors.map((e) => e.message).join('; ').slice(0, 400));
  return j.data;
}

async function main() {
  const report = { from: from.toISOString(), to: to.toISOString(), hours };
  if (!token) { report.unavailable = 'CLOUDFLARE_API_TOKEN is not set'; return report; }
  const z = await (await fetch(`https://api.cloudflare.com/client/v4/zones?name=${domain}`, { headers: H })).json();
  const zone = z.result?.[0]?.id;
  if (!zone) { report.unavailable = `zone ${domain} not readable with this token`; return report; }
  const v = { z: zone, s: from.toISOString(), e: to.toISOString() };
  const q = (dims, extra = '', limit = 100) => `httpRequestsAdaptiveGroups(limit:${limit},filter:{datetime_geq:$s,datetime_leq:$e${extra}},orderBy:[count_DESC]){count dimensions{${dims}}}`;
  try {
    const d = await gql(`query($z:String!,$s:Time!,$e:Time!){viewer{zones(filter:{zoneTag:$z}){
      all: httpRequestsAdaptiveGroups(limit:1,filter:{datetime_geq:$s,datetime_leq:$e}){count}
      ua: ${q('userAgent', '', 200)}
      cache: ${q('cacheStatus', '', 20)}
      asn: ${q('clientASNDescription', '', 15)}
      status: ${q('edgeResponseStatus', '', 15)}
      paths: ${q('clientRequestPath', ',requestSource:"eyeball"', 400)}
    }}}`, v);
    const zz = d.viewer.zones[0];
    report.requests = zz.all[0]?.count ?? 0;
    const fam = {};
    for (const x of zz.ua) { const f = family(x.dimensions.userAgent); fam[f] = (fam[f] ?? 0) + x.count; }
    report.by_family = Object.entries(fam).sort((a, b) => b[1] - a[1]).map(([k, n]) => ({ family: k, count: n }));
    report.by_cache = zz.cache.map((x) => ({ cache: x.dimensions.cacheStatus, count: x.count }));
    report.by_asn = zz.asn.map((x) => ({ asn: x.dimensions.clientASNDescription, count: x.count }));
    report.by_status = zz.status.map((x) => ({ status: x.dimensions.edgeResponseStatus, count: x.count }));
    const seg = {};
    for (const x of zz.paths) { const s = '/' + (String(x.dimensions.clientRequestPath).split('/')[1] ?? ''); seg[s] = (seg[s] ?? 0) + x.count; }
    report.by_segment_top400 = Object.entries(seg).sort((a, b) => b[1] - a[1]).slice(0, 15).map(([k, n]) => ({ segment: k, count: n }));
    report.distinct_paths_in_top400 = zz.paths.length;
    report.top_path_share = zz.paths[0] ? Math.round((zz.paths[0].count / Math.max(report.requests, 1)) * 1000) / 10 : 0;
  } catch (e) { report.unavailable = String(e.message ?? e).slice(0, 300); }
  return report;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const report = await main();
  if (out) fs.writeFileSync(out, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
}
