// Forms C and D of the Title Agreement, pre-filled from the owner's records (migration 0040). They stay on paper: the
// forms call for witnesses (one for Form C, two for Form D) who sign in person, and Form D is a power of attorney,
// which Ontario's Electronic Commerce Act leaves out of electronic signing. The owner prints the PDF (every spot to sign
// or initial is marked, 0049), signs it with the witnesses and takes a photo of each page with the phone; staff review it.
import { markdown, type Block } from '@/features/agreement/model';
import { FORM_C, FORM_D, WITNESSED_FORMS_VERSION } from './forms.generated';

export { WITNESSED_FORMS_VERSION };
export interface WitnessedFacts {
  code: 'C' | 'D1';
  owner: { legal_name: string; owner_type: string; address: string };
  vehicles: Array<{ name: string; vin: string; plate: string | null; finance_party: string | null; finance_account: string | null; permission: string | null; title_status: string | null }>;
  title_agreement: string | null;
  company: { brand: string; legal_name: string; address: string; phone: string; email: string; logo_key?: string | null };
}

export const FORM_TITLE = { C: 'Form C: lender or lessor permission acknowledgment', D1: 'Form D: limited power of attorney' } as const;

export function witnessedBlocks(f: WitnessedFacts): Block[] {
  const company = f.company.legal_name || f.company.brand;
  const src = (f.code === 'C' ? FORM_C : FORM_D)
    .replace(/\{\{company\}\}/g, company)
    .replace(/^> /gm, '')
    .replace(/^Owner: \[●\]\./m, `Owner: **${f.owner.legal_name}**.`);
  let blocks = markdown(src, {});
  if (f.code === 'C') {
    // the vehicle row of the form, one per financed or leased car
    blocks = blocks.map((b) => b.t === 'table' && b.head[0] === 'Vehicle'
      ? { ...b, rows: f.vehicles.map((v) => [v.name + (v.plate ? `, plate ${v.plate}` : ''), v.vin, [v.finance_party, v.finance_account].filter(Boolean).join(', account ') || 'Not given',
          v.permission === 'attached' ? '[x] Attached  [ ] Not obtained' : v.permission === 'not_obtained' ? '[ ] Attached  [x] Not obtained' : '[ ] Attached  [ ] Not obtained']) }
      : b);
  } else {
    blocks.splice(1, 0, { t: 'table', head: ['Vehicle', 'VIN', 'Plate'], rows: f.vehicles.length ? f.vehicles.map((v) => [v.name, v.vin, v.plate ?? 'Not registered yet']) : [['Every Vehicle in the Title Schedule', '', '']] });
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
    { t: 'p', text: `Title-Holding and Lease Agreement${f.title_agreement ? ` ${f.title_agreement}` : ''} between ${company}, operating as ${f.company.brand}, and ${f.owner.legal_name}.` },
    ...blocks,
    { t: 'h3', text: 'How to complete this form' },
    { t: 'ul', items: f.code === 'C'
      ? ['Everything is filled in. Initial each spot marked INITIAL HERE.', 'Sign and date where it says SIGN HERE, in front of one adult witness, who signs and prints their name in the witness spot.', 'On your phone, open Documents in your owner portal and tap Take a photo: one photo of each page.']
      : ['Everything is filled in. Sign and date Part 1 where it says SIGN HERE, in front of two adult witnesses, who sign and print their names in their spots.', 'Leave Part 2 for CarmaCars: we sign it with our witness when we approve your form.', 'On your phone, open Documents in your owner portal and tap Take a photo: one photo of each page.'] }
  ];
}
