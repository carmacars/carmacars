// The request to book, as the phone fills it: three short steps, then the same request the site sends
// (web/src/features/booking/schema.ts; the server checks it again with the site's own schema and the database checks it
// a third time). This only catches the plain mistakes early, with the site's wording. No imports.
export interface Rules { min_age: number; max_days: number; notice_minutes: number; licence_classes: string[] }
export interface Form {
  car: string; from: string; to: string; tf: string; tt: string;
  pickupAt: 'ours' | 'owner' | 'airport'; pickupAirport: string; returnAt: 'ours' | 'owner' | 'airport'; returnAirport: string;
  first: string; last: string; email: string; phone: string; dobY: string; dobM: string; dobD: string;
  licClass: string; coverage: '' | '1' | '3'; opcfAck: boolean; bookingType: 'standard' | 'non_refundable'; notes: string; promo: string; agree: boolean; marketing: boolean;
}
export const emptyForm = (car: string, from = '', to = ''): Form => ({ car, from, to, tf: '10:00', tt: '10:00', pickupAt: 'ours', pickupAirport: '', returnAt: 'ours', returnAirport: '',
  first: '', last: '', email: '', phone: '', dobY: '', dobM: '', dobD: '', licClass: '', coverage: '', opcfAck: false, bookingType: 'standard', notes: '', promo: '', agree: false, marketing: false });

export function ageOn(y: string, m: string, d: string, onIso: string): number | null {
  const Y = Number(y); const M = Number(m); const D = Number(d);
  if (!Y || !M || !D || Y < 1900 || M > 12 || D > 31) return null;
  const date = new Date(Date.UTC(Y, M - 1, D));
  if (date.getUTCMonth() !== M - 1) return null;
  const [ry, rm, rd] = onIso.split('-').map(Number);
  let a = ry! - Y; if (rm! < M || (rm === M && rd! < D)) a--;
  return a;
}
const DAY = /^\d{4}-\d{2}-\d{2}$/;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;
const minutes = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));

export type Errors = Partial<Record<keyof Form | 'dob', string>>;
/** Step 1: the dates and where. Step 2: who drives. Step 3: the licence, the coverage and the agreement. */
export function stepErrors(step: 1 | 2 | 3, f: Form, r: Rules, ctx: { todayIso: string; nowMinutes: number; signedInWithoutEmail?: boolean; insuranceIncluded?: boolean }): Errors {
  const e: Errors = {};
  if (step === 1) {
    if (!DAY.test(f.from)) e.from = 'Choose the pickup date.';
    else if (f.from < ctx.todayIso) e.from = 'The pickup date has passed.';
    if (!DAY.test(f.to)) e.to = 'Choose the return date.';
    if (!TIME.test(f.tf)) e.tf = 'Choose the pickup time.';
    if (!TIME.test(f.tt)) e.tt = 'Choose the return time.';
    if (!e.from && !e.to && !e.tf && !e.tt) {
      const days = Math.round((Date.parse(`${f.to}T00:00:00Z`) - Date.parse(`${f.from}T00:00:00Z`)) / 86400_000);
      if (f.to < f.from || (f.to === f.from && minutes(f.tt) <= minutes(f.tf))) e.to = 'The return must be after the pickup.';
      else if (days > r.max_days) e.to = `The longest rental is ${r.max_days} days. For longer, call us.`;
      if (f.from === ctx.todayIso && minutes(f.tf) < ctx.nowMinutes + r.notice_minutes) {
        e.tf = r.notice_minutes >= 60 ? `Pick a time at least ${Math.round(r.notice_minutes / 60)} hour${r.notice_minutes >= 120 ? 's' : ''} from now.` : 'Pick a later pickup time.';
      }
    }
    if (f.pickupAt === 'airport' && !f.pickupAirport) e.pickupAirport = 'Choose the airport.';
    if (f.returnAt === 'airport' && !f.returnAirport) e.returnAirport = 'Choose the airport.';
  }
  if (step === 2) {
    if (f.first.trim().length < 1) e.first = 'Enter your first name, as on your licence.';
    if (f.last.trim().length < 1) e.last = 'Enter your last name, as on your licence.';
    if (!ctx.signedInWithoutEmail && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(f.email.trim())) e.email = 'Enter your email.';
    if (f.phone.replace(/\D/g, '').length < 10) e.phone = 'Enter your mobile number with the area code.';
    const age = ageOn(f.dobY, f.dobM, f.dobD, DAY.test(f.from) ? f.from : ctx.todayIso);
    if (age === null) e.dob = 'Enter your date of birth.';
    else if (age < r.min_age) e.dob = `Drivers must be at least ${r.min_age} on the pickup date.`;
  }
  if (step === 3) {
    if (!f.licClass) e.licClass = 'Choose your licence class.';
    if (!ctx.insuranceIncluded) {
      if (f.coverage !== '1' && f.coverage !== '3') e.coverage = 'Choose how the car is covered.';
      else if (f.coverage === '1' && !f.opcfAck) e.opcfAck = 'Tick that you will upload your policy with OPCF 27.';
    }
    if (f.notes.length > 1000) e.notes = 'Keep the note under 1,000 characters.';
    if (!/^[A-Za-z0-9-]*$/.test(f.promo)) e.promo = 'A promo code has letters, numbers and dashes only.';
    if (!f.agree) e.agree = 'Tick the box to agree before sending.';
  }
  return e;
}

/** The request as the site's own form sends it (the fields the phone does not ask keep the site's defaults). */
export function requestData(f: Form): Record<string, unknown> {
  const place = { label: '', placeId: '' };
  return {
    car: f.car, from: f.from, to: f.to, tf: f.tf, tt: f.tt,
    pickupAt: f.pickupAt, pickupAddress: place, pickupAirport: f.pickupAt === 'airport' ? f.pickupAirport : '',
    returnAt: f.returnAt, returnAddress: place, returnAirport: f.returnAt === 'airport' ? f.returnAirport : '',
    first: f.first.trim(), last: f.last.trim(), email: f.email.trim().toLowerCase(), phone: f.phone.trim(), dobY: f.dobY, dobM: f.dobM, dobD: f.dobD,
    drivers: [], referrer: '', heardAbout: '', licClass: f.licClass, licIssuer: '',
    // a car with insurance included needs no choice (the site sends none either)
    coverage: f.coverage, coverageCard: '', coverageCardAck: false, opcfAck: f.coverage === '1' && f.opcfAck,
    bookingType: f.bookingType, winter: false, babySeats: 0, notes: f.notes.trim(), addons: [], agree: f.agree, marketing: f.marketing, notifyChannel: '', promo: f.promo.trim()
  };
}
/** One key for one request, however often Send is pressed (the server makes the same request once). */
export const requestKey = (random: string) => `app-${random.replace(/[^A-Za-z0-9-]/g, '').slice(0, 60)}`;
