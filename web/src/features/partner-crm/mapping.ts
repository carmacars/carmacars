// What goes to a partner's CRM and what comes back (migration 0136). No imports: Worker and `node --test`.
//
// Out: one of our cars (app.partner_crm_outbound_cars: CarmaCars' own and program owners' cars only) as the properties
// of a "CarmaCars Vehicles" custom object record, or as a product with a daily price when their plan has no custom
// objects, and as a row of the read-only feed (JSON or CSV) and the widget.
// In: their car, from a custom object record, a product or their feed, normalised for app.partner_crm_inbound_apply.

export type SupplyType = 'company' | 'program_owner' | 'partner';
export interface Availability { available_today: boolean; next_free_date: string | null; free_days_30: number; free_days_60: number; booked: Array<{ from: string; to: string }> }
export interface OutboundCar {
  vehicle_id: string; car_code: string | null; supply_type: SupplyType; name: string; year: number | null; make: string; model: string; trim: string | null;
  colour: string | null; class: string; seats: string | number | null; doors: string | number | null; body_style: string | null; transmission: string | null;
  drivetrain?: string | null; fuel?: string | null; slug: string; location: string; car_url: string; book_url: string; photos: string[]; photos_representative?: boolean;
  daily_cents: number | null; weekly_cents: number | null; monthly_cents: number | null; deposit_cents?: number | null; km_per_day?: string | number | null;
  availability: Availability | null;
}

/** THE RULE (the owner, October 24, 2026): only CarmaCars' own cars and program owners' cars go to a partner. The
 *  database already filters (app.partner_crm_outbound_cars); this is the second lock, before anything is sent. */
export const SHAREABLE: ReadonlySet<string> = new Set(['company', 'program_owner']);
export function shareable(cars: OutboundCar[]): { cars: OutboundCar[]; refused: number } {
  const ok = cars.filter((c) => SHAREABLE.has(c.supply_type));
  return { cars: ok, refused: cars.length - ok.length };
}

// ---------------------------------------------------------------------------------------------- the custom object
export const OBJECT_LABELS = { singular: 'CarmaCars Vehicle', plural: 'CarmaCars Vehicles' };
export const OBJECT_DESCRIPTION = 'Cars CarmaCars rents in Toronto, kept up to date by CarmaCars every 15 minutes. Book with the link on each record.';
export const PRIMARY = { key: 'vehicle_name', name: 'Vehicle' };
/** The fields of the object, created when missing. DATE values are YYYY-MM-DD; rates are dollars a day, week, month. */
export const OBJECT_FIELDS: ReadonlyArray<{ key: string; name: string; dataType: 'TEXT' | 'LARGE_TEXT' | 'NUMERICAL' | 'DATE' }> = [
  { key: 'car_code', name: 'Car code', dataType: 'TEXT' },
  { key: 'year', name: 'Year', dataType: 'NUMERICAL' },
  { key: 'make', name: 'Make', dataType: 'TEXT' },
  { key: 'model', name: 'Model', dataType: 'TEXT' },
  { key: 'trim', name: 'Trim', dataType: 'TEXT' },
  { key: 'vehicle_class', name: 'Class', dataType: 'TEXT' },
  { key: 'seats', name: 'Seats', dataType: 'NUMERICAL' },
  { key: 'body_style', name: 'Body', dataType: 'TEXT' },
  { key: 'transmission', name: 'Transmission', dataType: 'TEXT' },
  { key: 'colour', name: 'Colour', dataType: 'TEXT' },
  { key: 'daily_rate', name: 'Partner rate a day (CAD)', dataType: 'NUMERICAL' },
  { key: 'weekly_rate', name: 'Partner rate a week (CAD)', dataType: 'NUMERICAL' },
  { key: 'monthly_rate', name: 'Partner rate a month (CAD)', dataType: 'NUMERICAL' },
  { key: 'available_today', name: 'Available today', dataType: 'TEXT' },
  { key: 'next_free_date', name: 'Next free date', dataType: 'DATE' },
  { key: 'free_days_30', name: 'Free days, next 30', dataType: 'NUMERICAL' },
  { key: 'free_days_60', name: 'Free days, next 60', dataType: 'NUMERICAL' },
  { key: 'booked_dates', name: 'Booked dates', dataType: 'LARGE_TEXT' },
  { key: 'location', name: 'Location', dataType: 'TEXT' },
  { key: 'cover_photo', name: 'Cover photo', dataType: 'TEXT' },
  { key: 'photo_urls', name: 'Photos', dataType: 'LARGE_TEXT' },
  { key: 'book_url', name: 'Book on carmacars.ca', dataType: 'TEXT' },
  { key: 'car_url', name: 'Car page', dataType: 'TEXT' }
];

