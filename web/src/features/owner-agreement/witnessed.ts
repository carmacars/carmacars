// Forms C and D of the Title Agreement, pre-filled from the owner's records (migration 0040). Form D stays on paper: it
// calls for two witnesses who sign in person, and it is a power of attorney, which Ontario's Electronic Commerce Act
// leaves out of electronic signing. The owner prints the PDF (every spot to sign or initial is marked, 0049), signs it
// with the witnesses and takes a photo of each page with the phone; staff review it. Form C may also be signed on screen
// (the legal review, 0053): the owner signs and initials, and the witness, in person on the same device, types their
// name and the statement that they witnessed the owner sign in their presence.
// Relative imports with their extension: the unit tests render these documents in Node directly (render.test.ts).
import { markdown, type Block, type SignatureRow } from '../agreement/model.ts';
import { endSentence } from '../../lib/format.ts';
import { FORM_C, FORM_D, WITNESSED_FORMS_VERSION } from './forms.generated.ts';

export { WITNESSED_FORMS_VERSION };
export interface WitnessedFacts {
  code: 'C' | 'D1';
  owner: { legal_name: string; owner_type: string; address: string };
  vehicles: Array<{ name: string | null; vin: string | null; plate: string | null; finance_party: string | null; finance_account: string | null; permission: string | null; title_status: string | null }>;
  title_agreement: string | null;
  company: { brand: string; legal_name: string; address: string; phone: string; email: string; logo_key?: string | null };
}

export const FORM_TITLE = { C: 'Form C: lender or lessor permission acknowledgment', D1: 'Form D: limited power of attorney' } as const;
export const FORM_C_SCREEN_VERSION = `${WITNESSED_FORMS_VERSION}-screen`;
export const witnessStatement = (owner: string) => `I witnessed ${owner} sign in my presence.`;

/** Form C signed on screen: the same text, the initials and the two signatures (the owner's and the witness's). */
export function screenFormCBlocks(f: WitnessedFacts, sig?: { owner?: SignatureRow; witness?: SignatureRow; initials?: string }): Block[] {
  const blocks = witnessedBlocks({ ...f, code: 'C' })
    .filter((b) => !(b.t === 'table' && b.head[0] === 'Signer'))
    .map((b) => b.t === 'table' && b.head[0] === 'I acknowledge' ? { ...b, rows: b.rows.map((r) => [r[0]!, sig?.initials ?? 'Initialled when signed']) } : b);
  const how = blocks.findIndex((b) => b.t === 'h3' && b.text === 'How to complete this form');
  const blank = (party: string, name: string): SignatureRow => ({ party, name, signature: '', when: '' });
  return [
    ...blocks.slice(0, how < 0 ? blocks.length : how),
    { t: 'signatures', rows: [sig?.owner ?? blank('Owner', f.owner.legal_name), sig?.witness ?? blank('Witness', 'Signs on screen beside the owner')] },
    { t: 'p', text: `Witness statement: ${witnessStatement(f.owner.legal_name)}` }
  ];
}

// A car added before its VIN is known (VIN-first entry allows a draft without one): a blank to fill in by hand, never a crash
const NO_VIN = 'VIN not given yet';

export function witnessedBlocks(f: WitnessedFacts): Block[] {
  const company = f.company.legal_name || f.company.brand;
  const src = (f.code === 'C' ? FORM_C : FORM_D)
    .replace(/\{\{company\}\}/g, company)
    .replace(/^> /gm, '')
    .replace(/^Owner: \[●\]\./m, `Owner: **${f.owner.legal_name}**${/\.$/.test(f.owner.legal_name) ? '' : '.'}`);
  let blocks = markdown(src, {});
  if (f.code === 'C') {
    // the vehicle row of the form, one per financed or leased car
    blocks = blocks.map((b) => b.t === 'table' && b.head[0] === 'Vehicle'
      ? { ...b, rows: f.vehicles.map((v) => [(v.name ?? 'Vehicle') + (v.plate ? `, plate ${v.plate}` : ''), v.vin ?? NO_VIN, [v.finance_party, v.finance_account].filter(Boolean).join(', account ') || 'Not given',
          v.permission === 'attached' ? '[x] Attached  [ ] Not obtained' : v.permission === 'not_obtained' ? '[ ] Attached  [x] Not obtained' : '[ ] Attached  [ ] Not obtained']) }
      : b);
  } else {
    blocks.splice(1, 0, { t: 'table', head: ['Vehicle', 'VIN', 'Plate'], rows: f.vehicles.length ? f.vehicles.map((v) => [v.name ?? 'Vehicle', v.vin ?? NO_VIN, v.plate ?? 'Not registered yet']) : [['Every Vehicle in the Title Schedule', '', '']] });
  }
  // the signature tables: each spot to sign marked (the owner's and the witnesses'; CarmaCars signs Part 2 itself), and
  // the person's printed name under each signature
  const mark = (h: string) => `>> SIGN HERE (${h.toLowerCase()}) and date: ____________`;
  blocks = blocks.map((b) => {
    if (b.t !== 'table' || b.head[0] !== '') return b;
    const ours = b.head.includes('CarmaCars'); // Part 2 of Form D: CarmaCars and its witness sign it, not the owner
    return { ...b, head: ['Signer', ...b.head.slice(1)],
      rows: [...b.rows.map((r) => (r[0] === 'Signature and date' && !ours ? [r[0], ...b.head.slice(1).map(mark)] : r)),
        ['Printed name', ...b.head.slice(1).map((h) => (h === 'Owner' ? f.owner.legal_name : h === 'CarmaCars' ? company : ours ? '' : 'Print the name here'))]] };
  });
  // the acknowledgments of Form C: each initial spot marked
  blocks = blocks.map((b) => b.t === 'table' && b.head[0] === 'I acknowledge' ? { ...b, rows: b.rows.map((r) => [r[0]!, '>> INITIAL HERE: ____']) } : b);
  return [
    { t: 'title', text: FORM_TITLE[f.code] },
    { t: 'p', text: `Title-Holding and Lease Agreement${f.title_agreement ? ` ${f.title_agreement}` : ''} between ${company}, operating as ${f.company.brand}, and ${endSentence(f.owner.legal_name)}` },
    ...blocks,
    { t: 'h3', text: 'How to complete this form' },
    { t: 'ul', items: f.code === 'C'
      ? ['Everything is filled in. Initial each spot marked INITIAL HERE.', 'Sign and date where it says SIGN HERE, in front of one adult witness, who signs and prints their name in the witness spot.', 'On your phone, open Documents in your owner portal and tap Take a photo: one photo of each page.', 'Or sign it on screen instead: open Documents and choose Sign on screen, with your witness beside you on the same device.']
      : ['Everything is filled in. Sign and date Part 1 where it says SIGN HERE, in front of two adult witnesses, who sign and print their names in their spots.', 'Leave Part 2 for CarmaCars: we sign it with our witness when we approve your form.', 'On your phone, open Documents in your owner portal and tap Take a photo: one photo of each page.'] }
  ];
}
