// The Worker's health from Cloudflare (the verify workflow): the last 24 hours (or --hours N) of invocations of
// carmacars-prod by outcome (success, exceeded resources = Error 1102, exception), CPU time p50/p90/p99, the
// 5xx answers by path from the zone's request log, and, where Workers Observability answers, CPU per path.
// Each part that the API token may not read is reported as unavailable, never fatal.
//   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... node scripts/cf-analytics.mjs --hours 24 --out cf.json
import fs from 'node:fs';

const token = process.env.CLOUDFLARE_API_TOKEN, acc = process.env.CLOUDFLARE_ACCOUNT_ID;
const arg = (k, d) => { const i = process.argv.indexOf(`--${k}`); return i > 0 ? process.argv[i + 1] : d; };
const hours = Number(arg('hours', '24'));
const script = arg('script', 'carmacars-prod');
const domain = arg('domain', 'carmacars.ca');
const out = arg('out', null);
const to = new Date(Date.now() - 60_000), from = new Date(to.getTime() - hours * 3600_000);
const report = { from: from.toISOString(), to: to.toISOString(), hours, script };
const H = { Authorization: `Bearer ${token}`, 'content-type': 'application/json' };
const ms = (us) => (typeof us === 'number' ? Math.round(us / 10) / 100 : null); // microseconds to ms, 2 places

async function gql(query, variables) {
  const r = await fetch('https://api.cloudflare.com/client/v4/graphql', { method: 'POST', headers: H, body: JSON.stringify({ query, variables }) });
  const j = await r.json().catch(() => ({}));
  if (j.errors?.length) throw new Error(j.errors.map((e) => e.message).join('; ').slice(0, 400));
  return j.data;
}

if (!token || !acc) { console.log(JSON.stringify({ error: 'CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID are needed' })); process.exit(0); }

// 1. invocations by outcome, and CPU time over all of them (adaptive dataset: at most one day per query)
try {
  const parts = [];
  for (let t = from.getTime(); t < to.getTime(); t += 24 * 3600_000) parts.push([new Date(t), new Date(Math.min(t + 24 * 3600_000, to.getTime()))]);
  const byStatus = {};
  let all = null;
  for (const [s, e] of parts) {
    const d = await gql(`query($a:String!,$s:Time!,$e:Time!,$w:String!){viewer{accounts(filter:{accountTag:$a}){
      byStatus: workersInvocationsAdaptive(limit:50,filter:{datetime_geq:$s,datetime_leq:$e,scriptName:$w},orderBy:[sum_requests_DESC]){sum{requests errors subrequests}quantiles{cpuTimeP50 cpuTimeP90 cpuTimeP99}dimensions{status}}
      all: workersInvocationsAdaptive(limit:1,filter:{datetime_geq:$s,datetime_leq:$e,scriptName:$w}){sum{requests errors}quantiles{cpuTimeP50 cpuTimeP90 cpuTimeP99 cpuTimeP999}}}}}`,
      { a: acc, s: s.toISOString(), e: e.toISOString(), w: script });
    const a = d.viewer.accounts[0];
    for (const x of a.byStatus) {
      const k = x.dimensions.status;
      byStatus[k] ??= { requests: 0, errors: 0, cpu_ms_p50: null, cpu_ms_p99: null };
      byStatus[k].requests += x.sum.requests; byStatus[k].errors += x.sum.errors;
      byStatus[k].cpu_ms_p50 = ms(x.quantiles.cpuTimeP50); byStatus[k].cpu_ms_p99 = ms(x.quantiles.cpuTimeP99);
    }
    if (a.all[0]) all = { requests: (all?.requests ?? 0) + a.all[0].sum.requests, errors: (all?.errors ?? 0) + a.all[0].sum.errors,
      cpu_ms_p50: ms(a.all[0].quantiles.cpuTimeP50), cpu_ms_p90: ms(a.all[0].quantiles.cpuTimeP90), cpu_ms_p99: ms(a.all[0].quantiles.cpuTimeP99), cpu_ms_p999: ms(a.all[0].quantiles.cpuTimeP999) };
  }
  report.invocations = { all, by_status: byStatus,
    exceeded_resources: Object.entries(byStatus).filter(([k]) => /exceeded/i.test(k)).reduce((n, [, v]) => n + v.requests, 0) };
} catch (e) { report.invocations = { unavailable: String(e.message ?? e) }; }

