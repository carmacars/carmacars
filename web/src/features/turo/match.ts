// Which car a Turo email is about (migration 0088), with no setup per car. No imports, so the unit tests run it directly.
//
//   signalsOf   what the email says about the car: Turo car ids (in its links and image addresses), the car's name as
//               Turo writes it (the listing link's text, the image's alt text, "your <car>", a "Car" or "Vehicle"
//               line), VINs, colour words, the trip and the guest
//   scoreCars   every candidate car scored on those signals and on what we know (identities learned from earlier
//               emails, the optional "name on Turo" override, the trip already on a car, the guest's trips, the car
//               being busy then); a clear winner is applied, otherwise the short list goes to the model, then to a person
//   guestOf...  the guest's name, phone and email as the email shows them (never guessed; a masked number is not taken)
//
// Scores (added up per car):
//   Turo car id known for the car (learned or typed) 100 · VIN 100 · trip already on the car 100 · plate 90 ·
//   the typed "name on Turo" in the email 80 · a learned Turo name 35 (only when it tells the car apart) ·
//   make 10 · model 30 (an alias or family such as C-Class for C 300: 22) · year 10 · trim words 15 each (at most 2) ·
//   colour 12 · the guest already had a trip in this car around these dates 8
//   against: another Turo car id than the car's own -40 · another make -40 · another year -25 · another colour -15 ·
//   the make but not the model -10 · the car busy then (another trip or booking) -15
// A winner: 90 or more and 30 ahead of the next, or 40 or more and 15 ahead. Otherwise the cars within 30 of the best
// (and at least 20) are the short list.

export interface Identity { kind: 'turo_car_id' | 'name'; value: string; source?: 'auto' | 'staff' | 'override' }
export interface MatchCar {
  vehicle_id: string; name: string; listing_name?: string | null; turo_vehicle_id?: string | null; plate: string | null; vin: string | null;
  make: string | null; model: string | null; year: number | null; trim?: string | null; colour?: string | null;
  identities?: Identity[] | null;
  /** other trips and bookings of the car: [start, end, trip id or null] */
  busy?: Array<[string, string, string | null]> | null;
}
export interface MatchTrip { trip_id: string; vehicle_id: string; guest_first_name: string | null; starts_at: string | null; ends_at: string | null }
export interface Signals {
  turoCarIds: string[]; carNames: string[]; carName: string | null; vins: string[]; colours: string[]; years: number[];
  tripId: string | null; guest: string | null; start: string | null; end: string | null
}
export interface Scored { vehicle_id: string; name: string; score: number; why: string[] }
export interface MatchResult {
  vehicleId: string | null; hint: string | null; why: string | null; candidates: Scored[];
  how: 'turo_id' | 'vin' | 'plate' | 'trip' | 'override' | 'learned' | 'score' | null
}

const lower = (s: string) => s.toLowerCase();
export const norm = (s: string) => lower(s).replace(/&amp;/g, '&').replace(/[^a-z0-9]+/g, ' ').trim();
export const compact = (s: string) => lower(s).replace(/[^a-z0-9]+/g, '');

