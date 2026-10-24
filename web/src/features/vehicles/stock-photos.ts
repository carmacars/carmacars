// Stock photos for the vehicle pages (migration 0137; docs/changes/2026-10-24-seo-photos.md). Properly licensed photos
// of each make, model and generation from Wikimedia Commons (public domain, CC0, CC BY or CC BY-SA only), credited on
// the page. Never a photo of one of our cars: the fleet's own photos stay where they are.
//
// Pure functions shared by the pipeline (web/scripts/seo-photos/run.mjs) and the pages: the licence filter, the
// author in plain text, the score of a candidate photo, the model years of each generation, and the credit, alt text,
// addresses and ImageObject of a stored photo. No imports: the pipeline runs this file with Node's type stripping.

// ---------------------------------------------------------------- licences
/** What Commons says about a file (the imageinfo extmetadata values, as strings). */
export type CommonsMeta = {
  LicenseShortName?: string; License?: string; LicenseUrl?: string; UsageTerms?: string; Artist?: string; Credit?: string;
  AttributionRequired?: string; Copyrighted?: string; NonFree?: string; Restrictions?: string; ImageDescription?: string;
  ObjectName?: string; Categories?: string; DateTimeOriginal?: string;
};
export type LicenceVerdict = { ok: true; licence: string; licenceUrl: string | null; attribution: boolean } | { ok: false; reason: string };

const CC = /^cc[- ]by(-sa)?(?:[- ](\d\.\d))?(?:[- ]([a-z]{2,4}))?$/i;
/** Whether a file's licence lets the site use it, commercially and at scale, with a credit: public domain, CC0,
 *  CC BY or CC BY-SA (any version and port). Everything else is refused: non-commercial, no-derivatives, GFDL alone,
 *  fair use, "free" without a named licence, or a file Commons marks non-free. */
export function licenceOk(m: CommonsMeta): LicenceVerdict {
  const raw = (m.LicenseShortName ?? '').replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
  const code = (m.License ?? '').trim().toLowerCase();
  if (!raw && !code) return { ok: false, reason: 'no licence' };
  if (/^(true|1|yes)$/i.test(m.NonFree ?? '')) return { ok: false, reason: 'non-free' };
  const words = `${raw} ${code}`.toLowerCase();
  if (/\bnc\b|non[- ]?commercial|\bnd\b|no[- ]?deriv|fair use|all rights reserved/.test(words)) return { ok: false, reason: `not allowed: ${raw || code}` };
  // people who can be recognised, or insignia: not for a commercial page
  if (/personality|insignia/i.test(m.Restrictions ?? '')) return { ok: false, reason: `restricted: ${m.Restrictions}` };
  const url = /^https?:\/\//.test(m.LicenseUrl ?? '') ? m.LicenseUrl!.replace(/^http:/, 'https:') : null;
  if (/^(cc0|cc-zero|cc0 1\.0)$/i.test(raw) || code === 'cc0' || code === 'cc-zero') return { ok: true, licence: 'CC0', licenceUrl: url ?? 'https://creativecommons.org/publicdomain/zero/1.0/', attribution: false };
  if (/^(public domain|pd\b|pd-)/i.test(raw) || /^pd($|-)/.test(code)) return { ok: true, licence: 'Public domain', licenceUrl: url, attribution: false };
  const c = CC.exec(raw) ?? CC.exec(code.replace(/-(\d\.\d)/, ' $1'));
  if (c) {
    const name = `CC BY${c[1] ? '-SA' : ''}${c[2] ? ` ${c[2]}` : ''}`;
    const v = c[2] ?? '4.0';
    return { ok: true, licence: name, licenceUrl: url ?? `https://creativecommons.org/licenses/by${c[1] ? '-sa' : ''}/${v}/`, attribution: true };
  }
  return { ok: false, reason: `not on the allowed list: ${raw || code}` };
}

