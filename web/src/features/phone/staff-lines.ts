// R51 (5200, REQ-132): the pure parts of buying a staff line (server/staff-lines.ts). No imports: the unit tests run it as is.

/** The first voice number of Twilio's AvailablePhoneNumbers answer (E.164), or null. */
export function pickNumber(j: { available_phone_numbers?: Array<{ phone_number?: string }> } | null): string | null {
  return j?.available_phone_numbers?.map((n) => n.phone_number ?? '').find((n) => /^\+1[2-9]\d{9}$/.test(n)) ?? null;
}

/** The monthly price of a local number from Twilio's Pricing API (PhoneNumbers/Countries/CA): current_price, else base_price. */
export function linePrice(j: { phone_number_prices?: Array<{ number_type?: string; base_price?: string; current_price?: string }>; price_unit?: string } | null): { monthly: string; currency: string } | null {
  const p = j?.phone_number_prices?.find((x) => x.number_type === 'local');
  const v = p?.current_price ?? p?.base_price;
  if (!v || !/^\d+(\.\d+)?$/.test(v) || !j?.price_unit) return null;
  return { monthly: Number(v).toFixed(2), currency: j.price_unit.toUpperCase() };
}

/** All an Admin is ever shown of a staff line: its last 4 digits, "•••-•••-1234". */
export function maskedNumber(e164: string): string {
  const d = e164.replace(/\D/g, '');
  return d.length >= 4 ? `•••-•••-${d.slice(-4)}` : '•••';
}

/** A number is bought only by the live site: a public https address (Twilio must reach its webhook). Every test server
 *  (localhost, 127.0.0.1, a .test or .local host, plain http) is refused, so a test never buys a number. */
export function lineBuyBlocked(base: string): string | null {
  let u: URL;
  try { u = new URL(base); } catch { return 'The site address is not set (NEXT_PUBLIC_APP_URL).'; }
  if (u.protocol !== 'https:' || /^(localhost|127\.|0\.0\.0\.0|\[::1\])/.test(u.hostname) || /\.(test|local|localhost|example)$/.test(u.hostname))
    return 'Numbers are bought only from the live site.';
  return null;
}
