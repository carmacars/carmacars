// The mailing address of Site settings as Stripe Terminal wants it (0202): street, optional unit, city, province, postal
// code. "123 Example St, Unit 4, Toronto, ON M5V 1A1" and "123 Example St, Toronto ON M5V1A1, Canada" both read.
// Null when it cannot be read: the Admin is told to write it in that shape.
export interface CaAddress { line1: string; line2: string | null; city: string; state: string; postal_code: string; country: 'CA' }
const PROVINCES = ['AB', 'BC', 'MB', 'NB', 'NL', 'NS', 'NT', 'NU', 'ON', 'PE', 'QC', 'SK', 'YT'];

export function parseCaAddress(text: string | null | undefined): CaAddress | null {
  if (!text) return null;
  const parts = text.replace(/\n/g, ', ').split(',').map((s) => s.trim()).filter(Boolean);
  if (parts.length && /^canada$/i.test(parts[parts.length - 1]!)) parts.pop();
  if (parts.length < 2) return null;
  const tail = parts.pop()!;
  const m = /^(?:(.*?)\s+)?([A-Za-z]{2})\.?\s+([A-Za-z]\d[A-Za-z])\s?(\d[A-Za-z]\d)$/.exec(tail);
  if (!m) return null;
  const state = m[2]!.toUpperCase();
  if (!PROVINCES.includes(state)) return null;
  const city = (m[1] ?? '').trim() || parts.pop() || '';
  if (!city || !parts.length) return null;
  const [line1, ...rest] = parts;
  return { line1: line1!, line2: rest.length ? rest.join(', ') : null, city, state, postal_code: `${m[3]!.toUpperCase()} ${m[4]!.toUpperCase()}`, country: 'CA' };
}
