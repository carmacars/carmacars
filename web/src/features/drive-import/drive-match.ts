// Import photos from a Google Drive link (release 33, 0760): which car on the platform a Drive folder is for. The owner
// gives photos as a top folder with one folder per make, then one per car, named by hand ("2022 Mercedes C300 white",
// "GLE 350 - CABC 123"). The folder's own name and the names of the folders above it are read for the year, the make, the
// model, the colour and the plate; each car on the platform is scored, 01 Motors' partner cars first on a tie. The table
// on the page shows the best car and the next ones to choose from. Pure; drive-match.test.ts.

export interface Car { id: string; year: number | null; make: string; model: string; trim?: string | null; colour?: string | null; plate?: string | null; partner?: string | null; label?: string }
export interface Candidate { vehicle_id: string; score: number; why: string[] }
export interface Match { vehicle_id: string | null; score: number; note: string; candidates: Candidate[]; /** two cars scored alike: a person should look */ ambiguous: boolean }

const COLOURS: Record<string, string[]> = {
  white: ['white', 'pearl', 'blanc', 'polar'], black: ['black', 'noir', 'obsidian'], grey: ['grey', 'gray', 'silver', 'gris', 'graphite', 'charcoal', 'gunmetal'],
  blue: ['blue', 'bleu', 'navy'], red: ['red', 'rouge', 'burgundy', 'maroon'], green: ['green', 'vert'], brown: ['brown', 'bronze', 'tan', 'beige'], yellow: ['yellow', 'gold'], orange: ['orange']
};
const colourGroup = (w: string): string | null => { for (const [g, ws] of Object.entries(COLOURS)) if (ws.includes(w)) return g; return null; };

const MAKE_ALIASES: Record<string, string[]> = {
  'mercedes benz': ['mercedes', 'benz', 'merc', 'mb'], 'volkswagen': ['vw'], 'chevrolet': ['chevy'], 'land rover': ['landrover', 'rover'], 'rolls royce': ['rolls'], 'alfa romeo': ['alfa']
};

