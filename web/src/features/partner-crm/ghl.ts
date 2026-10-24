// The GoHighLevel (HighLevel, LeadConnector) API v2 client of the partner CRM link (migration 0136). No imports: it runs in
// the Worker and under `node --test`. Only this file and fake-ghl.ts know GoHighLevel's endpoints.
//
// Auth: a sub-account (location) Private Integration token, sent as "Authorization: Bearer pit-...", with the Version
// header. The token is never logged, never put in an error message and never returned (redact()).
//   GET    /locations/{locationId}                                   locations.readonly        (Test connection)
//   GET    /objects/?locationId=                                     objects/schema.readonly   (their custom objects)
//   GET    /objects/{key}?locationId=                                objects/schema.readonly
//   POST   /objects/                                                 objects/schema.write      (our "CarmaCars Vehicles" object)
//   GET    /custom-fields/object-key/{key}?locationId=               locations/customFields.readonly
//   POST   /custom-fields/folder, POST /custom-fields/               locations/customFields.write
//   POST   /objects/{key}/records/search                             objects/record.readonly   (their cars, when they keep them in an object)
//   POST   /objects/{key}/records, PUT|DELETE .../records/{id}       objects/record.write      (our cars)
//   GET    /products/?locationId=, GET /products/{id}/price          products.readonly, products/prices.readonly
//   POST|PUT|DELETE /products/..., POST|PUT /products/{id}/price      products.write, products/prices.write (the fallback)
//   GET    /opportunities/pipelines?locationId=                      opportunities.readonly
//   GET    /opportunities/search?location_id=&pipeline_id=...        opportunities.readonly    (leads they send us)
//   POST   /opportunities/                                           opportunities.write       (leads we send them)
//   POST   /contacts/upsert                                          contacts.write
// Limits (per app per location): 100 requests in 10 seconds, 200,000 a day. The X-RateLimit-* headers are read and the
// client waits when the burst window is nearly used; a 429 or a 5xx is tried again (3 times, with Retry-After).
// Custom objects and custom fields answer to Version v3 in HighLevel's current reference and to 2021-07-28 before it:
// the configured version is tried first, then the other, and the one that worked is kept for the run.

export const GHL_BASE = 'https://services.leadconnectorhq.com';
export const GHL_VERSIONS = ['2021-07-28', 'v3'] as const;

export interface GhlOptions {
  token: string;
  locationId: string;
  version?: string;
  base?: string;
  fetch?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  timeoutMs?: number;
  maxRetries?: number;
}

export class GhlError extends Error {
  readonly status: number;
  readonly path: string;
  constructor(message: string, status: number, path: string) { super(message); this.name = 'GhlError'; this.status = status; this.path = path; }
}

/** Every occurrence of the token (and anything shaped like one) out of a text. */
export function redact(text: string, token?: string): string {
  let s = String(text ?? '');
  if (token && token.length >= 6) s = s.split(token).join('[token]');
  return s.replace(/\bpit-[A-Za-z0-9-]{6,}/g, 'pit-[token]').replace(/Bearer\s+[A-Za-z0-9._-]{10,}/gi, 'Bearer [token]').slice(0, 500);
}

export interface GhlObjectSchema { id?: string; key: string; labels?: { singular?: string; plural?: string }; primaryDisplayProperty?: string }
export interface GhlField { id?: string; fieldKey?: string; name?: string; dataType?: string; parentId?: string }
export interface GhlRecord { id: string; properties: Record<string, unknown> }
export interface GhlProduct { _id?: string; id?: string; name: string; description?: string; image?: string; medias?: Array<{ url?: string; type?: string }>; productType?: string }
export interface GhlPrice { _id?: string; id?: string; name?: string; amount?: number; currency?: string; type?: string }
export interface GhlPipeline { id: string; name: string; stages: Array<{ id: string; name: string }> }
export interface GhlOpportunity { id: string; name?: string; monetaryValue?: number; pipelineStageId?: string; contactId?: string; contact?: { id?: string; name?: string; email?: string; phone?: string }; source?: string }

type Query = Record<string, string | number | undefined>;
interface Call { query?: Query; body?: unknown; versioned?: boolean; okStatuses?: number[] }

