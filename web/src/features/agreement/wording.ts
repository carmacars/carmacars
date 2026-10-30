// The rental agreement's wording, per booking (migration 0198). CarmaCars' standard text (source.generated.ts) is split
// into clauses: the 15 sections of Part 2, the Schedule of Fees (Part 3), the Owner Rental Addendum (Part 5) and the
// Booking Consents (Part 6). An Admin may reword a clause for one booking, add "Additional terms", or remove a clause
// that is not required (public.booking_clause_overrides); the PDF and the signing screens print the merged text.
// The database holds the same catalogue (agreement_clauses) and enforces it; wording.test.ts checks they match.
// Blind Spot's form is the insurer's official form: its printed terms are never changed here.
// Relative imports with their extension: the unit tests run these files in Node directly.
import { AGREEMENT_PARTS } from './source.generated.ts';

export type ClausePart = '2' | '3' | '5' | '6' | 'extra';
export interface ClauseDef {
  code: string; part: ClausePart; /** Part 2: the section number */ section?: number; title: string;
  /** false: required by law or the insurer, reworded but never removed */ removable: boolean;
  /** false: the wording is fixed (the consents the signer ticks) */ editable: boolean;
}

/** Part 2's sections, in order, with the code each keeps when the standard text is renumbered. */
const SECTIONS: Array<[string, boolean]> = [
  ['definitions', false], ['drivers', false], ['rental_period', false], ['pickup_return', false], ['charges', false], ['tolls', true],
  ['cancellation', false], ['coverage', false], ['damage', false], ['use', false], ['accidents', false], ['tracking', false],
  ['privacy', false], ['liability', false], ['general', false]
];

/** Part 2 split at its "### N. Title" headings: [{n, title, body}] (the body without its heading). */
export function part2Sections(body = AGREEMENT_PARTS['2'].body): Array<{ n: number; title: string; body: string }> {
  const out: Array<{ n: number; title: string; body: string }> = [];
  for (const chunk of body.split(/^(?=### \d+\. )/m)) {
    const m = chunk.match(/^### (\d+)\. (.+)\n/);
    if (!m) continue;
    out.push({ n: Number(m[1]), title: m[2]!.trim(), body: chunk.slice(m[0].length).replace(/^\n+|\n+$/g, '') });
  }
  return out;
}

export const ADDITIONAL = 'additional';

export const CLAUSES: ClauseDef[] = [
  ...part2Sections().map((s, i) => ({ code: SECTIONS[i]?.[0] ?? `section_${s.n}`, part: '2' as const, section: s.n, title: `${s.n}. ${s.title}`, removable: SECTIONS[i]?.[1] ?? false, editable: true })),
  { code: 'fee_schedule', part: '3', title: `Part 3: ${AGREEMENT_PARTS['3'].title}`, removable: false, editable: true },
  { code: 'owner_addendum', part: '5', title: `Part 5: ${AGREEMENT_PARTS['5'].title}`, removable: false, editable: true },
  { code: 'consents', part: '6', title: `Part 6: ${AGREEMENT_PARTS['6'].title}`, removable: false, editable: false },
  { code: ADDITIONAL, part: 'extra', title: 'Additional terms for this booking', removable: true, editable: true }
];
export const clauseDef = (code: string) => CLAUSES.find((c) => c.code === code) ?? null;

/** The standard wording of a clause ('' for the additional terms, which have none). */
export function standardText(code: string): string {
  const d = clauseDef(code);
  if (!d) return '';
  if (d.part === '2') return part2Sections().find((s) => s.n === d.section)?.body ?? '';
  if (d.part === 'extra') return '';
  return AGREEMENT_PARTS[d.part].body;
}

/** The booking's wording now: by clause code, the change in force (public.server_agreement_wording). */
export type Wording = Record<string, { action: 'edit' | 'add' | 'remove'; text: string | null }>;

export const REMOVED_NOTE = 'This section does not apply to this booking.';
const CHANGED = ' (worded for this booking)';

/** One Part's body with the booking's wording merged in; Part 2 also gets the additional terms as its last section. */
export function wordedPart(n: '2' | '3' | '5' | '6', w: Wording | null | undefined): { title: string; body: string } {
  const part = AGREEMENT_PARTS[n];
  if (!w || !Object.keys(w).length) return part;
  if (n !== '2') {
    const d = CLAUSES.find((c) => c.part === n)!;
    const o = w[d.code];
    if (!o || !d.editable) return part;
    if (o.action === 'remove' && d.removable) return { title: part.title + CHANGED, body: REMOVED_NOTE };
    return o.action === 'edit' && o.text ? { title: part.title + CHANGED, body: o.text } : part;
  }
  const sections = part2Sections(part.body);
  const out: string[] = [];
  for (const s of sections) {
    const d = CLAUSES.find((c) => c.part === '2' && c.section === s.n);
    const o = d ? w[d.code] : undefined;
    if (d && o?.action === 'remove' && d.removable) out.push(`### ${s.n}. ${s.title}${CHANGED}\n\n${REMOVED_NOTE}`);
    else if (d && o?.action === 'edit' && o.text) out.push(`### ${s.n}. ${s.title}${CHANGED}\n\n${o.text.trim()}`);
    else out.push(`### ${s.n}. ${s.title}\n\n${s.body}`);
  }
  const add = w[ADDITIONAL];
  if (add && add.action !== 'remove' && add.text?.trim()) out.push(`### ${(sections.at(-1)?.n ?? 0) + 1}. Additional terms for this booking\n\n${add.text.trim()}`);
  return { title: part.title, body: out.join('\n\n') };
}

/** What the agreement says about its own wording: null when it is all standard. */
export function wordingNotice(w: Wording | null | undefined, bookingType: string): string | null {
  if (!w) return null;
  const items = CLAUSES.filter((c) => w[c.code] && c.editable && (c.code !== 'owner_addendum' || bookingType === 'owner'))
    .filter((c) => (c.code === ADDITIONAL ? w[c.code]!.action !== 'remove' && !!w[c.code]!.text?.trim() : w[c.code]!.action === 'remove' ? c.removable : !!w[c.code]!.text))
    .map((c) => c.code === ADDITIONAL ? 'additional terms added at the end of Part 2' : `${c.part === '2' ? `section ${c.title}` : c.title} ${w[c.code]!.action === 'remove' ? 'does not apply' : 'reworded'}`);
  if (!items.length) return null;
  return `Worded for this booking: ${items.join('; ')}. Everything else is CarmaCars' standard wording.`;
}

/** The key terms' codes and the sections they summarize: a key term notes when its section is worded for the booking. */
export const KEY_TERM_SECTIONS: Record<string, string> = { damage: 'damage', charges: 'charges', fees: 'rental_period', coverage: 'coverage', cancellation: 'cancellation' };
export function keyTermNote(code: string, w: Wording | null | undefined): string {
  const s = KEY_TERM_SECTIONS[code];
  const o = s && w ? w[s] : undefined;
  if (!o || o.action !== 'edit' || !o.text) return '';
  return ` Section ${clauseDef(s!)!.title} is worded for my booking and I have read it.`;
}

/** A wording change as the version header prints it: long texts shortened, the full text being in the agreement. */
export function shortWording(v: string, max = 280): string {
  const t = v.replace(/\s+/g, ' ').trim();
  return t.length > max ? `${t.slice(0, max - 1).trimEnd()}… (full wording in the agreement)` : t;
}
