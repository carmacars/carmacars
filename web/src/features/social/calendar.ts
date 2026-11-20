// The content calendar's writer (release 48, migration 3263; the owner, Nov 20: "social content = an auto-generated CONTENT
// CALENDAR ... approved by staff before anything goes live"). A month of posts from the fleet's facts: each with its
// content pillar, format (reel, carousel, photo, story), caption, hashtags, the best time on each channel and a music
// suggestion. Pure (no I/O, no randomness): the same month and facts always give the same calendar, so a slot written
// twice is the same post, and the database keeps the first. Wording comes from the writing kit's engine, as the week's
// drafts of 0167 do. What last month's results taught (the best pillar, format and hour) leans the next month.
// Nothing here publishes: every post is a draft until a person approves it.
import { type Bank, type PickContext, pick } from '../kit/engine.ts';
import { TRIPS } from '../kit/facts.ts';
import { type CarFacts, carName, money, tag } from '../ads/listing.ts';
import type { Facts } from '../ads/social.ts';

export type Format = 'reel' | 'carousel' | 'photo' | 'story';
export type CalChannel = 'instagram' | 'facebook_page' | 'tiktok';
export interface Pillar { code: string; name: string; weight: number }
export interface Plan { mix: Partial<Record<Format, number>>; pillars: Pillar[]; times: Partial<Record<CalChannel, string[]>>; hashtags: string[]; music: Record<string, string> }
export interface Learned { posts?: number; pillars?: Record<string, number>; formats?: Record<string, number>; times?: Partial<Record<CalChannel, string>>; top_pillar?: string | null; top_format?: string | null }
export interface CalendarPost {
  slot_no: number; slot_date: string; format: Format; pillar: string; kind: string; channels: CalChannel[]; vehicle_id: string | null;
  hook: string; caption: string; hashtags: string[]; music: string | null; best_times: Partial<Record<CalChannel, string>>; link: string | null; photos: string[]; shot_list: string | null;
}
export interface MonthCalendar { month: string; posts: CalendarPost[]; plan: Plan; learned: Learned }

export const FORMATS: Format[] = ['reel', 'carousel', 'photo', 'story'];
export const FORMAT_WORDS: Record<Format, string> = { reel: 'Reel', carousel: 'Carousel', photo: 'Photo', story: 'Story' };
export const CHANNEL_WORDS: Record<CalChannel, string> = { instagram: 'Instagram', facebook_page: 'Facebook Page', tiktok: 'TikTok' };
/** Where each format goes: a reel everywhere (TikTok takes videos only), a story on Instagram, the rest on Meta. */
export const FORMAT_CHANNELS: Record<Format, CalChannel[]> = { reel: ['instagram', 'facebook_page', 'tiktok'], carousel: ['instagram', 'facebook_page'], photo: ['instagram', 'facebook_page'], story: ['instagram'] };
/** The weekdays posts go on, most wanted first (1 Monday to 7 Sunday): mid-week and the weekend lead. */
const DAY_ORDER = [2, 4, 6, 1, 5, 3, 7];
const KIND: Record<string, string> = { fleet: 'featured_car', offers: 'price_highlight', owners: 'owner_program', trust: 'requirements', local: 'seasonal', proof: 'custom' };