export interface Ghl {
  readonly locationId: string;
  request<T = unknown>(method: string, path: string, c?: Call): Promise<T>;
  location(): Promise<{ id: string; name?: string }>;
  listObjects(): Promise<GhlObjectSchema[]>;
  getObject(key: string): Promise<GhlObjectSchema | null>;
  createObject(key: string, singular: string, plural: string, description: string, primary: { key: string; name: string }): Promise<GhlObjectSchema>;
  objectFields(key: string): Promise<{ fields: GhlField[]; folders: Array<{ id: string; name?: string }> }>;
  createFolder(objectKey: string, name: string): Promise<{ id: string }>;
  createField(objectKey: string, parentId: string, f: { key: string; name: string; dataType: string }): Promise<GhlField>;
  searchRecords(key: string, page: number, pageLimit: number): Promise<{ records: GhlRecord[]; total: number }>;
  createRecord(key: string, properties: Record<string, unknown>): Promise<GhlRecord>;
  updateRecord(key: string, id: string, properties: Record<string, unknown>): Promise<GhlRecord>;
  deleteRecord(key: string, id: string): Promise<void>;
  listProducts(limit: number, offset: number): Promise<{ products: GhlProduct[]; total: number }>;
  createProduct(p: Record<string, unknown>): Promise<GhlProduct>;
  updateProduct(id: string, p: Record<string, unknown>): Promise<GhlProduct>;
  deleteProduct(id: string): Promise<void>;
  listPrices(productId: string): Promise<GhlPrice[]>;
  createPrice(productId: string, p: Record<string, unknown>): Promise<GhlPrice>;
  updatePrice(productId: string, priceId: string, p: Record<string, unknown>): Promise<GhlPrice>;
  pipelines(): Promise<GhlPipeline[]>;
  searchOpportunities(pipelineId: string, stageId: string, limit: number): Promise<GhlOpportunity[]>;
  createOpportunity(o: Record<string, unknown>): Promise<{ id: string }>;
  upsertContact(c: Record<string, unknown>): Promise<{ id: string; created: boolean }>;
  /** Requests made so far (the run's report). */
  readonly calls: number;
}

