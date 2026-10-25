// One run of a partner's CRM link (migration 0147), without the database or the network of its own: the job comes
// from public.server_partner_crm_job, the client is ghl.ts (or the fake), and the report goes back to
// public.server_partner_crm_done. No imports outside this folder: Worker and `node --test`.
import { GhlError, fullObjectKey, priceIdOf, productIdOf, type Ghl } from './ghl.ts';
import {
  OBJECT_DESCRIPTION, OBJECT_FIELDS, OBJECT_LABELS, PRIMARY, fromFeed, fromProduct, fromRecord, payloadHash, photoUrls, priceBody, productBody,
  recordProperties, shareable, toCents, type InboundCar, type OutboundCar
} from './mapping.ts';

export type Target = 'custom_object' | 'products';
export interface Connection {
  id: string; partner_id: string; partner: string; location_id: string; api_version: string; enabled: boolean; share_cars: boolean;
  outbound_target: 'auto' | Target; detected_target: Target | null; object_key: string;
  inbound_enabled: boolean; inbound_source: 'auto' | 'custom_object' | 'products' | 'feed' | 'off'; inbound_object_key: string | null; inbound_feed_url: string | null;
  leads_enabled: boolean; pipeline_id: string | null; pipeline_stage_id: string | null; inbound_stage_id: string | null; referral_code: string;
}
export interface RecordRow { vehicle_id: string; remote_kind: 'object_record' | 'product'; remote_id: string; price_id: string | null; payload_hash: string | null }
export interface LeadDue { booking_id: string; booking_number: string; reason: 'partner_car' | 'referral'; status: string; name: string | null; email: string | null; phone: string | null;
  car: string; pickup_at: string; return_at: string; total_cents: number | null }
export interface Job { run_id: string; connection: Connection; cars: OutboundCar[]; records: RecordRow[]; leads: LeadDue[]; known_opportunities: string[]; site: { url: string; name: string; city?: string | null } }
export interface Deps { ghl: Ghl; bucketUrl: (path: string) => string; fetchFeed?: (url: string) => Promise<string>; maxInbound?: number }

export interface Report {
  run_id: string; connection_id: string; kind: 'sync'; ok: boolean; error: string | null; target: Target | null;
  counts: Record<string, number>;
  records: Array<{ vehicle_id: string; remote_kind: RecordRow['remote_kind']; remote_id: string; price_id: string | null; payload_hash: string }>;
  removed: Array<{ vehicle_id: string; remote_kind: RecordRow['remote_kind'] }>;
  inbound: InboundCar[] | null;
  leads: Array<{ booking_id: string; reason: string; ok: boolean; skipped?: boolean; contact_id?: string | null; opportunity_id?: string | null; error?: string | null }>;
  partner_leads: Array<{ opportunity_id: string; name: string | null; email: string | null; phone: string | null; car: string | null; note: string | null; value_cents: number | null }>;
}

const msg = (e: unknown) => (e instanceof Error ? e.message : String(e)).slice(0, 300);
const denied = (e: unknown) => e instanceof GhlError && [401, 403, 404].includes(e.status);

/** Makes sure our object and its fields exist in their location. Returns false when their plan or token has no
 *  custom objects (the caller falls back to products). */
export async function ensureObject(ghl: Ghl, key: string): Promise<{ ok: boolean; created: boolean; fieldsAdded: number; problems: string[] }> {
  const problems: string[] = [];
  let created = false;
  try {
    let o = await ghl.getObject(key);
    if (!o) { o = await ghl.createObject(key, OBJECT_LABELS.singular, OBJECT_LABELS.plural, OBJECT_DESCRIPTION, PRIMARY); created = true; }
  } catch (e) {
    if (denied(e)) return { ok: false, created: false, fieldsAdded: 0, problems: [msg(e)] };
    throw e;
  }
  let fieldsAdded = 0;
  try {
    const { fields, folders } = await ghl.objectFields(key);
    const have = new Set(fields.map((f) => String(f.fieldKey ?? '').split('.').pop()));
    const missing = OBJECT_FIELDS.filter((f) => !have.has(f.key));
    if (missing.length) {
      const parent = folders[0]?.id || (await ghl.createFolder(key, 'CarmaCars')).id;
      for (const f of missing) {
        try { await ghl.createField(key, parent, f); fieldsAdded++; } catch (e) { problems.push(`field ${f.key}: ${msg(e)}`); }
      }
    }
  } catch (e) {
    problems.push(`fields: ${msg(e)}`);
  }
  return { ok: true, created, fieldsAdded, problems };
}

