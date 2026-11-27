// Add old photos (5185), the bulk flow: photos taken close together (Program settings old_photos_group_minutes) are one
// group, one check-in or check-out; photos with no capture time are a group of their own. No I/O here.

export interface Timed { id: string; at: string | null }
export interface Group<T extends Timed> { i: number; from: string | null; to: string | null; items: T[] }

export function groupByTime<T extends Timed>(items: T[], gapMinutes: number): Array<Group<T>> {
  const timed = items.filter((x) => x.at).sort((a, b) => Date.parse(a.at!) - Date.parse(b.at!));
  const out: Array<Group<T>> = [];
  for (const x of timed) {
    const last = out[out.length - 1];
    if (last && Date.parse(x.at!) - Date.parse(last.to!) <= gapMinutes * 60000) { last.items.push(x); last.to = x.at; }
    else out.push({ i: out.length, from: x.at, to: x.at, items: [x] });
  }
  const untimed = items.filter((x) => !x.at);
  if (untimed.length) out.push({ i: out.length, from: null, to: null, items: untimed });
  return out;
}

/** A plate as the vision model read it: letters and digits only, 2 to 8 of them, else null. */
export function cleanPlate(v: unknown): string | null {
  if (typeof v !== 'string') return null;
  const p = v.toUpperCase().replace(/[^A-Z0-9]/g, '');
  return p.length >= 2 && p.length <= 8 ? p : null;
}

/** The wait before the next try of an upload that failed on the network (seconds: 2, 4, 8, 16, then 30). */
export const retryDelay = (tries: number) => Math.min(30, 2 ** Math.max(1, tries)) * 1000;

/** The upload's key: the SHA-256 of the photo's own bytes, written as a UUID. The same photo picked again (after a reload,
 * or in a second pile) gets the same key, so the server attaches it once to a check-in or check-out (5185's client_key). */
export async function uploadKey(bytes: ArrayBuffer): Promise<string> {
  const h = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)).subarray(0, 16), (b) => b.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}