const dollars = (c: number | null | undefined) => (c === null || c === undefined ? null : Math.round(Number(c)) / 100);
const n = (x: unknown) => (x === null || x === undefined || x === '' || !Number.isFinite(Number(x)) ? null : Number(x));
export function bookedText(a: Availability | null): string {
  if (!a) return '';
  return a.booked.map((b) => (b.from === b.to ? b.from : `${b.from} to ${b.to}`)).join('\n');
}

/** Photo paths become addresses: a site path (/sample-photos/...) on the site, a storage path in the public bucket. */
export function photoUrls(paths: string[], site: string, bucketUrl: (p: string) => string): string[] {
  return paths.filter(Boolean).map((p) => (/^https?:\/\//.test(p) ? p : p.startsWith('/') ? `${site.replace(/\/$/, '')}${p}` : bucketUrl(p)));
}

export function recordProperties(car: OutboundCar, photos: string[]): Record<string, unknown> {
  const a = car.availability;
  const p: Record<string, unknown> = {
    vehicle_name: car.name,
    car_code: car.car_code ?? '',
    year: car.year,
    make: car.make,
    model: car.model,
    trim: car.trim ?? '',
    vehicle_class: car.class,
    seats: n(car.seats),
    body_style: car.body_style ?? '',
    transmission: car.transmission ?? '',
    colour: car.colour ?? '',
    daily_rate: dollars(car.daily_cents),
    weekly_rate: dollars(car.weekly_cents),
    monthly_rate: dollars(car.monthly_cents),
    available_today: a ? (a.available_today ? 'Yes' : 'No') : '',
    next_free_date: a?.next_free_date ?? null,
    free_days_30: a ? a.free_days_30 : null,
    free_days_60: a ? a.free_days_60 : null,
    booked_dates: bookedText(a),
    location: car.location,
    cover_photo: photos[0] ?? '',
    photo_urls: photos.join('\n'),
    book_url: car.book_url,
    car_url: car.car_url
  };
  // GoHighLevel refuses null for a number or a date: an unknown value is left out
  for (const k of Object.keys(p)) if (p[k] === null || p[k] === undefined) delete p[k];
  return p;
}

const money = (c: number | null | undefined) => (c === null || c === undefined ? 'on request' : `$${(Math.round(Number(c)) / 100).toLocaleString('en-CA', { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`);
export function productBody(car: OutboundCar, photos: string[]): Record<string, unknown> {
  const a = car.availability;
  const lines = [
    `${car.name}${car.car_code ? ` (${car.car_code})` : ''}. ${[car.class, car.body_style, car.seats ? `${car.seats} seats` : null, car.transmission].filter(Boolean).join(', ')}.`,
    `Partner rates: ${money(car.daily_cents)} a day, ${money(car.weekly_cents)} a week, ${money(car.monthly_cents)} a month (CAD).`,
    a ? `Available today: ${a.available_today ? 'yes' : 'no'}. Next free date: ${a.next_free_date ?? 'none in the next 60 days'}. Free days in the next 30: ${a.free_days_30}.` : null,
    a && a.booked.length ? `Booked: ${a.booked.map((b) => (b.from === b.to ? b.from : `${b.from} to ${b.to}`)).join(', ')}.` : null,
    `Location: ${car.location}.`,
    `Book: ${car.book_url}`
  ].filter(Boolean);
  return {
    name: `${car.name}${car.car_code ? ` (${car.car_code})` : ''}`.slice(0, 200),
    description: lines.join('\n'),
    productType: 'SERVICE',
    availableInStore: false,
    image: photos[0] ?? undefined,
    medias: photos.slice(0, 10).map((url, i) => ({ id: `cc-${i}`, title: `${car.name} ${i + 1}`, url, type: 'image', isFeatured: i === 0 }))
  };
}
export function priceBody(car: OutboundCar): Record<string, unknown> | null {
  if (car.daily_cents === null || car.daily_cents === undefined) return null;
  return { name: 'Partner rate a day', type: 'one_time', currency: 'CAD', amount: Math.round(Number(car.daily_cents)) / 100 };
}

/** A stable hash of what is sent (unchanged: not sent again). FNV-1a 64 bits as hex: no WebCrypto needed. */
export function payloadHash(x: unknown): string {
  const s = stableJson(x);
  let h1 = 0x811c9dc5, h2 = 0x01000193;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    h1 = Math.imul(h1 ^ c, 0x01000193) >>> 0;
    h2 = Math.imul(h2 ^ c, 0x811c9dc5) >>> 0;
  }
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0');
}
function stableJson(x: unknown): string {
  if (Array.isArray(x)) return `[${x.map(stableJson).join(',')}]`;
  if (x && typeof x === 'object') return `{${Object.keys(x as object).sort().map((k) => `${JSON.stringify(k)}:${stableJson((x as Record<string, unknown>)[k])}`).join(',')}}`;
  return JSON.stringify(x ?? null);
}

// ---------------------------------------------------------------------------------------------- the feed
export const FEED_COLUMNS = ['car_code', 'name', 'year', 'make', 'model', 'trim', 'class', 'seats', 'body_style', 'transmission', 'colour', 'daily_rate', 'weekly_rate', 'monthly_rate',
  'available_today', 'next_free_date', 'free_days_30', 'free_days_60', 'booked_dates', 'location', 'cover_photo', 'photo_urls', 'book_url', 'car_url'] as const;
export function feedRow(car: OutboundCar, photos: string[]): Record<(typeof FEED_COLUMNS)[number], string | number | boolean | null> {
  const a = car.availability;
  return {
    car_code: car.car_code, name: car.name, year: car.year, make: car.make, model: car.model, trim: car.trim, class: car.class, seats: n(car.seats),
    body_style: car.body_style, transmission: car.transmission, colour: car.colour,
    daily_rate: dollars(car.daily_cents), weekly_rate: dollars(car.weekly_cents), monthly_rate: dollars(car.monthly_cents),
    available_today: a ? a.available_today : null, next_free_date: a?.next_free_date ?? null, free_days_30: a?.free_days_30 ?? null, free_days_60: a?.free_days_60 ?? null,
    booked_dates: a ? a.booked.map((b) => `${b.from}/${b.to}`).join(' ') : null, location: car.location, cover_photo: photos[0] ?? null, photo_urls: photos.join(' '),
    book_url: car.book_url, car_url: car.car_url
  };
}
const csvCell = (v: unknown) => {
  if (v === null || v === undefined) return '';
  let s = String(v);
  // a cell a spreadsheet would run as a formula is quoted with a leading apostrophe
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
export function feedCsv(rows: Array<Record<string, unknown>>): string {
  return [FEED_COLUMNS.join(','), ...rows.map((r) => FEED_COLUMNS.map((k) => csvCell(r[k])).join(','))].join('\r\n') + '\r\n';
}

// ---------------------------------------------------------------------------------------------- what comes back
export interface InboundCar {
  remote_kind: 'object_record' | 'product' | 'feed'; remote_id: string; name: string; make: string | null; model: string | null; year: number | null; trim: string | null;
  colour: string | null; class: string | null; seats: number | null; doors: number | null; body: string | null; transmission: string | null;
  base_cents: number | null; multi_day_cents: number | null; long_term_cents: number | null; photos: string[]; booked: Array<{ from: string; to: string }>;
}

const MAKES = ['Mercedes-Benz', 'Mercedes', 'BMW', 'Audi', 'Porsche', 'Land Rover', 'Range Rover', 'Ferrari', 'McLaren', 'Mclaren', 'Lamborghini', 'Chevrolet', 'Cadillac',
  'Rolls-Royce', 'Rolls Royce', 'Bentley', 'Ford', 'Infiniti', 'Maserati', 'Tesla', 'Toyota', 'Lexus', 'Honda', 'Acura', 'Nissan', 'Hyundai', 'Kia', 'Genesis', 'Jeep',
  'Dodge', 'GMC', 'Volkswagen', 'Volvo', 'Jaguar', 'Mazda', 'Subaru', 'Lincoln', 'Aston Martin', 'Alfa Romeo', 'Mini', 'Chrysler', 'Ram', 'Polestar', 'Lucid', 'Rivian'];
const CANON: Record<string, string> = { mercedes: 'Mercedes-Benz', 'mercedes-benz': 'Mercedes-Benz', 'range rover': 'Land Rover', mclaren: 'McLaren', 'rolls royce': 'Rolls-Royce' };

/** "2025 Mercedes C43 AMG White" -> year 2025, make Mercedes-Benz, model C43, trim AMG White (a first guess; the sheet
 *  name match in the database comes first). */
export function parseName(name: string): { year: number | null; make: string | null; model: string | null; trim: string | null } {
  let s = String(name ?? '').replace(/\s+/g, ' ').trim();
  let year: number | null = null;
  const y = s.match(/\b(19[89]\d|20[0-4]\d)\b/);
  if (y) { year = Number(y[1]); s = s.replace(y[0], '').replace(/\s+/g, ' ').trim(); }
  const lower = s.toLowerCase();
  const make = [...MAKES].sort((a, b) => b.length - a.length).find((m) => lower.startsWith(m.toLowerCase() + ' ') || lower === m.toLowerCase());
  if (!make) return { year, make: null, model: null, trim: null };
  const rest = s.slice(make.length).trim().split(' ');
  const canon = CANON[make.toLowerCase()] ?? make;
  // "Range Rover Sport" keeps Range Rover in the model
  const model = make.toLowerCase() === 'range rover' ? `Range Rover${rest[0] ? ` ${rest[0]}` : ''}` : rest[0] ?? null;
  const trim = (make.toLowerCase() === 'range rover' ? rest.slice(1) : rest.slice(1)).join(' ') || null;
  return { year, make: canon, model, trim };
}

/** Dollars, "$1,250.00", "1250", 1250 (dollars) -> cents. */
export function toCents(v: unknown): number | null {
  if (v === null || v === undefined || v === '') return null;
  if (typeof v === 'object') return toCents((v as { value?: unknown; amount?: unknown }).value ?? (v as { amount?: unknown }).amount);
  const x = Number(String(v).replace(/[$,\sCAD]/gi, ''));
  return Number.isFinite(x) && x > 0 ? Math.round(x * 100) : null;
}
const text = (v: unknown) => (v === null || v === undefined ? null : String(v).trim() || null);
const int = (v: unknown) => { const x = parseInt(String(v ?? ''), 10); return Number.isFinite(x) ? x : null; };
const isoDate = (v: unknown) => { const s = String(v ?? '').trim().slice(0, 10); return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null; };

/** Their field names vary: the first key (any case, any separator, with or without the custom_objects.x. prefix) that
 *  matches one of the names. */
function pick(props: Record<string, unknown>, names: string[]): unknown {
  const norm = (k: string) => k.toLowerCase().replace(/^custom_objects\.[a-z0-9_]+\./, '').replace(/[^a-z0-9]/g, '');
  const map = new Map<string, unknown>();
  for (const [k, v] of Object.entries(props ?? {})) if (!map.has(norm(k))) map.set(norm(k), v);
  for (const nme of names) { const v = map.get(norm(nme)); if (v !== undefined && v !== null && v !== '') return v; }
  return undefined;
}
const urls = (v: unknown): string[] => {
  if (!v) return [];
  const list = Array.isArray(v) ? v.flatMap((x) => (typeof x === 'object' && x ? [(x as { url?: string }).url ?? ''] : [String(x)])) : String(v).split(/[\s,|]+/);
  return [...new Set(list.map((s) => s.trim()).filter((s) => /^https:\/\/[^\s]+$/.test(s)))].slice(0, 20);
};
/** "2026-11-01 to 2026-11-03, 2026-11-10" / [{from, to}] / "2026-11-01/2026-11-03" -> runs. */
export function bookedRuns(v: unknown): Array<{ from: string; to: string }> {
  if (!v) return [];
  if (Array.isArray(v)) return v.map((x) => (typeof x === 'string' ? bookedRuns(x)[0] : { from: isoDate((x as { from?: unknown; start?: unknown }).from ?? (x as { start?: unknown }).start), to: isoDate((x as { to?: unknown; end?: unknown }).to ?? (x as { end?: unknown }).end) }))
    .filter((r): r is { from: string; to: string } => !!r && !!r.from && !!r.to && r.to >= r.from);
  return String(v).split(/[\n;,]+/).map((s) => {
    const m = s.match(/(\d{4}-\d{2}-\d{2})(?:\s*(?:to|\/|-|\u2013|until)\s*(\d{4}-\d{2}-\d{2}))?/);
    return m ? { from: m[1]!, to: m[2] ?? m[1]! } : null;
  }).filter((r): r is { from: string; to: string } => !!r && r.to >= r.from);
}

function fromProps(kind: InboundCar['remote_kind'], id: string, props: Record<string, unknown>): InboundCar {
  const name = text(pick(props, ['vehicle_name', 'name', 'title', 'vehicle', 'car', 'listing'])) ?? '';
  const guess = parseName(name);
  const make = text(pick(props, ['make', 'brand', 'manufacturer'])) ?? guess.make;
  return {
    remote_kind: kind, remote_id: id, name: name || [make, text(pick(props, ['model']))].filter(Boolean).join(' '),
    make: make ? CANON[make.toLowerCase()] ?? make : null,
    model: text(pick(props, ['model'])) ?? guess.model,
    year: int(pick(props, ['year', 'model_year'])) ?? guess.year,
    trim: text(pick(props, ['trim', 'version', 'package'])) ?? (text(pick(props, ['model'])) ? null : guess.trim),
    colour: text(pick(props, ['colour', 'color', 'exterior_colour', 'exterior_color'])),
    class: text(pick(props, ['vehicle_class', 'class', 'category'])),
    seats: int(pick(props, ['seats', 'seating', 'passengers'])),
    doors: int(pick(props, ['doors'])),
    body: text(pick(props, ['body_style', 'body', 'body_type', 'type'])),
    transmission: text(pick(props, ['transmission', 'gearbox'])),
    base_cents: toCents(pick(props, ['daily_rate', 'rate_per_day', 'day_rate', 'daily', 'price_per_day', 'rate', 'price'])),
    multi_day_cents: toCents(pick(props, ['multi_day_rate', 'rate_3_days', 'three_day_rate', '3_day_rate', 'rate_3plus'])),
    long_term_cents: toCents(pick(props, ['weekly_daily_rate', 'long_term_rate', 'rate_7_days', 'seven_day_rate', '7_day_rate', 'rate_7plus']))
      ?? (() => { const w = toCents(pick(props, ['weekly_rate', 'week_rate', 'weekly'])); return w ? Math.round(w / 7) : null; })(),
    photos: urls(pick(props, ['photo_urls', 'photos', 'images', 'image_urls', 'gallery', 'cover_photo', 'photo', 'image', 'image_url'])),
    booked: bookedRuns(pick(props, ['booked_dates', 'booked', 'unavailable', 'unavailable_dates', 'blocked_dates', 'reservations']))
  };
}
export const fromRecord = (r: { id: string; properties: Record<string, unknown> }) => fromProps('object_record', r.id, r.properties);
export function fromProduct(p: { _id?: string; id?: string; name: string; description?: string; image?: string; medias?: Array<{ url?: string; type?: string }> }, dailyCents: number | null): InboundCar {
  const id = String(p._id ?? p.id ?? '');
  const c = fromProps('product', id, { name: p.name, photos: [p.image, ...(p.medias ?? []).filter((m) => !m.type || m.type === 'image').map((m) => m.url)].filter(Boolean) });
  return { ...c, base_cents: dailyCents ?? c.base_cents };
}
/** Their own feed: JSON (an array, or {vehicles|cars|inventory|data: [...]}) or CSV with a header row. */
export function fromFeed(body: string): InboundCar[] {
  const t = String(body ?? '').trim();
  let rows: Array<Record<string, unknown>> = [];
  if (t.startsWith('[') || t.startsWith('{')) {
    const j = JSON.parse(t) as unknown;
    const list = Array.isArray(j) ? j : ((j as Record<string, unknown>).vehicles ?? (j as Record<string, unknown>).cars ?? (j as Record<string, unknown>).inventory ?? (j as Record<string, unknown>).data ?? []);
    rows = Array.isArray(list) ? list.filter((x) => x && typeof x === 'object') as Array<Record<string, unknown>> : [];
  } else {
    rows = parseCsv(t);
  }
  return rows.slice(0, 500).map((r, i) => fromProps('feed', String(pick(r, ['id', 'vehicle_id', 'stock_number', 'stock', 'vin', 'car_code']) ?? text(pick(r, ['name', 'title'])) ?? i + 1).slice(0, 120), r));
}
export function parseCsv(t: string): Array<Record<string, string>> {
  const out: string[][] = [];
  let row: string[] = [], cell = '', q = false;
  for (let i = 0; i < t.length; i++) {
    const ch = t[i]!;
    if (q) { if (ch === '"') { if (t[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += ch; continue; }
    if (ch === '"') q = true;
    else if (ch === ',') { row.push(cell); cell = ''; }
    else if (ch === '\n' || ch === '\r') { if (ch === '\r' && t[i + 1] === '\n') i++; row.push(cell); out.push(row); row = []; cell = ''; }
    else cell += ch;
  }
  if (cell !== '' || row.length) { row.push(cell); out.push(row); }
  const [head, ...rest] = out.filter((r) => r.some((c) => c.trim() !== ''));
  if (!head) return [];
  return rest.map((r) => Object.fromEntries(head.map((h, i) => [h.trim(), (r[i] ?? '').trim()])));
}
