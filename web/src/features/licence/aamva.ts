// The driver's licence reader (release 31, D2): what a licence's back barcode says, and the checks that need no database.
// Pure, so the server, the browser and the unit tests share it (aamva.test.ts).
//
// Canadian and US licences carry a PDF417 barcode in the AAMVA DL/ID format: a header ("@", then "ANSI " and the
// issuer's 6-digit IIN), then data elements, each a 3-letter code and its value on its own line: DCS family name, DAC
// first name, DAD middle names, DBB date of birth, DAQ licence number, DCA class, DBD issue date, DBA expiry, DAJ the
// state or province, DAG street, DAI city, DAK postal code, DCG country. Dates are CCYYMMDD in Canada and MMDDCCYY in the
// US. Older cards put the whole name in DAA ("LAST,FIRST,MIDDLE").

export interface LicenceFields {
  first_name: string | null;
  last_name: string | null;
  full_name: string | null;
  date_of_birth: string | null;   // YYYY-MM-DD
  licence_number: string | null;
  licence_class: string | null;
  issued_on: string | null;       // YYYY-MM-DD
  expires_on: string | null;      // YYYY-MM-DD
  issuer: string | null;          // the province or state code: ON, QC, NY ...
  country: string | null;         // CAN, USA, or another
  address: string | null;
}

export const EMPTY_FIELDS: LicenceFields = {
  first_name: null, last_name: null, full_name: null, date_of_birth: null, licence_number: null, licence_class: null,
  issued_on: null, expires_on: null, issuer: null, country: null, address: null
};

/** Canadian provinces and territories, by their two-letter code. */
export const PROVINCES = ['AB', 'BC', 'MB', 'NB', 'NL', 'NS', 'NT', 'NU', 'ON', 'PE', 'QC', 'SK', 'YT'];
/** The issuer IIN of a few jurisdictions, for a barcode without DAJ. */
const IIN: Record<string, string> = { '636012': 'ON', '636017': 'QC', '636028': 'BC', '636048': 'MB', '604427': 'AB', '636044': 'SK', '636013': 'NS', '636016': 'NB', '636001': 'NY' };