/** The author as plain text: Commons gives HTML (a link to the user page, sometimes a table). */
export function plainAuthor(html: string | undefined | null): string {
  const s = String(html ?? '').replace(/<br\s*\/?>/gi, ', ').replace(/<[^>]*>/g, ' ').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/\s+/g, ' ').replace(/\s+,/g, ',').trim();
  return s.length > 120 ? `${s.slice(0, 117).trim()}...` : s;
}
/** The author's link when the Artist field is one link (a user page or a site). */
export function authorUrl(html: string | undefined | null): string | null {
  const links = [...String(html ?? '').matchAll(/href="([^"]+)"/g)].map((x) => x[1]!);
  if (links.length !== 1) return null;
  const u = links[0]!.startsWith('//') ? `https:${links[0]}` : links[0]!.startsWith('/') ? `https://commons.wikimedia.org${links[0]}` : links[0]!;
  return /^https:\/\/[^\s"<>]+$/.test(u) ? u : null;
}

// ---------------------------------------------------------------- choosing a photo
export type Candidate = {
  title: string; width: number; height: number; mime: string; meta: CommonsMeta;
  /** the generation's own image on Wikidata (P18): an editor already chose it as the picture of the car */
  wikidata?: boolean; quality?: boolean;
};
export type ScoreContext = { make: string; model: string; yearFrom?: number | null; yearTo?: number | null; rejected?: string[] };

// the view in a file's name or description, in the languages Commons photographers write in
const FRONT = /\b(front|frontal|3\/4|three[- ]quarter|vorder|frontansicht|vorne|avant|fronte|frente|delantera|voorkant|przod|fl|fr)\b|front[- ]?(left|right)|\bfront\d|_front/i;
const BAD = /\b(rear|back|heck|hinten|heckansicht|arri[eè]re|retro|trasera|interior|innenraum|innen|cockpit|dashboard|engine|engine bay|motorraum|badge|emblem|logo|wheel|wheels|felge|trunk|boot|kofferraum|detail|tail ?light|taillight|headlight|lamp|steering|gauge|odometer|speedometer|key|crash|crashed|wreck|wrecked|damaged|accident|unfall|burn|burnt|rust|rusty|junk|scrap|abandoned|police|polizei|polic[ei]a|sheriff|taxi|ambulance|fire ?truck|race|racing|rally|nascar|dtm|drift|toy|scale model|model car|modellauto|diecast|die-cast|lego|matchbox|hot wheels|drawing|sketch|blueprint|render|rendering|cgi|advert|brochure|poster|concept|prototype|camouflage|camo|mule|stretch|limousine|limo|tuning|tuned|modified|lowrider|hearse|wrap|wrapped|livery|graffiti|parade|underside|chassis|x-ray|cutaway|cut-away|airbag|recall)\b/i;
const SIDE = /\b(side|profile|seitenansicht|lateral|seite)\b/i;

/** The year of a file: its name ("2019 Toyota Camry...") or the date it was taken. */
export function fileYear(c: Candidate): number | null {
  const m = /\b(19[5-9]\d|20[0-4]\d)\b/.exec(c.title.replace(/\(\d{4}-\d\d-\d\d\)/g, ''));
  if (m) return Number(m[1]);
  return null;
}

/** A candidate's score, or null when it must not be used (licence, size, shape, subject, already rejected). Higher is
 *  better: the Wikidata image of the generation, a Commons quality image, a front three-quarter view, a large
 *  landscape photo, the right years. */
export function scoreCandidate(c: Candidate, x: ScoreContext): number | null {
  if (x.rejected?.includes(c.title)) return null;
  const lic = licenceOk(c.meta);
  if (!lic.ok) return null;
  if (!/^image\/(jpeg|png|webp)$/.test(c.mime)) return null;
  if (!(c.width >= 960 && c.height >= 480)) return null;
  const ratio = c.width / c.height;
  if (ratio < 1.15 || ratio > 2.4) return null;
  if (lic.attribution && !plainAuthor(c.meta.Artist)) return null;
  const words = `${c.title.replace(/^File:/, '').replace(/\.[a-z]+$/i, '').replace(/[_]+/g, ' ')} ${plainAuthor(c.meta.ImageDescription).slice(0, 300)} ${plainAuthor(c.meta.ObjectName)}`;
  if (BAD.test(words)) return null;
  // the model's name should be there (a file in a model's category may show another car beside it)
  const norm = (s: string) => s.toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '');
  const hasModel = norm(words).includes(norm(x.model));
  let s = 0;
  if (c.wikidata) s += 40;
  if (c.quality) s += 30;
  if (/featured pictures|valued images/i.test(c.meta.Categories ?? '')) s += 15;
  if (FRONT.test(words)) s += 25;
  else if (SIDE.test(words)) s -= 5;
  if (/ 0?1\.(jpe?g|png|webp)$/i.test(c.title)) s += 4;
  if (/ 0?2\.(jpe?g|png|webp)$/i.test(c.title)) s -= 6;
  if (hasModel) s += 10; else if (!c.wikidata) s -= 15;
  if (c.width >= 1600) s += 10;
  if (c.width >= 2400) s += 4;
  if (ratio >= 1.3 && ratio <= 1.8) s += 8;
  const y = fileYear(c);
  if (y !== null && x.yearFrom && x.yearTo) {
    // the photo's year is a model year near the generation's (a car photographed a few years later is still right)
    if (y >= x.yearFrom - 1 && y <= x.yearTo + 1) s += 10;
    else if (y < x.yearFrom - 1) s -= 40;
  }
  return s;
}

