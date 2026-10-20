import { z } from '@/lib/zod';
import { email, phone } from '@/features/forms/schemas';

// The booking request: one schema for the browser and the server action (docs/blueprint/08-forms.md
// section 2). The database checks everything again in public.submit_booking_request; this schema
// gives the person a clear message first. Policy numbers come from the database (site_facts).
export interface RequestRules { minAge: number; maxDays: number; maxAdditional: number; maxSeats: number; noteMax: number; licenceClasses: string[]; otherLicence: boolean; noticeMinutes: number }

export const place = z.object({ label: z.string().trim().max(300).default(''), placeId: z.string().trim().max(300).default('') });
const dobFields = { dobY: z.string().trim().default(''), dobM: z.string().trim().default(''), dobD: z.string().trim().default('') };
export const driverSchema = z.object({ first: z.string().trim().default(''), last: z.string().trim().default(''), email: z.string().trim().default(''), licClass: z.string().default(''), ...dobFields });

export const requestShape = z.object({
  car: z.string().trim().default(''),
  from: z.string().default(''), to: z.string().default(''), tf: z.string().default('10:00'), tt: z.string().default('10:00'),
  pickupAt: z.enum(['ours', 'owner', 'delivery', 'airport']).default('ours'), pickupAddress: place.default({ label: '', placeId: '' }), pickupAirport: z.string().default(''),
  returnAt: z.enum(['ours', 'owner', 'delivery', 'airport']).default('ours'), returnAddress: place.default({ label: '', placeId: '' }), returnAirport: z.string().default(''),
  first: z.string().trim().default(''), last: z.string().trim().default(''), email: z.string().trim().default(''), phone: z.string().trim().default(''), ...dobFields,
  drivers: z.array(driverSchema).default([]), referrer: z.string().trim().max(100).default(''),
  licClass: z.string().default(''), licIssuer: z.string().trim().max(100).default(''),
  coverage: z.string().default(''), bookingType: z.enum(['standard', 'non_refundable']).default('standard'),
  // 0066: add-ons replace the winter tire and baby seat fields (kept so an older saved draft still loads; it is converted)
  winter: z.boolean().default(false), babySeats: z.number().int().min(0).default(0), notes: z.string().default(''),
  addons: z.array(z.object({ code: z.string().trim().regex(/^[a-z0-9_]{2,40}$/), quantity: z.number().int().min(0).max(20), hours: z.number().min(0).max(24).nullable().optional() })).max(30).default([]),
  agree: z.boolean().default(false), marketing: z.boolean().default(false),
  // a promo code (a discount game's prize, a come-back code): checked by the quote and again when the request is sent
  promo: z.string().trim().max(40).regex(/^[A-Za-z0-9-]*$/, 'A promo code has letters, numbers and dashes only.').default('')
});
export type RequestData = z.infer<typeof requestShape>;
export const emptyRequest = (): RequestData => requestShape.parse({});

/** Which step each field belongs to, so the wizard can check one step at a time. */
export const STEP_OF: Record<string, number> = {
  car: 1, dates: 1, from: 1, to: 1, tf: 1, tt: 1, pickupAt: 1, pickupAddress: 1, pickupAirport: 1, returnAt: 1, returnAddress: 1, returnAirport: 1,
  first: 2, last: 2, email: 2, phone: 2, dob: 2, drivers: 2, referrer: 2,
  licClass: 3, licIssuer: 3, coverage: 3, bookingType: 3, notes: 3, addons: 4, winter: 4, babySeats: 4, agree: 5, marketing: 5, promo: 5
};

export function ageOn(y: string, m: string, d: string, onIso: string): number | null {
  const Y = Number(y); const M = Number(m); const D = Number(d);
  if (!Y || !M || !D || Y < 1900 || M > 12 || D > 31) return null;
  const date = new Date(Date.UTC(Y, M - 1, D));
  if (date.getUTCMonth() !== M - 1) return null;
  const [ry, rm, rd] = onIso.split('-').map(Number);
  let a = ry! - Y; if (rm! < M || (rm === M && rd! < D)) a--;
  return a;
}
export const dobIso = (y: string, m: string, d: string) => `${y.padStart(4, '0')}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`;
const isEmail = (v: string) => email.safeParse(v).success;

