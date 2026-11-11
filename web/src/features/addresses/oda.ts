// Statistics Canada's Open Database of Addresses (ODA, Open Government Licence - Canada) to the rows of ca_addresses
// (migration 2120). Pure, so the addresses workflow's loader (web/scripts/addresses/load.mjs) and the unit test share it.
// The ODA's CSV is read by its header names (version 1: latitude, longitude, street_no, street, str_name, str_type, str_dir,
// unit, city, postal_code, csdname, pruid ...); only the columns the address fields need are kept.

/** The provinces and territories by their census code (pruid), Ontario first (the order of the import). */
export const PROVINCE_BY_PRUID: Record<string, string> = {
  '35': 'ON', '24': 'QC', '59': 'BC', '48': 'AB', '46': 'MB', '47': 'SK', '12': 'NS', '13': 'NB', '10': 'NL', '11': 'PE', '60': 'YT', '61': 'NT', '62': 'NU'
};
/** The ODA's files (version 1): ten provinces and territories; Newfoundland and Labrador, Yukon and Nunavut have none. */
export const ODA_PROVINCES = ['ON', 'QC', 'BC', 'AB', 'MB', 'SK', 'NS', 'NB', 'PE', 'NT'] as const;
export const odaUrl = (p: string) => `https://www150.statcan.gc.ca/n1/en/pub/46-26-0001/2021001/ODA_${p}_v1.zip`;

/** One CSV line split into fields (double quotes, doubled quotes inside). */
export function csvLine(line: string): string[] {
  const out: string[] = [];
  let cur = '', q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i]!;
    if (q) {
      if (c === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; }
      else cur += c;
    } else if (c === '"') q = true;
    else if (c === ',') { out.push(cur); cur = ''; }
    else cur += c;
  }
  out.push(cur);
  return out;
}

const SMALL = new Set(['de', 'du', 'des', 'la', 'le', 'les', 'of', 'the', 'and', 'et', 'd', 'l']);
/** "KING STREET WEST" -> "King Street West"; "MCDONALD" -> "Mcdonald" is fine for a suggestion; "rue de la gare" keeps its small words. */
export function titleCase(s: string): string {
  return s.toLowerCase().replace(/\s+/g, ' ').trim().split(' ').map((w, i) => (i > 0 && SMALL.has(w) ? w
    : w.replace(/(^|[-'])(\p{L})/gu, (_m, a: string, b: string) => a + b.toUpperCase()))).join(' ');
}

export interface AddressRow { province: string; num: string | null; street: string; unit: string | null; city: string | null; postal: string | null; lat: number | null; lng: number | null }

const POSTAL = /^([A-Z]\d[A-Z])\s*(\d[A-Z]\d)$/;
const clip = (s: string | undefined, n: number) => { const t = (s ?? '').replace(/\s+/g, ' ').trim(); return t ? t.slice(0, n) : null; };
const num = (s: string | undefined) => { const v = Number(s); return s && s.trim() && Number.isFinite(v) ? Math.round(v * 1e6) / 1e6 : null; };

/** The header's positions of the fields used (by name, whatever their order). */
export function headerIndex(header: string[]): Record<string, number> {
  const idx: Record<string, number> = {};
  header.forEach((h, i) => { idx[h.trim().toLowerCase().replace(/^\uFEFF/, '')] = i; });
  return idx;
}

/** One ODA row to a row of ca_addresses, or null when it has no street (a point with no civic address is no use to a form). */
export function odaRow(f: string[], idx: Record<string, number>, fallbackProvince: string): AddressRow | null {
  const g = (k: string) => (idx[k] === undefined ? undefined : f[idx[k]!]);
  const street = clip(g('street') || [g('str_name'), g('str_type'), g('str_dir')].filter((x) => x && x.trim()).join(' '), 120);
  if (!street) return null;
  const postalRaw = (g('postal_code') ?? '').toUpperCase().replace(/\s+/g, '');
  const pm = POSTAL.exec(postalRaw);
  const province = PROVINCE_BY_PRUID[(g('pruid') ?? '').trim()] ?? fallbackProvince;
  const lat = num(g('latitude')), lng = num(g('longitude'));
  return {
    province,
    num: clip(g('street_no'), 20),
    street: titleCase(street),
    unit: clip(g('unit'), 20),
    city: (() => { const c = clip(g('city') || g('csdname'), 80); return c ? titleCase(c) : null; })(),
    postal: pm ? `${pm[1]} ${pm[2]}` : null,
    lat: lat !== null && lat >= 40 && lat <= 84 ? lat : null,
    lng: lng !== null && lng >= -142 && lng <= -52 ? lng : null
  };
}

/** A row as a line of COPY ... (format csv): empty fields are NULL. */
export function copyLine(r: AddressRow): string {
  const q = (v: string | number | null) => (v === null ? '' : typeof v === 'number' ? String(v) : /[",\n\r]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v);
  return [r.province, r.num, r.street, r.unit, r.city, r.postal, r.lat, r.lng].map(q).join(',') + '\n';
}
export const COPY_COLUMNS = 'province, num, street, unit, city, postal, lat, lng';
