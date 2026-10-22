import { nameCase } from './name-case.ts';
// VIN-first entry (migration 0082): the VIN's own rules, the decoder's answer in our words, the one summary line and the
// colour swatches. Pure, so the browser, the server and the unit tests share it (src/features/vin/vin.test.ts).
// The database keeps the same check (app.vin_check_ok, 0040) and decides what is stored.

/** 17 letters and digits, never I, O or Q (ISO 3779). */
export const VIN_RE = /^[A-HJ-NPR-Z0-9]{17}$/;

/** Upper case, with spaces and dashes taken out (people copy VINs with both). */
export const cleanVin = (v: string) => (v ?? '').toUpperCase().replace(/[\s-]/g, '');

const VALUE: Record<string, number> = {
  A: 1, B: 2, C: 3, D: 4, E: 5, F: 6, G: 7, H: 8, J: 1, K: 2, L: 3, M: 4, N: 5, P: 7, R: 9, S: 2, T: 3, U: 4, V: 5, W: 6, X: 7, Y: 8, Z: 9
};
const WEIGHT = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2];

/** The check digit a VIN should carry in position 9 (North American VINs; 49 CFR 565.15). */
export function expectedCheckDigit(vin: string): string | null {
  const v = cleanVin(vin);
  if (!VIN_RE.test(v)) return null;
  let sum = 0;
  for (let i = 0; i < 17; i++) {
    const c = v[i]!;
    sum += (/\d/.test(c) ? Number(c) : VALUE[c]!) * WEIGHT[i]!;
  }
  const m = sum % 11;
  return m === 10 ? 'X' : String(m);
}

export const vinCheckOk = (vin: string) => { const e = expectedCheckDigit(vin); return e !== null && cleanVin(vin)[8] === e; };

export type VinState =
  | { kind: 'empty' }
  | { kind: 'typing'; length: number }
  | { kind: 'bad_chars'; chars: string[] }
  | { kind: 'too_long'; length: number }
  | { kind: 'check_digit'; vin: string }
  | { kind: 'ok'; vin: string };

/** Where the VIN typed so far stands; ok and check_digit are both 17 valid characters. */
export function vinState(raw: string): VinState {
  const v = cleanVin(raw);
  if (!v) return { kind: 'empty' };
  const bad = [...new Set(v.replace(/[A-HJ-NPR-Z0-9]/g, '').split('').filter(Boolean))];
  if (bad.length) return { kind: 'bad_chars', chars: bad };
  if (v.length < 17) return { kind: 'typing', length: v.length };
  if (v.length > 17) return { kind: 'too_long', length: v.length };
  return vinCheckOk(v) ? { kind: 'ok', vin: v } : { kind: 'check_digit', vin: v };
}

/** The message under the VIN field, in plain words; null when there is nothing to say. */
export function vinMessage(s: VinState): string | null {
  switch (s.kind) {
    case 'empty': return null;
    case 'typing': return `${s.length} of 17 characters`;
    case 'too_long': return `A VIN has 17 characters; this one has ${s.length}. Check for an extra character.`;
    case 'bad_chars': {
      const map: Record<string, string> = { I: '1', O: '0', Q: '0' };
      const hints = s.chars.filter((c) => map[c]).map((c) => `${c} is probably ${map[c]}`);
      return hints.length ? `VINs never use I, O or Q: ${hints.join(', ')}.` : `A VIN has only letters and digits: remove ${s.chars.map((c) => `"${c}"`).join(', ')}.`;
    }
    case 'check_digit':
      return 'This VIN does not add up: one character may be misread (0 and D, 1 and L, 5 and S, 8 and B are the usual ones). Check it against the ownership permit. You can still save it.';
    case 'ok': return null;
  }
}

// ---------------------------------------------------------------- the decoder's answer (NHTSA vPIC DecodeVinValues)
export interface VinDecode {
  ok: boolean; year?: string; make?: string; model?: string; trim?: string; trim_candidates?: string[] | null; body_class?: string; fuel?: string; drivetrain?: string; transmission?: string;
  doors?: string; seats?: string; engine?: string; error_code?: string; raw?: Record<string, unknown>;
}