/** Lower case, accents off, every run of other characters a single space. */
export function norm(s: string): string {
  return String(s ?? '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}
const squash = (s: string) => norm(s).replace(/ /g, '');
const tokens = (s: string) => norm(s).split(' ').filter(Boolean);

/** A plate as typed: capitals and digits only. */
export const plateKey = (s: string | null | undefined) => String(s ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');

/** The years named in a text (1980 to 2100, as whole numbers). */
export function yearsIn(text: string): number[] {
  return [...String(text).matchAll(/(?<![0-9])((?:19[89]|20[0-9])[0-9])(?![0-9])/g)].map((m) => Number(m[1])).filter((y) => y >= 1980 && y <= 2100);
}

/** Words of a text that look like a plate: 5 to 8 letters and digits with at least one of each, as one word or two
 *  ("CABC 123", "ABCD-123"). */
export function platesIn(text: string): string[] {
  const out = new Set<string>();
  const w = String(text).toUpperCase().split(/[^A-Z0-9]+/).filter(Boolean);
  const ok = (k: string) => k.length >= 5 && k.length <= 8 && /[A-Z]/.test(k) && /[0-9]/.test(k) && !/^(19|20)[0-9]{2}$/.test(k);
  for (let i = 0; i < w.length; i++) {
    if (ok(w[i]!)) out.add(w[i]!);
    if (i + 1 < w.length && w[i]!.length <= 5 && w[i + 1]!.length <= 4 && ok(w[i]! + w[i + 1]!)) out.add(w[i]! + w[i + 1]!);
  }
  return [...out];
}

/** Does the text name this model? "C 300" matches C300 and C-300, "C-Class" a C with its number, "GLE-Class" the GLE.
 *  Returns 0, 0.5 (part of it) or 1. */
export function modelHit(text: string, model: string, trim?: string | null): number {
  const t = ` ${norm(text)} `, tq = squash(text);
  const full = norm(model);
  if (!full) return 0;
  const tr = squash(trim ?? '');
  if (tr.length >= 3 && tq.includes(tr)) return 1;
  if (t.includes(` ${full} `) || (squash(model).length >= 3 && tq.includes(squash(model)))) return 1;
  const base = full.replace(/ (class|series)$/, '');
  if (base.length >= 3) {
    if (t.includes(` ${base} `) || tq.includes(base.replace(/ /g, ''))) return 1;
    const words = base.split(' ');
    if (words.length > 1) { const hits = words.filter((w) => t.includes(` ${w} `)).length; return hits === words.length ? 1 : hits > 0 ? 0.5 : 0; }
    return 0;
  }
  // a class letter or two (C, E, S, X5): it needs its number, C 300 or C300
  if (new RegExp(`(^| )${base}( )?[0-9]{2,3}( |$)`).test(t.trim())) return 1;
  return t.includes(` ${base} `) ? 0.5 : 0;
}

export function makeHit(text: string, make: string): boolean {
  const t = ` ${norm(text)} `;
  const m = norm(make);
  if (!m) return false;
  if (t.includes(` ${m} `)) return true;
  const first = m.split(' ')[0]!;
  if (first.length >= 4 && t.includes(` ${first} `)) return true;
  return (MAKE_ALIASES[m] ?? []).some((a) => t.includes(` ${a} `));
}

/** Scores one car against a folder: its own name counts in full, the names of the folders above it (a make folder) count
 *  for the make only. */
export function scoreCar(folderName: string, ancestors: string[], car: Car): Candidate {
  const why: string[] = [];
  let score = 0;
  const above = ancestors.join(' ');
  const plate = plateKey(car.plate);
  if (plate.length >= 4 && (platesIn(folderName).includes(plate) || squash(folderName).includes(plate.toLowerCase()))) { score += 100; why.push('plate'); }
  const mk = makeHit(folderName, car.make) ? 'own' : makeHit(above, car.make) ? 'above' : null;
  if (mk) { score += mk === 'own' ? 25 : 20; why.push('make'); }
  const md = modelHit(folderName, car.model, car.trim);
  if (md > 0) { score += md === 1 ? 40 : 15; why.push(md === 1 ? 'model' : 'part of the model'); }
  const years = yearsIn(folderName);
  if (car.year && years.includes(car.year)) { score += 20; why.push('year'); }
  else if (car.year && years.length) { score -= 15; why.push('another year'); }
  const cw = colourGroup(norm(car.colour ?? '').split(' ')[0] ?? '');
  const fw = new Set(tokens(folderName).map(colourGroup).filter(Boolean));
  if (cw && fw.has(cw)) { score += 12; why.push('colour'); }
  else if (cw && fw.size) { score -= 12; why.push('another colour'); }
  return { vehicle_id: car.id, score, why };
}

/** The car for a folder. `minScore` is what makes a proposal (a make alone is not enough); the 01 Motors partner's cars win a
 *  tie and the next car is shown to choose from. */
export function matchFolder(folderName: string, ancestors: string[], cars: Car[], o: { minScore?: number; taken?: ReadonlySet<string>; partnerFirst?: RegExp } = {}): Match {
  const minScore = o.minScore ?? 55;
  const first = o.partnerFirst ?? /01\s*motors/i;
  const scored = cars.map((c) => {
    const s = scoreCar(folderName, ancestors, c);
    const partner = c.partner && first.test(c.partner) ? 3 : 0;
    const spare = o.taken?.has(c.id) ? -4 : 0;
    return { ...s, rank: s.score + partner + spare };
  }).filter((s) => s.score > 0).sort((a, b) => b.rank - a.rank || a.vehicle_id.localeCompare(b.vehicle_id));
  const candidates = scored.slice(0, 5).map((s) => ({ vehicle_id: s.vehicle_id, score: s.score, why: s.why }));
  const best = scored[0];
  if (!best || best.score < minScore) return { vehicle_id: null, score: best?.score ?? 0, note: best ? `Closest: ${best.why.join(', ')} only` : 'No car looks like this folder', candidates, ambiguous: false };
  const next = scored[1];
  const ambiguous = !!next && next.score >= minScore && best.rank - next.rank < 8 && !best.why.includes('plate');
  return { vehicle_id: best.vehicle_id, score: best.score, note: `${ambiguous ? 'Two cars look alike: ' : ''}matched on ${best.why.join(', ')}`, candidates, ambiguous };
}

/** A folder holds a car's photos (not a make folder): it has photos of its own. */
export const isCarFolder = (photosHere: number) => photosHere > 0;
