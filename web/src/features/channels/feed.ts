// Listing channels (migration 0214): one car of the channel feed as a JSON row, a CSV row and a Google vehicle-listings
// style RSS item (g: namespace). Only CarmaCars' own and co-hosted cars ever reach here: the database filters
// (app.channel_feed_cars) and SHARED is the second lock. No imports: Worker and `node --test`.

export interface ChannelCar {
  vehicle_id: string; car_code: string | null; supply_type: string; name: string; year: number | null; make: string; model: string; trim: string | null; colour: string | null;
  class: string; seats: string | number | null; doors: string | number | null; body_style: string | null; transmission: string | null; fuel?: string | null;
  location: string; car_url: string; photos: string[]; daily_cents: number | null; weekly_cents: number | null; monthly_cents: number | null; deposit_cents: number | null;
  km_per_day: string | number | null; availability: { available_today: boolean; next_free_date: string | null; free_days_30: number } | null;
}
export const SHARED: ReadonlySet<string> = new Set(['company', 'program_owner']);
export const shared = (cars: ChannelCar[]) => cars.filter((c) => SHARED.has(c.supply_type));

const dollars = (c: number | null | undefined) => (c === null || c === undefined ? null : Math.round(Number(c)) / 100);
const num = (x: unknown) => (x === null || x === undefined || x === '' || !Number.isFinite(Number(x)) ? null : Number(x));

/** The car page with the channel as its source, so bookings it sends show under Marketing > Bookings by channel. */
export function tracked(url: string, channel: string): string {
  const u = new URL(url);
  u.searchParams.set('utm_source', channel); u.searchParams.set('utm_medium', 'listing'); u.searchParams.set('utm_campaign', 'channel_feed');
  return u.toString();
}

export const COLUMNS = ['id', 'title', 'year', 'make', 'model', 'trim', 'class', 'body_style', 'seats', 'doors', 'transmission', 'fuel', 'colour', 'daily_rate_cad', 'weekly_rate_cad',
  'monthly_rate_cad', 'deposit_cad', 'km_per_day', 'available_today', 'next_free_date', 'free_days_30', 'location', 'link', 'image_link', 'additional_image_links'] as const;
export type Row = Record<(typeof COLUMNS)[number], string | number | boolean | null>;

export function row(c: ChannelCar, channel: string, photo: (p: string) => string): Row {
  const photos = c.photos.map(photo);
  return {
    id: c.car_code || c.vehicle_id, title: c.name, year: c.year, make: c.make, model: c.model, trim: c.trim, class: c.class, body_style: c.body_style, seats: num(c.seats),
    doors: num(c.doors), transmission: c.transmission, fuel: c.fuel ?? null, colour: c.colour, daily_rate_cad: dollars(c.daily_cents), weekly_rate_cad: dollars(c.weekly_cents),
    monthly_rate_cad: dollars(c.monthly_cents), deposit_cad: dollars(c.deposit_cents), km_per_day: num(c.km_per_day), available_today: c.availability ? c.availability.available_today : null,
    next_free_date: c.availability?.next_free_date ?? null, free_days_30: c.availability?.free_days_30 ?? null, location: c.location, link: tracked(c.car_url, channel),
    image_link: photos[0] ?? null, additional_image_links: photos.slice(1, 10).join(' ') || null
  };
}

const cell = (v: unknown) => {
  if (v === null || v === undefined) return '';
  let s = String(v);
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`;   // never a spreadsheet formula
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
export const csv = (rows: Row[]) => [COLUMNS.join(','), ...rows.map((r) => COLUMNS.map((k) => cell(r[k])).join(','))].join('\r\n') + '\r\n';

const x = (s: unknown) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&apos;');
const tag = (k: string, v: unknown) => (v === null || v === undefined || v === '' ? '' : `<g:${k}>${x(v)}</g:${k}>`);

/** RSS 2.0 with Google's g: namespace, in the shape of Google's vehicle listings feed: the price is the daily rate. */
export function xml(rows: Row[], site: { url: string; name: string; city: string }): string {
  const items = rows.map((r) => [
    '<item>', tag('id', r.id), `<title>${x(r.title)}</title>`, `<link>${x(r.link)}</link>`,
    `<description>${x(`${r.title} for rent in ${r.location}. ${r.daily_rate_cad !== null ? `From $${Number(r.daily_rate_cad).toFixed(2)} CAD a day` : 'Ask for a price'}${r.km_per_day ? `, ${r.km_per_day} km a day included` : ''}.`)}</description>`,
    tag('link', r.link), tag('image_link', r.image_link), ...(r.additional_image_links ? String(r.additional_image_links).split(' ').map((u) => tag('additional_image_link', u)) : []),
    tag('price', r.daily_rate_cad !== null ? `${Number(r.daily_rate_cad).toFixed(2)} CAD` : null), tag('availability', r.available_today === false ? 'out_of_stock' : 'in_stock'),
    tag('condition', 'used'), tag('brand', r.make), tag('model', r.model), tag('year', r.year), tag('trim', r.trim), tag('color', r.colour), tag('body_style', r.body_style),
    tag('transmission', r.transmission), tag('fuel_type', r.fuel), tag('vehicle_fulfillment', 'in_store'), tag('store_code', site.city),
    tag('custom_label_0', 'rental_per_day'), tag('custom_label_1', r.class), '</item>'].filter(Boolean).join(''));
  return `<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0" xmlns:g="http://base.google.com/ns/1.0"><channel><title>${x(site.name)} cars for rent</title><link>${x(site.url)}</link><description>${x(`${site.name} rental cars in ${site.city}, daily rates in CAD`)}</description>${items.join('')}</channel></rss>\n`;
}