async function outbound(job: Job, d: Deps, r: Report): Promise<void> {
  const c = job.connection;
  const { cars, refused } = shareable(job.cars);
  r.counts.cars = cars.length;
  r.counts.refused = refused;
  let target: Target = c.outbound_target === 'auto' ? c.detected_target ?? 'custom_object' : c.outbound_target;
  if (target === 'custom_object') {
    const o = await ensureObject(d.ghl, c.object_key);
    r.counts.fields_added = o.fieldsAdded;
    if (o.problems.length) r.counts.field_problems = o.problems.length;
    if (!o.ok) {
      if (c.outbound_target === 'custom_object') throw new Error(`Custom objects are not available with this token or plan (${o.problems[0] ?? ''}). Choose Products, or add the objects scopes`);
      target = 'products';
    }
  }
  r.target = target;
  const kind: RecordRow['remote_kind'] = target === 'custom_object' ? 'object_record' : 'product';
  const mine = new Map(job.records.filter((x) => x.remote_kind === kind).map((x) => [x.vehicle_id, x]));
  const live = new Set(cars.map((x) => x.vehicle_id));
  for (const k of ['created', 'updated', 'unchanged', 'removed', 'failed']) r.counts[k] = 0;
  const errors: string[] = [];
  for (const car of cars) {
    const photos = photoUrls(car.photos ?? [], job.site.url, d.bucketUrl);
    const rec = mine.get(car.vehicle_id);
    try {
      if (kind === 'object_record') {
        const props = recordProperties(car, photos);
        const hash = payloadHash({ kind, props });
        if (rec && rec.payload_hash === hash) { r.counts.unchanged!++; continue; }
        let id = rec?.remote_id ?? '';
        if (id) {
          try { await d.ghl.updateRecord(c.object_key, id, props); r.counts.updated!++; }
          catch (e) { if (e instanceof GhlError && e.status === 404) { id = (await d.ghl.createRecord(c.object_key, props)).id; r.counts.created!++; } else throw e; }
        } else { id = (await d.ghl.createRecord(c.object_key, props)).id; r.counts.created!++; }
        if (!id) throw new Error('GoHighLevel gave no record id');
        r.records.push({ vehicle_id: car.vehicle_id, remote_kind: kind, remote_id: id, price_id: null, payload_hash: hash });
      } else {
        const body = productBody(car, photos);
        const price = priceBody(car);
        const hash = payloadHash({ kind, body, price });
        if (rec && rec.payload_hash === hash) { r.counts.unchanged!++; continue; }
        let id = rec?.remote_id ?? '';
        let priceId = rec?.price_id ?? null;
        if (id) {
          try { await d.ghl.updateProduct(id, body); r.counts.updated!++; }
          catch (e) { if (e instanceof GhlError && e.status === 404) { id = productIdOf(await d.ghl.createProduct(body)); priceId = null; r.counts.created!++; } else throw e; }
        } else { id = productIdOf(await d.ghl.createProduct(body)); r.counts.created!++; }
        if (!id) throw new Error('GoHighLevel gave no product id');
        if (price) {
          if (priceId) {
            try { await d.ghl.updatePrice(id, priceId, price); }
            catch (e) { if (e instanceof GhlError && e.status === 404) priceId = priceIdOf(await d.ghl.createPrice(id, price)) || null; else throw e; }
          } else priceId = priceIdOf(await d.ghl.createPrice(id, price)) || null;
        }
        r.records.push({ vehicle_id: car.vehicle_id, remote_kind: kind, remote_id: id, price_id: priceId, payload_hash: hash });
      }
    } catch (e) {
      r.counts.failed!++;
      if (errors.length < 3) errors.push(`${car.car_code ?? car.name}: ${msg(e)}`);
    }
  }
  // a car no longer shared (sold, off the site, retired, a setting changed): removed from their CRM
  for (const rec of job.records) {
    if (live.has(rec.vehicle_id) && rec.remote_kind === kind) continue;
    try {
      if (rec.remote_kind === 'object_record') await d.ghl.deleteRecord(c.object_key, rec.remote_id); else await d.ghl.deleteProduct(rec.remote_id);
      r.removed.push({ vehicle_id: rec.vehicle_id, remote_kind: rec.remote_kind });
      r.counts.removed!++;
    } catch (e) {
      if (errors.length < 3) errors.push(`remove ${rec.remote_id}: ${msg(e)}`);
    }
  }
  if (errors.length) throw new Error(errors.join('; '));
}

