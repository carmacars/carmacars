// The listing text of a car for a channel (migration 0167, the spec's section 2 templates): title, body, price line,
// hashtags, the tracked link and the photo order, within the channel's limits. Written from the car's own record only
// (app.ads_facts): a fact the record does not have is left out with its sentence, nothing is claimed that the record does
// not say, no review or rating is mentioned. Brand: CarmaCars. No long dashes. Pure (no I/O): the unit tests run it in Node.
import { type AdChannel, type ChannelSpec, carPage, channelOf, withUtm } from './channels.ts';

export interface AdPhoto { path: string; label?: string | null; shot?: string | null; alt?: string | null; sample?: boolean }
export interface CarFacts {
  vehicle_id: string; car_code: string | null; slug: string; name: string; year: number; make: string; model: string; trim?: string | null;
  colour?: string | null; class?: string | null; seats?: number | null; transmission?: string | null; body_style?: string | null; fuel?: string | null;
  features?: string[]; allows_18_to_20?: boolean | null; no_credit_card?: boolean | null; on_fleet_policy?: boolean | null; is_featured?: boolean | null;
  first_published_at?: string | null; taking: boolean; free_this_weekend?: boolean | null;
  daily: number | null; weekend: number | null; weekly: number | null; monthly: number | null; deposit: number | null; km: number | null; overage: number | null; delivery: number | null;
  photos: AdPhoto[];
}
export interface Rules { min_age: number | null; standard_min_age: number | null; max_days: number | null }
export interface Listing {
  channel: AdChannel; title: string | null; body: string; priceLine: string; hashtags: string[]; link: string; bookingNote: string;
  photos: AdPhoto[]; warnings: string[]; limits: { title: [number, number] | null; body: [number, number] };
}

/** $75, $1,600, $72.50 (app.ad_money of 0167 says the same). */
export function money(cents: number | null | undefined): string | null {
  if (cents === null || cents === undefined || !Number.isFinite(cents)) return null;
  const whole = cents % 100 === 0;
  return `$${(cents / 100).toLocaleString('en-US', { minimumFractionDigits: whole ? 0 : 2, maximumFractionDigits: whole ? 0 : 2 })}`;
}

/** The price line every channel carries (app.ad_price_line of 0167 writes the same, for the update tasks). */
export function priceLine(c: Pick<CarFacts, 'daily' | 'weekly' | 'monthly'>): string {
  if (!c.daily || c.daily <= 0) return '';
  return `From ${money(c.daily)} a day${c.weekly && c.weekly > 0 ? `, ${money(c.weekly)} a week` : ''}${c.monthly && c.monthly > 0 ? `, ${money(c.monthly)} for 30 days` : ''}, plus HST.`;
}

/** The car as people say it: 2023 Mercedes-Benz C 300. */
export const carName = (c: Pick<CarFacts, 'year' | 'make' | 'model'>) => `${c.year} ${c.make} ${c.model}`.replace(/\s+/g, ' ').trim();

/** A hashtag from words: letters and digits only. */
export const tag = (s: string) => '#' + s.normalize('NFKD').replace(/[^A-Za-z0-9]+(.)?/g, (_m, ch: string | undefined) => (ch ? ch.toUpperCase() : '')).replace(/^[a-z]/, (x) => x.toUpperCase());

export function hashtags(c: CarFacts, n: number): string[] {
  if (n <= 0) return [];
  const all = ['#CarmaCars', '#TorontoCarRental', tag(`${c.make} ${c.model}`), tag(c.make), '#CarRentalToronto', '#RentACar', '#Toronto', '#GTA', c.class ? tag(`${c.class} car`) : null, '#RoadTrip'];
  return [...new Set(all.filter((x): x is string => !!x && x.length > 1))].slice(0, n);
}

/** The photos in the order to post them (the listing's own order: cover first), at most the channel's number. */
export function photoOrder(photos: AdPhoto[], max: number): AdPhoto[] {
  return photos.filter((p) => p && p.path).slice(0, Math.max(0, max));
}

const sentence = (s: string | null | undefined) => (s ? s.trim().replace(/\s+/g, ' ') : '');
const join = (parts: Array<string | null | undefined | false>, sep = ' ') => parts.filter((p): p is string => !!p && p.trim() !== '').join(sep);
function cut(s: string, max: number): string {
  if (s.length <= max) return s;
  const words = s.slice(0, max + 1).split(' ');
  words.pop();
  return words.join(' ').replace(/[,;:]$/, '');
}

function describe(c: CarFacts): string {
  const bits = [c.class ? `${c.class} car`.replace(/\bcar car\b/i, 'car') : null, c.seats ? `${c.seats} seats` : null, c.transmission ? c.transmission.toLowerCase() : null, c.colour ? c.colour.toLowerCase() : null].filter(Boolean);
  return bits.length ? `${bits.join(', ').replace(/^./, (x) => x.toUpperCase())}.` : '';
}

function ratesSentence(c: CarFacts): string {
  const parts = [c.daily ? `${money(c.daily)} a day` : null, c.weekend && c.weekend !== c.daily ? `${money(c.weekend)} a day on weekends` : null,
    c.weekly ? `${money(c.weekly)} a week` : null, c.monthly ? `${money(c.monthly)} for 30 days` : null].filter(Boolean);
  return parts.length ? `${parts.join(', ').replace(/^./, (x) => x.toUpperCase())}, plus HST.` : '';
}

function kmSentence(c: CarFacts): string {
  if (!c.km) return '';
  return `${c.km} km a day included${c.overage ? `, ${money(c.overage)} for each extra km` : ''}.`;
}

