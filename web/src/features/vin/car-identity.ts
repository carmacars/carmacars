// One make, one model family, one trim and one body per car (release 48 AN, migration 3151; the same rule as
// app.car_identity and app.car_body in the database, which applies it on every save). The owner, November 20: the car
// filters showed "CLA 250" and "CLA-Class" (and "3 Series" and "330i") as separate models. Filters and facets group by the
// family; the trim is a detail.
// Portable (other brand builds): relative imports only, no framework; model-family.ts holds the Mercedes-Benz and BMW codes.
import { modelFamily } from './model-family.ts';
import { MAKE_NAMES, MODEL_FAMILIES } from './car-identity-data.ts';

export interface CarIdentity { make: string; model: string; trim: string | null; known: boolean | null }

const clean = (s: string | null | undefined) => (s ?? '').replace(/\s+/g, ' ').trim();
export const carKey = (s: string | null | undefined) => (s ?? '').toUpperCase().replace(/[^A-Z0-9]+/g, '');

/** The make as we write it ("Mercedes", "MB", "mercedes benz" -> Mercedes-Benz); an unknown make as typed. */
export function carMake(make: string | null | undefined): string {
  const m = clean(make);
  return MAKE_NAMES[carKey(m)] ?? m;
}

const TRIM_CODES = new Set(['SLE', 'SLT', 'SEL', 'SE', 'LE', 'XLE', 'XSE', 'LX', 'EX', 'EX-L', 'LT', 'LS', 'LTZ', 'XLT', 'AWD', 'FWD', 'RWD', '4WD', 'ESV', 'HSE',
  'SV', 'SR5', 'TRD', 'GTS', 'GT', 'RS', 'GS-P', 'GS', 'GX', 'GXL', 'SXT', 'RT', 'R/T', 'SRT', 'AT4', 'XL', 'ST', 'SR', 'SL', 'S']);

/** Each word once (case-insensitive), 4MATIC in capitals (0520's mf_join). */
function joinWords(words: string[]): string | null {
  const seen: string[] = [];
  for (const w of words) if (w && !seen.some((x) => x.toUpperCase() === w.toUpperCase())) seen.push(/^4matic\+?$/i.test(w) ? w.toUpperCase() : w);
  return seen.length ? seen.join(' ') : null;
}

/** The trim as one spelling: 4M -> 4MATIC, GC -> Gran Coupe (BMW), trim codes in capitals, the family not repeated. */
export function carTrimClean(make: string, family: string | null, trim: string | null | undefined): string | null {
  let t = clean(trim);
  if (!t) return null;
  t = t.replace(/(\d)-4M(\+?)(?=\s|$)/gi, '$1 4MATIC$2').replace(/(^|\s)4M(\+?)(?=\s|$)/gi, '$14MATIC$2');
  if (make.toUpperCase() === 'BMW') t = t.replace(/(^|\s)GC(?=\s|$)/g, '$1Gran Coupe');
  if (family && t.length > family.length && carKey(t.slice(0, family.length)) === carKey(family) && t[family.length] === ' ')
    t = (family === 'AMG GT' ? 'GT' + t.slice(family.length) : t.slice(family.length)).trim();
  return joinWords(t.split(' ').filter(Boolean).map((w) => (TRIM_CODES.has(w.toUpperCase()) && w !== w.toUpperCase() && !/\d/.test(w) && w.length <= 4 ? w.toUpperCase() : w)));
}

const familiesOf = (make: string) => (MODEL_FAMILIES[make] ?? []).map((f) => (typeof f === 'string' ? { family: f, aliases: [] as string[] } : { family: f[0], aliases: f[1] }));

