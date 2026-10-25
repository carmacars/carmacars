// The kit's facts from each page's own read: a place hub (migration 0095) and the vehicle pages and their twins (0097).
// Pure (type imports only), so the unit tests build pages from fixtures exactly as the routes do.
import type { KitValues } from './engine.ts';
import { type KitPage, type PageKind, type SpecIn, type VehicleIn, baseTags, placeFacts, termFacts, vehicleFacts, withArticle } from './facts.ts';
import type { Hub } from '../places/data.ts';

const TOKENS = ['brand', 'city', 'maxDays', 'weekFrom', 'minAge', 'fullAge', 'licence', 'depLead', 'notice', 'offerHours', 'hst', 'airports', 'delMin', 'reply', 'pet'] as const;
/** Only the site tokens the library uses (an empty one makes its sentences skip). */
export function kitTokens(t: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const k of TOKENS) if (t[k]) out[k] = t[k]!;
  return out;
}

const AUTO = (lead?: string | null) => lead === 'auto_service';

/** A place hub: /car-rental/<term>/<place>, /detailing/..., /body-shop/..., /buy/<sale term>/<place>. */
export function hubKit(h: Hub, label: string, tokens: Record<string, string>, note?: string): KitPage {
  const v = h.term.vertical;
  const wide = ['country', 'province', 'area', 'region'].includes(h.place.kind);
  const kind: PageKind = AUTO(h.term.lead_kind) ? 'hub-auto' : v === 'sale' ? 'hub-sale' : v === 'detailing' ? 'hub-detailing' : v === 'bodyshop' ? 'hub-bodyshop'
    : h.term.served === 'request' ? 'hub-request' : wide ? 'hub-wide' : 'hub-rental';
  const tags = baseTags(kind, [v]);
  const values: KitValues = {};
  const parent = [...h.ancestors].reverse().find((a) => a.kind === 'city');
  placeFacts({ slug: h.place.slug, name: h.place.name, label, kind: h.place.kind, country: h.place.country, region: h.place.region, regionName: h.place.region_name,
    gta: !!h.place.gta, inToronto: h.ancestors.some((a) => a.slug === 'toronto'), km: h.delivery.km, inReach: !!h.delivery.in_reach, reachKm: h.delivery.reach_km,
    feeFromCents: h.delivery.fee_from_cents ?? null, originLabel: h.origin.label, parent: h.place.kind === 'neighbourhood' ? parent?.name ?? null : null,
    airport: h.airport, nearby: h.nearby.map((n) => n.name), landmarks: h.landmarks.map((l) => l.name), within: [...(h.gta_members ?? []), ...h.children].map((c) => c.name) }, values, tags);
  termFacts({ slug: h.term.slug, title: h.term.title, phrase: h.term.phrase, vertical: v, served: h.term.served, lead: h.term.lead_kind, note: note ?? h.term.intent_note, synonym: !!h.term.canonical_path }, values, tags);
  if (h.service) { values.service = h.service.name.charAt(0).toLowerCase() + h.service.name.slice(1); if (h.service.from_price_cents) { tags.add('svcprice'); values.servicePrice = `$${Math.round(h.service.from_price_cents / 100).toLocaleString('en-CA')}`; } }
  const cars = h.counts?.car_count ?? h.cars.length;
  if (cars > 0) { values.cars = cars; tags.add('cars'); }
  // a price only from real cars (never the sample cars' example rates)
  if ((h.real_cars ?? 0) > 0 && h.counts?.min_daily_cents) { values.fromDaily = `$${Math.round(h.counts.min_daily_cents / 100)}`; tags.add('price'); }
  return { kind, path: h.path, values, tags, tokens: kitTokens(tokens) };
}

/** The vehicle pages and their twins: /cars/..., /buy/..., /t/<term>/... */
export interface VehiclePageIn extends VehicleIn {
  path: string; level: 'make' | 'model' | 'year' | 'trim' | 'city' | 'colour' | 'city_colour';
  mode?: 'cars' | 'rental' | 'sale' | 'detailing' | 'bodyshop';
  term?: { slug: string; name: string; phrase?: string | null; kind: string; lead?: string | null; note?: string | null } | null;
  city?: { name: string; kind: string; km: number | null; feeCents?: number | null; parent?: string | null; nearby?: string[]; airport?: string | null; reachKm?: number } | null;
}
export function vehicleKit(x: VehiclePageIn, tokens: Record<string, string>): KitPage {
  const mode = x.mode ?? 'cars';
  const tier = x.level === 'city' || x.level === 'colour' || x.level === 'city_colour';
  const kind: PageKind = mode === 'cars' ? (x.level === 'make' ? 'car-make' : x.level === 'model' ? 'car-model' : x.level === 'year' ? 'car-year' : x.level === 'trim' ? 'car-trim' : 'car-tier')
    : mode === 'sale' ? 'twin-sale' : mode === 'detailing' ? 'twin-detailing' : mode === 'bodyshop' ? (AUTO(x.term?.lead) ? 'twin-auto' : 'twin-bodyshop') : 'twin-rental';
  const tags = baseTags(kind, [`level-${x.level}`, ...(tier ? ['tier'] : [])]);
  const values: KitValues = {};
  vehicleFacts(x, values, tags);
  if (values.trans) values.aTrans = withArticle(String(values.trans));
  if (x.term) termFacts({ slug: x.term.slug, title: x.term.name, phrase: x.term.phrase, vertical: x.term.kind, lead: x.term.lead, note: x.term.note }, values, tags);
  if (x.city) {
    const reach = x.city.reachKm ?? 80;
    const local = ['city', 'neighbourhood', 'airport'].includes(x.city.kind);
    tags.add('city');
    values.place = x.city.name;
    if (!local) tags.add('wide');
    else if (x.city.km !== null && x.city.km !== undefined) {
      values.km = Math.round(x.city.km);
      tags.add(x.city.km <= reach ? 'served' : 'far');
      if (x.city.km <= reach && x.city.feeCents) { values.deliveryFrom = `$${Math.round(x.city.feeCents / 100)}`; tags.add('fee'); }
    }
    if (x.city.parent && x.city.parent !== x.city.name) values.parentCity = x.city.parent;
    if (x.city.nearby?.length) { values.nearbyList = x.city.nearby.slice(0, 3).join(', ').replace(/, ([^,]*)$/, ' and $1'); tags.add('nearby'); }
    if (x.city.airport) { values.airport = x.city.airport; tags.add('airport'); }
    if (tags.has('served')) tags.add('winter');
  }
  return { kind, path: x.path, values, tags, tokens: kitTokens(tokens) };
}