const FUEL: Record<string, string> = { gasoline: 'gasoline', diesel: 'diesel', electric: 'electric', 'plug-in hybrid': 'plug_in_hybrid', hybrid: 'hybrid', 'flexible fuel vehicle (ffv)': 'gasoline', ethanol: 'gasoline' };
export function fuelOf(primary: string, electrification: string, secondary = ''): string {
  const e = (electrification ?? '').toLowerCase();
  if (e.includes('phev') || e.includes('plug-in')) return 'plug_in_hybrid';
  if (e.includes('bev') || e.includes('battery electric')) return 'electric';
  if (e.includes('hev') || e.includes('hybrid')) return 'hybrid';
  const p = (primary ?? '').toLowerCase();
  if (p.includes('electric') && (secondary ?? '').toLowerCase().includes('gasoline')) return 'plug_in_hybrid';
  return FUEL[p] ?? (p.includes('electric') ? 'electric' : p.includes('gasoline') ? 'gasoline' : p.includes('diesel') ? 'diesel' : '');
}

/** Make names in the case people write them: "MERCEDES-BENZ" is "Mercedes-Benz", "BMW" stays. */
export function makeName(make: string): string {
  const m = (make ?? '').trim();
  if (!m) return '';
  return nameCase(m.toUpperCase(), 'make');
}

/** vPIC lists every trim a VIN may be when the VIN does not say ("S, SE, SEL", "S / SE / R-Line", "FE or LXS"): no trim
 *  then, rather than a list (0094: the database keeps the list as vehicles.trim_candidates and asks which one). */
export const TRIM_LIST = /,|\s\/\s|\sor\s/i;
export const trimOf = (t: string) => { const x = (t ?? '').trim(); return TRIM_LIST.test(x) ? '' : x; };
/** The trims of such a list, in order, each once; null when it is not a list. */
export function trimCandidates(t: string | null | undefined): string[] | null {
  const x = (t ?? '').trim();
  if (!TRIM_LIST.test(x)) return null;
  const out: string[] = [];
  for (const p of x.split(/\s*,\s*|\s+\/\s+|\s+or\s+/i)) { const y = p.trim(); if (y && !out.includes(y)) out.push(y); }
  return out.length > 1 ? out : null;
}

