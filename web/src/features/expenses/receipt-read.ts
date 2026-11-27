// Reading a receipt photo (migration 5143): what the vision model is asked, and how its answer is checked before anyone sees
// it. The person checks every field before the expense is saved; nothing read is trusted alone. Pure: the capture screen and
// the unit tests share it (receipt-read.test.ts). Relative imports with their extension: the unit tests run it in Node.
import { findDate, normPlate } from '../tolls/parse.ts';

export const RECEIPT_SYSTEM = 'You read receipts and invoices for car expenses in Ontario: gas, car washes, oil changes, tires, repairs, parts, parking, registration. Answer with JSON only, in the shape asked. Copy each value exactly as printed. Use null for anything you cannot read clearly. Never guess an amount.';
export const RECEIPT_PROMPT = `Read this receipt or invoice. Answer with one JSON object with every key below, using null for anything not printed or not readable:
{"vendor": "the business name as printed", "date": "YYYY-MM-DD", "subtotal": 0.00, "tax": 0.00, "total": 0.00, "what": "a few words: what was bought or done", "plate": "a licence plate printed on it, letters and digits only", "vin": "a 17-character VIN printed on it", "confidence": 0}
"subtotal" is the amount before tax, "tax" the HST or GST and PST together, "total" the amount paid. "confidence" is 0 to 100: how sure you are of the amounts.`;
export const RECEIPT_SCHEMA = {
  type: 'object',
  properties: {
    vendor: { type: ['string', 'null'] }, date: { type: ['string', 'null'] }, subtotal: { type: ['number', 'string', 'null'] }, tax: { type: ['number', 'string', 'null'] },
    total: { type: ['number', 'string', 'null'] }, what: { type: ['string', 'null'] }, plate: { type: ['string', 'null'] }, vin: { type: ['string', 'null'] }, confidence: { type: ['number', 'null'] }
  },
  required: ['total']
} as const;

export interface ReceiptCar { id: string; name: string; plate: string | null; vin: string | null }
export interface ReceiptRead { amount_cents: number | null; hst_cents: number | null; expense_on: string | null; vendor: string | null; category: string | null; vehicle_id: string | null; what: string | null; confidence: number; problems: string[] }

const cents = (v: unknown): number | null => {
  const n = typeof v === 'number' ? v : typeof v === 'string' ? Number(v.replace(/[$,\s]/g, '')) : NaN;
  return Number.isFinite(n) && n >= 0 && n < 1_000_000 ? Math.round(n * 100) : null;
};
const str = (v: unknown, max = 160): string | null => (typeof v === 'string' && v.trim() && !/^(null|n\/a|none|unknown|-)$/i.test(v.trim()) ? v.trim().slice(0, max) : null);

/** The category from the vendor and what was bought (the company's expense categories); null when nothing fits. */
const CATEGORY_WORDS: Array<[string, RegExp]> = [
  ['maint_oil', /\b(oil change|lube|synthetic|oil & filter|oil and filter)\b|jiffy|mr\.? lube|quick lube/i],
  ['maint_tire_service', /\b(tire (swap|rotation|change|storage)|seasonal (swap|change)|winter tires? (on|off|install))\b/i],
  ['maint_tires', /\b(tires?|tyres?)\b/i],
  ['maint_brakes', /\bbrakes?|rotors?|pads\b/i],
  ['maint_battery', /\bbatter(y|ies)\b/i],
  ['maint_inspection', /\b(safety|inspection|emissions)\b/i],
  ['maint_registration', /serviceontario|\b(plate sticker|registration|validation)\b/i],
  ['field_fuel', /\b(gas|fuel|petro|esso|shell|pioneer|ultramar|husky|mobil|costco gas|unleaded|diesel|litres?)\b/i],
  ['field_cleaning', /\b(car ?wash|wash|detail(ing)?|vacuum|clean)\b/i],
  ['field_parking', /\b(parking|green p|impark|indigo|presto|transit|uber|lyft)\b/i],
  ['field_parts', /\b(parts?|canadian tire|autozone|napa|wiper|bulb|fluid|accessor)\b/i],
  ['maint_service', /\b(service|repair|mechanic|garage|auto centre|automotive|labou?r)\b/i]
];
export function guessCategory(text: string, allowed: string[]): string | null {
  for (const [code, re] of CATEGORY_WORDS) if (allowed.includes(code) && re.test(text)) return code;
  return null;
}

/** The vision model's answer checked: amounts that add up, a real date not ahead, the car by its plate or VIN. */
export function normalizeReceipt(data: unknown, ctx: { cars: ReceiptCar[]; categories: string[]; today: string }): ReceiptRead {
  const o = (data && typeof data === 'object' ? data : {}) as Record<string, unknown>;
  const problems: string[] = [];
  const total = cents(o.total);
  let tax = cents(o.tax), sub = cents(o.subtotal);
  if (sub == null && total != null && tax != null) sub = total - tax;
  if (tax == null && total != null && sub != null && total >= sub) tax = total - sub;
  if (sub == null && total != null) { sub = total; problems.push('No tax was read: check whether the total includes HST'); }
  if (sub != null && tax != null && total != null && sub + tax !== total) problems.push(`The amount and the tax add up to ${((sub + tax) / 100).toFixed(2)}, the total says ${(total / 100).toFixed(2)}`);
  if (sub != null && tax != null && tax > sub) { problems.push('The tax read is more than the amount: check both'); tax = null; }
  if (sub == null) problems.push('No amount was read: type it from the receipt');
  const d = str(o.date, 40);
  let on = d ? findDate(d, 'auto')?.iso ?? null : null;
  if (on && on > ctx.today) { problems.push('The date read is ahead of today: check it'); on = null; }
  if (!on) problems.push('No date was read: today is used, check it');
  const vendor = str(o.vendor), what = str(o.what, 200);
  const category = guessCategory([vendor, what].filter(Boolean).join(' '), ctx.categories);
  const plate = normPlate(str(o.plate, 20)); const vin = str(o.vin, 20)?.toUpperCase().replace(/[^A-Z0-9]/g, '') ?? null;
  const car = (vin && vin.length === 17 ? ctx.cars.find((c) => c.vin?.toUpperCase() === vin) : undefined) ?? (plate ? ctx.cars.find((c) => normPlate(c.plate) === plate) : undefined) ?? null;
  const conf = typeof o.confidence === 'number' && Number.isFinite(o.confidence) ? Math.max(0, Math.min(100, Math.round(o.confidence))) : 50;
  return { amount_cents: sub, hst_cents: tax, expense_on: on ?? ctx.today, vendor, category, vehicle_id: car?.id ?? null, what, confidence: Math.max(0, conf - problems.length * 10), problems };
}

/** Several photos of one receipt (or a receipt and its invoice): the first value read wins for each field, the amounts from the
 *  read with the highest confidence. */
export function mergeReads(reads: ReceiptRead[]): ReceiptRead | null {
  if (!reads.length) return null;
  const best = [...reads].sort((a, b) => (b.amount_cents != null ? 1 : 0) - (a.amount_cents != null ? 1 : 0) || b.confidence - a.confidence)[0]!;
  const first = <K extends keyof ReceiptRead>(k: K) => reads.map((r) => r[k]).find((v) => v != null) ?? null;
  return { ...best, vendor: best.vendor ?? first('vendor'), category: best.category ?? first('category'), vehicle_id: best.vehicle_id ?? first('vehicle_id'), what: best.what ?? first('what') } as ReceiptRead;
}