const BANK: Record<string, Bank> = {
  fleet_hook: ['Meet the {car}', 'Your next drive: the {car}', 'The {car}, ready when you are'],
  fleet: [
    'The {car} is on CarmaCars from {daily} a day. Pick it up in Toronto or have it delivered. Book at the link in bio.',
    'Need a car this week? The {car} is from {daily} a day, with delivery across the GTA. Book at the link in bio.',
    'Take the {car} for the weekend or the week: from {daily} a day on CarmaCars. Book at the link in bio.'
  ],
  offers_hook: ['From {daily} a day', 'A week from {weekly}', 'The lowest rate this week'],
  offers: [
    'The {car} is from {daily} a day right now, {weekly} for a full week. Check its calendar and book at the link in bio.',
    'Renting for longer costs less: the {car} is {weekly} a week, from {daily} a day. Book at the link in bio.'
  ],
  trust_hook: ['How renting works', 'What you need to rent', 'Three steps to your car'],
  trust: [
    'Renting with CarmaCars in three steps: send a request, sign and pay online, pick up the car or have it delivered. You need to be {age}, hold a G2 or G licence and choose one coverage option. Questions? Send us a message.',
    'What you need to rent with CarmaCars: {age}, a G2 or G licence, one coverage option and a refundable deposit on the day of pickup. Everything is signed and paid online before you get the keys.'
  ],
  local_hook: ['Weekend idea: {trip}', 'Where to this weekend?', '{trip}, {km} km away'],
  local: [
    'Weekend idea: {trip}, about {km} km from Toronto, for {what}. Cars on CarmaCars start at {daily} a day. Book at the link in bio.',
    'Where to this weekend? {trip} is about {km} km from Toronto: {what}. Rent a car from {daily} a day. Book at the link in bio.'
  ],
  owners_hook: ['Your car could earn', 'Parked most of the week?', 'Earn with your car'],
  owners: [
    'Own a car that sits parked most of the week? With the CarmaCars owner program it goes on our fleet insurance policy, we rent it out in Toronto and we pay you every month. Fees apply. See how it works at the link in bio.',
    'Your car could earn while you are not using it. In the CarmaCars owner program we handle the renters, the cleaning and the paperwork, and pay you monthly. Fees apply. Details at the link in bio.'
  ],
  proof_hook: ['Why renters come back', 'What renters say', 'Rented, returned, rebooked'],
  proof: [
    'Why renters come back to CarmaCars: clean cars, clear prices, delivery when you want it and a person who answers. See the fleet at the link in bio.',
    'Clear prices, clean cars and a team that answers: that is what renters tell us they come back for. See what is free this week at the link in bio.'
  ]
};
const SHOTS: Record<Format, (car: string | null) => string> = {
  reel: (car) => (car ? `Make it from the ${car}'s photos under Short videos, or film: 1. the car from the front corner, 2. the interior, 3. the price on screen, 4. end on the CarmaCars sign. 10 to 20 seconds, vertical.`
    : 'Film vertically, 10 to 20 seconds: 1. the opening line on screen, 2. two or three cars from the lot, 3. end on the CarmaCars sign.'),
  story: () => 'One vertical photo or a 5 to 10 second clip, the opening line on screen, a link sticker to the page.',
  carousel: (car) => (car ? `Up to 5 photos of the ${car}: the front corner first, then the side, the interior and the trunk.` : 'Up to 5 photos, the strongest first.'),
  photo: () => 'One photo, the car filling the frame.'
};

const iso = (d: Date) => d.toISOString().slice(0, 10);
const isoDow = (day: string) => ((new Date(`${day}T12:00:00Z`).getUTCDay() + 6) % 7) + 1;
function ctx(seed: string, facts: Record<string, string | number | null | undefined>): PickContext {
  return { seed, facts, tokens: {}, tags: new Set(), used: new Set() };
}
const say = (bank: string, seed: string, facts: Record<string, string | number | null | undefined>) => pick(BANK[bank], bank, ctx(seed, facts)) ?? '';

/** The days of a month (YYYY-MM), in order. */
export function monthDays(month: string): string[] {
  const [y, m] = month.split('-').map(Number) as [number, number];
  const out: string[] = [];
  for (let d = new Date(Date.UTC(y, m - 1, 1, 12)); d.getUTCMonth() === m - 1; d.setUTCDate(d.getUTCDate() + 1)) out.push(iso(d));
  return out;
}
/** A week's formats in posting order, the formats spread out (never two reels in a row while another format is left);
 *  the format that did best last month goes first. */