/** Their cars, from where the link says (auto: the object named, else the feed; products only when chosen). */
export async function readInbound(job: Job, d: Deps): Promise<InboundCar[] | null> {
  const c = job.connection;
  if (!c.inbound_enabled || c.inbound_source === 'off') return null;
  const source = c.inbound_source === 'auto' ? (c.inbound_object_key ? 'custom_object' : c.inbound_feed_url ? 'feed' : null) : c.inbound_source;
  const max = d.maxInbound ?? 300;
  if (source === 'custom_object' && c.inbound_object_key) {
    if (fullObjectKey(c.inbound_object_key) === fullObjectKey(c.object_key)) throw new Error('Their cars cannot come from the object we fill with ours');
    const out: InboundCar[] = [];
    for (let page = 1; page <= 10 && out.length < max; page++) {
      const { records } = await d.ghl.searchRecords(c.inbound_object_key, page, 100);
      out.push(...records.map(fromRecord));
      if (records.length < 100) break;
    }
    return out.slice(0, max);
  }
  if (source === 'products') {
    const ours = new Set(job.records.filter((x) => x.remote_kind === 'product').map((x) => x.remote_id));
    const out: InboundCar[] = [];
    for (let offset = 0; offset < max; offset += 100) {
      const { products } = await d.ghl.listProducts(100, offset);
      for (const p of products) {
        const id = productIdOf(p);
        if (!id || ours.has(id)) continue;
        let daily: number | null = null;
        try {
          const prices = await d.ghl.listPrices(id);
          const best = prices.find((x) => /day|daily/i.test(String(x.name ?? ''))) ?? prices[0];
          daily = toCents(best?.amount);
        } catch { /* a product without prices is still a car to review */ }
        out.push(fromProduct(p, daily));
      }
      if (products.length < 100) break;
    }
    return out.slice(0, max);
  }
  if (source === 'feed' && c.inbound_feed_url) {
    if (!d.fetchFeed) throw new Error('Their feed cannot be read here');
    return fromFeed(await d.fetchFeed(c.inbound_feed_url)).slice(0, max);
  }
  return null;
}

async function leads(job: Job, d: Deps, r: Report): Promise<void> {
  const c = job.connection;
  if (!c.leads_enabled) return;
  r.counts.leads_sent = 0; r.counts.leads_failed = 0; r.counts.partner_leads = 0;
  if (c.pipeline_id && c.pipeline_stage_id) {
    for (const l of job.leads) {
      if (!l.email && !l.phone) { r.leads.push({ booking_id: l.booking_id, reason: l.reason, ok: false, skipped: true, error: 'No email or phone' }); continue; }
      try {
        const [first, ...last] = String(l.name ?? '').trim().split(/\s+/);
        const contact = await d.ghl.upsertContact({ firstName: first || undefined, lastName: last.join(' ') || undefined, email: l.email ?? undefined, phone: l.phone ?? undefined,
          source: job.site.name, tags: ['carmacars', l.reason === 'referral' ? 'carmacars-referral' : 'carmacars-booking'] });
        const opp = await d.ghl.createOpportunity({ pipelineId: c.pipeline_id, pipelineStageId: c.pipeline_stage_id, contactId: contact.id, status: 'open',
          name: `${l.car} · ${job.site.name} ${l.booking_number}`.slice(0, 200), monetaryValue: l.total_cents ? Math.round(l.total_cents) / 100 : undefined,
          source: l.reason === 'referral' ? `${job.site.name} (your booking link)` : `${job.site.name} (your car)` });
        r.leads.push({ booking_id: l.booking_id, reason: l.reason, ok: true, contact_id: contact.id, opportunity_id: opp.id });
        r.counts.leads_sent!++;
      } catch (e) {
        r.leads.push({ booking_id: l.booking_id, reason: l.reason, ok: false, error: msg(e) });
        r.counts.leads_failed!++;
      }
    }
  }
  if (c.pipeline_id && c.inbound_stage_id) {
    const known = new Set(job.known_opportunities);
    for (const o of await d.ghl.searchOpportunities(c.pipeline_id, c.inbound_stage_id, 50)) {
      if (!o.id || known.has(o.id)) continue;
      r.partner_leads.push({ opportunity_id: o.id, name: o.contact?.name ?? null, email: o.contact?.email ?? null, phone: o.contact?.phone ?? null,
        car: o.name ?? null, note: o.source ? `Source: ${o.source}` : null, value_cents: o.monetaryValue ? Math.round(o.monetaryValue * 100) : null });
      r.counts.partner_leads!++;
    }
  }
}

