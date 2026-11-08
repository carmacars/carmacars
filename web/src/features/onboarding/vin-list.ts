// A list of VINs, pasted or from a CSV or text file (r34, migration 0824): one VIN a line, or separated by commas,
// semicolons, tabs or spaces; a CSV with a "VIN" column is read from that column only. Anything that looks like it was
// meant as a VIN (11 or more letters and digits) is kept, so a typo is reported rather than dropped; words, years and
// prices are left out. The database checks each one again. Pure: unit-tested in vin-list.test.ts.
import { cleanVin, VIN_RE, vinCheckOk } from '../vin/vin.ts';

export const VIN_LIST_MAX = 50;

const cells = (line: string) => line.split(/[,;\t]/).map((c) => c.trim().replace(/^"(.*)"$/, '$1').trim());

export function parseVinList(text: string): { vins: string[]; extra: number } {
  const lines = (text ?? '').replace(/\r/g, '').split('\n').filter((l) => l.trim());
  let tokens: string[];
  const head = lines.length ? cells(lines[0]!).map((c) => c.toLowerCase()) : [];
  const col = head.findIndex((c) => c === 'vin' || c === 'vins' || c === 'vin number' || c === 'vehicle identification number');
  if (col >= 0) tokens = lines.slice(1).map((l) => cells(l)[col] ?? '');
  else tokens = lines.flatMap((l) => l.split(/[\s,;]+/)).map((t) => t.replace(/^"|"$/g, ''));
  const out: string[] = [];
  for (const t of tokens) {
    const v = cleanVin(t);
    if (/^[A-Z0-9]{11,20}$/.test(v)) out.push(v);
  }
  return { vins: out.slice(0, VIN_LIST_MAX), extra: Math.max(0, out.length - VIN_LIST_MAX) };
}

/** What the browser can already say about one VIN, before the decoder (the database says it again). */
export function vinProblem(v: string): string | null {
  if (!VIN_RE.test(v)) return 'Not a VIN: 17 letters and digits, never I, O or Q';
  if (!vinCheckOk(v)) return 'The check digit (the 9th character) does not match: check the VIN for a typo';
  return null;
}
