// The Worker's failures from Workers Observability (the verify and cf-logs workflows): invocations by outcome
// (ok, exception, exceededCpu, exceededResources, canceled) for a window, and the newest failed events (an exception,
// a CPU or resource limit, or a 5xx answer) with the route, the message and the stack. No personal data leaves here:
// paths without their query string, no headers, no cookies, no request bodies, email addresses and long tokens masked.
//
//   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ACCOUNT_ID=... node scripts/cf-errors.mjs [--hours 24] [--from <ms>] [--to <ms>]
//        [--script carmacars-prod] [--limit 50] [--out file.json]
// The token needs Account > Workers Observability > Read. Without it the report says so (and exits 0).
import fs from 'node:fs';

const arg = (k, d) => { const i = process.argv.indexOf('--' + k); return i > 0 ? process.argv[i + 1] : d; };
const token = process.env.CLOUDFLARE_API_TOKEN, acc = process.env.CLOUDFLARE_ACCOUNT_ID;
const script = arg('script', 'carmacars-prod');
const limit = Math.min(Number(arg('limit', '50')), 100);
const out = arg('out');
const to = Number(arg('to', String(Date.now())));
const from = Number(arg('from', String(to - Number(arg('hours', '24')) * 3600_000)));
const PERMISSION = 'Account > Workers Observability > Read (or Workers Tail Read) on the CLOUDFLARE_API_TOKEN secret';

export function clean(s, n = 500) {
  if (s == null) return null;
  return String(s)
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, '<email>')
    .replace(/\b(eyJ[\w-]+\.[\w-]+\.[\w-]+)\b/g, '<jwt>')
    .replace(/\b(sk|pk|rk|whsec|re)_[A-Za-z0-9_]{8,}\b/g, '<key>')
    .replace(/\b[a-f0-9]{32,}\b/gi, '<hex>')
    .replace(/(https?:\/\/[^\s?#"']+)\?[^\s#"']*/g, '$1')
    .slice(0, n);
}
export function routeOf(u) {
  if (!u) return null;
  try { return new URL(u, 'https://x').pathname; } catch { return clean(String(u).split('?')[0], 200); }
}
const get = (o, path) => path.split('.').reduce((x, k) => (x == null ? undefined : x[k]), o);
const first = (o, ...paths) => { for (const p of paths) { const v = get(o, p); if (v !== undefined && v !== null && v !== '') return v; } return undefined; };

/** One failed event as kept in the report (fields picked one by one; nothing else of the event is copied). */
export function pick(e) {
  const w = e.$workers ?? {}, m = e.$metadata ?? {};
  const url = first(w, 'event.request.url', 'event.request.path') ?? first(m, 'url');
  const status = first(w, 'event.response.status') ?? first(m, 'statusCode', 'status');
  const stack = first(m, 'stack', 'error.stack') ?? first(e, 'source.stack', 'source.error.stack', 'source.exception.stack');
  const message = first(m, 'error', 'message') ?? first(e, 'source.message', 'source.error.message', 'source.exception.message');
  return {
    at: e.timestamp ?? m.timestamp ?? null, outcome: w.outcome ?? null, status: status ?? null,
    method: first(w, 'event.request.method') ?? null, route: routeOf(url), trigger: w.eventType ?? m.trigger ?? null,
    cpu_ms: w.cpuTimeMs ?? null, wall_ms: w.wallTimeMs ?? null, level: m.level ?? null,
    message: clean(message), stack: clean(stack, 1500), request_id: m.requestId ?? w.requestId ?? null
  };
}

async function query(body) {
  const r = await fetch(`https://api.cloudflare.com/client/v4/accounts/${acc}/workers/observability/telemetry/query`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify(body)
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.success === false) {
    const msg = JSON.stringify(j.errors ?? j).slice(0, 300);
    const err = new Error(`${r.status} ${msg}`); err.status = r.status; throw err;
  }
  return j.result ?? {};
}
const base = { datasets: ['cloudflare-workers'] };
const byScript = { key: '$metadata.service', operation: 'eq', type: 'string', value: script };

async function main() {
  const report = { script, from: new Date(from).toISOString(), to: new Date(to).toISOString() };
  if (!token || !acc) { report.unavailable = 'CLOUDFLARE_API_TOKEN or CLOUDFLARE_ACCOUNT_ID is not set'; return report; }
  // 1. invocations by outcome
  try {
    const res = await query({ queryId: `carmacars-outcomes-${Date.now()}`, view: 'calculations', limit: 20, timeframe: { from, to },
      parameters: { ...base, filters: [byScript], calculations: [{ operator: 'count', alias: 'n' }, { operator: 'p99', key: '$workers.cpuTimeMs', keyType: 'number', alias: 'cpu_p99' }],
        groupBys: [{ type: 'string', value: '$workers.outcome' }], orderBy: { value: 'n', order: 'desc' }, limit: 20 } });
    const outcomes = {};
    for (const c of res.calculations ?? []) for (const g of c.aggregates ?? []) {
      const k = (g.groups ?? []).map((x) => x.value).join(' ') || '(none)';
      outcomes[k] = { ...(outcomes[k] ?? {}), [c.alias ?? 'value']: typeof g.value === 'number' ? Math.round(g.value * 100) / 100 : g.value };
    }
    report.outcomes = outcomes;
  } catch (e) {
    report.unavailable = String(e.message).slice(0, 300);
    if (e.status === 401 || e.status === 403 || /auth|permission/i.test(e.message)) report.permission_needed = PERMISSION;
    return report;
  }
  // 2. the newest failed events
  try {
    const res = await query({ queryId: `carmacars-failures-${Date.now()}`, view: 'events', limit, timeframe: { from, to },
      parameters: { ...base, filters: [byScript,
        { key: '$workers.outcome', operation: 'neq', type: 'string', value: 'ok' }] } });
    const res5 = await query({ queryId: `carmacars-5xx-${Date.now()}`, view: 'events', limit, timeframe: { from, to },
      parameters: { ...base, filters: [byScript, { key: '$workers.event.response.status', operation: 'gte', type: 'number', value: 500 }] } }).catch(() => ({}));
    const events = [...(res.events?.events ?? res.events ?? []), ...(res5.events?.events ?? res5.events ?? [])];
    const seen = new Set();
    report.failures = events.map(pick).filter((x) => { const k = `${x.at}|${x.route}|${x.request_id}`; if (seen.has(k)) return false; seen.add(k); return true; })
      .sort((a, b) => String(b.at).localeCompare(String(a.at))).slice(0, limit);
    const by = {};
    for (const f of report.failures) { const k = `${f.outcome ?? '?'} ${f.status ?? ''} ${f.route ?? f.trigger ?? '?'}`.replace(/\s+/g, ' '); by[k] = (by[k] ?? 0) + 1; }
    report.failures_by_route = Object.entries(by).sort((a, b) => b[1] - a[1]).map(([k, n]) => ({ key: k, count: n }));
  } catch (e) { report.failures_unavailable = String(e.message).slice(0, 300); }
  return report;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const report = await main();
  if (out) fs.writeFileSync(out, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
}
