// The English strings of the language versions of the search pages (release 36, part 2; migration 2004). This file is
// the source: the seo-i18n workflow stores each string as data (seo_string_sources) and its translations in
// seo_strings. {name} placeholders are filled from the page's data; a translation must keep every placeholder.
// Pure, relative imports only.
/** The language codes of seo_languages (2004): an address whose first segment is not one of them is never looked up. */
export const LANG_CODES = new Set(['fr', 'pa', 'zh', 'yue', 'ar', 'ur', 'tl', 'es', 'pt', 'it', 'ta', 'fa', 'ko', 'ru', 'hi', 'gu', 'vi', 'pl']);

export const CATALOG = {
  'common.cars_ready': 'Cars ready to book',
  'common.request': 'Send a request',
  'common.no_payment': 'No payment until we confirm the car and the price.',
  'common.questions': 'Questions',
  'common.read_english': 'Read this page in English',
  'common.machine_note': 'This page was translated automatically. The English page is the reference.',
  'common.from_day': 'From {price} a day',
  'common.request_exact': 'Request this exact car',
  'common.request_exact_text': 'Tell us your dates and we look for the car you want. Nothing is booked or charged.',
  'facts.cars': 'Cars',
  'facts.from': 'From',
  'facts.week': 'Weekly from',
  'facts.delivery': 'Delivery from',
  'facts.when': 'When',
  'facts.venue': 'Venue',
  'landing.h1': '{name} with {brand}',
  'landing.h1_location': 'Car rental in {place}',
  'landing.lead': '{brand} rents cars in Toronto: delivered to your address, a hotel or the airport, or picked up from us. Send a request with no payment, and pay only once we confirm the car and the full price.',
  'landing.prices': '{count} cars on the site now, from {price} a day and {week} a week, before HST.',
  'event.h1': 'Rent a car for {event}',
  'event.lead': '{event} is {when}, at {venue}. Rent a car from {brand} for the trip: delivered to your address, a hotel or the airport, or picked up in Toronto.',
  'event.usually': 'usually {months}',
  'airport.h1': '{airport} car rental, delivered to the terminal',
  'airport.lead': '{brand} meets you at the terminal with the car at the time we confirm: no rental counter and no shuttle.',
  'airport.fee': 'Airport delivery starts at {price}, the standard delivery price for the distance.',
  'req.title': 'What you need to rent',
  'req.age': 'Drivers must be {age} or older at pickup.',
  'req.deposit': 'The deposit is a hold on your card of {min} to {max}, depending on the car, released after the return.',
  'req.bring': 'At pickup, bring your original licence and the card you paid with.',
  'faq.pay_q': 'Do I pay when I send a request?',
  'faq.pay_a': 'No. You pay only after we confirm the car and the price and you approve the offer.',
  'faq.deliver_q': 'Can you deliver the car?',
  'faq.deliver_a': 'Yes: to your address, a hotel or the airport, at the time we confirm.',
  'hub.h1': 'Car rental in Toronto: pages in {language}',
  'hub.lead': 'Rent a car from {brand} in Toronto, delivered or picked up. These pages are in {language}.',
  'hub.pages': 'Ways to rent',
  'hub.events': 'Events',
  'hub.airports': 'Airports',
  // r37 (2302): the vehicle multipliers and the per-car service pages, only where a real car backs them
  'vehicle.h1': 'Rent the {car}',
  'vehicle.h1_place': 'Rent the {car} in {place}',
  'vehicle.h1_place_colour': 'Rent a {colour} {car} in {place}',
  'vehicle.h1_service': '{service} for the {car}',
  'vehicle.lead': '{brand} has the {car} on the site now: delivered to your address, a hotel or the airport, or picked up from us. Send a request with no payment.',
  'vehicle.lead_service': '{service} for the {car}, from {brand} in Toronto. Send a request and we confirm the price and the time before anything is charged.',
  'vehicle.colour_note': 'The car shown is {colour}, a real car in our fleet.'
} as const;
export type I18nKey = keyof typeof CATALOG;

/** The placeholders of a string. */
export const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]!).sort();
/** A translation is usable only when it keeps exactly the source's placeholders and is not empty. */
export function validTranslation(source: string, text: string): boolean {
  const t = text.trim();
  return t.length > 0 && t.length <= 2000 && placeholders(source).join() === placeholders(t).join() && !/[<>]/.test(t);
}
/** Placeholders to markers a translation model leaves alone ({price} to [[0]]) and back. */
export function protect(s: string): { text: string; names: string[] } {
  const names: string[] = [];
  return { text: s.replace(/\{(\w+)\}/g, (_, n: string) => `[[${names.push(n) - 1}]]`), names };
}
export const restore = (s: string, names: string[]) => s.replace(/\[\[\s*(\d+)\s*\]\]/g, (m, i: string) => (names[Number(i)] !== undefined ? `{${names[Number(i)]}}` : m));

/** A translator for a language bundle: the translation when there is one, else the English (counted as missing). */
export function translator(strings: Record<string, string>) {
  const missing = new Set<string>();
  const t = (key: I18nKey, vars: Record<string, string | number> = {}) => {
    const raw = strings[key] ?? (missing.add(key), CATALOG[key]);
    return raw.replace(/\{(\w+)\}/g, (m, n: string) => (vars[n] !== undefined ? String(vars[n]) : m));
  };
  return { t, missing };
}