/** The best candidate (highest score, then the larger photo), or null when none may be used. */
export function pickBest<T extends Candidate>(cands: T[], x: ScoreContext): { c: T; score: number } | null {
  let best: { c: T; score: number } | null = null;
  const seen = new Set<string>();
  for (const c of cands) {
    if (seen.has(c.title)) continue;
    seen.add(c.title);
    const s = scoreCandidate(c, x);
    if (s === null) continue;
    if (!best || s > best.score || (s === best.score && c.width * c.height > best.c.width * best.c.height)) best = { c, score: s };
  }
  return best;
}

/** A generic photo for the place and service pages (a road, a car being detailed, a body shop): the same licence,
 *  size and shape rules, no people's faces as the subject, nothing that misleads (a crash, a police car, a toy). */
const BAD_GENERIC = /\b(police|polizei|crash|crashed|wreck|accident|collision scene|fire|burning|protest|riot|funeral|toy|model|lego|drawing|sketch|logo|map|diagram|poster|advert|portrait|selfie|wedding|nascar|race|racing)\b/i;
export function scoreGeneric(c: Candidate, slot: { avoid?: string[] } = {}): number | null {
  const lic = licenceOk(c.meta);
  if (!lic.ok) return null;
  if (!/^image\/(jpeg|png|webp)$/.test(c.mime) || c.width < 1280 || c.height < 640) return null;
  const ratio = c.width / c.height;
  if (ratio < 1.3 || ratio > 2.2) return null;
  if (lic.attribution && !plainAuthor(c.meta.Artist)) return null;
  const words = `${c.title} ${plainAuthor(c.meta.ImageDescription).slice(0, 300)}`;
  if (BAD_GENERIC.test(words) || (slot.avoid ?? []).some((w) => words.toLowerCase().includes(w.toLowerCase()))) return null;
  let s = 0;
  if (c.quality) s += 30;
  if (/featured pictures|valued images/i.test(c.meta.Categories ?? '')) s += 15;
  if (c.width >= 2400) s += 10;
  if (ratio >= 1.4 && ratio <= 1.8) s += 8;
  return s;
}

// ---------------------------------------------------------------- generations and model years
/** A generation as Wikidata describes it: production start and end (year, and month when known). */
export type Generation = { id: string; label: string; start: number | null; startMonth?: number | null; end: number | null; image?: string | null; category?: string | null };
export type GenRange = Generation & { from: number; to: number };

/** The first model year of a generation. North American model years start in the autumn: production that begins in
 *  the second half of a year (or in a year whose month is not known) is the next model year; in the first half, the
 *  same year. */
export function firstModelYear(g: Generation): number | null {
  if (g.start === null) return null;
  return g.startMonth && g.startMonth >= 1 && g.startMonth <= 6 ? g.start : g.start + 1;
}

/** Each generation's model years within the catalog's [first, last]: from its first model year to the year before the
 *  next generation's (or its production end, plus one, for the last). Generations without a start are left out;
 *  generations starting the same model year are one (the one with an image). */
