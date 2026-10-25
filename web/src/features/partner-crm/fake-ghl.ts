// A GoHighLevel stand-in (migration 0147): the endpoints ghl.ts uses, in memory, as a fetch function. The unit tests mock
// the API with it, and local work and the end-to-end tests use it (CRM_PROVIDER=fake) so nothing reaches a real CRM.
// A token containing "bad" is refused (401); "noobjects" has no custom objects (403, as a plan without them);
// "slow" answers 429 once per path first.
export interface FakeState {
  location: { id: string; name: string };
  objects: Map<string, { key: string; labels: { singular: string; plural: string } }>;
  fields: Map<string, Array<{ id: string; fieldKey: string; name: string; dataType: string; parentId: string }>>;
  folders: Map<string, Array<{ id: string; name: string }>>;
  records: Map<string, Map<string, { id: string; properties: Record<string, unknown> }>>;
  products: Map<string, { _id: string; name: string; description?: string; image?: string; medias?: Array<{ url: string; type: string }> }>;
  prices: Map<string, Array<{ _id: string; name: string; amount: number; currency: string; type: string }>>;
  pipelines: Array<{ id: string; name: string; stages: Array<{ id: string; name: string }> }>;
  opportunities: Array<{ id: string; name: string; pipelineId: string; pipelineStageId: string; contactId?: string; monetaryValue?: number; source?: string; contact?: { name?: string; email?: string; phone?: string } }>;
  contacts: Map<string, { id: string; email?: string; phone?: string; firstName?: string; lastName?: string; tags?: string[] }>;
  log: Array<{ method: string; path: string; version: string | null; auth: string | null }>;
}

export function fakeState(locationId = 'loc01motorsFAKE'): FakeState {
  return {
    location: { id: locationId, name: '01 Motors (test CRM)' },
    objects: new Map([['custom_objects.vehicles', { key: 'custom_objects.vehicles', labels: { singular: 'Vehicle', plural: 'Vehicles' } }]]),
    fields: new Map(), folders: new Map(), records: new Map([['custom_objects.vehicles', new Map([
      ['rec-g63', { id: 'rec-g63', properties: { name: 'Mercedes G63 AMG', make: 'Mercedes-Benz', model: 'G-Class', trim: 'G63 AMG', daily_rate: 1100, photos: 'https://images.example.test/g63-1.jpg https://images.example.test/g63-2.jpg', booked_dates: '2026-11-20 to 2026-11-22' } }],
      ['rec-new', { id: 'rec-new', properties: { name: '2025 Mercedes-Benz CLE 53 AMG Cabriolet', daily_rate: '$450', seats: 4 } }]
    ])]]),
    products: new Map(), prices: new Map(),
    pipelines: [{ id: 'pipeRentals01', name: 'Rentals', stages: [{ id: 'stageNew01', name: 'New lead' }, { id: 'stageSendCC', name: 'Send to CarmaCars' }] }],
    opportunities: [{ id: 'oppFromPartner1', name: 'Wants a Range Rover next weekend', pipelineId: 'pipeRentals01', pipelineStageId: 'stageSendCC', monetaryValue: 900, source: 'Instagram',
      contact: { name: 'Sam Example', email: 'sam.example@example.test', phone: '+14165550100' } }],
    contacts: new Map(), log: []
  };
}

let seq = 0;
const nid = (p: string) => `${p}${(++seq).toString(36).padStart(6, '0')}${Math.random().toString(36).slice(2, 8)}`;

