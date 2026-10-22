// Text templates (migration 0085): the same rules as the database (app.phone_text_ok, app.phone_render), for the Admin
// preview and the unit tests. No imports.

export const PLACEHOLDERS = ['first_name', 'booking', 'car', 'pickup', 'return', 'amount', 'link'] as const;
export type Vars = Partial<Record<(typeof PLACEHOLDERS)[number], string | null>>;

/** Why a template is refused (null: fine). 1 to 480 characters, no long dashes, names CarmaCars. */
export function templateProblem(t: string | null | undefined): string | null {
  const s = (t ?? '').trim();
  if (!s) return 'Write the text';
  if (s.length > 480) return 'Keep it under 480 characters (about three text messages)';
  if (/[\u2013\u2014]/.test(s)) return 'No long dashes: use a comma, a colon or a full stop';
  if (!s.includes('CarmaCars')) return 'Name CarmaCars in the text, so people know who it is from';
  const unknown = [...s.matchAll(/\{([a-z_]+)\}/g)].map((m) => m[1]!).filter((k) => !(PLACEHOLDERS as readonly string[]).includes(k));
  if (unknown.length) return `Unknown placeholder: {${unknown[0]}}`;
  return null;
}

/** Fills the placeholders; one without a value is dropped with the space before it. */
export function renderTemplate(t: string, v: Vars): string {
  let s = t ?? '';
  for (const k of PLACEHOLDERS) {
    const val = (v[k] ?? '').trim();
    s = val ? s.split(`{${k}}`).join(val) : s.replace(new RegExp(`\\s?\\{${k}\\}`, 'g'), '');
  }
  return s.replace(/\s+/g, ' ').replace(/\s+([,.!?:)])/g, '$1').replace(/\u2014/g, ',').replace(/\u2013/g, '-').trim().slice(0, 1600);
}

/** How many SMS segments a text takes (GSM-7: 160, or 153 each when split; anything else: 70 / 67). */
export function segments(s: string): number {
  if (!s) return 0;
  const gsm = /^[\n\r -_a-zA-Z0-9@£$¥èéùìòÇØøÅåΔΦΓΛΩΠΨΣΘΞÆæßÉ!"#¤%&'()*+,\-./:;<=>?¡ÄÖÑÜ§¿äöñüà^{}\\[~\]|€]*$/.test(s);
  const one = gsm ? 160 : 70, many = gsm ? 153 : 67;
  return s.length <= one ? 1 : Math.ceil(s.length / many);
}

export const SAMPLE_VARS: Vars = { first_name: 'Maya', booking: 'CC-10482', car: '2024 Honda Civic Sport', pickup: 'Fri Oct 23 at 10:00 am', return: 'Mon Oct 26 at 10:00 am', amount: '$468.95', link: 'https://carmacars.ca/account/bookings/CC-10482' };

/** The booking texts and the email each one follows (the database's app.phone_sms_kind). */
export const SMS_MOMENTS: Array<{ kind: string; email: string; label: string }> = [
  { kind: 'offer_sent', email: 'renter_offer_ready', label: 'Offer sent' },
  { kind: 'payment_confirmed', email: 'renter_booking_confirmed', label: 'Payment received, booking confirmed' },
  { kind: 'payment_received', email: 'renter_payment_receipt', label: 'Payment received (other payments)' },
  { kind: 'pickup_tomorrow', email: 'renter_booking_reminder', label: 'Pickup tomorrow' },
  { kind: 'return_reminder', email: 'renter_return_reminder', label: 'Return reminder' },
  { kind: 'payment_link', email: 'renter_recovery_pay', label: 'Payment link (left the pay page)' }
];
