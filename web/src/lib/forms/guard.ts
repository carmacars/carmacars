// The words and matching of the form guard (r40-forms): what a field says when it is empty or wrong, how an error message from the
// server is tied to the field it names, and the title of the summary. No DOM here, so the unit tests run it as is (guard.test.ts);
// guard-dom.ts and FormGuard.tsx put it on the page for every form of the site.

/** The parts of a ValidityState the words need (a plain object, so a test can build one). */
export interface ValidityLike {
  valueMissing?: boolean; typeMismatch?: boolean; patternMismatch?: boolean; tooShort?: boolean; tooLong?: boolean;
  rangeUnderflow?: boolean; rangeOverflow?: boolean; stepMismatch?: boolean; badInput?: boolean; customError?: boolean;
}
export interface ControlFacts { kind: 'text' | 'email' | 'url' | 'tel' | 'number' | 'date' | 'select' | 'checkbox' | 'radio' | 'file' | 'textarea' | 'other';
  min?: string; max?: string; minLength?: number; maxLength?: number; title?: string; message?: string }

/** The short message under a field that failed the browser's own check. */
export function validityMessage(v: ValidityLike, c: ControlFacts): string {
  if (v.valueMissing) {
    if (c.kind === 'checkbox') return 'Tick this box to continue.';
    if (c.kind === 'radio') return 'Choose one.';
    if (c.kind === 'select') return 'Choose an option.';
    if (c.kind === 'file') return 'Add a file.';
    return 'Fill this in.';
  }
  if (v.typeMismatch) return c.kind === 'email' ? 'Enter a valid email address, like name@example.com.' : c.kind === 'url' ? 'Enter a full web address, starting with https://' : 'Enter a valid value.';
  if (v.patternMismatch) return c.title ? `Check the format: ${c.title.replace(/[.\s]+$/, '')}.` : 'Check the format.';
  if (v.tooShort) return `Use at least ${c.minLength ?? 'a few more'} characters.`;
  if (v.tooLong) return `Use at most ${c.maxLength ?? 'fewer'} characters.`;
  if (v.rangeUnderflow) return c.min ? `Enter ${c.min} or more.` : 'This is too low.';
  if (v.rangeOverflow) return c.max ? `Enter ${c.max} or less.` : 'This is too high.';
  if (v.stepMismatch) return 'Enter a whole or valid number.';
  if (v.badInput) return c.kind === 'date' ? 'Enter a valid date.' : 'Enter a valid value.';
  if (v.customError && c.message) return c.message;
  return c.message || 'Check this field.';
}

/** A label as a person reads it: no star, no "(optional)", one space between words. */
export const cleanLabel = (s: string): string => s.replace(/\s+/g, ' ').replace(/\s*\*+\s*$/, '').replace(/\s*\((?:optional|required)\)\s*$/i, '').replace(/\s+optional$/i, '').trim();

/** A field name as words: licence_number, licenceNumber and licence-number all become "licence number". */
export const humanName = (n: string): string => n.replace(/\[\d*\]/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[_\-.]+/g, ' ').replace(/\s+/g, ' ').trim().toLowerCase();

const norm = (s: string): string => s.toLowerCase().replace(/[‘’ʼ]/g, "'").replace(/[^a-z0-9' ]+/g, ' ').replace(/\s+/g, ' ').trim();
const MIN_LEN = 4;

export interface FieldRef { id: string; label: string; name?: string }
/**
 * The fields a server message names: a field whose label (or name as words) appears in the message as whole words, "Driver's
 * licence number is required" names the field labelled "Driver's licence number". A shorter label inside a longer one that also
 * matched ("address" in "home address") is dropped. Labels under 4 letters never match (too many false hits).
 */
export function fieldsNamedIn(message: string, fields: FieldRef[]): string[] {
  const m = ` ${norm(message)} `;
  const hits: Array<{ id: string; term: string }> = [];
  for (const f of fields) {
    const terms = [cleanLabel(f.label), f.name ? humanName(f.name) : ''].map(norm).filter((t) => t.length >= MIN_LEN);
    const t = terms.find((x) => m.includes(` ${x} `));
    if (t) hits.push({ id: f.id, term: t });
  }
  return hits.filter((h) => !hits.some((o) => o !== h && o.term.length > h.term.length && o.term.includes(h.term))).map((h) => h.id);
}

export interface Problem { id: string; label: string; message: string }
/** The summary's heading. */
export const summaryTitle = (n: number): string => (n === 1 ? 'Fix 1 thing to continue' : `Fix these ${n} things to continue`);
/** The summary's line for one problem ("First name: Fill this in."). */
export const problemLine = (p: Problem): string => (p.label ? `${p.label}: ${p.message}` : p.message);
/** A stable text of the problems, to redraw the summary only when it changed. */
export const problemSig = (ps: Problem[]): string => ps.map((p) => `${p.id}\u0001${p.label}\u0001${p.message}`).join('\u0002');