// 2. answers of 500 and above by path, from the zone's HTTP request analytics (Error 1102 is a 503 here)
try {
  const z = await (await fetch(`https://api.cloudflare.com/client/v4/zones?name=${domain}`, { headers: H })).json();
  const zone = z.result?.[0]?.id;
  if (!zone) throw new Error(`zone ${domain} not readable with this token`);
  const parts = [];
  for (let t = from.getTime(); t < to.getTime(); t += 24 * 3600_000) parts.push([new Date(t), new Date(Math.min(t + 24 * 3600_000, to.getTime()))]);
  const paths = {};
  let total = 0;
  for (const [s, e] of parts) {
    const d = await gql(`query($z:String!,$s:Time!,$e:Time!){viewer{zones(filter:{zoneTag:$z}){
      errors: httpRequestsAdaptiveGroups(limit:40,filter:{datetime_geq:$s,datetime_leq:$e,edgeResponseStatus_geq:500},orderBy:[count_DESC]){count dimensions{clientRequestPath edgeResponseStatus}}
      all: httpRequestsAdaptiveGroups(limit:1,filter:{datetime_geq:$s,datetime_leq:$e}){count}}}}`, { z: zone, s: s.toISOString(), e: e.toISOString() });
    const zz = d.viewer.zones[0];
    total += zz.all[0]?.count ?? 0;
    for (const x of zz.errors) { const k = `${x.dimensions.edgeResponseStatus} ${x.dimensions.clientRequestPath}`; paths[k] = (paths[k] ?? 0) + x.count; }
  }
  report.http = { requests: total, errors_5xx: Object.values(paths).reduce((a, b) => a + b, 0), by_path: Object.entries(paths).sort((a, b) => b[1] - a[1]).slice(0, 25).map(([k, n]) => ({ path: k, count: n })) };
} catch (e) { report.http = { unavailable: String(e.message ?? e) }; }

// 3. CPU time per path (Workers Observability, where the account has it and the token may query it)
try {
  const body = (path) => ({
    queryId: `carmacars-cpu-by-path-${Date.now()}`, view: 'calculations', limit: 40,
    timeframe: { from: from.getTime(), to: to.getTime() },
    parameters: {
      datasets: ['cloudflare-workers'],
      filters: [{ key: '$metadata.service', operation: 'eq', type: 'string', value: script }],
      calculations: [{ operator: 'count', alias: 'requests' }, { operator: 'p50', key: '$workers.cpuTimeMs', keyType: 'number', alias: 'p50' }, { operator: 'p99', key: '$workers.cpuTimeMs', keyType: 'number', alias: 'p99' }],
      groupBys: [{ type: 'string', value: path }], orderBy: { value: 'requests', order: 'desc' }, limit: 40
    }
  });
  let got = null, lastErr = '';
  for (const path of ['$workers.event.request.path', '$metadata.trigger', '$workers.event.request.url']) {
    const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${acc}/workers/observability/telemetry/query`, { method: 'POST', headers: H, body: JSON.stringify(body(path)) });
    const j = await r.json().catch(() => ({}));
    if (r.ok && j.success !== false && j.result) { got = { groupedBy: path, result: j.result }; break; }
    lastErr = `${r.status} ${JSON.stringify(j.errors ?? j).slice(0, 300)}`;
  }
  if (!got) throw new Error(lastErr);
  const rows = [];
  for (const c of got.result.calculations ?? []) {
    for (const g of c.aggregates ?? []) {
      const key = (g.groups ?? []).map((x) => x.value).join(' ') || '(all)';
      const row = rows.find((x) => x.path === key) ?? (rows.push({ path: key }), rows[rows.length - 1]);
      row[c.alias ?? c.calculation ?? 'value'] = typeof g.value === 'number' ? Math.round(g.value * 100) / 100 : g.value;
    }
  }
  report.cpu_by_path = { grouped_by: got.groupedBy, rows: rows.sort((a, b) => (b.requests ?? 0) - (a.requests ?? 0)).slice(0, 30) };
  if (!rows.length) report.cpu_by_path.raw = JSON.stringify(got.result).slice(0, 1500);
} catch (e) { report.cpu_by_path = { unavailable: String(e.message ?? e).slice(0, 400) }; }

if (out) fs.writeFileSync(out, JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
