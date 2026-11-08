// Forms C and D of the Title Agreement, pre-filled from the owner's records (migration 0040). Since 0720 (the owner's
// decision of November 7, 2026: no paper signature for anyone) both are signed on screen only: the owner signs with the
// signing steps of every signature, and the witnesses (one for Form C, two for Form D), in person on the same device,
// type their names and the statement that they witnessed the owner sign in their presence. Part 2 of Form D is signed
// for CarmaCars from the stored signatures: the signing officer, and the second signing officer as CarmaCars' witness
// (Program settings). witnessedBlocks is the printable copy (every spot marked), kept for reading.
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
export const FORM_D_SCREEN_VERSION = `${WITNESSED_FORMS_VERSION}-d-screen`;
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

/** Who signs Form D's Part 2 for CarmaCars (Program settings): the signing officer and the second signing officer. */
export interface CompanySigners { officer: string | null; officer_title: string | null; second: string | null; second_title: string | null }

/** Form D signed on screen (0720): the same text; Part 1 signed by the owner and the two witnesses, Part 2 by CarmaCars
 *  (the signing officer) and its witness (the second signing officer), each from the signatures given or blank. */
export function screenFormDBlocks(f: WitnessedFacts, c: CompanySigners, sig?: { owner?: SignatureRow; w1?: SignatureRow; w2?: SignatureRow; company?: SignatureRow; companyWitness?: SignatureRow }): Block[] {
  const blocks = witnessedBlocks({ ...f, code: 'D1' });
  const how = blocks.findIndex((b) => b.t === 'h3' && b.text === 'How to complete this form');
  const company = f.company.legal_name || f.company.brand;
  const blank = (party: string, name: string): SignatureRow => ({ party, name, signature: '', when: '' });
  const titled = (n: string | null, t: string | null) => (n ? `${n}${t ? `, ${t}` : ''}` : null);
  let part = 0;
  return blocks.slice(0, how < 0 ? blocks.length : how).map((b): Block => {
    if (b.t !== 'table' || b.head[0] !== 'Signer') return b;
    part += 1;
    return part === 1
      ? { t: 'signatures', rows: [sig?.owner ?? blank('Owner', f.owner.legal_name), sig?.w1 ?? blank('Witness 1', 'Signs on screen beside the owner'), sig?.w2 ?? blank('Witness 2', 'Signs on screen beside the owner')] }
      : { t: 'signatures', rows: [sig?.company ?? blank('CarmaCars', titled(c.officer, c.officer_title) ?? company),
          sig?.companyWitness ?? blank('Witness (CarmaCars)', titled(c.second, c.second_title) ?? 'The second CarmaCars signer (to be set in Program settings)')] };
  }).concat([{ t: 'p', text: `Witness statement (Part 1): ${witnessStatement(f.owner.legal_name)} Part 2 is signed for ${company} from its stored signatures when the owner signs.` }]);
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
    { t: 'p', text: `Title-Holding and Lease Agreement${f.title_agreement ? ` ${f.title_agreement}` : ''} between ${company} and ${endSentence(f.owner.legal_name)}` },
    ...blocks,
    { t: 'h3', text: 'How to complete this form' },
    { t: 'ul', items: f.code === 'C'
      ? ['Everything is filled in. Initial each spot marked INITIAL HERE.', 'Sign and date where it says SIGN HERE, in front of one adult witness, who signs and prints their name in the witness spot.', 'On your phone, open Documents in your owner portal and tap Take a photo: one photo of each page.', 'Or sign it on screen instead: open Documents and choose Sign on screen, with your witness beside you on the same device.']
      : ['Everything is filled in. Sign and date Part 1 where it says SIGN HERE, in front of two adult witnesses, who sign and print their names in their spots.', 'Leave Part 2 for CarmaCars: we sign it with our witness when we approve your form.', 'On your phone, open Documents in your owner portal and tap Take a photo: one photo of each page.'] }
  ];
}
