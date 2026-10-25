// The week's Facebook Page and Instagram drafts (migration 0167, the spec's section 3 weekly plan), written from the fleet
// with the writing kit's engine (one wording per week and post, chosen by a stable hash: the same week always reads the
// same, the next week differently). Monday: a new car (published in the last 14 days) or a featured one; Tuesday: the owner
// program; Thursday: the cars free this weekend; Friday: the requirements; Sunday: a price highlight or a seasonal trip
// (alternate weeks). Wednesday's walkaround video and Saturday's handover story are filmed by field staff: no draft.
// Every draft waits for a person's approval. Pure (no I/O).
import { type Bank, type PickContext, pick } from '../kit/engine.ts';
import { TRIPS } from '../kit/facts.ts';
import { type CarFacts, type Rules, carName, hashtags, money } from './listing.ts';

export type DraftKind = 'new_car' | 'featured_car' | 'price_highlight' | 'weekend_list' | 'seasonal' | 'owner_program' | 'requirements';
export type SocialChannel = 'instagram' | 'facebook_page';
export interface Draft { slot_date: string; kind: DraftKind; channels: SocialChannel[]; vehicle_id: string | null; caption: string; link: string | null; photos: string[] }
export interface Facts { today: string; site_url: string; rules: Rules; cars: CarFacts[] }

export const KIND_WORDS: Record<string, string> = {
  new_car: 'New car', featured_car: 'Featured car', price_highlight: 'Price highlight', weekend_list: 'Free this weekend', seasonal: 'Seasonal trip',
  owner_program: 'Owner program', requirements: 'Requirements', custom: 'Written by staff'
};

const BANK: Record<string, Bank> = {
  new_head: ['New on CarmaCars: the {car}.', 'Just added to the fleet: the {car}.', 'Now on CarmaCars: the {car}.'],
  feat_head: ['This week\'s pick: the {car}.', 'Meet the {car}.', 'On the road this week: the {car}.'],
  car_price: ['From {daily} a day, {weekly} a week.', 'From {daily} a day[, or {weekly} for a week].', 'Rent it from {daily} a day.'],
  owner: [
    'Own a car that sits parked most of the week? With the CarmaCars owner program it goes on our fleet insurance policy, we rent it out in Toronto and we pay you every month. Fees apply. See how it works: {link}',
    'Your car could earn while you are not using it. In the CarmaCars owner program your car goes on our fleet insurance policy, we handle the renters and pay you monthly. Fees apply. Details: {link}',
    'Thinking about what your car costs you when it is parked? CarmaCars rents cars out for their owners: on our fleet insurance policy, renters handled by us, paid to you monthly. Fees apply. Learn more: {link}'
  ],
  weekend_head: ['Free this weekend on CarmaCars:', 'Still free for the weekend:', 'Plans this weekend? These cars are free:'],
  req: [
    'What you need to rent with CarmaCars: {age}, a G2 or G licence, one coverage option (OPCF 27 on your own policy, your credit card\'s rental coverage, or the CarmaCars Protection Plan) and a refundable deposit at pickup. Rentals up to {max} days.',
    'Renting with CarmaCars, in short: you are {age}, you hold a G2 or G licence, you pick one coverage option (your own OPCF 27, your credit card\'s coverage or our Protection Plan) and a refundable deposit is taken at pickup. Up to {max} days.'
  ],
  price_head: ['The lowest daily rate on CarmaCars right now: the {car} from {daily} a day.', 'Need a car without spending much? The {car} is from {daily} a day.'],
  trip: [
    'Weekend idea: {trip}, about {km} km from Toronto, for {what}. Cars on CarmaCars start at {daily} a day.',
    'Where to this weekend? {trip} is about {km} km from Toronto: {what}. Rent a car from {daily} a day on CarmaCars.'
  ]
};