export function weekFormats(mix: Plan['mix'], top?: string | null): Format[] {
  const left = FORMATS.map((f) => ({ f, n: Math.max(0, Math.min(7, Math.floor(mix[f] ?? 0))) }));
  const out: Format[] = [];
  let last: Format | null = null;
  while (left.some((x) => x.n > 0) && out.length < 7) {
    const order = [...left].filter((x) => x.n > 0).sort((a, b) => (Number(b.f === top && !out.length) - Number(a.f === top && !out.length)) || b.n - a.n || FORMATS.indexOf(a.f) - FORMATS.indexOf(b.f));
    const next = order.find((x) => x.f !== last) ?? order[0]!;
    out.push(next.f); next.n -= 1; last = next.f;
  }
  return out;
}
/** The pillars in the order they come up: each as often as its weight, spread out, the one that did best once more. */
export function pillarCycle(pillars: Pillar[], top?: string | null): string[] {
  const left = pillars.filter((p) => p.code && p.weight > 0).map((p) => ({ code: p.code, n: Math.min(9, Math.floor(p.weight)) + (p.code === top ? 1 : 0), w: p.weight }));
  const out: string[] = [];
  let last = '';
  while (left.some((x) => x.n > 0)) {
    const order = left.filter((x) => x.n > 0).sort((a, b) => b.n - a.n || b.w - a.w || a.code.localeCompare(b.code));
    const next = order.find((x) => x.code !== last) ?? order[0]!;
    out.push(next.code); next.n -= 1; last = next.code;
  }
  return out.length ? out : ['fleet'];
}
/** Hashtags of a post: the plan's, the pillar's, the car's make and model; no repeats, at most ten. */
export function postTags(plan: Plan, pillar: string, car: CarFacts | null): string[] {
  const extra: Record<string, string[]> = { owners: ['#CarOwners', '#PassiveIncome'], local: ['#Ontario', '#RoadTrip'], offers: ['#Deals'], trust: ['#HowItWorks'], proof: ['#Reviews'], fleet: [] };
  const all = [...plan.hashtags, ...(extra[pillar] ?? []), ...(car ? [tag(car.make), tag(`${car.make} ${car.model}`)] : [])].map((t) => (t.startsWith('#') ? t : `#${t}`)).filter((t) => t.length > 1);
  return [...new Set(all)].slice(0, 10);
}

/** A month's calendar. `from`: days before it are left out (today for the running month). `recent`: cars posted lately
 *  come last. A post whose facts are missing (no car with photos for a car post) falls back to a post that needs none. */