// ---------------------------------------------------------------- the email's signals
const URL_RE = /https?:\/\/[^\s"'<>)\]]+/gi;
/** Turo car (listing) ids in Turo's links and image addresses; never the trip's own number. */
export function turoCarIdsOf(all: string, tripId: string | null): string[] {
  const out = new Set<string>();
  for (const [u] of all.matchAll(URL_RE)) {
    if (!/turo/i.test(u)) continue;
    const pats = [/-rental\/(?:[^/?#\s]+\/)*?(\d{5,12})(?=[/?#]|$)/i, /\/vehicles?\/(?:images?\/|photos?\/)?(\d{5,12})(?=[/?#._-]|$)/i, /\/listings?\/(\d{5,12})(?=[/?#]|$)/i,
      /[?&](?:vehicle_?id|listing_?id|vehicleId|listingId)=(\d{5,12})\b/i];
    for (const re of pats) { const m = re.exec(u); if (m && m[1] !== tripId) out.add(m[1]!); }
  }
  // "Vehicle ID: 2711093" written out
  for (const m of all.matchAll(/\b(?:vehicle|listing|car)\s*(?:id|number|#)\s*[:#]?\s*(\d{5,12})\b/gi)) if (m[1] !== tripId) out.add(m[1]!);
  return [...out];
}

const tidyName = (s: string) => s.replace(URL_RE, ' ').replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/&#39;|&rsquo;/g, "'").replace(/\s+/g, ' ')
  .replace(/^(?:your|the|a|an)\s+/i, '').replace(/\s*(?:\(|\.\s|\.$|,|!|\s-\s|:).*$/, '').trim().slice(0, 80);
const YEAR = /\b(19[89]\d|20[0-4]\d)\b/;

/** The car's name as the email writes it, best first: the listing link's text, image alt text, "Car:" lines, "your <car>". */
export function carNamesOf(subject: string, text: string, html: string, makes: string[]): string[] {
  const out: string[] = [];
  const add = (s: string | undefined) => { const t = s ? tidyName(s) : ''; if (t.length >= 3 && /[a-z]/i.test(t) && !out.some((x) => lower(x) === lower(t))) out.push(t); };
  const makeRe = makes.length ? new RegExp(`\\b(?:${makes.map((m) => m.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})\\b`, 'i') : null;
  for (const m of html.matchAll(/<a\s[^>]*href\s*=\s*["']([^"']*turo[^"']*-rental\/[^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi)) add(m[2]);
  for (const m of html.matchAll(/<img\s[^>]*alt\s*=\s*["']([^"']{3,120})["'][^>]*>/gi)) {
    const alt = m[1]!;
    if (YEAR.test(alt) || makeRe?.test(alt)) add(alt);
  }
  const t = `${subject}\n${text.slice(0, 4000)}`.replace(/[ \t ]+/g, ' ');
  for (const m of t.matchAll(/(?:^|\n)\s*(?:car|vehicle)\b\s*[:\-]?\s*([^\n]{3,80})/gi)) if (YEAR.test(m[1]!) || makeRe?.test(m[1]!)) add(m[1]);
  for (const m of t.matchAll(/\b(?:with|in|for|booked|book|of|on) your ((?:(?:19|20)\d{2} )?[A-Z][A-Za-z-]+(?: [A-Za-z0-9][A-Za-z0-9-]*){0,5})/g)) add(m[1]);
  for (const m of t.matchAll(/\byour ((?:(?:19|20)\d{2} )?[A-Z][A-Za-z-]+(?: [A-Za-z0-9][A-Za-z0-9-]*){0,5})/g)) add(m[1]);
  // a phrase ends at the guest's next words ("... GLC 2021 from Oct 22")
  return out.map((s) => s.replace(/\s+(?:from|for|is|has|was|on|at|with|trip|starting|until|to)\b.*$/i, '').trim()).filter((s) => s.length >= 3);
}

export const COLOURS = ['black', 'white', 'silver', 'grey', 'blue', 'red', 'green', 'brown', 'beige', 'gold', 'orange', 'yellow', 'purple', 'burgundy', 'maroon', 'bronze', 'champagne', 'tan', 'navy', 'teal'];
const COLOUR_ALIAS: Record<string, string> = { gray: 'grey', graphite: 'grey', charcoal: 'grey', gunmetal: 'grey', obsidian: 'black', ebony: 'black', onyx: 'black', jet: 'black',
  pearl: 'white', ivory: 'white', snow: 'white', polar: 'white', platinum: 'silver', iridium: 'silver', navy: 'blue', burgundy: 'red', maroon: 'red', crimson: 'red', wine: 'red' };
/** The base colours named in a string ("Obsidian Black" → black; "Iridium Silver" → silver). */
export function coloursIn(s: string | null | undefined): string[] {
  const out = new Set<string>();
  for (const w of norm(s ?? '').split(' ')) { if (COLOURS.includes(w)) out.add(COLOUR_ALIAS[w] ?? w); }
  if (!out.size) for (const w of norm(s ?? '').split(' ')) if (COLOUR_ALIAS[w]) out.add(COLOUR_ALIAS[w]!);
  return [...out];
}

export function signalsOf(subject: string, text: string, html: string, o: { tripId: string | null; guest: string | null; start: string | null; end: string | null; makes: string[] }): Signals {
  const all = `${subject}\n${text}\n${html}`;
  const carNames = carNamesOf(subject, text, html, o.makes);
  const colourBits = [...carNames, ...[...all.matchAll(/\bcolou?r\s*[:\-]\s*([A-Za-z ]{3,30})/gi)].map((m) => m[1]!)];
  const years = [...new Set(carNames.flatMap((s) => [...s.matchAll(new RegExp(YEAR.source, 'g'))].map((m) => Number(m[1]))))];
  const vins = [...new Set([...`${subject}\n${text}`.toUpperCase().matchAll(/\b([A-HJ-NPR-Z0-9]{17})\b/g)].map((m) => m[1]!).filter((v) => /\d/.test(v) && /[A-Z]/.test(v)))];
  return { turoCarIds: turoCarIdsOf(all, o.tripId), carNames, carName: carNames[0] ?? null, vins, colours: [...new Set(colourBits.flatMap(coloursIn))], years,
    tripId: o.tripId, guest: o.guest, start: o.start, end: o.end };
}

// ---------------------------------------------------------------- makes and models, with their aliases
const MAKE_ALIAS: Record<string, string> = { mercedes: 'mercedesbenz', benz: 'mercedesbenz', mb: 'mercedesbenz', mercedesbenz: 'mercedesbenz', vw: 'volkswagen',
  chevy: 'chevrolet', landrover: 'landrover', range: 'landrover', rangerover: 'landrover', alfa: 'alfaromeo', alfaromeo: 'alfaromeo', merc: 'mercedesbenz' };
export const makeKey = (make: string) => MAKE_ALIAS[compact(make)] ?? compact(make);
const KNOWN_MAKES = ['acura', 'alfaromeo', 'audi', 'bmw', 'buick', 'cadillac', 'chevrolet', 'chrysler', 'dodge', 'fiat', 'ford', 'genesis', 'gmc', 'honda', 'hyundai',
  'infiniti', 'jaguar', 'jeep', 'kia', 'landrover', 'lexus', 'lincoln', 'maserati', 'mazda', 'mercedesbenz', 'mini', 'mitsubishi', 'nissan', 'polestar', 'porsche', 'ram',
  'rivian', 'subaru', 'tesla', 'toyota', 'volkswagen', 'volvo'];
for (const k of KNOWN_MAKES) MAKE_ALIAS[k] ??= k;
const FAMILY_MAKES = new Set(['mercedesbenz', 'lexus', 'acura']);
/** The model's family: C 300, C300, C-Class → c; GLC 300 → glc; 330i, 3 Series → 3series; RX 350 → rx (Lexus). */
export function modelFamily(model: string, make: string): string {
  let c = compact(model).replace(/(?:class|klasse)$/, '').replace(/^amg/, '');
  const mk = makeKey(make);
  if (mk === 'bmw') { const m = /^(\d)\d\d[a-z]*$/.exec(c); if (m) c = `${m[1]}series`; }
  if (FAMILY_MAKES.has(mk)) { const m = /^([a-z]{1,3})\d{2,3}[a-z]*$/.exec(c); if (m) c = m[1]!; }
  return c;
}
/** The make's words found in a string: "mercedes-benz glc" has mercedesbenz. */
function makesIn(s: string): Set<string> {
  const toks = norm(s).split(' ');
  const out = new Set<string>();
  for (let i = 0; i < toks.length; i++) {
    for (const n of [3, 2, 1]) {
      const k = toks.slice(i, i + n).join('');
      if (k && MAKE_ALIAS[k]) out.add(MAKE_ALIAS[k]!);
    }
  }
  return out;
}
/** 30 when the model is written as ours (C300, C 300, Model3, CR-V), 22 for its family (C-Class for C 300), else 0. */
export function modelHit(names: string[], model: string, make: string): number {
  const want = compact(model), fam = modelFamily(model, make);
  if (!want) return 0;
  let best = 0;
  for (const s of names) {
    const toks = norm(s).split(' ').filter(Boolean);
    for (let i = 0; i < toks.length; i++) {
      for (let n = 1; n <= 3 && i + n <= toks.length; n++) {
        const seq = toks.slice(i, i + n);
        const c = seq.join('');
        if (c === want) return 30;
        // one letter alone ("a", "c") counts only as "C-Class"
        if (c.length === 1 && seq.length === 1 && toks[i + 1] !== 'class') continue;
        if (fam && modelFamily(c, make) === fam && fam.length >= 1) best = Math.max(best, 22);
      }
    }
  }
  return best;
}

const TRIM_SKIP = new Set(['and', 'with', 'the', 'base', 'edition', 'final', 'sedan', 'coupe', 'suv', 'hatchback', 'wagon', 'awd', 'fwd', 'rwd', '4x4', 'door']);
const plateRe = (plate: string) => new RegExp(`(^|[^a-z0-9])${compact(plate).split('').join('[ -]?')}([^a-z0-9]|$)`, 'i');
const overlaps = (a0: number, a1: number, b0: number, b1: number) => a0 < b1 && b0 < a1;

/** Every candidate car scored, best first, with the reasons in words. */
export function scoreCars(sig: Signals, subject: string, text: string, cars: MatchCar[], trips: MatchTrip[] = []): Scored[] {
  const all = `${subject}\n${text}`;
  const n = ` ${norm(all)} `;
  const c = compact(all);
  const names = sig.carNames.length ? sig.carNames : [];
  const nameText = names.join(' \n ');
  for (const x of cars) if (x.make) MAKE_ALIAS[compact(x.make)] ??= makeKey(x.make);
  const emailMakes = makesIn(nameText);
  const nameNorms = new Set(names.map(norm));
  const tripCar = sig.tripId ? trips.find((t) => t.trip_id === sig.tripId)?.vehicle_id ?? null : null;
  const s0 = sig.start ? Date.parse(sig.start) : NaN, s1 = sig.end ? Date.parse(sig.end) : NaN;
  const out: Array<Scored & { desc: number; learnedName: boolean }> = [];
  for (const car of cars) {
    let score = 0, desc = 0;
    const why: string[] = [];
    const add = (pts: number, w: string, descriptive = false) => { score += pts; if (descriptive) desc += pts; why.push(`${pts > 0 ? '+' : ''}${pts} ${w}`); };
    const ids = new Set([...(car.identities ?? []).filter((i) => i.kind === 'turo_car_id').map((i) => i.value), ...(car.turo_vehicle_id ? [car.turo_vehicle_id] : [])]);
    const idHit = sig.turoCarIds.find((x) => ids.has(x));
    if (idHit) add(100, `Turo car ${idHit}`);
    else if (ids.size && sig.turoCarIds.length) add(-40, `another Turo car (${sig.turoCarIds.join(', ')}) than this car's (${[...ids].join(', ')})`);
    if (tripCar === car.vehicle_id) add(100, `Turo trip ${sig.tripId} is on this car`);
    if (car.vin && car.vin.length >= 11 && (c.includes(compact(car.vin)) || sig.vins.includes(car.vin.toUpperCase()))) add(100, 'VIN');
    if (car.plate && compact(car.plate).length >= 4 && plateRe(car.plate).test(all)) add(90, `plate ${car.plate}`);
    if (car.listing_name && norm(car.listing_name).length >= 4 && n.includes(` ${norm(car.listing_name)} `)) add(80, `name on Turo "${car.listing_name}"`);
    // what the email calls the car
    if (names.length && car.make) {
      const mk = makeKey(car.make);
      const makeOk = emailMakes.has(mk) || norm(nameText).split(' ').some((w) => compact(w) === mk);
      if (makeOk) add(10, car.make, true);
      else if (emailMakes.size) add(-40, `the email names another make`);
      if (car.model) {
        const mh = modelHit(names, car.model, car.make);
        if (mh) add(mh, mh === 30 ? car.model : `${car.model} (as ${names[0]})`, true);
        else if (makeOk) add(-10, `the model is not ${car.model}`, true);
      }
      if (car.year && sig.years.length) { if (sig.years.includes(car.year)) add(10, String(car.year), makeOk); else add(-25, `another year (${sig.years.join(', ')})`, makeOk); }
      const trimToks = norm(car.trim ?? '').split(' ').filter((w) => w.length >= 2 && !TRIM_SKIP.has(w) && !compact(car.model ?? '').includes(w));
      const nameToks = new Set(norm(nameText).split(' '));
      const trimHits = [...new Set(trimToks.filter((w) => nameToks.has(w)))].slice(0, 2);
      if (trimHits.length) add(15 * trimHits.length, `trim ${trimHits.join(' ')}`, true);
    } else if (!names.length && car.make && car.model) {
      // no name found: the make and the model's first real word anywhere in the email, as before
      const mk = norm(car.make), md = norm(car.model);
      const key = md.split(' ').find((w) => w.length > 1);
      if (n.includes(` ${mk.split(' ')[0]}`) && key && n.includes(` ${key}`)) { add(10, car.make, true); add(30, car.model, true); if (car.year && n.includes(` ${car.year} `)) add(10, String(car.year), true); }
    }
    const carColours = coloursIn(car.colour);
    if (sig.colours.length && carColours.length) {
      if (sig.colours.some((x) => carColours.includes(x))) add(12, `colour ${lower(car.colour ?? '')}`, true);
      else add(-15, `another colour (${sig.colours.join(', ')})`, true);
    }
    // a learned Turo name: only when it tells this car apart (identical cars share Turo's "Make Model Year")
    const learnedName = (car.identities ?? []).some((i) => i.kind === 'name' && nameNorms.has(norm(i.value)));
    // the guest's trips and the car's other trips at these dates
    if (sig.guest && Number.isFinite(s0)) {
      const g = lower(sig.guest);
      if (trips.some((t) => t.vehicle_id === car.vehicle_id && t.trip_id !== sig.tripId && lower(t.guest_first_name ?? '') === g && t.starts_at && t.ends_at
        && overlaps(s0 - 2 * 86400000, (Number.isFinite(s1) ? s1 : s0) + 2 * 86400000, Date.parse(t.starts_at), Date.parse(t.ends_at)))) add(8, `${sig.guest} had a trip in this car then`);
    }
    if (Number.isFinite(s0) && Number.isFinite(s1) && tripCar !== car.vehicle_id
      && (car.busy ?? []).some(([a, b, t]) => (!t || t !== sig.tripId) && overlaps(s0, s1, Date.parse(a), Date.parse(b)))) add(-15, 'busy then (another trip or booking)');
    out.push({ vehicle_id: car.vehicle_id, name: car.name, score, why, desc, learnedName });
  }
  for (const x of out) {
    if (!x.learnedName) continue;
    const rivals = out.filter((y) => y !== x && y.desc >= x.desc && y.desc >= 10 && !y.learnedName);
    if (!rivals.length) { x.score += 35; x.why.push('+35 the Turo name learned for this car'); }
  }
  return out.sort((a, b) => b.score - a.score).map(({ vehicle_id, name, score, why }) => ({ vehicle_id, name, score, why }));
}

const HOW: Array<[RegExp, MatchResult['how']]> = [[/^\+100 Turo car /, 'turo_id'], [/^\+100 Turo trip /, 'trip'], [/^\+100 VIN/, 'vin'], [/^\+90 plate/, 'plate'],
  [/^\+80 name on Turo/, 'override'], [/the Turo name learned/, 'learned']];
export function decide(scored: Scored[], hint: string | null): MatchResult {
  const top = scored[0];
  const second = scored[1]?.score ?? -Infinity;
  if (top && ((top.score >= 90 && top.score - second >= 30) || (top.score >= 40 && top.score - second >= 15))) {
    const how = HOW.find(([re]) => top.why.some((w) => re.test(w)))?.[1] ?? 'score';
    return { vehicleId: top.vehicle_id, hint: top.name, why: top.why.filter((w) => w.startsWith('+')).join(', '), candidates: scored.filter((s) => s.score > 0).slice(0, 5), how };
  }
  const short = top ? scored.filter((s) => s.score >= Math.max(20, top.score - 30)).slice(0, 5) : [];
  return { vehicleId: null, hint, why: short.length > 1 ? `matches ${short.length} cars (${short.map((s) => s.name).join(', ')})` : short.length ? `not sure: ${short[0]!.name} (${short[0]!.score})` : 'no car of ours matches',
    candidates: short, how: null };
}

export function matchCar(sig: Signals, subject: string, text: string, cars: MatchCar[], trips: MatchTrip[] = []): MatchResult {
  return decide(scoreCars(sig, subject, text, cars, trips), sig.carName);
}

// ---------------------------------------------------------------- the model's pick between the short list
export const AI_CAR_SYSTEM = 'You match one Turo trip email to one car of a car rental fleet. You get how the email names the car and a short list of '
  + 'candidate cars. Answer with the id of the candidate the email is about, or "unsure" when the email does not tell them apart. '
  + 'Never guess between identical cars: the same make, model and year with nothing else in the email to tell them apart is "unsure". Return JSON only.';
export const aiCarSchema = (ids: string[]) => ({ type: 'object', additionalProperties: false, required: ['vehicle_id'],
  properties: { vehicle_id: { type: 'string', enum: [...ids, 'unsure'] } } });
export function aiCarPrompt(sig: Pick<Signals, 'carNames' | 'colours' | 'turoCarIds'>, subject: string, cars: MatchCar[]): string {
  const lines = cars.map((c) => `- id ${c.vehicle_id}: ${[c.year, c.make, c.model, c.trim].filter(Boolean).join(' ')}${c.colour ? `, colour ${c.colour}` : ''}${c.plate ? `, plate ending ${compact(c.plate).slice(-3).toUpperCase()}` : ''}`);
  return `Email subject: ${subject.slice(0, 200)}\nHow the email names the car: ${sig.carNames.slice(0, 4).join(' | ') || 'not named'}\n`
    + `Colour words in the email: ${sig.colours.join(', ') || 'none'}\nTuro car numbers in the email: ${sig.turoCarIds.join(', ') || 'none'}\n\nCandidates:\n${lines.join('\n')}`;
}
/** The model's answer is used only when it is one of the short list. */
export function acceptAiCar(answer: unknown, short: Scored[]): string | null {
  const id = typeof answer === 'object' && answer ? (answer as { vehicle_id?: unknown }).vehicle_id : null;
  return typeof id === 'string' && short.some((s) => s.vehicle_id === id) ? id : null;
}

// ---------------------------------------------------------------- the guest's details, as the email shows them
export interface Guest { name: string | null; phone: string | null; email: string | null; phoneMasked: boolean }
const TOLL_FREE = new Set(['800', '833', '844', '855', '866', '877', '888']);
const PHONE_RE = /(?<!\d)(?:\+?1[\s.\-]?)?\(?([2-9]\d{2})\)?[\s.\-]?(\d{3})[\s.\-]?(\d{4})(?!\d)/g;
const MASKED_RE = /(?:\+?1[\s.\-]?)?\(?[\d*•xX#]{3}\)?[\s.\-]?[\d*•xX#]{3}[\s.\-]?[\d*•xX#]{2,4}/g;
const NOT_GUEST = new Set(["you're", 'you\u2019re', 'youre', 'turo', 'you', 'your', 'the', 'trip', 'guest', 'host', 'hi', 'hello', 'we', 'this', 'new', 'good', 'great', 'congrats', 'reservation', 'booking', 'message', 'call', 'text', 'contact']);
const cleanName = (s: string) => s.replace(/\s+/g, ' ').trim().replace(/[^A-Za-zÀ-ɏ .'-]/g, '').slice(0, 60).trim();

/** The guest's name (as shown: "Ayesha K."), phone and email, only when the email shows them next to the guest. */
export function guestOf(subject: string, text: string, first: string | null): Guest {
  const t = `${subject}\n${text.slice(0, 6000)}`.replace(/[ \t ]+/g, ' ');
  let name: string | null = null;
  const pats = [
    /(?:^|\n)\s*(?:[Gg]uest|[Rr]enter|[Pp]rimary [Dd]river|[Dd]river)\s*(?:[Nn]ame)?\s*[:\-]?\s*([A-Z][A-Za-zÀ-ɏ'-]+(?: [A-Z][A-Za-zÀ-ɏ'-]+| [A-Z]\.){0,2})/,
    /\b([A-Z][A-Za-zÀ-ɏ'-]+(?: [A-Z][A-Za-zÀ-ɏ'-]+| [A-Z]\.){0,2}) (?:has )?(?:booked|cancel(?:l)?ed|changed|modified|updated|extended|requested|wants to book)\b/
  ];
  for (const re of pats) {
    // the longest way the email writes the guest ("Liam T." over the subject's "Liam")
    const found = [...t.matchAll(new RegExp(re.source, 'g'))].map((m) => cleanName(m[1] ?? ''))
      .filter((v) => v && !NOT_GUEST.has(lower(v.split(' ')[0]!)) && (!first || lower(v).startsWith(lower(first))))
      .sort((a, b) => b.length - a.length);
    if (found[0]) { name = found[0]; break; }
  }
  name = name ?? first;
  // the lines about the guest: their name, or "guest", "renter", "driver"
  const g = lower((name ?? first ?? '').split(' ')[0] ?? '');
  const lines = t.split('\n').filter((l) => (g.length >= 2 && lower(l).includes(g)) || /\b(guest|renter|driver)\b/i.test(l));
  let phone: string | null = null, email: string | null = null, masked = false;
  for (const l of lines) {
    if (/\bturo\b.*\b(support|help|team|line|call us)\b|\b(support|help center)\b/i.test(l)) continue;
    for (const m of l.matchAll(MASKED_RE)) if (/[*•xX#]/.test(m[0]) && /\d/.test(m[0])) masked = true;
    if (!phone) for (const m of l.matchAll(PHONE_RE)) { if (!TOLL_FREE.has(m[1]!)) { phone = `+1${m[1]}${m[2]}${m[3]}`; break; } }
    if (!email) {
      const e = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i.exec(l)?.[0];
      if (e && !/turo|carmacars|noreply|no-reply|google\.com/i.test(e)) email = lower(e);
    }
  }
  return { name, phone, email, phoneMasked: masked && !phone };
}
