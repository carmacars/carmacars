// Reading an Ontario vehicle permit (ownership) photo (migration 0290). The vision model is asked for the vehicle portion
// of the permit; its answer is checked here before anyone sees it: the VIN's check digit, the plate's Ontario format,
// the plate sticker expiry printed as YYMMDD, the year against the VIN's year code, and the colour as one of the
// swatches. Nothing is saved from it: staff (or the owner) review the details in the form and save them as usual.
// Pure, so the browser, the server and the unit tests share it (permit-read.test.ts).
import { cleanVin, colourName, VIN_RE, vinCheckOk } from '../vin/vin.ts';

export const PERMIT_SYSTEM = 'You read Ontario vehicle permits (the ownership document issued by ServiceOntario). Answer with JSON only, in the shape asked. Copy each value exactly as printed. Use null for anything you cannot read clearly. Never guess a VIN, a plate or a number.';
export const PERMIT_PROMPT = `Read the vehicle portion of this Ontario vehicle permit. Answer with one JSON object with every key below, using null for anything not printed or not readable:
{"plate": "the plate number, letters and digits only", "vin": "the 17-character vehicle identification number", "year": 0, "make": "the make as printed, for example HYUND", "model": "the model code as printed", "body": "the body type as printed, for example 4DR", "colour": "the colour as printed, for example GRY", "permit_number": "the permit number as printed", "sticker_expiry": "the plate validation (sticker) expiry as printed, YYMMDD", "confidence": 0}
"confidence" is 0 to 100: how sure you are of the whole reading.`;
export const PERMIT_SCHEMA = {
  type: 'object',
  properties: {
    plate: { type: ['string', 'null'] }, vin: { type: ['string', 'null'] }, year: { type: ['number', 'string', 'null'] }, make: { type: ['string', 'null'] },
    model: { type: ['string', 'null'] }, body: { type: ['string', 'null'] }, colour: { type: ['string', 'null'] }, permit_number: { type: ['string', 'null'] },
    sticker_expiry: { type: ['string', 'null'] }, confidence: { type: ['number', 'null'] }
  },
  required: ['vin']
} as const;

/** Colour codes printed on Ontario permits, as the swatches. */
const COLOUR_CODES: Record<string, string> = {
  BLK: 'Black', BK: 'Black', WHI: 'White', WHT: 'White', WT: 'White', GRY: 'Grey', GRA: 'Grey', GY: 'Grey', CHA: 'Grey', SIL: 'Silver', SLV: 'Silver',
  BLU: 'Blue', BL: 'Blue', RED: 'Red', RD: 'Red', MAR: 'Red', GRN: 'Green', GN: 'Green', BRN: 'Brown', BRZ: 'Brown', BGE: 'Beige', TAN: 'Beige',
  GLD: 'Gold', ONG: 'Orange', ORG: 'Orange', YEL: 'Yellow', PLE: 'Purple', PUR: 'Purple'
};
/** Body codes printed on permits, in words. */
const BODY_CODES: Record<string, string> = {
  '4DR': 'Sedan, 4 doors', '2DR': 'Coupe, 2 doors', '5DR': 'Hatchback, 5 doors', '3DR': 'Hatchback, 3 doors', SW: 'Station wagon', SUV: 'SUV',
  CONV: 'Convertible', CV: 'Convertible', VAN: 'Van', MPV: 'Minivan', PU: 'Pickup', PK: 'Pickup', '4D': 'Sedan, 4 doors', '2D': 'Coupe, 2 doors'
};
/** The model year a VIN's tenth character stands for: 1 to 9 are 2001 to 2009, A to Y (no I, O, Q, U or Z) 2010 to 2030
 *  (the codes repeat every 30 years; the 1980 to 2000 cycle is too old for the fleet). */