export function monthPlan(f: Facts, month: string, plan: Plan, learned: Learned = {}, opts: { from?: string; recent?: string[]; turn?: { slot: number; by: number } } = {}): MonthCalendar {
  const from = opts.from ?? f.today;
  const site = f.site_url.replace(/\/$/, '');
  const recent = new Set(opts.recent ?? []);
  const cars = f.cars.filter((c) => c.taking && c.daily && c.slug && c.photos.some((p) => p.path && !p.sample))
    .sort((a, b) => Number(recent.has(a.vehicle_id)) - Number(recent.has(b.vehicle_id)) || a.name.localeCompare(b.name));
  const cheapest = [...cars].sort((a, b) => (a.daily ?? 0) - (b.daily ?? 0));
  const formats = weekFormats(plan.mix, learned.top_format);
  const cycle = pillarCycle(plan.pillars, learned.top_pillar);
  const photosOf = (c: CarFacts, n: number) => c.photos.filter((p) => p.path && !p.sample).slice(0, n).map((p) => p.path);
  const age = f.rules.min_age ? `${f.rules.min_age} or older` : '21 or older';
  const posts: CalendarPost[] = [];
  // weeks: Monday to Sunday; a week's posts go on its most wanted weekdays that are in the month
  const days = monthDays(month);
  const weeks = new Map<string, string[]>();
  for (const d of days) { const key = iso(new Date(Date.parse(`${d}T12:00:00Z`) - (isoDow(d) - 1) * 86_400_000)); weeks.set(key, [...(weeks.get(key) ?? []), d]); }
  let slot = 0; let carNo = 0; let tripNo = Number(month.slice(5, 7));
  for (const inMonth of weeks.values()) {
    const wanted = DAY_ORDER.map((dow) => inMonth.find((d) => isoDow(d) === dow)).filter((d): d is string => !!d).slice(0, formats.length).sort();
    wanted.forEach((day, i) => {
      slot += 1;
      const no = slot;
      const format = formats[i % formats.length]!;
      // Regenerate: this slot again, the next car and the next wording
      const by = opts.turn?.slot === no ? opts.turn.by : 0;
      let pillar = cycle[(no - 1) % cycle.length]!;
      const needsCar = pillar === 'fleet' || pillar === 'offers';
      let car: CarFacts | null = needsCar ? (pillar === 'offers' ? cheapest[(carNo + by) % Math.max(cheapest.length, 1)] : cars[(carNo + by) % Math.max(cars.length, 1)]) ?? null : null;
      if (needsCar && !car) pillar = 'trust';
      // every post carries a picture: a post about no one car borrows the next car's cover
      const media = car ?? cars[(carNo + no + by) % Math.max(cars.length, 1)] ?? null;
      if (needsCar && car) carNo += 1;
      const trips = TRIPS.filter((t) => !t.border);
      const trip = trips[(tripNo + by) % trips.length]!;
      if (pillar === 'local') tripNo += 1;
      const seed = `${month}|${no}|${pillar}|${car?.vehicle_id ?? ''}${by ? `|again${by}` : ''}`;
      const v = { car: car ? carName(car) : '', daily: money((car ?? cheapest[0])?.daily ?? null), weekly: money((car ?? cheapest[0])?.weekly ?? null), age, trip: trip.name, km: trip.km, what: trip.what };
      const caption = say(pillar in BANK ? pillar : 'fleet', seed, v);
      const hook = say(`${pillar in BANK ? pillar : 'fleet'}_hook`, seed, v);
      // a day already past keeps its slot number and its turn of the cars, so the rest of the month reads the same
      if (!caption || day < from) return;
      const channels = FORMAT_CHANNELS[format];
      const best: Partial<Record<CalChannel, string>> = {};
      for (const ch of channels) { const t = plan.times[ch] ?? []; best[ch] = learned.times?.[ch] ?? t[(no - 1) % Math.max(t.length, 1)] ?? '12:00'; }
      car = needsCar ? car : null;
      posts.push({
        slot_no: no, slot_date: day, format, pillar, kind: KIND[pillar] ?? 'custom', channels, vehicle_id: (car ?? (format === 'reel' ? media : null))?.vehicle_id ?? null,
        hook, caption, hashtags: postTags(plan, pillar, car), music: format === 'photo' ? null : plan.music[pillar] ?? null, best_times: best,
        link: car ? `${site}/cars/${car.slug}` : pillar === 'owners' ? `${site}/list-your-car` : pillar === 'trust' ? `${site}/how-it-works` : `${site}/cars`,
        photos: media ? photosOf(media, format === 'carousel' ? 5 : 1) : [], shot_list: SHOTS[format](car ? carName(car) : null)
      });
    });
  }
  return { month, posts, plan, learned };
}

/** One slot written again (Regenerate): the same day, format and pillar, the next car and the next wording. */
export function regeneratePost(f: Facts, month: string, plan: Plan, learned: Learned, slotNo: number, attempt: number, opts: { recent?: string[] } = {}): CalendarPost | null {
  return monthPlan(f, month, plan, learned, { from: `${month}-01`, recent: opts.recent, turn: { slot: slotNo, by: Math.max(1, attempt) } }).posts.find((p) => p.slot_no === slotNo) ?? null;
}

/** Counts of a month's posts by format and by pillar, for the calendar's summary line. */
export function mixOf(posts: Array<Pick<CalendarPost, 'format' | 'pillar'>>): { formats: Record<string, number>; pillars: Record<string, number> } {
  const formats: Record<string, number> = {}; const pillars: Record<string, number> = {};
  for (const p of posts) { formats[p.format] = (formats[p.format] ?? 0) + 1; pillars[p.pillar] = (pillars[p.pillar] ?? 0) + 1; }
  return { formats, pillars };
}
