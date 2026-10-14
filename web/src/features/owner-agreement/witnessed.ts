// Forms C and D of the Title Agreement, pre-filled from the owner's records (migration 0040). The owner prints the
// PDF, signs it on paper with the witnesses and uploads a photo or scan; staff review it.
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
  // the signature tables: the person's printed name under each signature
  blocks = blocks.map((b) => b.t === 'table' && b.head[0] === '' ? { ...b, head: ['Signer', ...b.head.slice(1)], rows: [...b.rows, ['Printed name', ...b.head.slice(1).map((h) => (h === 'Owner' ? f.owner.legal_name : h === 'CarmaCars' ? company : ''))]] } : b);
  return [
    { t: 'title', text: FORM_TITLE[f.code] },
    { t: 'p', text: `Title-Holding and Lease Agreement${f.title_agreement ? ` ${f.title_agreement}` : ''} between ${company}, operating as ${f.company.brand}, and ${f.owner.legal_name}.` },
    ...blocks,
    { t: 'h3', text: 'How to complete this form' },
    { t: 'ul', items: f.code === 'C'
      ? ['Initial each acknowledgment by hand.', 'Sign and date it in front of one adult witness, who signs and prints their name.', 'Upload a clear photo or scan of every page under Documents in your owner portal.']
      : ['Sign and date Part 1 in front of two adult witnesses, who sign and print their names.', 'Leave Part 2 for CarmaCars: we sign it with our witness when we approve your form.', 'Upload a clear photo or scan of every page under Documents in your owner portal.'] }
  ];
}