const clean = (s: string | undefined) => {
  const v = (s ?? '').replace(/\s+/g, ' ').trim();
  return v && !/^(NONE|UNAVL|UNAVAILABLE)$/i.test(v) ? v : null;
};
const title = (s: string | null) => (s ? s.toLowerCase().replace(/(^|[\s'-])([a-z])/g, (_, a: string, b: string) => a + b.toUpperCase()) : null);
const validDay = (y: number, m: number, d: number) => {
  if (y < 1900 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31) return false;
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
};
const iso = (y: number, m: number, d: number) => `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;

/** An AAMVA date (8 digits), as YYYY-MM-DD: CCYYMMDD (Canada) or MMDDCCYY (US), whichever is a real day; the country decides a tie. */
export function aamvaDate(raw: string | null | undefined, country: string | null = null): string | null {
  const s = (raw ?? '').replace(/\D/g, '');
  if (s.length !== 8) return null;
  const ymd = [Number(s.slice(0, 4)), Number(s.slice(4, 6)), Number(s.slice(6, 8))] as const;
  const mdy = [Number(s.slice(4, 8)), Number(s.slice(0, 2)), Number(s.slice(2, 4))] as const;
  const a = validDay(...ymd); const b = validDay(...mdy);
  if (a && b) return country === 'USA' ? iso(...mdy) : iso(...ymd);
  if (a) return iso(...ymd);
  if (b) return iso(...mdy);
  return null;
}

/** The data elements of an AAMVA barcode, code to value (the first of each). */
export function aamvaElements(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  // elements are separated by line feeds (some readers give carriage returns or record separators); the first one of a
  // subfile follows its "DL" or "ID" marker on the same line
  const lines = text.replace(/\r\n?/g, '\n').replace(/[\u001e\u001d]/g, '\n').split('\n');
  for (let line of lines) {
    const sub = /(?:^|[^A-Z])(?:DL|ID)(D[A-Z]{2}.*)$/.exec(line);
    if (sub && !/^D[A-Z]{2}/.test(line)) line = sub[1]!;
    const m = /^(D[A-Z]{2}|Z[A-Z]{2})(.*)$/.exec(line.trim());
    if (m && !(m[1]! in out)) out[m[1]!] = m[2]!;
  }
  return out;
}

/** Whether a text read from a barcode is an AAMVA licence. */
export const isAamva = (text: string) => /ANSI ?\d{6}/.test(text) || (/\bDAQ/.test(text) && /\bDBB/.test(text));

/** The fields of a licence from its barcode text; null when it is not a licence barcode. */
export function parseAamva(text: string): LicenceFields | null {
  if (!text || !isAamva(text)) return null;
  const e = aamvaElements(text);
  const country = clean(e.DCG)?.toUpperCase() ?? null;
  let last = clean(e.DCS); let first = clean(e.DAC ?? e.DCT); const middle = clean(e.DAD);
  if (!last && e.DAA) { const [l, f] = e.DAA.split(/[,$]/); last = clean(l); first = first ?? clean(f); }
  const issuerRaw = clean(e.DAJ)?.toUpperCase() ?? null;
  const iin = /ANSI ?(\d{6})/.exec(text)?.[1];
  const issuer = issuerRaw && /^[A-Z]{2}$/.test(issuerRaw) ? issuerRaw : (iin ? IIN[iin] ?? null : null);
  const ctry = country ?? (issuer && PROVINCES.includes(issuer) ? 'CAN' : issuer ? 'USA' : null);
  const street = title(clean(e.DAG)); const city = title(clean(e.DAI)); const postal = clean(e.DAK)?.replace(/0000$/, '') ?? null;
  const number = clean(e.DAQ)?.toUpperCase() ?? null;
  const f: LicenceFields = {
    first_name: title(first), last_name: title(last),
    full_name: [title(first), title(middle), title(last)].filter(Boolean).join(' ') || null,
    date_of_birth: aamvaDate(e.DBB, ctry),
    licence_number: number,
    licence_class: clean(e.DCA)?.toUpperCase() ?? null,
    issued_on: aamvaDate(e.DBD, ctry),
    expires_on: aamvaDate(e.DBA, ctry),
    issuer, country: ctry,
    address: [street, city, issuer, postal].filter(Boolean).join(', ') || null
  };
  return f.licence_number || f.date_of_birth || f.last_name ? f : null;
}

/** An Ontario licence number, A1234-56789-01234 (a letter, then 14 digits), dashes as printed. */
export function ontarioFormat(n: string | null | undefined): string | null {
  const s = (n ?? '').toUpperCase().replace(/[\s-]/g, '');
  return /^[A-Z]\d{14}$/.test(s) ? `${s.slice(0, 5)}-${s.slice(5, 10)}-${s.slice(10)}` : null;
}

/**
 * Ontario's number check: the letter is the first letter of the family name, and the last six digits are the date of
 * birth (YYMMDD; the month plus 50 on some cards). Each part is said apart, so staff see which one does not match.
 */
export function ontarioCheck(n: string | null | undefined, lastName: string | null | undefined, dob: string | null | undefined): { format: boolean; letter: boolean | null; birth: boolean | null } {
  const f = ontarioFormat(n);
  if (!f) return { format: false, letter: null, birth: null };
  const s = f.replace(/-/g, '');
  const ln = (lastName ?? '').trim().toUpperCase().replace(/[^A-Z]/g, '');
  const letter = ln ? s[0] === ln[0] : null;
  let birth: boolean | null = null;
  if (dob && /^\d{4}-\d{2}-\d{2}$/.test(dob)) {
    const yy = dob.slice(2, 4); const mm = Number(dob.slice(5, 7)); const dd = dob.slice(8, 10);
    const tail = s.slice(9);
    birth = tail === `${yy}${String(mm).padStart(2, '0')}${dd}` || tail === `${yy}${String(mm + 50).padStart(2, '0')}${dd}`;
  }
  return { format: true, letter, birth };
}

/** An Ontario licence: issued by ON (the barcode's DAJ, or the read "Ontario"). */
export const isOntario = (issuer: string | null | undefined) => /^(ON|ONT|ONTARIO)$/i.test((issuer ?? '').trim());

// ---------------------------------------------------------------- the vision model, for a front or a back with no barcode
export const LICENCE_SYSTEM = 'You read a photo of one side of a driver\'s licence and answer in JSON. Copy what is printed, exactly; never guess. Dates as YYYY-MM-DD. issuer is the two-letter province or state code (ON for Ontario) or the country for an international licence. quality: "ok" when every corner and every word is visible and sharp; "blurry" when text is hard to read; "cut_off" when part of the card is outside the photo; "not_licence" when it is not a driver\'s licence. side: "front" (photo, name) or "back" (barcode).';
export const LICENCE_PROMPT = 'Read this driver\'s licence. Return {"side","quality","first_name","last_name","date_of_birth","licence_number","licence_class","issued_on","expires_on","issuer","country","address"}; use null for anything not printed or not readable.';
export const LICENCE_SCHEMA = {
  type: 'object',
  properties: {
    side: { type: 'string' }, quality: { type: 'string' }, first_name: { type: 'string' }, last_name: { type: 'string' }, date_of_birth: { type: 'string' },
    licence_number: { type: 'string' }, licence_class: { type: 'string' }, issued_on: { type: 'string' }, expires_on: { type: 'string' },
    issuer: { type: 'string' }, country: { type: 'string' }, address: { type: 'string' }
  }
};
export type Quality = 'ok' | 'blurry' | 'cut_off' | 'not_licence' | 'unreadable';
const day = (s: unknown) => (typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s.trim()) && validDay(Number(s.slice(0, 4)), Number(s.slice(5, 7)), Number(s.slice(8, 10))) ? s.trim() : null);
const str = (s: unknown, max = 120) => (typeof s === 'string' ? clean(s.slice(0, max)) : null);
/** The model's answer, checked: only well-formed values are kept. */
export function fieldsFromModel(d: unknown): { fields: LicenceFields; quality: Quality; side: 'front' | 'back' | null } {
  const o = (d && typeof d === 'object' ? d : {}) as Record<string, unknown>;
  const q = String(o.quality ?? '').toLowerCase().replace(/[\s-]/g, '_');
  const quality: Quality = q === 'ok' || q === 'blurry' || q === 'cut_off' || q === 'not_licence' ? q : 'unreadable';
  let issuer = str(o.issuer, 40)?.toUpperCase() ?? null;
  if (issuer === 'ONTARIO' || issuer === 'ONT') issuer = 'ON';
  const first = title(str(o.first_name)); const last = title(str(o.last_name));
  const fields: LicenceFields = {
    first_name: first, last_name: last, full_name: [first, last].filter(Boolean).join(' ') || null,
    date_of_birth: day(o.date_of_birth), licence_number: str(o.licence_number, 40)?.toUpperCase() ?? null,
    licence_class: str(o.licence_class, 10)?.toUpperCase() ?? null, issued_on: day(o.issued_on), expires_on: day(o.expires_on),
    issuer, country: str(o.country, 40)?.toUpperCase() ?? (issuer && PROVINCES.includes(issuer) ? 'CAN' : null), address: str(o.address, 200)
  };
  const side = o.side === 'front' || o.side === 'back' ? o.side : null;
  return { fields, quality, side };
}

/** The plain message when a photo cannot be used: the renter takes it again straight away. */
export function retakeMessage(q: Quality, side: 'licence_front' | 'licence_back'): string | null {
  const what = side === 'licence_back' ? 'the back of your licence' : 'the front of your licence';
  if (q === 'blurry' || q === 'unreadable') return `We could not read ${what}: the photo is blurry. Take it again in good light, held still, with the card filling the frame.`;
  if (q === 'cut_off') return `Part of ${what} is outside the photo. Take it again with all four corners in the frame.`;
  if (q === 'not_licence') return `That photo does not look like ${what}. Take a photo of the licence itself.`;
  return null;
}
