// Facebook Marketplace kits (migration 0410, docs/runbooks/marketplace.md): everything one car's vehicle listing on
// facebook.com/marketplace/create/vehicle asks for, written from the car's own record (app.ads_facts of 0167 and the
// extra facts of app.marketplace_read): the field values in the form's order, the description in Marketplace style, the
// ten best photos in order, the location and the tracked link. Computed when the page opens, so it always carries
// today's prices. Nothing here is posted by the server: Claude in Chrome (or a person) posts it from the owner's profile.
// Pure (no I/O): the unit tests run it in Node. Relative imports only.
import { carPage, withUtm } from '../ads/channels.ts';
import { ageWords, carName, money, priceLine, textProblem, type AdPhoto, type CarFacts, type Rules } from '../ads/listing.ts';

export interface KitExtra { odometer_km?: number | null; home_area?: string | null; supply?: 'program_owner' | 'company' | 'partner' | null; drivetrain?: string | null; doors?: number | null }
export interface KitSettings { posts_per_day: number; renew_days: number; location: string }

export interface KitField { label: string; value: string; note?: string }
export interface Kit {
  vehicle_id: string; code: string | null; name: string;
  /** the vehicle form's fields, in the order the form asks for them */
  fields: KitField[];
  /** Marketplace shows Year Make Model as a vehicle's title; this line opens the description */
  title: string;
  priceLine: string;
  /** the whole-dollar daily rate for the Price box */
  price: number | null;
  description: string;
  /** the same description without the link, for a listing Facebook holds back for the link */
  descriptionNoLink: string;
  photos: AdPhoto[];
  location: string;
  link: string;
  /** what stops the car being posted today (empty: ready) */
  blockers: string[];
  warnings: string[];
}

/** Marketplace's body styles. */
export function bodyStyle(raw: string | null | undefined): string {
  const s = (raw ?? '').toLowerCase();
  if (/convertible|cabrio|roadster|spyder|spider/.test(s)) return 'Convertible';
  if (/coupe|coupé/.test(s)) return 'Coupe';
  if (/minivan|van/.test(s)) return 'Minivan';
  if (/pickup|truck/.test(s)) return 'Truck';
  if (/suv|crossover|sport utility/.test(s)) return 'SUV';
  if (/wagon|estate/.test(s)) return 'Wagon';
  if (/hatch/.test(s)) return 'Hatchback';
  if (/sedan|saloon/.test(s)) return 'Sedan';
  return 'Other';
}

const COLOURS = ['Black', 'Blue', 'Brown', 'Gold', 'Green', 'Grey', 'Pink', 'Purple', 'Red', 'Silver', 'Orange', 'White', 'Yellow', 'Charcoal', 'Off white', 'Tan', 'Beige', 'Burgundy', 'Turquoise'];
/** Marketplace's exterior colours (the nearest one; "Other" when nothing fits). */
export function colour(raw: string | null | undefined): string {
  const s = (raw ?? '').toLowerCase().trim();
  if (!s) return '';
  if (/gr[ae]y|graphite|gunmetal/.test(s)) return 'Grey';
  if (/charcoal/.test(s)) return 'Charcoal';
  if (/pearl|ivory|cream/.test(s)) return 'Off white';
  if (/maroon|wine|burgundy/.test(s)) return 'Burgundy';
  if (/navy/.test(s)) return 'Blue';
  if (/champagne|bronze/.test(s)) return 'Gold';
  const hit = COLOURS.find((c) => s.includes(c.toLowerCase()));
  return hit ?? 'Other';
}

/** Marketplace's fuel types. */
export function fuelType(raw: string | null | undefined): string {
  const s = (raw ?? '').toLowerCase();
  if (/plug/.test(s)) return 'Plug-in hybrid';
  if (/hybrid/.test(s)) return 'Hybrid';
  if (/electric|ev\b|bev/.test(s)) return 'Electric';
  if (/diesel/.test(s)) return 'Diesel';
  if (/flex|e85/.test(s)) return 'Flex';
  if (/gas|petrol|premium|regular|unleaded/.test(s) || !s) return 'Gasoline';
  return 'Other';
}

export const transmission = (raw: string | null | undefined) => (/manual|stick/i.test(raw ?? '') ? 'Manual transmission' : 'Automatic transmission');

/** Excellent for a car up to 3 model years old, Very good after that. */
export const condition = (year: number, todayIso: string) => (Number(todayIso.slice(0, 4)) - year <= 3 ? 'Excellent' : 'Very good');

/** The odometer as a listing gives it: rounded up to the next thousand. */
export const mileage = (km: number | null | undefined) => (km && km > 0 ? Math.ceil(km / 1000) * 1000 : null);

// The order buyers look at a car in: the cover, the front three-quarter, the dashboard and front seats, then around the car.
const SHOT_RANK = ['front_left', 'front', 'dashboard', 'front_seats', 'rear_left', 'rear_seats', 'rear', 'left', 'trunk', 'front_right', 'right', 'rear_right', 'wheel', 'other'];
const rankOf = (p: AdPhoto & { is_cover?: boolean }) => (p.is_cover ? -1 : (() => { const i = SHOT_RANK.indexOf(p.shot ?? 'other'); return i < 0 ? SHOT_RANK.length : i; })());

/** The ten best photos in posting order: the cover first, then the shots buyers look for, never a sample. */
export function bestPhotos(photos: Array<AdPhoto & { is_cover?: boolean }>, max = 10): AdPhoto[] {
  const real = photos.filter((p) => p && p.path && !p.sample);
  const first = real[0];
  return real.map((p, i) => ({ p, i, r: p === first ? -2 : rankOf(p) })).sort((a, b) => a.r - b.r || a.i - b.i).slice(0, max).map((x) => x.p);
}

