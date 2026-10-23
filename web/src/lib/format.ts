// Formatting only. Money is integer cents from the database; nothing here does pricing arithmetic.
export function money(cents: number | null | undefined, opts: { cents?: boolean } = {}): string {
  if (cents === null || cents === undefined) return '';
  const v = cents / 100;
  const show = opts.cents || cents % 100 !== 0;
  const s = Math.abs(v).toLocaleString('en-CA', { minimumFractionDigits: show ? 2 : 0, maximumFractionDigits: 2 });
  return (v < 0 ? '−$' : '$') + s;
}
export const pct = (bps: number) => `${+(bps / 100).toFixed(2)}%`;
/** A North American number as people write it ("+14165550142" reads "416-555-0142"); anything else as it is. */
export function phone(v: string | null | undefined): string {
  if (!v) return '';
  const d = v.replace(/\D/g, '');
  const n = d.length === 11 && d.startsWith('1') ? d.slice(1) : d;
  return n.length === 10 && /^\+?1?[\d\s().-]+$/.test(v.trim()) ? `${n.slice(0, 3)}-${n.slice(3, 6)}-${n.slice(6)}` : v;
}
/** A name at the end of a sentence: "Northshore Auto Holdings Ltd." keeps its one full stop. */
export const endSentence = (s: string) => (/[.!?]$/.test(s.trim()) ? s.trim() : `${s.trim()}.`);
/** How the company is named as a party: "18122211 Canada Inc., operating as CarmaCars" (the brand alone without a legal name). */
export const companyParty = (legal: string | null | undefined, brand: string | null | undefined = 'CarmaCars') =>
  legal && legal.trim() ? `${legal.trim().replace(/,$/, '')}, operating as ${brand || 'CarmaCars'}` : brand || 'CarmaCars';
export const ordinal = (n: number) => `${n}${n % 10 === 1 && n % 100 !== 11 ? 'st' : n % 10 === 2 && n % 100 !== 12 ? 'nd' : n % 10 === 3 && n % 100 !== 13 ? 'rd' : 'th'}`;
export function list(items: string[], join = 'or'): string {
  if (items.length < 2) return items.join('');
  return `${items.slice(0, -1).join(', ')} ${join} ${items[items.length - 1]}`;
}
export const plural = (n: number, one: string, many = one + 's') => `${n} ${n === 1 ? one : many}`;
export const hours = (min: number) => (min % 60 === 0 ? plural(min / 60, 'hour') : plural(min, 'minute'));
export const titleCase = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
export const FUEL_LABEL: Record<string, string> = { gasoline: 'Gasoline', diesel: 'Diesel', hybrid: 'Hybrid', plug_in_hybrid: 'Plug-in hybrid', electric: 'Electric' };