const iso = (d: Date) => d.toISOString().slice(0, 10);
export function addDays(day: string, n: number): string { const d = new Date(`${day}T12:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return iso(d); }
/** The Monday of the week a day is in. */
export function mondayOf(day: string): string { const d = new Date(`${day}T12:00:00Z`); return addDays(day, -((d.getUTCDay() + 6) % 7)); }
const weekNo = (monday: string) => Math.floor(Date.parse(`${monday}T12:00:00Z`) / (7 * 86400000));

function ctx(seed: string, facts: Record<string, string | number | null | undefined>): PickContext {
  return { seed, facts, tokens: {}, tags: new Set(), used: new Set() };
}
const say = (bank: string, seed: string, facts: Record<string, string | number | null | undefined>) => pick(BANK[bank], bank, ctx(seed, facts)) ?? '';
const site = (f: Facts) => f.site_url.replace(/\/$/, '');

/** Winter (December to March), summer (June to August), or neither: the trips that fit the season of a day. */
export function tripsFor(day: string) {
  const m = Number(day.slice(5, 7));
  const season = m === 12 || m <= 3 ? 'winter' : m >= 6 && m <= 8 ? 'summer' : null;
  return TRIPS.filter((t) => !t.border && (season === null ? !t.season : !t.season || t.season === season));
}

/** The week's drafts. Days before p_from (today) are left out; a draft whose facts are missing is not written. */
export function weekPlan(f: Facts, monday: string, from: string = f.today): Draft[] {
  const cars = f.cars.filter((c) => c.taking && c.daily && c.slug);
  const out: Draft[] = [];
  const add = (d: Draft) => { if (d.slot_date >= from && d.caption) out.push(d); };
  const wk = weekNo(monday);
  const both: SocialChannel[] = ['instagram', 'facebook_page'];
  const photos = (c: CarFacts, n = 10) => c.photos.filter((p) => p.path && !p.sample).slice(0, n).map((p) => p.path);
  const tags = (c: CarFacts) => hashtags(c, 8).join(' ');

  // Monday: the newest car (published in the 14 days before), else a featured one, in turn week by week
  if (cars.length) {
    const fresh = cars.filter((c) => c.first_published_at && Date.parse(c.first_published_at) >= Date.parse(`${monday}T00:00:00Z`) - 14 * 86400000)
      .sort((a, b) => Date.parse(b.first_published_at!) - Date.parse(a.first_published_at!));
    const pool = cars.some((c) => c.is_featured) ? cars.filter((c) => c.is_featured) : cars;
    const car = fresh[0] ?? pool[wk % pool.length]!;
    const kind: DraftKind = fresh[0] ? 'new_car' : 'featured_car';
    const v = { car: carName(car), daily: money(car.daily), weekly: money(car.weekly) };
    const seed = `${monday}|mon|${car.vehicle_id}`;
    add({ slot_date: monday, kind, channels: both, vehicle_id: car.vehicle_id, link: `${site(f)}/cars/${car.slug}`, photos: photos(car),
      caption: [say(kind === 'new_car' ? 'new_head' : 'feat_head', seed, v), say('car_price', seed, v), car.car_code ? `Car code ${car.car_code}.` : '', 'Book at the link in bio.', tags(car)].filter(Boolean).join('\n\n') });
  }
  // Tuesday: the owner program
  add({ slot_date: addDays(monday, 1), kind: 'owner_program', channels: both, vehicle_id: null, link: `${site(f)}/list-your-car`, photos: [],
    caption: [say('owner', `${monday}|tue`, { link: `${site(f)}/list-your-car` }), '#CarmaCars #Toronto #CarOwners'].join('\n\n') });
  // Thursday: the cars free this weekend
  const free = cars.filter((c) => c.free_this_weekend).sort((a, b) => (a.daily ?? 0) - (b.daily ?? 0)).slice(0, 6);
  if (free.length) {
    add({ slot_date: addDays(monday, 3), kind: 'weekend_list', channels: both, vehicle_id: null, link: `${site(f)}/cars`, photos: free.map((c) => photos(c, 1)[0]).filter((x): x is string => !!x),
      caption: [say('weekend_head', `${monday}|thu`, {}), free.map((c) => `${carName(c)}, from ${money(c.daily)} a day`).join('\n'), 'Book at the link in bio.', '#CarmaCars #TorontoCarRental #Weekend'].join('\n\n') });
  }
  // Friday: the requirements
  const r = f.rules;
  const age = r.min_age ? `${r.min_age} or older (some cars ${r.standard_min_age ?? 21} or older)` : null;
  if (age && r.max_days) add({ slot_date: addDays(monday, 4), kind: 'requirements', channels: ['instagram'], vehicle_id: null, link: `${site(f)}/requirements`, photos: [],
    caption: [say('req', `${monday}|fri`, { age, max: r.max_days }), 'Questions? Send us a message.', '#CarmaCars #TorontoCarRental'].join('\n\n') });
  // Sunday: a price highlight or a seasonal trip, in turn
  const cheapest = [...cars].sort((a, b) => (a.daily ?? 0) - (b.daily ?? 0))[0];
  if (cheapest) {
    const sunday = addDays(monday, 6);
    if (wk % 2 === 0) {
      add({ slot_date: sunday, kind: 'price_highlight', channels: ['facebook_page'], vehicle_id: cheapest.vehicle_id, link: `${site(f)}/cars/${cheapest.slug}`, photos: photos(cheapest, 4),
        caption: [say('price_head', `${monday}|sun`, { car: carName(cheapest), daily: money(cheapest.daily) }), `Book or check the calendar: ${site(f)}/cars/${cheapest.slug}`].join('\n\n') });
    } else {
      const trips = tripsFor(sunday);
      const t = trips[wk % trips.length];
      if (t) add({ slot_date: sunday, kind: 'seasonal', channels: ['facebook_page'], vehicle_id: null, link: `${site(f)}/cars`, photos: [],
        caption: [say('trip', `${monday}|sun`, { trip: t.name, km: t.km, what: t.what, daily: money(cheapest.daily) }), `See the cars: ${site(f)}/cars`].join('\n\n') });
    }
  }
  return out;
}

/** utm_campaign of a draft: the car's code, or what the post is about. */
export const draftCampaign = (d: { kind: string; car_code?: string | null }) => d.car_code ?? d.kind;

/** The caption as posted on a channel: the page's address becomes its tracked link; on the Facebook Page the link goes in
 *  the text (it can be clicked there); on Instagram it stays "link in bio" (a caption cannot hold a link that works). */
export function captionFor(caption: string, channel: SocialChannel, link: string | null, trackedLink: string | null): string {
  if (!link || !trackedLink) return caption;
  const tracked = caption.split(link).join(trackedLink);
  if (channel === 'instagram') return tracked;
  const swapped = tracked.replace(/Book at the link in bio\./g, `Book or check the calendar: ${trackedLink}`);
  return swapped.includes(trackedLink) ? swapped : `${swapped}\n\n${trackedLink}`;
}