// ---------------------------------------------------------------- the gearbox (0094)
/** The four gearbox words of the listings (app.listing_norm_transmission). */
export const GEARBOXES = ['Automatic', 'Automatic (CVT)', 'Automatic (dual-clutch)', 'Manual'] as const;
export type Gearbox = (typeof GEARBOXES)[number];
/** A gearbox as vPIC or a person wrote it, as one of the four; null when it says nothing. */
export function gearboxOf(raw: string | null | undefined): Gearbox | null {
  const p = (raw ?? '').trim();
  if (!p) return null;
  if (/automated manual|dual.?clutch|dct|\(am/i.test(p)) return 'Automatic (dual-clutch)';
  if (/continuously|cvt|\(av|variable/i.test(p)) return 'Automatic (CVT)';
  if (/manual|^man\b/i.test(p)) return 'Manual';
  if (/auto/i.test(p)) return 'Automatic';
  return null;
}
/** EPA's transmission words for a year, make and model (fueleconomy.gov menu options: "Auto (S6), 4 cyl, 2.0 L, Turbo",
 *  "Man 6-spd", "Auto (AV-S7)", "Auto (AM-S7)"): the one gearbox they all share, 'mixed' when they differ, null when none. */
export function epaGearbox(texts: string[]): Gearbox | 'mixed' | null {
  const kinds = new Set<Gearbox>();
  for (const t of texts) { const g = gearboxOf(t.split(',')[0] ?? ''); if (g) kinds.add(g); }
  if (!kinds.size) return null;
  return kinds.size === 1 ? [...kinds][0]! : 'mixed';
}
/** The gearbox to store (0094): EPA's when one type covers every EPA row for the car; vPIC's only when vPIC states it
 *  for this VIN (a style and its number of speeds) and EPA does not say otherwise; else none, and staff confirm it. */
export function chooseGearbox(epa: Gearbox | 'mixed' | null, vpic: { style: string; speeds: string }): { gearbox: Gearbox | null; source: 'epa' | 'vpic_explicit' | 'none' } {
  const v = vpic.style && vpic.speeds ? gearboxOf(vpic.style) : null;
  if (epa === 'mixed') return { gearbox: null, source: 'none' };
  if (epa) return v && v !== epa ? { gearbox: null, source: 'none' } : { gearbox: epa, source: 'epa' };
  return v ? { gearbox: v, source: 'vpic_explicit' } : { gearbox: null, source: 'none' };
}

const n = (s: unknown) => { const x = String(s ?? '').trim(); return x && x !== 'Not Applicable' && x !== '0' ? x : ''; };

/** One vPIC DecodeVinValues result in the shape the listing worker and public.server_record_vin_decode store. */
export function mapVpic(x: Record<string, unknown>): VinDecode {
  // vPIC answers in capitals: the names in the case people write them (0087), so a new car never comes in shouting
  const year = n(x.ModelYear), make = makeName(n(x.Make)), model = nameCase(n(x.Model), 'model');
  const litres = n(x.DisplacementL), cyl = n(x.EngineCylinders), conf = n(x.EngineConfiguration);
  const litresText = litres ? `${Number(litres) ? Number(litres).toFixed(1) : litres} L` : '';
  const engine = [litresText, cyl && (/v-shaped/i.test(conf) ? `V${cyl}` : `${cyl} cylinders`), n(x.Turbo) && /yes/i.test(n(x.Turbo)) ? 'turbo' : ''].filter(Boolean).join(', ');
  const speeds = n(x.TransmissionSpeeds);
  const style = n(x.TransmissionStyle);
  return {
    ok: !!(year && make && model), year, make, model, trim: nameCase(trimOf(n(x.Trim) || n(x.Series)), 'trim'),
    trim_candidates: trimCandidates(n(x.Trim) || n(x.Series))?.map((t) => nameCase(t, 'trim')) ?? null, body_class: n(x.BodyClass),
    fuel: fuelOf(n(x.FuelTypePrimary), n(x.ElectrificationLevel), n(x.FuelTypeSecondary)), drivetrain: n(x.DriveType),
    transmission: style ? (speeds && !/continuously/i.test(style) ? `${style}, ${speeds} speeds` : style) : '',
    doors: n(x.Doors), seats: n(x.Seats), engine,
    error_code: n(x.ErrorCode) || undefined, raw: x
  };
}

// ---------------------------------------------------------------- the summary line
/** The decode as it comes back from the database (app.vin_facts), the fields in the samples' words. */
export interface DecodedCar {
  year: number | null; make: string | null; model: string | null; trim: string | null; body: string | null; fuel: string | null;
  drivetrain: string | null; transmission: string | null; doors: number | null; seats: number | null; engine: string | null;
  /** 0094: the trims the VIN may be when the decoder lists several; the add-a-car form asks which one */
  trim_candidates?: string[] | null;
  /** the decoder's own words for the body ("Sport Utility Vehicle (SUV)/Multi-Purpose Vehicle (MPV)") */
  body_class?: string | null;
}
export const FUEL_WORDS: Record<string, string> = { gasoline: 'Gas', diesel: 'Diesel', hybrid: 'Hybrid', plug_in_hybrid: 'Plug-in hybrid', electric: 'Electric' };

/** "2016 Porsche Macan S" */
export const carName = (c: Partial<DecodedCar>) => [c.year, c.make, c.model, c.trim].filter((x) => x !== null && x !== undefined && String(x).trim() !== '').join(' ');

/** "SUV · 5 seats · 4 doors · Gas · All-wheel drive · Automatic · 3.0 L, V6": the details, in one line. */
export function detailLine(c: Partial<DecodedCar>): string {
  return [c.body, c.seats ? `${c.seats} seats` : '', c.doors ? `${c.doors} doors` : '', c.fuel ? FUEL_WORDS[c.fuel] ?? c.fuel : '', c.drivetrain, c.transmission, c.engine]
    .filter((x) => x && String(x).trim()).join(' · ');
}

// ---------------------------------------------------------------- colour
/** The swatches: the colours people use for cars, in the words the listing uses. */
export const COLOURS: ReadonlyArray<{ name: string; hex: string }> = [
  { name: 'Black', hex: '#111111' }, { name: 'White', hex: '#f6f6f4' }, { name: 'Grey', hex: '#7b7f85' }, { name: 'Silver', hex: '#c4c7cc' },
  { name: 'Blue', hex: '#1f4fa3' }, { name: 'Red', hex: '#b3202a' }, { name: 'Green', hex: '#2f6b3a' }, { name: 'Brown', hex: '#6b4a2f' },
  { name: 'Beige', hex: '#d8c8a8' }, { name: 'Gold', hex: '#c8a24a' }, { name: 'Orange', hex: '#e06a1b' }, { name: 'Yellow', hex: '#f2c81f' }, { name: 'Purple', hex: '#5d3b8a' }
];

const COLOUR_WORDS: Array<[RegExp, string]> = [
  [/black|ebony|onyx|obsidian|jet|midnight black/, 'Black'], [/white|pearl|ivory|alpine|snow|chalk/, 'White'], [/silver|platinum|aluminum|aluminium/, 'Silver'],
  [/gr[ae]y|graphite|gunmetal|charcoal|slate|magnetic|titanium|nardo|anthracite/, 'Grey'], [/blue|navy|azure|cobalt|sapphire|teal/, 'Blue'],
  [/red|maroon|burgundy|crimson|ruby|wine|cherry/, 'Red'], [/green|olive|emerald|lime|forest/, 'Green'], [/brown|bronze|copper|mocha|chocolate|espresso/, 'Brown'],
  [/beige|tan|sand|champagne|cream|khaki/, 'Beige'], [/gold/, 'Gold'], [/orange/, 'Orange'], [/yellow/, 'Yellow'], [/purple|violet|plum/, 'Purple']
];
/** A colour as a person or the vision model wrote it, as one of the swatches; null when it is none of them. */
export function colourName(raw: string | null | undefined): string | null {
  const s = (raw ?? '').trim().toLowerCase();
  if (!s) return null;
  const exact = COLOURS.find((c) => c.name.toLowerCase() === s);
  if (exact) return exact.name;
  for (const [re, name] of COLOUR_WORDS) if (re.test(s)) return name;
  return null;
}

/** The vision model's answer for the colour of a car photo: {"colour": "...", "confidence": 0 to 100}. */
export const COLOUR_SYSTEM = 'You look at one photo of a car and name its body paint colour. Answer with JSON only.';
export const COLOUR_PROMPT = `What is the main body paint colour of the car in this photo? Choose one of: ${COLOURS.map((c) => c.name).join(', ')}. `
  + 'Ignore the background, the windows, the wheels and reflections. Answer as {"colour": "<one of the names>", "confidence": <0 to 100>}.';
/** The colour to store from the model's answer: one of the swatches with confidence 60 or more, else null. */
export function colourFromAnswer(data: unknown): string | null {
  if (!data || typeof data !== 'object') return null;
  const d = data as { colour?: unknown; color?: unknown; confidence?: unknown };
  const name = colourName(String(d.colour ?? d.color ?? ''));
  const conf = Number(d.confidence ?? 100);
  return name && Number.isFinite(conf) && conf >= 60 ? name : null;
}

// ---------------------------------------------------------------- the fallback: year, make and model from lists
export function yearChoices(now = new Date()): number[] {
  const top = now.getFullYear() + 1;
  return Array.from({ length: top - 1989 }, (_, i) => top - i);
}
/** The makes on the fallback list (the decoder's spelling); "Other" lets a person type one. */
export const MAKES: readonly string[] = [
  'Acura', 'Alfa Romeo', 'Aston Martin', 'Audi', 'Bentley', 'BMW', 'Buick', 'Cadillac', 'Chevrolet', 'Chrysler', 'Dodge', 'Ferrari', 'FIAT', 'Ford', 'Genesis',
  'GMC', 'Honda', 'Hyundai', 'Infiniti', 'Jaguar', 'Jeep', 'Kia', 'Lamborghini', 'Land Rover', 'Lexus', 'Lincoln', 'Lucid', 'Maserati', 'Mazda', 'McLaren',
  'Mercedes-Benz', 'MINI', 'Mitsubishi', 'Nissan', 'Polestar', 'Porsche', 'Ram', 'Rivian', 'Rolls-Royce', 'Subaru', 'Tesla', 'Toyota', 'Volkswagen', 'Volvo'
];
