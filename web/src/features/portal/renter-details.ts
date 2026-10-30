// "Complete your details" (migration 0195): the blanks of the rental agreement the renter fills in, as the database
// lists them (public.renter_agreement_missing: date of birth, home address, mobile, their licence number, issuer and
// expiry, the coverage's insurer, policy and expiry or the card's issuer and last four digits). Pure: the form, the
// checks before sending and the values sent (public.renter_agreement_fill).
export interface RenterMissing { key: string; label: string; field: string; required?: boolean }
export type DetailInput = 'date' | 'text' | 'tel' | 'address' | 'insurer' | 'issuer' | 'last4';
export interface DetailField { name: string; label: string; input: DetailInput; hint?: string }

const FIELDS: Record<string, DetailField> = {
  date_of_birth: { name: 'date_of_birth', label: 'Date of birth', input: 'date' },
  address: { name: 'address', label: 'Home address', input: 'address' },
  mobile: { name: 'mobile', label: 'Mobile number', input: 'tel', hint: 'With the country code outside Canada and the US.' },
  licence_number: { name: 'licence_number', label: 'Licence number', input: 'text', hint: 'As on the card, for example A1234-12345-12345.' },
  licence_issuer: { name: 'licence_issuer', label: 'Licence issued by', input: 'issuer' },
  licence_expiry: { name: 'licence_expiry', label: 'Licence expiry', input: 'date', hint: 'It must be valid until the return date.' },
  insurer_name: { name: 'insurer_name', label: 'Your insurer', input: 'insurer' },
  policy_number: { name: 'policy_number', label: 'Policy number', input: 'text' },
  policy_expiry: { name: 'policy_expiry', label: 'Policy expiry', input: 'date' },
  card_issuer: { name: 'card_issuer', label: 'Bank that issued the card with the coverage', input: 'text' },
  card_last4: { name: 'card_last4', label: 'Last four digits of that card', input: 'last4' }
};
const ORDER = Object.keys(FIELDS);
export const ADDRESS_KEYS = ['address_line1', 'address_line2', 'city', 'province', 'postal_code', 'country'] as const;

/** The form's fields, once each, in a fixed order; anything the renter does not fill is left out. */
export function detailFields(missing: RenterMissing[]): DetailField[] {
  const asked = new Set(missing.map((m) => m.field));
  return ORDER.filter((k) => asked.has(k)).map((k) => FIELDS[k]!);
}

/** What is wrong before sending, by field (the database checks again). */
export function checkDetails(fields: DetailField[], v: Record<string, string>, today = new Date().toISOString().slice(0, 10)): Record<string, string> {
  const e: Record<string, string> = {};
  const t = (k: string) => (v[k] ?? '').trim();
  for (const f of fields) {
    if (f.input === 'address') {
      for (const k of ['address_line1', 'city', 'province', 'postal_code']) if (!t(k)) e[k] = 'Required.';
      continue;
    }
    if (!t(f.name)) { e[f.name] = 'Required.'; continue; }
    if (f.name === 'date_of_birth' && t(f.name) >= today) e[f.name] = 'Give your date of birth.';
    if (f.input === 'last4' && !/^\d{4}$/.test(t(f.name))) e[f.name] = 'The last four digits.';
    if (f.input === 'tel' && t(f.name).replace(/[^\d]/g, '').length < 10) e[f.name] = 'Give the full number.';
  }
  return e;
}

/** The values sent: only the fields asked, trimmed (the licence number in capitals, no spaces). */
export function detailPayload(fields: DetailField[], v: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  const put = (k: string) => { const x = (v[k] ?? '').trim(); if (x) out[k] = k === 'licence_number' ? x.replace(/\s/g, '').toUpperCase() : x; };
  for (const f of fields) {
    if (f.input === 'address') ADDRESS_KEYS.forEach(put);
    else put(f.name);
  }
  return out;
}
