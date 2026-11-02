// One model name per car family (migration 0520; the same rule as app.car_model_family in the database, and the unit
// test and supabase/tests/99_model_family.sql check the same cases). The owner, November 2026: /cars showed "C-Class" and
// "C300", "CLA-Class" and "CLA250" as separate models. The model is the family as the maker names it (C-Class, CLA-Class,
// GLA-Class, GLC, AMG GT, 3 Series); the code and the words after it are the trim (C300 4MATIC, CLA250 4MATIC, 330i).
// VIN decode, the permit scan, partner sheets and manual entry all go through it (the database applies it on every save).
// A value it cannot read with certainty is left exactly as typed: a guess never renames a car.
// Relative imports only (the unit test runs it in Node).

/** Mercedes-Benz: a model code's letters and the family the maker names. */
const MB: Record<string, string> = {
  A: 'A-Class', B: 'B-Class', C: 'C-Class', E: 'E-Class', S: 'S-Class', G: 'G-Class', CLA: 'CLA-Class', CLS: 'CLS-Class', CLE: 'CLE',
  GLA: 'GLA-Class', GLB: 'GLB', GLC: 'GLC', GLE: 'GLE', GLS: 'GLS', GLK: 'GLK-Class', ML: 'M-Class', GL: 'GL-Class', SL: 'SL', SLC: 'SLC', SLK: 'SLK-Class',
  EQB: 'EQB', EQE: 'EQE', EQS: 'EQS'
};
/** Mercedes-Benz family names as other sources write them (vPIC, permits, sheets) and the name we keep. */
const MB_ALIAS: Record<string, string> = {
  'A CLASS': 'A-Class', 'B CLASS': 'B-Class', 'C CLASS': 'C-Class', 'E CLASS': 'E-Class', 'S CLASS': 'S-Class', 'G CLASS': 'G-Class',
  'CLA CLASS': 'CLA-Class', CLA: 'CLA-Class', 'CLS CLASS': 'CLS-Class', CLS: 'CLS-Class', 'CLE CLASS': 'CLE', CLE: 'CLE',
  'GLA CLASS': 'GLA-Class', GLA: 'GLA-Class', 'GLB CLASS': 'GLB', GLB: 'GLB', 'GLC CLASS': 'GLC', GLC: 'GLC', 'GLC COUPE': 'GLC',
  'GLE CLASS': 'GLE', GLE: 'GLE', 'GLE COUPE': 'GLE', 'GLS CLASS': 'GLS', GLS: 'GLS', 'GLK CLASS': 'GLK-Class', 'M CLASS': 'M-Class', 'GL CLASS': 'GL-Class',
  'SL CLASS': 'SL', SL: 'SL', 'SLC CLASS': 'SLC', SLC: 'SLC', 'SLK CLASS': 'SLK-Class', 'AMG GT': 'AMG GT', 'MERCEDES AMG GT': 'AMG GT', GT: 'AMG GT',
  'AMG GT 4 DOOR COUPE': 'AMG GT', EQB: 'EQB', EQE: 'EQE', 'EQE SUV': 'EQE', EQS: 'EQS', 'EQS SUV': 'EQS', SPRINTER: 'Sprinter', METRIS: 'Metris',
  'MAYBACH S CLASS': 'S-Class', 'MAYBACH GLS': 'GLS'
};
/** BMW: the families. */
const BMW_FAMILIES = ['1 Series', '2 Series', '3 Series', '4 Series', '5 Series', '6 Series', '7 Series', '8 Series', 'X1', 'X2', 'X3', 'X3 M', 'X4', 'X4 M', 'X5', 'X5 M',
  'X6', 'X6 M', 'X7', 'XM', 'Z4', 'M2', 'M3', 'M4', 'M5', 'M8', 'i3', 'i4', 'i5', 'i7', 'i8', 'iX', 'iX3'];
