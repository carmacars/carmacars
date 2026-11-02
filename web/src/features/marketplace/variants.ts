// Copy variants of a Marketplace kit (migration 0510): each salesperson posts a car from their own Facebook profile in a
// variant of their own, so no two live listings share a title, a description or a cover photo. Variant 1 is the owner's
// kit unchanged (Admin > Marketing > Marketplace); the team takes variants 2 and up. A variant changes the opening line
// (the title), the order of the description's blocks and its closing lines, the photo order and the cover, and tags the link.
// The owner's wording rule holds in every variant: no "rent", "rental" or "for rent", and "Daily and weekly bookings only,
// not for sale" stays the second line. Pure (no I/O): the unit tests run it in Node. Relative imports only.
import { carName, type AdPhoto, type CarFacts } from '../ads/listing.ts';
import type { Kit } from './kit.ts';

export const MAX_VARIANT = 10;
export const NOT_FOR_SALE = 'Daily and weekly bookings only, not for sale.';

/** The opening line of variant n (2 to 10); price: whole dollars a day. */
export function variantTitle(c: Pick<CarFacts, 'year' | 'make' | 'model'>, price: number | null, n: number): string {
  const name = carName(c);
  const p = price ? `$${price}` : null;
  const t: Record<number, string> = {
    2: `${name} by the day or week${p ? `, from ${p}/day` : ''}`,
    3: `Drive this ${name} this week${p ? `: ${p} a day` : ''}`,
    4: `${name} available daily and weekly${p ? `, ${p}/day` : ''}`,
    5: `Your ${name} for the day${p ? `, from ${p}` : ''}`,
    6: `Daily ${name}, weekly prices too${p ? `: from ${p}/day` : ''}`,
    7: `Book a ${name} for a day or a week${p ? ` (${p}/day)` : ''}`,
    8: `${name}: a day, a weekend or a week${p ? `, from ${p}` : ''}`,
    9: `Need a car? This ${name}${p ? ` from ${p} a day` : ' by the day'}`,
    10: `${name} ready to book today${p ? `, ${p}/day` : ''}`
  };
  return t[n] ?? `${name} by the day (${n})`;
}

const LINK_LINE = ['See the calendar and book in 2 minutes: {link}', 'Pick your dates and see your total: {link}', 'Check the dates and book online: {link}',
  'The live calendar and your price: {link}', 'Choose your days and request it here: {link}'];
const CLOSER = ['Or message your phone number and we will call you.', 'Prefer a call? Message your number and we will ring you.',
  'Send your phone number and someone will call you shortly.', 'Questions? Message your number for a quick call.', 'Or send your number and we will call you back.'];

/** The base description's blocks: the opener and "not for sale", the car's facts, what is needed to book, the closing lines. */
function blocks(desc: string): { facts: string[]; reqs: string[]; close: string[] } {
  const lines = desc.split('\n').slice(2).filter((l) => l.trim() !== '');
  const r = lines.findIndex((l) => /^To book:/.test(l));
  const c = lines.findIndex((l) => /^(See the calendar|Book on carmacars\.ca)/.test(l));
  const end = c < 0 ? lines.length : c;
  return { facts: lines.slice(0, r < 0 ? end : r), reqs: r < 0 ? [] : lines.slice(r, end), close: lines.slice(end) };
}

/** Variant n's description from the base one (kit.description or kit.descriptionNoLink). */
export function variantDescription(base: string, title: string, n: number, link: string | null): string {
  if (n <= 1) return base;
  const { facts, reqs, close } = blocks(base);
  const code = close.find((l) => /^Car code /.test(l));
  const i = (n - 2) % LINK_LINE.length;
  const tail = [link ? LINK_LINE[i]!.replace('{link}', link) : 'Book on carmacars.ca: search the car code below.', CLOSER[(n + 1) % CLOSER.length]!, code].filter((x): x is string => !!x);
  // even variants lead with the facts, odd ones with what is needed to book; the facts turn by the variant too
  const f = facts.length > 1 ? [...facts.slice((n - 2) % facts.length), ...facts.slice(0, (n - 2) % facts.length)] : facts;
  const body = (n % 2 === 0 ? [f, reqs] : [reqs, f]).filter((b) => b.length);
  return [`${title}.`, NOT_FOR_SALE, ...body.flatMap((b) => ['', ...b]), '', ...tail].join('\n').replace(/\n{3,}/g, '\n\n').trim();
}

/** Variant n's photos: its own cover (the n-th best photo), then the rest in the kit's order. */
export function variantPhotos(photos: AdPhoto[], n: number): AdPhoto[] {
  if (n <= 1 || photos.length < 2) return photos;
  const k = (n - 1) % photos.length;
  return [photos[k]!, ...photos.filter((_, j) => j !== k)];
}

/** The variants a car can have live: one cover photo each, at most the setting (and 10). */
export const variantCount = (photos: number, maxLive: number): number => Math.max(0, Math.min(photos, maxLive, MAX_VARIANT));

export const variantLink = (link: string, n: number): string => {
  if (n <= 1) return link;
  const u = new URL(link);
  u.searchParams.set('utm_content', `v${n}`);
  return u.toString();
};

/** The kit of variant n (1: the kit itself). */
export function variantKit(k: Kit, c: Pick<CarFacts, 'year' | 'make' | 'model'>, n: number): Kit & { variant: number; cover: string } {
  if (n <= 1) return { ...k, variant: 1, cover: k.photos[0]?.path ?? '' };
  const title = variantTitle(c, k.price, n);
  const link = variantLink(k.link, n);
  const photos = variantPhotos(k.photos, n);
  return {
    ...k, variant: n, title, link, photos, cover: photos[0]?.path ?? '',
    description: variantDescription(k.description.replace(k.link, link), title, n, link),
    descriptionNoLink: variantDescription(k.descriptionNoLink, title, n, null)
  };
}