/** The Spec rows of content.ts as the kit reads them (the most efficient first, as the specs table orders them). */
export const specIn = (s: SpecIn) => s;

// ---------------------------------------------------------------- the vehicle pages' reads, as the kit's input
type Inv = { exact: Array<{ seats: number | null; daily_rate_cents: number; is_sample?: boolean }>; same_model: unknown[]; similar: unknown[] };
type City = { name: string; kind: string; parent: string | null; km: number | null; delivery: { fee_cents: number | null; airport_name?: string | null } | null; nearby: Array<{ name: string }> };
type Level = VehiclePageIn['level'];
/** Any vehicle page (make, model, year, trim, place or colour) as the shape the views read (data.ts, deep.tsx). */
export interface VehicleRead {
  level: Level; path: string; make: { name: string }; inventory: Inv; settings: { gas_cents: number; premium_extra_cents: number };
  model?: { name: string; vclass: string | null }; year?: number; vclass?: string | null; body_group?: string;
  trim?: { name: string; rank: number }; siblings?: unknown[]; trims?: Array<{ name: string }>;
  models?: Array<{ name: string; first_year: number; last_year: number; fuels: string[] }>;
  years?: Array<{ year: number; l100_min: number | null; kwh100_min: number | null; trims: Array<{ name: string }> }>;
  city?: City | null; colour?: { name: string } | null;
}
export interface VehicleExtras { recalls?: number | null; complaints?: { total: number; components: Array<{ component: string }> } | null; forSale?: number }

/** The kit's input from a vehicle page's read, its specs and dimensions (computed by the view), its tree and extras. */
export function vehicleInput(p: VehicleRead, o: { sp: SpecIn[]; dims?: Array<{ length_cm: number | null; width_cm: number | null; height_cm: number | null; curb_kg: number | null }>;
  mode?: VehiclePageIn['mode']; path?: string; term?: VehiclePageIn['term']; x?: VehicleExtras }): VehiclePageIn {
  const inv = p.inventory;
  const real = inv.exact.filter((c) => !c.is_sample).map((c) => c.daily_rate_cents);
  const years = p.years ?? [];
  const rated = years.filter((y) => y.l100_min !== null || y.kwh100_min !== null);
  const best = [...rated].sort((a, b) => Number(a.l100_min ?? a.kwh100_min) - Number(b.l100_min ?? b.kwh100_min))[0];
  const models = p.models ?? [];
  const spans = models.flatMap((m) => [m.first_year, m.last_year]).concat(years.map((y) => y.year));
  const trimNames = p.trims?.length ? p.trims.map((t) => t.name) : years.length ? [...new Set(years.flatMap((y) => y.trims.map((t) => t.name)))] : undefined;
  const c = p.city ?? null;
  return {
    path: o.path ?? p.path, level: p.level, mode: o.mode ?? 'cars', make: p.make.name, model: p.model?.name, year: p.year, trim: p.trim?.name, colour: p.colour?.name ?? null,
    vclass: p.vclass ?? p.model?.vclass ?? null, bodyGroup: p.body_group ?? null, sp: o.sp, dims: o.dims ?? [], seats: inv.exact.find((x) => x.seats)?.seats ?? null,
    cars: inv.exact.length, fromDailyCents: real.length ? Math.min(...real) : null, similar: inv.similar.length + inv.same_model.length,
    models: models.length || undefined, modelNames: models.length ? models.map((m) => m.name) : undefined,
    evModels: models.filter((m) => m.fuels.includes('electric')).length || undefined, hybridModels: models.filter((m) => m.fuels.some((f) => f === 'hybrid' || f === 'plug_in_hybrid')).length || undefined,
    firstYear: spans.length ? Math.min(...spans) : undefined, lastYear: spans.length ? Math.max(...spans) : undefined, yearsCount: years.length || undefined,
    bestYear: best && rated.length > 1 ? best.year : undefined, trimNames: p.level === 'make' || p.trim ? undefined : trimNames,
    trimRank: p.trim?.rank, trimCount: p.trim ? (p.siblings?.length ?? 1) : undefined, premiumPerLitreCents: p.settings.gas_cents + p.settings.premium_extra_cents,
    recalls: o.x?.recalls ?? null, complaints: o.x?.complaints?.total ?? null, complaintTop: o.x?.complaints?.components.map((k) => k.component), forSale: o.x?.forSale ?? 0,
    term: o.term ?? null,
    city: c ? { name: c.name, kind: c.kind, km: c.km, feeCents: c.delivery?.fee_cents ?? null, parent: c.parent, nearby: c.nearby.map((n) => n.name), airport: c.delivery?.airport_name ?? null } : null
  };
}