export function generationRanges(gens: Generation[], first: number, last: number): GenRange[] {
  const dated = gens.map((g) => ({ g, from: firstModelYear(g) })).filter((x): x is { g: Generation; from: number } => x.from !== null).sort((a, b) => a.from - b.from || Number(!!b.g.image) - Number(!!a.g.image));
  const one: Array<{ g: Generation; from: number }> = [];
  for (const x of dated) if (!one.length || one[one.length - 1]!.from !== x.from) one.push(x);
  const out: GenRange[] = [];
  one.forEach((x, i) => {
    const next = one[i + 1];
    let to = next ? next.from - 1 : x.g.end !== null ? Math.max(x.g.end + 1, x.from) : last;
    if (next && x.g.end !== null) to = Math.min(to, Math.max(x.g.end + 1, x.from));
    const from = Math.max(x.from, first), to2 = Math.min(to, last);
    if (from <= to2) out.push({ ...x.g, from, to: to2 });
  });
  // the catalog's first model year may come a year before the first generation's (a car sold as next year's model
  // from the spring): the first generation takes it
  if (out.length && one.length && out[0]!.from === first + 1 && one[0]!.from === first + 1) out[0] = { ...out[0]!, from: first };
  return out;
}

/** The generation of one model year, or null (no generation covers it). */
export function generationFor(ranges: GenRange[], year: number): GenRange | null {
  return ranges.find((r) => year >= r.from && year <= r.to) ?? null;
}

// ---------------------------------------------------------------- a stored photo on a page
export type StockPhoto = {
  id: string; make: string; model: string; make_name: string | null; model_name: string | null; year_from: number | null; year_to: number | null;
  generation: string | null; path: string; sizes: number[]; width: number; height: number; author: string; author_url?: string | null;
  licence: string; licence_url: string | null; source_url: string;
};
export type GenericPhoto = Omit<StockPhoto, 'make' | 'model' | 'make_name' | 'model_name' | 'year_from' | 'year_to' | 'generation'> & { slot: string; alt: string | null };

/** The stored file of one width ("seo-photos/toyota/camry/2018-2024-1280.webp"). */
export const sizePath = (p: { path: string }, w: number) => `${p.path}-${w}.webp`;
/** srcset for the widths stored, through the site's public files address. */
export function srcSet(p: { path: string; sizes: number[] }, url: (path: string) => string): string {
  return [...p.sizes].sort((a, b) => a - b).map((w) => `${url(sizePath(p, w))} ${w}w`).join(', ');
}
/** The largest width stored (the sharing image and the fallback src). */
export const largest = (p: { sizes: number[] }) => Math.max(...p.sizes);
/** The height of the photo at a width, from its stored shape. */
export const heightAt = (p: { width: number; height: number }, w: number) => Math.round((w * p.height) / p.width);

/** The years of the generation in words ("2018 to 2024"), or "" for a photo of the model in general. */
export const genYears = (p: Pick<StockPhoto, 'year_from' | 'year_to'>) => (p.year_from && p.year_to ? (p.year_from === p.year_to ? String(p.year_from) : `${p.year_from} to ${p.year_to}`) : '');
/** The alt text: what the photo shows (the model and its generation's years), never a claim that it is our car. */
export function photoAlt(p: StockPhoto): string {
  const name = [p.make_name, p.model_name].filter(Boolean).join(' ') || 'Car';
  const ys = genYears(p);
  return ys ? `${name} of the ${ys} generation` : name;
}
/** The credit line: "Photo: <author>, <licence>, Wikimedia Commons" with its links. */
export function credit(p: { author: string; licence: string; licence_url: string | null; source_url: string }) {
  return { text: `Photo: ${p.author}, ${p.licence}, Wikimedia Commons`, author: p.author, licence: p.licence, licenceUrl: p.licence_url, source: p.source_url };
}
/** The ImageObject for the page's structured data (license, creditText, acquireLicensePage, creator). */
export function imageObjectLd(p: StockPhoto | GenericPhoto, url: (path: string) => string, caption?: string) {
  const w = largest(p);
  return {
    '@type': 'ImageObject', contentUrl: url(sizePath(p, w)), url: url(sizePath(p, w)), width: w, height: heightAt(p, w),
    ...(caption ? { caption } : {}),
    creditText: credit(p).text, creator: { '@type': 'Person', name: p.author }, copyrightNotice: p.author,
    ...(p.licence_url ? { license: p.licence_url } : {}), acquireLicensePage: p.source_url
  };
}

/** One of several photos, the same one for the same page (the page's address hashed). */
export function pickFor<T>(items: T[], key: string): T | null {
  if (!items.length) return null;
  let h = 0;
  for (let i = 0; i < key.length; i++) h = (h * 31 + key.charCodeAt(i)) >>> 0;
  return items[h % items.length]!;
}