const YEAR_LETTERS = 'ABCDEFGHJKLMNPRSTVWXY';
export function vinYear(vin: string): number | null {
  const v = cleanVin(vin);
  if (!VIN_RE.test(v)) return null;
  const c = v[9]!;
  if (/[1-9]/.test(c)) return 2000 + Number(c);
  const i = YEAR_LETTERS.indexOf(c);
  return i < 0 ? null : 2010 + i;
}

/** The plate as letters and digits; its Ontario format in words. */
export type PlateFormat = 'standard' | 'older' | 'personalized' | 'invalid';
export function plateFormat(raw: string | null | undefined): PlateFormat {
  const p = (raw ?? '').toUpperCase().replace(/[\s-]/g, '');
  if (!p) return 'invalid';
  if (/^[A-Z]{4}\d{3}$/.test(p)) return 'standard';
  if (/^[A-Z]{3}\d{3}$/.test(p)) return 'older';
  if (/^[A-Z0-9]{2,8}$/.test(p) && /[A-Z]/.test(p)) return 'personalized';
  return 'invalid';
}

/** YYMMDD (or a date in words the model may give) as YYYY-MM-DD; null when it is not a real date. */
export function stickerDate(raw: string | null | undefined): string | null {
  const s = (raw ?? '').trim();
  let y: number, m: number, d: number;
  const six = /^(\d{2})(\d{2})(\d{2})$/.exec(s.replace(/[\s/.-]/g, ''));
  const iso = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
  if (iso) { y = Number(iso[1]); m = Number(iso[2]); d = Number(iso[3]); }
  else if (six && s.replace(/[\s/.-]/g, '').length === 6) { y = 2000 + Number(six[1]); m = Number(six[2]); d = Number(six[3]); }
  else return null;
  const t = new Date(Date.UTC(y, m - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) return null;
  if (y < 2000 || y > 2099) return null;
  return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

export interface PermitRead {
  plate: string | null; vin: string | null; year: number | null; make: string | null; model: string | null;
  body: string | null; body_words: string | null; colour: string | null; colour_printed: string | null;
  permit_number: string | null; sticker_expires_on: string | null;
  /** what to look at before saving, in plain words (empty when everything checked out) */
  problems: string[];
  /** each field's state for the review: read and checked, read with a doubt, or not read */
  checks: Record<'plate' | 'vin' | 'year' | 'make' | 'model' | 'body' | 'colour' | 'permit_number' | 'sticker_expires_on', 'ok' | 'check' | 'missing'>;
  confidence: number;
}

type Obj = Record<string, unknown>;
const str = (v: unknown, max = 40): string | null => (typeof v === 'string' && v.trim() && !/^(null|n\/a|none|unknown|-)$/i.test(v.trim()) ? v.trim().slice(0, max) : typeof v === 'number' && Number.isFinite(v) ? String(v) : null);

/** The model's answer, checked. `today` (YYYY-MM-DD) dates the sticker check. */
export function normalizePermit(data: unknown, today: string): PermitRead {
  const d = (data && typeof data === 'object' && !Array.isArray(data) ? data : {}) as Obj;
  const problems: string[] = [];
  const checks = {} as PermitRead['checks'];

  // the VIN: 17 characters, I, O and Q read as the digits they nearly always are, then the check digit
  let vin = str(d.vin, 30) ? cleanVin(str(d.vin, 30)!).replace(/[IOQ]/g, (c) => (c === 'I' ? '1' : '0')) : null;
  if (vin && !VIN_RE.test(vin)) { problems.push(`The VIN read has ${vin.length} characters, not 17: type it from the permit.`); vin = null; checks.vin = 'missing'; }
  else if (vin && !vinCheckOk(vin)) { problems.push('The VIN does not pass its check digit: compare it with the permit, one character may be misread.'); checks.vin = 'check'; }
  else checks.vin = vin ? 'ok' : 'missing';
  if (!str(d.vin, 30)) problems.push('The VIN could not be read: type it from the permit.');

  const plateRaw = str(d.plate, 20);
  const plate = plateRaw ? plateRaw.toUpperCase().replace(/[^A-Z0-9]/g, '') : null;
  const pf = plateFormat(plate);
  checks.plate = !plate ? 'missing' : pf === 'standard' || pf === 'older' ? 'ok' : 'check';
  if (plate && pf === 'personalized') problems.push(`The plate ${plate} is not in the usual Ontario format (four letters and three digits): check it, it may be a personalized plate.`);
  if (plate && pf === 'invalid') problems.push(`The plate read (${plate}) is not a plate: type it from the permit.`);

  const yRaw = typeof d.year === 'number' ? d.year : Number(str(d.year, 4));
  let year = Number.isInteger(yRaw) && yRaw >= 1981 && yRaw <= new Date(`${today}T12:00:00Z`).getUTCFullYear() + 1 ? yRaw : null;
  const vy = vin ? vinYear(vin) : null;
  if (!year && vy) year = vy;
  checks.year = !year ? 'missing' : vy && vy !== year ? 'check' : 'ok';
  if (year && vy && vy !== year) problems.push(`The permit says ${year} but the VIN says ${vy}: check the year.`);

  const make = str(d.make, 30)?.toUpperCase() ?? null;
  const model = str(d.model, 30)?.toUpperCase() ?? null;
  checks.make = make ? 'ok' : 'missing';
  checks.model = model ? 'ok' : 'missing';

  const body = str(d.body, 20)?.toUpperCase().replace(/\s+/g, '') ?? null;
  const bodyWords = body ? BODY_CODES[body] ?? null : null;
  checks.body = body ? 'ok' : 'missing';

  const colourPrinted = str(d.colour, 20)?.toUpperCase() ?? null;
  const colour = colourPrinted ? COLOUR_CODES[colourPrinted.replace(/[^A-Z]/g, '')] ?? colourName(colourPrinted) : null;
  checks.colour = !colourPrinted ? 'missing' : colour ? 'ok' : 'check';
  if (colourPrinted && !colour) problems.push(`The colour code ${colourPrinted} is not one we know: choose the colour.`);

  const pnRaw = str(d.permit_number, 30);
  const permit = pnRaw ? pnRaw.toUpperCase().replace(/\s+/g, '') : null;
  const permitOk = !!permit && /^[A-Z0-9-]{4,20}$/.test(permit);
  checks.permit_number = !permit ? 'missing' : permitOk ? 'ok' : 'check';
  if (permit && !permitOk) problems.push('The permit number read does not look right: type it from the permit.');

  const sticker = stickerDate(str(d.sticker_expiry, 20));
  checks.sticker_expires_on = !str(d.sticker_expiry, 20) ? 'missing' : !sticker ? 'check' : sticker < today ? 'check' : 'ok';
  if (str(d.sticker_expiry, 20) && !sticker) problems.push('The plate sticker expiry is not a date (it is printed as YYMMDD): type it from the permit.');
  if (sticker && sticker < today) problems.push(`The plate sticker expired on ${sticker}: renew it before the car is rented.`);

  const said = typeof d.confidence === 'number' && Number.isFinite(d.confidence) ? Math.max(0, Math.min(100, d.confidence <= 1 ? d.confidence * 100 : d.confidence)) : 60;
  const doubts = Object.values(checks).filter((c) => c !== 'ok').length;
  return {
    plate: plate && pf !== 'invalid' ? plate : null, vin, year, make, model, body, body_words: bodyWords, colour, colour_printed: colourPrinted,
    permit_number: permitOk ? permit : null, sticker_expires_on: sticker,
    problems, checks, confidence: Math.round(Math.min(said, 95 - doubts * 10))
  };
}

/** How many fields were read and checked, for the line under the photo ("7 of 9 read"). */
export const permitScore = (r: PermitRead) => ({ ok: Object.values(r.checks).filter((c) => c === 'ok').length, of: Object.keys(r.checks).length });