export function location(extra: KitExtra | undefined, s: KitSettings): string {
  const area = extra?.home_area?.trim();
  return area ? (/,/.test(area) ? area : `${area}, Ontario`) : s.location;
}

const lines = (xs: Array<string | null | undefined | false>) => xs.filter((x): x is string => !!x && x.trim() !== '').join('\n');

/** The description in Marketplace style: short lines a phone shows whole, rates first, the next step last. The owner's rule
 * (November 1, 2026): no "rent", "rental" or "for rent"; the car is booked by the day, and the text says it is not for sale. */
export function description(c: CarFacts, r: Rules, link: string | null): string {
  const full = c.trim ? `${carName(c)} ${c.trim}` : carName(c);
  const spec = [c.colour, c.seats ? `${c.seats} seats` : null, c.transmission?.toLowerCase()].filter(Boolean).join(', ');
  const rates = [c.daily ? `${money(c.daily)} a day` : null, c.weekend && c.weekend !== c.daily ? `${money(c.weekend)} a day on weekends` : null,
    c.weekly ? `${money(c.weekly)} a week` : null, c.monthly ? `${money(c.monthly)} for 30 days` : null].filter(Boolean).join(', ');
  const age = ageWords(c, r);
  return lines([
    `Book this ${full} by the day${c.daily ? `, from ${money(c.daily)}/day` : ''}.`,
    'Daily and weekly bookings only, not for sale.',
    spec ? `${spec.replace(/^./, (x) => x.toUpperCase())}.` : null,
    c.free_this_weekend ? 'Free this weekend: drive it today.' : null,
    rates ? `${rates.replace(/^./, (x) => x.toUpperCase())}, plus HST.` : null,
    c.km ? `${c.km} km a day included${c.overage ? `, ${money(c.overage)} for each extra km` : ''}.` : null,
    c.delivery ? `Delivery across Ontario from ${money(c.delivery)} each way, or pick it up.` : 'Pick it up from us.',
    c.on_fleet_policy ? 'Liability coverage included.' : null,
    '',
    `To book: ${[age, 'a G2 or G licence', 'OPCF 27 on your own policy, a credit card with collision damage cover, or our Protection Plan', c.no_credit_card ? null : 'a credit card in your name'].filter(Boolean).join('; ')}.`,
    c.deposit ? `${money(c.deposit)} refundable deposit hold on pickup day.` : null,
    '',
    link ? `See the calendar and book in 2 minutes: ${link}` : 'Book on carmacars.ca: search the car code below.',
    'Or message your phone number and we will call you.',
    c.car_code ? `Car code ${c.car_code}.` : null
  ]).replace(/\n{3,}/g, '\n\n').trim();
}

/** One car's kit. todayIso: the Toronto date (YYYY-MM-DD). */
export function buildKit(c: CarFacts, r: Rules, extra: KitExtra | undefined, s: KitSettings, site: string, todayIso: string): Kit {
  const link = withUtm(carPage(site, c.slug), 'fb_marketplace', 'marketplace', c.car_code ?? c.slug);
  const photos = bestPhotos(c.photos as Array<AdPhoto & { is_cover?: boolean }>);
  const km = mileage(extra?.odometer_km);
  const price = c.daily && c.daily > 0 ? Math.round(c.daily / 100) : null;
  const loc = location(extra, s);
  const blockers: string[] = [];
  const warnings: string[] = [];
  if (!c.taking) blockers.push('Not taking requests on the site');
  if (!price) blockers.push('No daily rate');
  if (!photos.length) blockers.push(c.photos.some((p) => p.sample) ? 'Only sample photos: take real photos first' : 'No photos');
  else if (photos.length < 5) warnings.push(`Only ${photos.length} real photos: listings with 8 or more get more messages`);
  if (km === null) warnings.push('No odometer reading on file: read it from the odometer photo or ask fleet');
  if (extra?.supply === 'partner') warnings.push('A partner\'s car: post our own and co-hosted cars first');
  const ext = colour(c.colour);
  const fields: KitField[] = [
    { label: 'Vehicle type', value: 'Car/Truck' },
    { label: 'Location', value: loc },
    { label: 'Year', value: String(c.year) },
    { label: 'Make', value: c.make },
    { label: 'Model', value: c.trim ? `${c.model} ${c.trim}` : c.model, note: 'Pick the model from the list; type the trim if the list has it' },
    { label: 'Mileage (km)', value: km ? String(km) : '', note: km ? 'Rounded up to the next thousand' : 'Read the odometer photo' },
    { label: 'Price', value: price ? String(price) : '', note: 'The daily rate in dollars; the description says it is per day' },
    { label: 'Body style', value: bodyStyle(c.body_style ?? c.class) },
    { label: 'Exterior colour', value: ext, note: ext === 'Other' ? `The car is ${c.colour}` : undefined },
    { label: 'Interior colour', value: '', note: 'Pick what the seat photos show' },
    { label: 'Clean title', value: 'Leave unticked', note: 'A booking listing makes no title claim' },
    { label: 'Vehicle condition', value: condition(c.year, todayIso) },
    { label: 'Fuel type', value: fuelType(c.fuel) },
    { label: 'Transmission', value: transmission(c.transmission) }
  ];
  const title = `Book this ${carName(c)} by the day${price ? `, from $${price}/day` : ''}`;
  const desc = description(c, r, link);
  const p = textProblem(desc);
  if (p) warnings.push(p);
  return {
    vehicle_id: c.vehicle_id, code: c.car_code, name: c.name, fields, title, priceLine: priceLine(c), price, description: desc,
    descriptionNoLink: description(c, r, null), photos, location: loc, link, blockers, warnings
  };
}