/** Checks the whole request; `issues` maps a field key (or dates, dob, drivers.N.x) to a message. */
export function checkRequest(v: RequestData, r: RequestRules, ctx: { todayIso: string; nowMinutes: number; knownCar: boolean }): Record<string, string> {
  const e: Record<string, string> = {};
  const set = (k: string, m: string) => { if (!(k in e)) e[k] = m; };
  // step 1
  if (!v.car || !ctx.knownCar) set('car', 'Choose a car.');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v.from) || !/^\d{4}-\d{2}-\d{2}$/.test(v.to)) set('dates', !v.from ? 'Pick a pickup date and a return date.' : 'Pick a return date.');
  else {
    const mins = (iso: string, t: string) => Date.parse(iso + 'T00:00:00Z') / 6e4 + Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
    const a = mins(v.from, v.tf); const z = mins(v.to, v.tt);
    if (z <= a) set('dates', 'The return time is before the pickup time.');
    else if (Math.ceil((z - a) / 1440) > r.maxDays) set('dates', `One booking covers up to ${r.maxDays} days. Shorten the dates; you can renew later.`);
    else if (a < mins(ctx.todayIso, '00:00') + ctx.nowMinutes + r.noticeMinutes) set('dates', `Pickup needs at least ${r.noticeMinutes / 60} hours’ notice. Choose a later time.`);
  }
  if (v.pickupAt === 'delivery' && v.pickupAddress.label.trim().length < 5) set('pickupAddress', 'Add the delivery address so we can price the trip.');
  if (v.pickupAt === 'airport' && !v.pickupAirport) set('pickupAirport', 'Choose an airport.');
  if (v.returnAt === 'delivery' && v.pickupAt !== 'delivery' && v.returnAddress.label.trim().length < 5) set('returnAddress', 'Add the address where we pick the car up.');
  if (v.returnAt === 'airport' && !v.returnAirport) set('returnAirport', 'Choose an airport.');
  // step 2
  if (v.first.length < 1 || v.first.length > 60) set('first', 'Enter your first name as it appears on your licence.');
  if (v.last.length < 1 || v.last.length > 60) set('last', 'Enter your last name as it appears on your licence.');
  if (!isEmail(v.email)) set('email', v.email ? 'Enter an email address like name@example.com.' : 'Enter your email so we can send the price.');
  if (!phone.safeParse(v.phone).success) set('phone', v.phone ? 'Enter a phone number with area code.' : 'Enter a mobile number we can reach you on.');
  const ref = /^\d{4}-\d{2}-\d{2}$/.test(v.from) ? v.from : ctx.todayIso;
  const age = ageOn(v.dobY, v.dobM, v.dobD, ref);
  if (age === null) set('dob', 'Enter your full date of birth.');
  else if (age < r.minAge) set('dob', `Drivers must be ${r.minAge} or older at pickup.`);
  else if (age > 110) set('dob', 'Check the year.');
  if (v.drivers.length > r.maxAdditional) set('drivers', `A booking may name up to ${r.maxAdditional} additional drivers.`);
  v.drivers.forEach((d, i) => {
    if (!d.first || !d.last) set(`drivers.${i}.name`, 'Enter this driver’s first and last name.');
    if (!isEmail(d.email)) set(`drivers.${i}.email`, 'Enter this driver’s email. We send them the agreement to sign.');
    const a = ageOn(d.dobY, d.dobM, d.dobD, ref);
    if (a === null) set(`drivers.${i}.dob`, 'Enter this driver’s full date of birth.');
    else if (a < r.minAge) set(`drivers.${i}.dob`, `Drivers must be ${r.minAge} or older at pickup.`);
  });
  if (v.referrer.length > 100) set('referrer', 'Keep it under 100 characters.');
  // step 3
  const classes = [...r.licenceClasses, ...(r.otherLicence ? ['other'] : [])];
  if (!classes.includes(v.licClass)) set('licClass', 'Choose your licence class.');
  if (v.licClass === 'other' && v.licIssuer.length < 2) set('licIssuer', 'Tell us which province, state or country issued it.');
  if (!['1', '2', '3'].includes(v.coverage)) set('coverage', 'Choose how the car will be covered. You can change it before pickup.');
  if (v.notes.length > r.noteMax) set('notes', `Keep the note under ${r.noteMax} characters.`);
  // step 4: add-ons are checked by the database (notice, stock, the car)
  // step 5
  if (!v.agree) set('agree', 'Tick this box to send your request.');
  return e;
}

export const stepOfKey = (k: string) => STEP_OF[k.split('.')[0]!] ?? 5;

/** An older draft's winter tires and baby seats, as add-ons. */
export function migrateExtras(v: RequestData): RequestData {
  if (!v.winter && !v.babySeats) return v;
  const a = v.addons.filter((c) => c.code !== 'winter_tire' && c.code !== 'baby_seat');
  if (v.babySeats) a.push({ code: 'baby_seat', quantity: v.babySeats, hours: null });
  if (v.winter) a.push({ code: 'winter_tire', quantity: 1, hours: null });
  return { ...v, addons: a, winter: false, babySeats: 0 };
}

/** The zod schema the browser and the server both run: structure from requestShape, rules above. */
export function requestSchema(r: RequestRules, ctx: { todayIso: string; nowMinutes: number; knownCar: (slug: string) => boolean }) {
  return requestShape.superRefine((v, c) => {
    for (const [k, message] of Object.entries(checkRequest(v, r, { ...ctx, knownCar: ctx.knownCar(v.car) }))) c.addIssue({ code: 'custom', path: k.split('.'), message });
  });
}