/** One sync: our cars out, theirs in, leads both ways. Each part fails on its own; the run says what failed. */
export async function runSync(job: Job, d: Deps): Promise<Report> {
  const r: Report = { run_id: job.run_id, connection_id: job.connection.id, kind: 'sync', ok: true, error: null, target: null, counts: {}, records: [], removed: [], inbound: null, leads: [], partner_leads: [] };
  const errors: string[] = [];
  if (job.connection.share_cars) {
    try { await outbound(job, d, r); } catch (e) { errors.push(`Our cars: ${msg(e)}`); }
  }
  try { r.inbound = await readInbound(job, d); if (r.inbound) r.counts.their_cars = r.inbound.length; } catch (e) { r.inbound = null; errors.push(`Their cars: ${msg(e)}`); }
  try { await leads(job, d, r); } catch (e) { errors.push(`Leads: ${msg(e)}`); }
  r.counts.requests = d.ghl.calls;
  r.ok = errors.length === 0;
  r.error = errors.length ? errors.join(' | ').slice(0, 1000) : null;
  return r;
}

export interface TestReport {
  ok: boolean; error: string | null; target: Target | null;
  test: { location: { id: string; name: string | null } | null; checks: Record<string, { ok: boolean; note?: string }>; objects: Array<{ key: string; label: string }>;
    pipelines: Array<{ id: string; name: string; stages: Array<{ id: string; name: string }> }>; requests: number };
}
/** Test connection: reads only (the location, their objects, products, pipelines); never writes to their CRM. */
export async function testConnection(ghl: Ghl): Promise<TestReport> {
  const checks: TestReport['test']['checks'] = {};
  let location: TestReport['test']['location'] = null;
  let objects: TestReport['test']['objects'] = [];
  let pipelines: TestReport['test']['pipelines'] = [];
  try { const l = await ghl.location(); location = { id: l.id, name: l.name ?? null }; checks.location = { ok: true }; }
  catch (e) { checks.location = { ok: false, note: msg(e) }; }
  if (checks.location?.ok === false && /refused/.test(checks.location.note ?? '')) {
    return { ok: false, error: checks.location.note ?? 'The token was refused', target: null, test: { location, checks, objects, pipelines, requests: ghl.calls } };
  }
  try { objects = (await ghl.listObjects()).map((o) => ({ key: String(o.key), label: String(o.labels?.plural ?? o.labels?.singular ?? o.key) })); checks.objects = { ok: true }; }
  catch (e) { checks.objects = { ok: false, note: msg(e) }; }
  try { await ghl.listProducts(1, 0); checks.products = { ok: true }; } catch (e) { checks.products = { ok: false, note: msg(e) }; }
  try { pipelines = await ghl.pipelines(); checks.pipelines = { ok: true }; } catch (e) { checks.pipelines = { ok: false, note: msg(e) }; }
  const target: Target | null = checks.objects.ok ? 'custom_object' : checks.products.ok ? 'products' : null;
  const ok = !!checks.location?.ok && target !== null;
  const error = ok ? null : !checks.location?.ok ? checks.location?.note ?? 'The location could not be read' : 'Neither custom objects nor products can be used with this token';
  return { ok, error, target, test: { location, checks, objects, pipelines, requests: ghl.calls } };
}