export const fullObjectKey = (k: string) => (k.startsWith('custom_objects.') || k.includes('.') ? k : `custom_objects.${k}`);
const idOf = (x: { _id?: string; id?: string } | null | undefined) => String(x?._id ?? x?.id ?? '');
const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function createGhl(o: GhlOptions): Ghl {
  if (!o.token) throw new GhlError('Not connected: no token', 0, '');
  if (!/^[A-Za-z0-9_-]{6,64}$/.test(o.locationId ?? '')) throw new GhlError('Not connected: no location ID', 0, '');
  const base = (o.base ?? GHL_BASE).replace(/\/$/, '');
  const f = o.fetch ?? fetch;
  const sleep = o.sleep ?? defaultSleep;
  const maxRetries = o.maxRetries ?? 3;
  const loc = o.locationId;
  const version = o.version && (GHL_VERSIONS as readonly string[]).includes(o.version) ? o.version : GHL_VERSIONS[0];
  let objectsVersion: string | null = null;
  let remaining: number | null = null;
  let windowMs = 10_000;
  let calls = 0;

  async function once(method: string, path: string, v: string, c: Call): Promise<{ status: number; data: unknown; headers: Headers }> {
    const q = Object.entries(c.query ?? {}).filter(([, x]) => x !== undefined && x !== '').map(([k, x]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(x))}`).join('&');
    const url = `${base}${path}${q ? `?${q}` : ''}`;
    for (let attempt = 0; ; attempt++) {
      // the burst window nearly used: wait for it to pass
      if (remaining !== null && remaining <= 2) { await sleep(Math.min(windowMs, 10_000)); remaining = null; }
      calls++;
      let r: Response;
      try {
        r = await f(url, {
          method,
          headers: { authorization: `Bearer ${o.token}`, version: v, accept: 'application/json', ...(c.body !== undefined ? { 'content-type': 'application/json' } : {}) },
          body: c.body !== undefined ? JSON.stringify(c.body) : undefined,
          signal: AbortSignal.timeout(o.timeoutMs ?? 20_000)
        });
      } catch (e) {
        if (attempt < maxRetries) { await sleep(500 * 2 ** attempt); continue; }
        throw new GhlError(`GoHighLevel did not answer (${redact(e instanceof Error ? e.message : String(e), o.token)})`, 0, path);
      }
      const rem = Number(r.headers.get('x-ratelimit-remaining'));
      if (Number.isFinite(rem) && r.headers.get('x-ratelimit-remaining') !== null) remaining = rem;
      const iv = Number(r.headers.get('x-ratelimit-interval-milliseconds'));
      if (Number.isFinite(iv) && iv > 0) windowMs = iv;
      if ((r.status === 429 || r.status >= 500) && attempt < maxRetries) {
        const ra = Number(r.headers.get('retry-after'));
        await sleep(Number.isFinite(ra) && ra > 0 ? Math.min(ra * 1000, 30_000) : r.status === 429 ? Math.min(windowMs, 10_000) : 500 * 2 ** attempt);
        continue;
      }
      const text = await r.text();
      let data: unknown = null;
      try { data = text ? JSON.parse(text) : null; } catch { data = { message: text.slice(0, 200) }; }
      return { status: r.status, data, headers: r.headers };
    }
  }

  const message = (d: unknown) => {
    const m = (d as { message?: unknown; error?: unknown } | null)?.message ?? (d as { error?: unknown } | null)?.error;
    return Array.isArray(m) ? m.join('; ') : typeof m === 'string' ? m : '';
  };

  async function request<T>(method: string, path: string, c: Call = {}): Promise<T> {
    const objects = c.versioned ?? (path.startsWith('/objects') || path.startsWith('/custom-fields'));
    const tries = objects ? [objectsVersion ?? version, ...GHL_VERSIONS.filter((x) => x !== (objectsVersion ?? version))] : [version];
    let last: { status: number; data: unknown } | null = null;
    for (const v of objectsVersion ? [objectsVersion] : tries) {
      const res = await once(method, path, v, c);
      if (res.status < 400 || c.okStatuses?.includes(res.status)) {
        if (objects) objectsVersion = v;
        return res.data as T;
      }
      last = res;
      // only a refusal that names the version is tried with the other one
      if (!(objects && [400, 404, 422].includes(res.status) && /version/i.test(message(res.data)))) break;
    }
    const st = last?.status ?? 0;
    const why = redact(message(last?.data), o.token);
    const plain = st === 401 ? 'The token was refused (check it, or make a new one)'
      : st === 403 ? 'The token is not allowed to do this (a scope is missing, or the location ID is not the token\'s)'
      : st === 404 ? 'Not found'
      : st === 422 ? 'GoHighLevel refused the data'
      : st === 429 ? 'Too many requests for now'
      : `GoHighLevel answered ${st}`;
    throw new GhlError(`${plain}${why ? `: ${why}` : ''} (${method} ${path.replace(/\/[A-Za-z0-9]{16,}(?=\/|$)/g, '/:id')})`, st, path);
  }

  const api: Ghl = {
    locationId: loc,
    get calls() { return calls; },
    request,
    async location() {
      const d = await request<{ location?: { id?: string; _id?: string; name?: string } }>('GET', `/locations/${encodeURIComponent(loc)}`);
      return { id: idOf(d.location) || loc, name: d.location?.name };
    },
    async listObjects() {
      const d = await request<{ objects?: GhlObjectSchema[] }>('GET', '/objects/', { query: { locationId: loc } });
      return d.objects ?? [];
    },
    async getObject(key) {
      try {
        const d = await request<{ object?: GhlObjectSchema }>('GET', `/objects/${encodeURIComponent(fullObjectKey(key))}`, { query: { locationId: loc } });
        return d.object ?? null;
      } catch (e) {
        if (e instanceof GhlError && (e.status === 404 || e.status === 400)) return null;
        throw e;
      }
    },
    async createObject(key, singular, plural, description, primary) {
      const k = fullObjectKey(key);
      const d = await request<{ object?: GhlObjectSchema }>('POST', '/objects/', { body: {
        labels: { singular, plural }, key: k, description, locationId: loc,
        primaryDisplayPropertyDetails: { key: `${k}.${primary.key}`, name: primary.name, dataType: 'TEXT' } } });
      return d.object ?? { key: k };
    },
    async objectFields(key) {
      const d = await request<{ fields?: GhlField[]; folders?: Array<{ id: string; name?: string }> }>('GET', `/custom-fields/object-key/${encodeURIComponent(fullObjectKey(key))}`, { query: { locationId: loc } });
      return { fields: d.fields ?? [], folders: d.folders ?? [] };
    },
    async createFolder(objectKey, name) {
      const d = await request<{ id?: string; folder?: { id?: string } }>('POST', '/custom-fields/folder', { body: { objectKey: fullObjectKey(objectKey), name, locationId: loc } });
      return { id: String(d.id ?? d.folder?.id ?? '') };
    },
    async createField(objectKey, parentId, x) {
      const k = fullObjectKey(objectKey);
      const d = await request<{ field?: GhlField }>('POST', '/custom-fields/', { body: {
        locationId: loc, name: x.name, dataType: x.dataType, fieldKey: `${k}.${x.key}`, objectKey: k, parentId, showInForms: false } });
      return d.field ?? { fieldKey: `${k}.${x.key}` };
    },
    async searchRecords(key, page, pageLimit) {
      const d = await request<{ records?: GhlRecord[]; total?: number }>('POST', `/objects/${encodeURIComponent(fullObjectKey(key))}/records/search`, { body: { locationId: loc, page, pageLimit, query: '', searchAfter: [] } });
      return { records: (d.records ?? []).map((r) => ({ id: String(r.id), properties: (r.properties ?? {}) as Record<string, unknown> })), total: Number(d.total ?? 0) };
    },
    async createRecord(key, properties) {
      const d = await request<{ record?: GhlRecord }>('POST', `/objects/${encodeURIComponent(fullObjectKey(key))}/records`, { body: { locationId: loc, properties } });
      return { id: String(d.record?.id ?? ''), properties: d.record?.properties ?? properties };
    },
    async updateRecord(key, id, properties) {
      const d = await request<{ record?: GhlRecord }>('PUT', `/objects/${encodeURIComponent(fullObjectKey(key))}/records/${encodeURIComponent(id)}`, { query: { locationId: loc }, body: { properties } });
      return { id: String(d.record?.id ?? id), properties: d.record?.properties ?? properties };
    },
    async deleteRecord(key, id) {
      await request('DELETE', `/objects/${encodeURIComponent(fullObjectKey(key))}/records/${encodeURIComponent(id)}`, { query: { locationId: loc }, okStatuses: [404] });
    },
    async listProducts(limit, offset) {
      const d = await request<{ products?: GhlProduct[]; total?: Array<{ total?: number }> | number }>('GET', '/products/', { query: { locationId: loc, limit, offset } });
      const total = Array.isArray(d.total) ? Number(d.total[0]?.total ?? 0) : Number(d.total ?? 0);
      return { products: d.products ?? [], total };
    },
    async createProduct(p) {
      const d = await request<GhlProduct & { product?: GhlProduct }>('POST', '/products/', { body: { ...p, locationId: loc } });
      return d.product ?? d;
    },
    async updateProduct(id, p) {
      const d = await request<GhlProduct & { product?: GhlProduct }>('PUT', `/products/${encodeURIComponent(id)}`, { body: { ...p, locationId: loc } });
      return d.product ?? d;
    },
    async deleteProduct(id) {
      await request('DELETE', `/products/${encodeURIComponent(id)}`, { query: { locationId: loc }, okStatuses: [404] });
    },
    async listPrices(productId) {
      const d = await request<{ prices?: GhlPrice[] } | GhlPrice[]>('GET', `/products/${encodeURIComponent(productId)}/price`, { query: { locationId: loc } });
      return Array.isArray(d) ? d : d.prices ?? [];
    },
    async createPrice(productId, p) {
      const d = await request<GhlPrice & { price?: GhlPrice }>('POST', `/products/${encodeURIComponent(productId)}/price`, { body: { ...p, locationId: loc } });
      return d.price ?? d;
    },
    async updatePrice(productId, priceId, p) {
      const d = await request<GhlPrice & { price?: GhlPrice }>('PUT', `/products/${encodeURIComponent(productId)}/price/${encodeURIComponent(priceId)}`, { body: { ...p, locationId: loc } });
      return d.price ?? d;
    },
    async pipelines() {
      const d = await request<{ pipelines?: GhlPipeline[] }>('GET', '/opportunities/pipelines', { query: { locationId: loc } });
      return (d.pipelines ?? []).map((p) => ({ id: String(p.id), name: String(p.name ?? ''), stages: (p.stages ?? []).map((s) => ({ id: String(s.id), name: String(s.name ?? '') })) }));
    },
    async searchOpportunities(pipelineId, stageId, limit) {
      const d = await request<{ opportunities?: GhlOpportunity[] }>('GET', '/opportunities/search', { query: { location_id: loc, pipeline_id: pipelineId, pipeline_stage_id: stageId, limit } });
      return d.opportunities ?? [];
    },
    async createOpportunity(x) {
      const d = await request<{ opportunity?: { id?: string } }>('POST', '/opportunities/', { body: { ...x, locationId: loc } });
      return { id: String(d.opportunity?.id ?? '') };
    },
    async upsertContact(x) {
      const d = await request<{ contact?: { id?: string }; new?: boolean }>('POST', '/contacts/upsert', { body: { ...x, locationId: loc } });
      return { id: String(d.contact?.id ?? ''), created: d.new === true };
    }
  };
  return api;
}

export const priceIdOf = (p: GhlPrice | null | undefined) => idOf(p);
export const productIdOf = (p: GhlProduct | null | undefined) => idOf(p);
