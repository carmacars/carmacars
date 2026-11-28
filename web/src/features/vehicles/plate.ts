// REQ-141 (5212): a car has no real plate when the plate is empty, only X characters (XXXXXXXX), only zeros or a
// placeholder word. The same rule as app.plate_missing in the database; the database decides, the pages mirror it.

const PLACEHOLDER = /^(X+|0+|TBD|TBA|NA|NONE|NOPLATE|PENDING|UNKNOWN|TEMP)?$/;

/** The plate as the database keeps it: capitals and digits only. */
export const normPlate = (p: string | null | undefined): string => (p ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');

/** True when no real plate is on file. */
export const plateMissing = (p: string | null | undefined): boolean => PLACEHOLDER.test(normPlate(p));

/** The problem with a plate typed in, or null when it can be saved. */
export function plateProblem(p: string): string | null {
  const n = normPlate(p);
  if (n.length < 2 || n.length > 8) return 'Enter the plate as on the ownership permit: 2 to 8 letters and numbers.';
  if (plateMissing(n)) return 'Enter the real plate, as on the ownership permit, not a placeholder.';
  return null;
}