/** The make, model family, trim and whether the family is one we know (null: a make we keep no families for). */
export function carIdentity(make: string | null | undefined, model: string | null | undefined, trim: string | null | undefined): CarIdentity {
  const mk = carMake(make), mo = clean(model), tr = clean(trim) || null;
  if (!mo) return { make: mk, model: model ?? '', trim: trim ?? null, known: null };
  if (mk === 'Mercedes-Benz' || mk === 'BMW') {
    let f = modelFamily(mk, mo, tr);
    // a family typed with the trim after it ("CLA-Class CLA250", "3 Series 330i")
    if (!f.known) {
      const w = mo.split(' ');
      for (let k = w.length - 1; k >= 1; k--) {
        const head = w.slice(0, k).join(' ');
        // only a family name itself (no code: "C 300 something" stays as typed, as 0520 wants)
        const h = modelFamily(mk, head, null);
        if (h.known && !h.trim) { f = modelFamily(mk, head, [w.slice(k).join(' '), tr].filter(Boolean).join(' ')); break; }
      }
    }
    return { make: mk, model: f.model, trim: carTrimClean(mk, f.model, f.trim), known: f.known };
  }
  const fams = familiesOf(mk);
  const w = mo.split(' ');
  for (let k = w.length; k >= 1; k--) {
    const head = carKey(w.slice(0, k).join(' '));
    const hit = fams.filter((f) => carKey(f.family) === head || f.aliases.some((a) => carKey(a) === head)).sort((a, b) => b.family.length - a.family.length)[0];
    if (hit) return { make: mk, model: hit.family, trim: carTrimClean(mk, hit.family, [w.slice(k).join(' '), tr].filter(Boolean).join(' ')), known: true };
  }
  return { make: mk, model: mo, trim: carTrimClean(mk, mo, tr), known: fams.length ? false : null };
}

/** One body name: Sedan, Coupe, Convertible, SUV, Hatchback, Wagon, Minivan, Pickup truck, Van (or the value as typed). */
export function carBody(body: string | null | undefined): string | null {
  const b = clean(body);
  if (!b) return body ?? null;
  const k = b.toUpperCase();
  if (/(PICKUP|TRUCK|CREW ?CAB|SUPERCREW)/.test(k)) return 'Pickup truck';
  if (/(MINIVAN|MPV ?$|PEOPLE CARRIER)/.test(k) && !/SPORT UTILITY/.test(k)) return 'Minivan';
  if (/(SUV|SPORT UTILITY|CROSSOVER|UTILITY)/.test(k)) return 'SUV';
  if (/(CONVERTIBLE|CABRIO|ROADSTER|SPIDER|SPYDER|VOLANTE)/.test(k)) return 'Convertible';
  if (/(COUPE|COUPÉ)/.test(k)) return 'Coupe';
  if (/(HATCH|LIFTBACK|SPORTBACK)/.test(k)) return 'Hatchback';
  if (/(WAGON|ESTATE|TOURING|AVANT)/.test(k)) return 'Wagon';
  if (/(SEDAN|SALOON)/.test(k)) return 'Sedan';
  if (/\bVAN\b/.test(k)) return 'Van';
  return b;
}

/** The cars grouped by make and model family (the filters' options: families only, the trim is a detail). */
export function familyGroups<T extends { make: string; model: string; trim?: string | null; model_family?: string | null }>(cars: T[]): Array<{ make: string; families: Array<{ model: string; count: number }> }> {
  const makes = new Map<string, Map<string, number>>();
  for (const c of cars) {
    if (!c.make || !c.model) continue;
    const id = carIdentity(c.make, c.model, c.trim ?? null);
    const fams = makes.get(id.make) ?? new Map<string, number>();
    // the database's family when the row carries it (3151), else the same rule here
    const fam = c.model_family || id.model;
    fams.set(fam, (fams.get(fam) ?? 0) + 1);
    makes.set(id.make, fams);
  }
  const by = (a: string, b: string) => a.localeCompare(b, 'en', { numeric: true });
  return [...makes.entries()].sort(([a], [b]) => by(a, b))
    .map(([make, fams]) => ({ make, families: [...fams.entries()].sort(([a], [b]) => by(a, b)).map(([model, count]) => ({ model, count })) }));
}
