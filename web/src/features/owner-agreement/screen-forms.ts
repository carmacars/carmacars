// Forms A and B of the Title-Holding and Lease Agreement (migration 0044), pre-filled from the owner's records and
// signed on screen with the built-in signature (no witness is needed), or signed on paper and recorded by an Admin.
// Relative imports with their extension: the unit tests render these documents in Node directly (render.test.ts).
import { markdown, type Block, type SignatureRow } from '../agreement/model.ts';
import { endSentence } from '../../lib/format.ts';
import { FORM_A, FORM_B, SCREEN_FORMS_VERSION } from './forms-ab.generated.ts';

export { SCREEN_FORMS_VERSION };
export interface ScreenFormFacts {
  code: 'A' | 'B';
  owner_id: string;
  owner: { legal_name: string; owner_type: string; corporation_name: string | null; signer_name: string; address: string };
  vehicles: Array<{ name: string; vin: string | null; plate: string | null; method: string; title_status: string | null }>;
  title_agreement: string | null;
  company: { brand: string; legal_name: string; address: string; phone: string; email: string; corporation_number?: string | null };
}

export const SCREEN_FORM_TITLE = { A: 'Form A: trust declaration', B: 'Form B: lease summary' } as const;
const METHOD: Record<string, string> = { co_registrant: 'Co-Registrant', transfer: 'Transfer', lease_existing_corporation: 'Lease, existing corporation', lease_new_owner_corporation: 'Lease, new Owner Corporation' };

export function screenFormBlocks(f: ScreenFormFacts, sig?: { owner?: SignatureRow; carmacars?: SignatureRow }): Block[] {
  const company = f.company.legal_name || f.company.brand;
  const src = (f.code === 'A' ? FORM_A : FORM_B).replace(/\{\{company\}\}/g, company).replace(/^Owner: \[●\]\./m, `Owner: **${f.owner.legal_name}**${/\.$/.test(f.owner.legal_name) ? '' : '.'}`);
  let blocks = markdown(src, {});
  // the cars the form covers
  blocks = blocks.map((b) => (b.t === 'table' && b.head[0] === 'Vehicle'
    ? { ...b, rows: f.vehicles.length ? f.vehicles.map((v) => [v.name + (v.plate ? `, plate ${v.plate}` : ''), v.vin ?? '', METHOD[v.method] ?? v.method, v.title_status === 'owned_outright' ? 'None' : 'See the Title Schedule']) : [['Every Vehicle in the Title Schedule under a Lease method', '', '', '']] }
    : b));
  if (f.code === 'A') blocks.splice(1, 0, { t: 'table', head: ['Vehicle', 'VIN', 'Onboarding Method'], rows: f.vehicles.map((v) => [v.name + (v.plate ? `, plate ${v.plate}` : ''), v.vin ?? '', METHOD[v.method] ?? v.method]) });
  // the lease table of Form B: the lessor is the owner's corporation
  blocks = blocks.map((b) => (b.t === 'table' && b.head[0] === 'Item'
    ? { ...b, rows: b.rows.map((r) => (r[0] === 'Lessor (owner)' ? [r[0]!, `${f.owner.corporation_name ?? f.owner.legal_name}, address ${f.owner.address || 'as on the ownership permit'}; corporation and registrant numbers as on the ownership permit`] : r[0] === 'Lessee' ? [r[0]!, company] : r)) }
    : b));
  // the signature table becomes the signatures (on screen: the owner's and CarmaCars')
  blocks = blocks.filter((b) => !(b.t === 'table' && b.head[0] === ''));
  const blank = (party: string, name: string): SignatureRow => ({ party, name, signature: '', when: '' });
  return [
    { t: 'title', text: SCREEN_FORM_TITLE[f.code] },
    { t: 'p', text: `Title-Holding and Lease Agreement${f.title_agreement ? ` ${f.title_agreement}` : ''} between ${company} and ${endSentence(f.owner.legal_name)}` },
    ...blocks,
    { t: 'signatures', rows: [sig?.owner ?? blank(f.code === 'B' ? 'Lessor (owner)' : 'Owner', f.owner.signer_name), sig?.carmacars ?? blank(f.code === 'B' ? 'Lessee (CarmaCars)' : 'CarmaCars', company)] }
  ];
}