/** The words that may follow a model code and still be a trim of it ("C300 4MATIC Coupe"); anything else is left as typed. */
const TRIM_WORDS = new Set(['4MATIC', '4MATIC+', 'AMG', 'COUPE', 'COUPÉ', 'CABRIOLET', 'CABRIO', 'CONVERTIBLE', 'SEDAN', 'WAGON', 'ESTATE', 'SUV', '4-DOOR', '4DR', '2DR',
  'ROADSTER', 'HYBRID', 'PLUG-IN', 'SPORT', 'PREMIUM', 'NIGHT', 'EDITION', 'FINAL', 'MAYBACH', 'PULLMAN', 'LWB', 'AVANTGARDE', 'EXCLUSIVE', 'PROGRESSIVE',
  'LUXURY', 'PACKAGE']);
/** The words after "AMG GT 63". */
const GT_WORDS = new Set(['4MATIC', '4MATIC+', 'AMG', 'COUPE', '4-DOOR', 'ROADSTER', 'EDITION']);
/** BMW: the words that may follow a model code ("330i xDrive", "M440i Gran Coupe"). */
const BMW_WORDS = new Set(['XDRIVE', 'SDRIVE', 'M', 'SPORT', 'GRAN', 'COUPE', 'TOURING', 'COMPETITION', 'CONVERTIBLE', 'SEDAN', 'PACKAGE', 'PREMIUM', 'EDITION']);

const MB_MAKES = ['MERCEDES-BENZ', 'MERCEDES BENZ', 'MERCEDES', 'MERCEDES-AMG', 'MERCEDES-MAYBACH', 'MERCE', 'MB'];
const norm = (s: string) => s.toUpperCase().replace(/[-_/]+/g, ' ').replace(/\s+/g, ' ').trim();
const clean = (s: string | null | undefined) => (s ?? '').replace(/\s+/g, ' ').trim();
export const isMercedes = (make: string | null | undefined) => MB_MAKES.includes(clean(make).toUpperCase());
export const isBmw = (make: string | null | undefined) => clean(make).toUpperCase() === 'BMW';

export interface Family { model: string; trim: string | null; known: boolean | null }

/** "C 300 4MATIC" -> the code C300 and the rest "4MATIC"; null when it is not a Mercedes-Benz model code with known words after it. */
function mbCode(s: string): { family: string; code: string; rest: string[] } | null {
  const words = clean(s).split(' ');
  let i = 0;
  const pre: string[] = [];
  // "Maybach S580", "AMG C43", "Mercedes-AMG GLE53": the badge is kept with the trim
  while (i < words.length && /^(MAYBACH|AMG|MERCEDES-AMG)$/i.test(words[i]!)) { if (!/^MERCEDES-AMG$/i.test(words[i]!)) pre.push(words[i]!); i++; }
  const head = words[i] ?? '';
  let m = /^([A-Z]{1,3})[ -]?(\d{2,3})([a-z]{0,1})$/i.exec(head);
  let used = 1;
  // "C 300" written as two words
  if (!m && /^[A-Z]{1,3}$/i.test(head) && /^\d{2,3}[a-z]?$/i.test(words[i + 1] ?? '')) { m = /^([A-Z]{1,3})(\d{2,3})([a-z]?)$/i.exec(head + words[i + 1]); used = 2; }
  if (!m) return null;
  const letters = m[1]!.toUpperCase();
  const family = MB[letters];
  if (!family) return null;
  const rest = words.slice(i + used);
  const twoDigit = m[2]!.length === 2;
  // an AMG car's "S" (C63 S) is part of the trim; after a three digit code a lone letter is not a trim word
  if (!rest.every((w) => TRIM_WORDS.has(w.toUpperCase()) || (twoDigit && w === 'S'))) return null;
  return { family, code: `${letters}${m[2]}${m[3] ?? ''}`, rest: [...pre, ...rest] };
}

const fixWord = (w: string) => (/^4matic\+?$/i.test(w) ? w.toUpperCase() : w);
const join = (...parts: Array<string | null | undefined>) => {
  const seen: string[] = [];
  for (const p of parts) for (const w of clean(p).split(' ')) if (w && !seen.some((x) => x.toUpperCase() === w.toUpperCase())) seen.push(fixWord(w));
  return seen.length ? seen.join(' ') : null;
};
/** "C300 4MATIC" with the code first, then the badge, then the rest ("C43 AMG", "S580 Maybach" is written "Maybach S580"). */
const codeTrim = (c: { code: string; rest: string[] }, trim: string | null) => {
  const maybach = c.rest.some((w) => /^maybach$/i.test(w));
  const rest = c.rest.filter((w) => !/^maybach$/i.test(w));
  const t = trim && cleanTrimOf(trim, c.code);
  return join(maybach ? 'Maybach' : null, c.code, ...rest, t);
};
/** A trim that repeats the code ("C300 4MATIC" with the code C300) keeps only what it adds. */
function cleanTrimOf(trim: string, code: string): string {
  const c = mbCode(trim);
  if (c && c.code.toUpperCase() === code.toUpperCase()) return c.rest.join(' ');
  return trim;
}

