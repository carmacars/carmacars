import { VIN_RE, cleanVin, vinCheckOk } from './vin.ts';

// VIN by photo or camera (release 28): what a barcode reader or the vision model hands back, made into one VIN. Pure, so
// the browser, the server and the unit tests share it (vin-read.test.ts).
//
// - The barcode on the door jamb or under the windshield is Code 39, Code 128 or Data Matrix. Imported cars often carry
//   an "I" before the VIN (18 characters), and some labels add spaces or a trailing check character: the 17 characters
//   that form a VIN are kept.
// - Read text (a photo of the plate on the dashboard or the door sticker) confuses I, O and Q (never in a VIN) with 1 and
//   0, and a few look-alikes (S and 5, B and 8, Z and 2, G and 6, D and 0). I, O and Q are always replaced; a look-alike
//   is swapped only when that makes the check digit (position 9) add up, and only one change is made.

const ALWAYS: Record<string, string> = { I: '1', O: '0', Q: '0' };
/** Look-alikes tried, both ways, when the check digit does not add up. */
const LOOKALIKE: Array<[string, string]> = [['S', '5'], ['B', '8'], ['Z', '2'], ['G', '6'], ['D', '0'], ['T', '7'], ['A', '4'], ['L', '1'], ['U', 'V']];

export interface VinRead {
  /** the VIN, 17 characters */
  vin: string;
  /** the check digit adds up (North American VINs; a European VIN may not use it) */
  checkOk: boolean;
  /** characters were changed from what was read (I, O or Q, or one look-alike) */
  corrected: boolean;
  /** what was read, cleaned, before any change */
  raw: string;
}

/** I, O and Q, which a VIN never has, as 1, 0 and 0. */
const swapAlways = (s: string) => s.replace(/[IOQ]/g, (c) => ALWAYS[c]!);

/** One 17-character VIN from what was read: I, O and Q replaced, then at most one look-alike swapped when that makes the
 *  check digit add up. Null when it is not 17 letters and digits. */
export function fixVin(raw: string): VinRead | null {
  const r = cleanVin(raw).replace(/[^A-Z0-9]/g, '');
  if (r.length !== 17) return null;
  const v = swapAlways(r);
  if (!VIN_RE.test(v)) return null;
  if (vinCheckOk(v)) return { vin: v, checkOk: true, corrected: v !== r, raw: r };
  // positions 13 to 17 are the serial number, digits on almost every car: look-alike letters there read as digits
  const serial = v.slice(0, 12) + v.slice(12).replace(/[SBZGDTAL]/g, (c) => LOOKALIKE.find(([a]) => a === c)![1]);
  if (serial !== v && VIN_RE.test(serial) && vinCheckOk(serial)) return { vin: serial, checkOk: true, corrected: true, raw: r };
  // one look-alike: the first position (left to right) whose swap makes the check digit add up; when two different
  // swaps both add up, the read is ambiguous and nothing is changed
  const found = new Set<string>();
  for (let i = 0; i < 17; i++) {
    for (const [a, b] of LOOKALIKE) {
      for (const [from, to] of [[a, b], [b, a]] as const) {
        if (v[i] !== from) continue;
        const t = v.slice(0, i) + to + v.slice(i + 1);
        if (VIN_RE.test(t) && vinCheckOk(t)) found.add(t);
      }
    }
  }
  if (found.size === 1) return { vin: [...found][0]!, checkOk: true, corrected: true, raw: r };
  return { vin: v, checkOk: false, corrected: v !== r, raw: r };
}

/** Every VIN in a barcode's text or a read text, best first: the ones whose check digit adds up, then the rest. A
 *  barcode's "I" prefix (imports) and any characters around the VIN are dropped. */
export function vinsIn(text: string): VinRead[] {
  const up = (text ?? '').toUpperCase();
  const seen = new Map<string, VinRead>();
  const add = (s: string) => { const f = fixVin(s); if (f && !seen.has(f.vin)) seen.set(f.vin, f); };
  const run = (raw: string) => {
    const x = raw.replace(/[ -]/g, '');
    if (x.length === 17) add(x);
    else if (x.length === 18 && x[0] === 'I') add(x.slice(1));
    else if (x.length > 17) for (let i = 0; i + 17 <= x.length; i++) add(x.slice(i, i + 17));
  };
  // each word of letters and digits first; only when none is a VIN, runs with the spaces and dashes people print
  // inside a VIN (1HGCM 82633 A004352) joined
  for (const m of up.matchAll(/[A-Z0-9]{17,}/g)) run(m[0]);
  if (!seen.size) for (const m of up.matchAll(/[A-Z0-9](?:[A-Z0-9]|[ -](?=[A-Z0-9])){15,}/g)) run(m[0]);
  const all = [...seen.values()];
  // a longer run gives many windows: keep the windows whose check digit adds up when there are any
  const good = all.filter((x) => x.checkOk);
  return good.length ? [...good.filter((x) => !x.corrected), ...good.filter((x) => x.corrected)] : all.slice(0, 3);
}

/** The best VIN of a read, or null. */
export const bestVin = (text: string): VinRead | null => vinsIn(text)[0] ?? null;

/** What the person is told about a VIN read from a photo or the camera. */
export function readMessage(r: VinRead, how: 'barcode' | 'photo'): string {
  const from = how === 'barcode' ? 'the barcode' : 'the photo';
  if (r.checkOk && !r.corrected) return `Read from ${from}. Check it against the car before saving.`;
  if (r.checkOk) return `Read from ${from}, with a misread character corrected (${r.raw} read). Check it against the car before saving.`;
  return `Read from ${from}, but the VIN does not add up: one character may be misread. Check it against the car or the ownership permit.`;
}

// ---------------------------------------------------------------- the vision model (photo upload)
export const VIN_SYSTEM = 'You read vehicle identification numbers (VINs) from photos. Answer with JSON only.';
export const VIN_PROMPT = [
  'The photo shows a vehicle identification number: the VIN plate on the dashboard seen through the windshield, the sticker in the driver\'s door jamb, a barcode label, an ownership permit or an insurance slip.',
  'Find the VIN: exactly 17 letters and digits. Copy each character exactly as printed. A VIN never contains the letters I, O or Q.',
  'Answer as {"vin": "<the 17 characters, or empty when no VIN is readable>", "other": ["<any other 17-character candidates>"]}.'
].join(' ');

/** The model's answer as VIN reads, best first (the "vin" field, then the "other" ones). */
export function vinsFromModel(data: unknown): VinRead[] {
  const d = (data ?? {}) as { vin?: unknown; other?: unknown };
  const texts = [typeof d.vin === 'string' ? d.vin : '', ...(Array.isArray(d.other) ? d.other.filter((x): x is string => typeof x === 'string') : [])];
  const seen = new Map<string, VinRead>();
  for (const t of texts) for (const r of vinsIn(t)) if (!seen.has(r.vin)) seen.set(r.vin, r);
  const all = [...seen.values()];
  return [...all.filter((x) => x.checkOk), ...all.filter((x) => !x.checkOk)];
}
