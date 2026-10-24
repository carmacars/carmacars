// An address in its parts (migration 0130's address autofill): what the forms fill when a suggestion is chosen.
// From Google's address components when there are some, else from the one-line address ("65 Front St W, Unit 4,
// Toronto, ON M5J 1E6, Canada"). Pure, so the forms, the server and the tests share it.
export interface AddressParts { street: string; unit: string; city: string; province: string; postal_code: string; country: string }
export const EMPTY_PARTS: AddressParts = { street: '', unit: '', city: '', province: '', postal_code: '', country: '' };

type Component = { longText?: string; shortText?: string; types?: string[] };

const PROVINCES: Record<string, string> = {
  ontario: 'ON', quebec: 'QC', 'british columbia': 'BC', alberta: 'AB', manitoba: 'MB', saskatchewan: 'SK', 'nova scotia': 'NS', 'new brunswick': 'NB',
  'newfoundland and labrador': 'NL', 'prince edward island': 'PE', yukon: 'YT', 'northwest territories': 'NT', nunavut: 'NU'
};
const POSTAL = /\b([ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z])\s?(\d[ABCEGHJ-NPRSTV-Z]\d)\b/i;
const ZIP = /\b\d{5}(?:-\d{4})?\b/;

export function fromComponents(cs: Component[] | undefined | null): AddressParts | null {
  if (!cs?.length) return null;
  const get = (t: string, short = false) => { const c = cs.find((x) => x.types?.includes(t)); return (short ? c?.shortText : c?.longText) ?? c?.longText ?? ''; };
  const number = get('street_number'); const route = get('route');
  const street = [number, route].filter(Boolean).join(' ') || get('premise') || get('point_of_interest');
  const p = { street, unit: get('subpremise'), city: get('locality') || get('postal_town') || get('sublocality') || get('administrative_area_level_3'),
    province: get('administrative_area_level_1', true), postal_code: get('postal_code').toUpperCase(), country: get('country') };
  if (/^canada$/i.test(p.country) && /^[A-Z]\d[A-Z]\d[A-Z]\d$/.test(p.postal_code)) p.postal_code = `${p.postal_code.slice(0, 3)} ${p.postal_code.slice(3)}`;
  return p.street || p.city ? p : null;
}

/** The one-line address split into its parts, as well as it can be. */
export function fromLabel(label: string): AddressParts {
  const raw = (label ?? '').split(',').map((x) => x.trim()).filter(Boolean);
  const out: AddressParts = { ...EMPTY_PARTS };
  if (!raw.length) return out;
  if (/^(canada|united states|usa|us)$/i.test(raw[raw.length - 1]!)) out.country = /^canada$/i.test(raw.pop()!) ? 'Canada' : 'United States';
  // "ON M5J 1E6", "Ontario", "NY 10001"
  const last = raw[raw.length - 1] ?? '';
  const pc = POSTAL.exec(last) ?? ZIP.exec(last);
  const provWord = last.replace(POSTAL, '').replace(ZIP, '').trim();
  if (pc || PROVINCES[provWord.toLowerCase()] || /^[A-Z]{2}$/.test(provWord)) {
    raw.pop();
    out.province = PROVINCES[provWord.toLowerCase()] ?? provWord.toUpperCase();
    if (pc) out.postal_code = pc[2] ? `${pc[1]!.toUpperCase()} ${pc[2].toUpperCase()}` : pc[0];
    if (!out.country && pc?.[2]) out.country = 'Canada';
  }
  if (raw.length) out.city = raw.pop()!;
  // a place name before the street ("Union Station, 65 Front Street West"): the part with the number is the street
  const unitAt = raw.findIndex((x) => /^(unit|suite|apt|apartment|#)\s*\S+/i.test(x));
  if (unitAt >= 0) out.unit = raw.splice(unitAt, 1)[0]!.replace(/^(unit|suite|apt|apartment)\s*/i, '').replace(/^#\s*/, '');
  const streetAt = raw.findIndex((x) => /^\d/.test(x));
  out.street = streetAt >= 0 ? raw[streetAt]! : raw[raw.length - 1] ?? '';
  if (!out.country && out.province && Object.values(PROVINCES).includes(out.province)) out.country = 'Canada';
  return out;
}

/** One line again, for the fields that keep a single address. */
export function toLine(p: Partial<AddressParts>): string {
  const region = [p.province, p.postal_code].filter(Boolean).join(' ');
  return [p.street, p.unit ? `Unit ${p.unit}` : '', p.city, region, p.country && !/^canada$/i.test(p.country) ? p.country : ''].filter(Boolean).join(', ');
}