/** The family and the trim of one car. */
export function modelFamily(make: string | null | undefined, model: string | null | undefined, trim: string | null | undefined): Family {
  const mo = clean(model), tr = clean(trim) || null;
  if (!mo) return { model: model ?? '', trim: trim ?? null, known: null };
  if (isMercedes(make)) {
    const alias = MB_ALIAS[norm(mo)];
    if (alias) {
      // the family as named; a trim that is a code of another family is left alone
      const t = tr ? mbCode(tr) : null;
      return { model: alias, trim: t && t.family === alias ? codeTrim(t, null) : tr, known: true };
    }
    const c = mbCode(mo);
    if (c) return { model: c.family, trim: codeTrim(c, tr), known: true };
    // "AMG GT 53", "AMG GT63 S": the AMG GT family
    const gt = /^(?:MERCEDES-)?AMG GT ?(\d{2})?(?: (.*))?$/i.exec(mo);
    if (gt && (!gt[2] || gt[2].split(' ').every((w) => GT_WORDS.has(w.toUpperCase()) || w === 'S')))
      return { model: 'AMG GT', trim: join(gt[1] ? `GT${gt[1]}` : null, gt[2], tr), known: true };
    const known = Object.values(MB).includes(mo) || Object.values(MB_ALIAS).includes(mo);
    return { model: mo, trim: tr, known };
  }
  if (isBmw(make)) {
    // "330i", "M340i", "330e", "540i xDrive": the series; "X5 xDrive40i" is the X5, "X3 M Competition" stays the X3 M
    const s = /^(M?)(\d)(\d{2})([ide]|xi)(?: (.*))?$/i.exec(mo);
    if (s && (!s[5] || s[5].split(' ').every((w) => BMW_WORDS.has(w.toUpperCase()))))
      return { model: `${s[2]} Series`, trim: join(`${s[1]!.toUpperCase()}${s[2]}${s[3]}${s[4]!.toLowerCase()}`, s[5], tr), known: true };
    const x = /^(X\d|Z4|i\d|iX) (.+)$/i.exec(mo);
    if (x && !/^M( |$)/.test(x[2]!)) {
      const fam = /^x\d$/i.test(x[1]!) ? x[1]!.toUpperCase() : x[1]!;
      if (BMW_FAMILIES.includes(fam)) return { model: fam, trim: join(x[2], tr), known: true };
    }
    return { model: mo, trim: tr, known: BMW_FAMILIES.includes(mo) };
  }
  return { model: mo, trim: tr, known: null };
}

/** The models of a list of cars grouped by family, each with its trims (the /cars filter). */
export function familyTree<T extends { make: string; model: string; trim?: string | null }>(cars: T[]): Array<{ make: string; families: Array<{ model: string; trims: string[] }> }> {
  const makes = new Map<string, Map<string, Set<string>>>();
  for (const c of cars) {
    if (!c.make || !c.model) continue;
    const f = modelFamily(c.make, c.model, c.trim ?? null);
    const fams = makes.get(c.make) ?? new Map<string, Set<string>>();
    const trims = fams.get(f.model) ?? new Set<string>();
    if (f.trim) trims.add(f.trim);
    fams.set(f.model, trims); makes.set(c.make, fams);
  }
  const by = (a: string, b: string) => a.localeCompare(b, 'en', { numeric: true });
  return [...makes.entries()].sort(([a], [b]) => by(a, b)).map(([make, fams]) => ({
    make, families: [...fams.entries()].sort(([a], [b]) => by(a, b)).map(([model, trims]) => ({ model, trims: [...trims].sort(by) }))
  }));
}