export function fakeGhlFetch(state: FakeState = fakeState()): typeof fetch {
  const throttled = new Set<string>();
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const method = (init?.method ?? 'GET').toUpperCase();
    const h = new Headers(init?.headers);
    const auth = h.get('authorization');
    const version = h.get('version');
    const path = url.pathname;
    state.log.push({ method, path, version, auth: auth ? auth.replace(/Bearer\s+(\S{4})\S*/, 'Bearer $1...') : null });
    const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
    const json = (status: number, data: unknown, extra: Record<string, string> = {}) =>
      new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json', 'x-ratelimit-remaining': '90', 'x-ratelimit-max': '100', 'x-ratelimit-interval-milliseconds': '10000', ...extra } });
    const token = (auth ?? '').replace(/^Bearer\s+/i, '');
    if (!token.startsWith('pit-') || token.includes('bad')) return json(401, { statusCode: 401, message: 'Invalid JWT' });
    if (!version) return json(400, { statusCode: 400, message: 'version header was not found' });
    if (token.includes('slow') && !throttled.has(path)) { throttled.add(path); return json(429, { message: 'Too many requests' }, { 'retry-after': '0' }); }
    const loc = url.searchParams.get('locationId') ?? url.searchParams.get('location_id') ?? (body.locationId as string | undefined);
    if (path !== `/locations/${state.location.id}` && loc && loc !== state.location.id) return json(403, { statusCode: 403, message: 'The token does not have access to this location' });
    const noObjects = token.includes('noobjects');
    let m: RegExpMatchArray | null;

    if (method === 'GET' && (m = path.match(/^\/locations\/([^/]+)$/))) {
      return m[1] === state.location.id ? json(200, { location: { id: state.location.id, name: state.location.name } }) : json(403, { message: 'The token does not have access to this location' });
    }
    if (path.startsWith('/objects') || path.startsWith('/custom-fields')) {
      if (noObjects) return json(403, { statusCode: 403, message: 'Custom objects are not available on this plan' });
    }
    if (method === 'GET' && path === '/objects/') return json(200, { objects: [...state.objects.values()] });
    if (method === 'POST' && path === '/objects/') {
      const key = String(body.key);
      if (state.objects.has(key)) return json(400, { message: 'An object with that key exists' });
      state.objects.set(key, { key, labels: body.labels as { singular: string; plural: string } });
      state.records.set(key, new Map());
      const primary = body.primaryDisplayPropertyDetails as { key: string; name: string; dataType: string };
      state.fields.set(key, [{ id: nid('fld'), fieldKey: primary.key, name: primary.name, dataType: primary.dataType, parentId: '' }]);
      return json(201, { object: { id: nid('obj'), key, labels: body.labels } });
    }
    if (method === 'GET' && (m = path.match(/^\/custom-fields\/object-key\/([^/]+)$/))) {
      const key = decodeURIComponent(m[1]!);
      return json(200, { fields: state.fields.get(key) ?? [], folders: state.folders.get(key) ?? [] });
    }
    if (method === 'POST' && path === '/custom-fields/folder') {
      const f = { id: nid('fold'), name: String(body.name) };
      state.folders.set(String(body.objectKey), [...(state.folders.get(String(body.objectKey)) ?? []), f]);
      return json(201, { ...f, objectKey: body.objectKey, locationId: loc });
    }
    if (method === 'POST' && path === '/custom-fields/') {
      if (!body.parentId) return json(422, { message: ['parentId should not be empty'] });
      const f = { id: nid('fld'), fieldKey: String(body.fieldKey), name: String(body.name), dataType: String(body.dataType), parentId: String(body.parentId) };
      state.fields.set(String(body.objectKey), [...(state.fields.get(String(body.objectKey)) ?? []), f]);
      return json(201, { field: f });
    }
    if ((m = path.match(/^\/objects\/([^/]+)$/)) && method === 'GET') {
      const o = state.objects.get(decodeURIComponent(m[1]!));
      return o ? json(200, { object: o }) : json(404, { message: 'Object not found' });
    }
    if ((m = path.match(/^\/objects\/([^/]+)\/records\/search$/)) && method === 'POST') {
      const recs = [...(state.records.get(decodeURIComponent(m[1]!))?.values() ?? [])];
      const page = Number(body.page ?? 1), lim = Number(body.pageLimit ?? 10);
      return json(201, { records: recs.slice((page - 1) * lim, page * lim), total: recs.length });
    }
    if ((m = path.match(/^\/objects\/([^/]+)\/records$/)) && method === 'POST') {
      const key = decodeURIComponent(m[1]!);
      if (!state.objects.has(key)) return json(404, { message: 'Object not found' });
      const known = new Set((state.fields.get(key) ?? []).map((f) => f.fieldKey.split('.').pop()));
      const bad = Object.keys((body.properties ?? {}) as object).filter((k) => !known.has(k));
      if (bad.length) return json(422, { message: [`Unknown properties: ${bad.join(', ')}`] });
      const r = { id: nid('rec'), properties: body.properties as Record<string, unknown> };
      state.records.get(key)!.set(r.id, r);
      return json(201, { record: r });
    }
    if ((m = path.match(/^\/objects\/([^/]+)\/records\/([^/]+)$/))) {
      const key = decodeURIComponent(m[1]!), id = decodeURIComponent(m[2]!);
      const recs = state.records.get(key);
      if (!recs?.has(id)) return json(404, { message: 'Record not found' });
      if (method === 'PUT') { recs.set(id, { id, properties: body.properties as Record<string, unknown> }); return json(200, { record: recs.get(id) }); }
      if (method === 'DELETE') { recs.delete(id); return json(200, { id, success: true }); }
    }
    if (path === '/products/' && method === 'GET') {
      const all = [...state.products.values()];
      const lim = Number(url.searchParams.get('limit') ?? 20), off = Number(url.searchParams.get('offset') ?? 0);
      return json(200, { products: all.slice(off, off + lim), total: [{ total: all.length }] });
    }
    if (path === '/products/' && method === 'POST') {
      const p = { _id: nid('prod'), name: String(body.name), description: body.description as string | undefined, image: body.image as string | undefined, medias: body.medias as Array<{ url: string; type: string }> | undefined };
      state.products.set(p._id, p);
      return json(201, p);
    }
    if ((m = path.match(/^\/products\/([^/]+)$/))) {
      const id = decodeURIComponent(m[1]!);
      if (!state.products.has(id)) return json(404, { message: 'Product not found' });
      if (method === 'PUT') { state.products.set(id, { ...state.products.get(id)!, name: String(body.name), description: body.description as string, image: body.image as string, medias: body.medias as Array<{ url: string; type: string }> }); return json(200, state.products.get(id)); }
      if (method === 'DELETE') { state.products.delete(id); state.prices.delete(id); return json(200, { status: true }); }
    }
    if ((m = path.match(/^\/products\/([^/]+)\/price$/))) {
      const id = decodeURIComponent(m[1]!);
      if (!state.products.has(id)) return json(404, { message: 'Product not found' });
      if (method === 'GET') return json(200, { prices: state.prices.get(id) ?? [] });
      if (method === 'POST') { const pr = { _id: nid('price'), name: String(body.name), amount: Number(body.amount), currency: String(body.currency), type: String(body.type) }; state.prices.set(id, [...(state.prices.get(id) ?? []), pr]); return json(201, pr); }
    }
    if ((m = path.match(/^\/products\/([^/]+)\/price\/([^/]+)$/)) && method === 'PUT') {
      const list = state.prices.get(decodeURIComponent(m[1]!)) ?? [];
      const pr = list.find((x) => x._id === decodeURIComponent(m![2]!));
      if (!pr) return json(404, { message: 'Price not found' });
      Object.assign(pr, { name: String(body.name), amount: Number(body.amount) });
      return json(200, pr);
    }
    if (path === '/opportunities/pipelines' && method === 'GET') return json(200, { pipelines: state.pipelines });
    if (path === '/opportunities/search' && method === 'GET') {
      const p = url.searchParams.get('pipeline_id'), s = url.searchParams.get('pipeline_stage_id');
      return json(200, { opportunities: state.opportunities.filter((o) => (!p || o.pipelineId === p) && (!s || o.pipelineStageId === s)), meta: { total: state.opportunities.length } });
    }
    if (path === '/opportunities/' && method === 'POST') {
      if (!body.pipelineId || !body.contactId || !body.name) return json(422, { message: ['pipelineId, contactId and name are required'] });
      const o = { id: nid('opp'), name: String(body.name), pipelineId: String(body.pipelineId), pipelineStageId: String(body.pipelineStageId), contactId: String(body.contactId), monetaryValue: body.monetaryValue as number | undefined, source: body.source as string | undefined };
      state.opportunities.push(o);
      return json(201, { opportunity: o });
    }
    if (path === '/contacts/upsert' && method === 'POST') {
      const found = [...state.contacts.values()].find((c) => (body.email && c.email === body.email) || (body.phone && c.phone === body.phone));
      const c = { ...(found ?? { id: nid('con') }), email: body.email as string | undefined, phone: body.phone as string | undefined, firstName: body.firstName as string | undefined, lastName: body.lastName as string | undefined, tags: body.tags as string[] | undefined };
      state.contacts.set(c.id, c);
      return json(found ? 200 : 201, { new: !found, contact: c });
    }
    return json(404, { message: `No such endpoint in the stand-in: ${method} ${path}` });
  }) as typeof fetch;
}