/** Who may rent it, from the site's rules and the car's own setting. */
export function ageWords(c: CarFacts, r: Rules): string | null {
  if (c.allows_18_to_20 && r.min_age) return `age ${r.min_age} or older${r.standard_min_age && r.standard_min_age > r.min_age ? ` (this car is open to ages ${r.min_age} to ${r.standard_min_age - 1})` : ''}`;
  if (r.standard_min_age) return `age ${r.standard_min_age} or older for this car`;
  return null;
}

function needs(c: CarFacts, r: Rules): string {
  const items = [ageWords(c, r), 'a G2 or G licence', 'one coverage option: OPCF 27 on your own auto policy, your credit card\'s rental coverage, or the CarmaCars Protection Plan',
    c.no_credit_card ? null : 'a credit card in your name'].filter(Boolean);
  return `You need: ${items.join('; ')}.`;
}

function shortNeeds(c: CarFacts, r: Rules): string {
  const age = c.allows_18_to_20 && r.min_age ? `${r.min_age}+` : r.standard_min_age ? `${r.standard_min_age}+` : null;
  return join([age ? `${age}, G2 or G licence.` : 'G2 or G licence.', c.on_fleet_policy ? 'Liability coverage included.' : null, c.deposit ? `${money(c.deposit)} refundable deposit.` : null]);
}

function titleFor(c: CarFacts, spec: ChannelSpec): string | null {
  if (spec.titleMax === null) return null;
  const name = carName(c);
  const from = c.daily ? money(c.daily) : null;
  const options = [
    from ? `Rent a ${name} in Toronto, from ${from} a day` : `Rent a ${name} in Toronto`,
    from ? `Rent a ${name} in Toronto, ${from}/day` : null,
    from ? `${name} for rent, ${from} a day` : null,
    from ? `${c.make} ${c.model} rental, ${from}/day` : null,
    `${name} for rent`
  ].filter((x): x is string => !!x);
  return options.find((t) => t.length <= spec.titleMax!) ?? cut(options[options.length - 1]!, spec.titleMax);
}

/** The listing of one car for one channel. */
export function writeListing(c: CarFacts, r: Rules, channel: AdChannel, site: string): Listing {
  const spec = channelOf(channel)!;
  const link = withUtm(carPage(site, c.slug), channel, spec.medium, c.car_code ?? c.slug);
  const price = priceLine(c);
  const warnings: string[] = [];
  if (!c.taking) warnings.push('This car does not take requests on the site now: do not post it until it does.');
  if (!c.daily) warnings.push('The car has no daily rate yet: set its rates first.');
  if (!c.car_code) warnings.push('The car has no car code: the link uses its page name instead.');
  const photos = photoOrder(c.photos, spec.photoMax);
  if (!photos.length) warnings.push('The car has no listing photos yet.');
  if (photos.some((p) => p.sample)) warnings.push('These are sample photos, not this car: take real photos before you post (an ad must show the car itself).');
  const code = c.car_code ? `Car code ${c.car_code} (quote it when you call or write).` : '';
  const tags = hashtags(c, spec.hashtags);
  const title = titleFor(c, spec);
  let body: string;
  let bookingNote = '';

  if (channel === 'instagram' || channel === 'facebook_page') {
    const head = `${carName(c)}${c.daily ? `, from ${money(c.daily)} a day` : ''}.`;
    const lines = [head, describe(c), shortNeeds(c, r), kmSentence(c), c.delivery ? `Delivery in the Toronto area from ${money(c.delivery)} each way.` : '',
      channel === 'instagram' ? `Book at the link in bio. ${code}` : `Book or check the calendar: ${link}`, tags.join(' ')];
    body = join(lines.map(sentence), '\n\n');
    if (channel === 'instagram') bookingNote = `Link for the bio or a story link sticker: ${link}`;
  } else if (channel === 'google_business') {
    body = join([`Now available: ${carName(c)}${c.daily ? ` from ${money(c.daily)} a day` : ''}.`, describe(c), shortNeeds(c, r), kmSentence(c), c.car_code ? `Car code ${c.car_code}.` : '']);
    bookingNote = `Button: Book, linked to ${link}`;
  } else {
    const lines = [
      channel === 'fb_marketplace' ? 'For rent by the day, week or month (not for sale).' : 'For rent by the day, week or month.',
      join([describe(c), ratesSentence(c)]), kmSentence(c),
      c.delivery ? `Delivery from ${money(c.delivery)} each way, or pick it up yourself.` : 'Pick it up yourself.',
      c.on_fleet_policy ? 'Liability coverage included.' : '',
      needs(c, r), c.deposit ? `${money(c.deposit)} refundable deposit taken at pickup.` : '', r.max_days ? `Rentals up to ${r.max_days} days.` : '',
      `Book or check the calendar on CarmaCars: ${link}`, code];
    body = join(lines.map(sentence), '\n\n');
  }
  if (body.length > spec.bodyMax) { body = body.slice(0, spec.bodyMax); warnings.push(`Shortened to the ${spec.bodyMax} characters ${spec.label} takes.`); }
  return {
    channel, title, body, priceLine: price, hashtags: tags, link, bookingNote, photos, warnings,
    limits: { title: title === null || spec.titleMax === null ? null : [title.length, spec.titleMax], body: [body.length, spec.bodyMax] }
  };
}

/** Text we publish: no long dashes, never the numbered company name (app.ads_text_problem of 0167 checks the same). */
export function textProblem(s: string): string | null {
  if (!s.trim()) return 'The text is empty';
  if (s.includes('—') || s.includes(' – ')) return 'Rewrite the long dash with a comma, colon or full stop';
  if (/\b18122211\b/.test(s)) return 'Use the brand name CarmaCars, not the numbered company name';
  return null;
}
