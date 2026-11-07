// The Referral Override Agreement (migration 0640): an owner who referred another owner is paid an override on the
// referred owner's cars (owner_referral_links, 0543) and may see them read only. The text is docs/source/
// v2_referral_override.md (scripts/gen-owner-agreements.mjs); the cover summary is filled from the link
// (app.referral_agreement_facts). Signed in the owner portal (/owner/referral-agreement/<link>) or on paper.
// Relative imports with their extension: the unit tests render it in Node directly.
import { markdown, type Block, type SignatureRow } from '../agreement/model.ts';
import { REFERRAL_ARTICLES, REFERRAL_TEMPLATE_VERSION } from './source.generated.ts';

export const REFERRAL_AGREEMENT_TITLE = 'Referral Override Agreement';
export { REFERRAL_TEMPLATE_VERSION };

export interface ReferralFacts {
  owner_id: string; link_id: string;
  referrer: { legal_name: string; owner_type: 'individual' | 'corporation'; signer_name: string; signer_title: string | null; email: string | null; hst_number: string | null; address: string };
  referred: { legal_name: string };
  share_bps: number; sees_cars: boolean; effective_from: string; agreement_status: 'not_sent' | 'sent' | 'signed';
  payout_day: number;
  company: { brand: string; legal_name: string; address: string; phone: string; email: string };
}

const ordinal = (n: number) => `${n}${n % 100 >= 11 && n % 100 <= 13 ? 'th' : ({ 1: 'st', 2: 'nd', 3: 'rd' } as Record<number, string>)[n % 10] ?? 'th'}`;
const points = (bps: number) => `${+(bps / 100).toFixed(2)} points (${+(bps / 100).toFixed(2)}% of Owner Revenue)`;
const day = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'UTC', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(`${iso.slice(0, 10)}T12:00:00Z`));

export function referralAgreementBlocks(f: ReferralFacts, sig?: { referrer?: SignatureRow; company?: SignatureRow }): Block[] {
  const company = f.company.legal_name || 'the Company';
  const blank = (party: string, name: string): SignatureRow => ({ party, name, signature: '', when: '' });
  return [
    { t: 'title', text: REFERRAL_AGREEMENT_TITLE },
    { t: 'h2', text: 'Cover summary' },
    { t: 'p', text: 'This page is a summary, except the numbers in it, which form part of the Agreement.' },
    { t: 'table', kv: true, head: ['Item', 'Details'], rows: [
      ['The Company', `${company}${f.company.address ? `, ${f.company.address}` : ''}`],
      ['Referrer', `${f.referrer.legal_name}${f.referrer.address ? `, ${f.referrer.address}` : ''}`],
      ['Referrer email, HST number', [f.referrer.email, f.referrer.hst_number ? `HST ${f.referrer.hst_number}` : 'No HST number'].filter(Boolean).join('; ')],
      ['Referred Owner', f.referred.legal_name],
      ['Override Rate', points(f.share_bps)],
      ['Start Date', day(f.effective_from)],
      ['Referrer sees the Referred Vehicles (3.1)', f.sees_cars ? 'Yes, read only' : 'No'],
      ['Payout Date', `The ${ordinal(f.payout_day)} of each month`]
    ] },
    { t: 'h2', text: 'The Agreement' },
    ...markdown(REFERRAL_ARTICLES, {}),
    { t: 'h2', text: 'Signatures' },
    { t: 'signatures', rows: [sig?.referrer ?? blank(f.referrer.owner_type === 'corporation' ? `Referrer (corporation)${f.referrer.signer_title ? `, ${f.referrer.signer_title}` : ''}` : 'Referrer', f.referrer.signer_name),
      sig?.company ?? { ...blank(company, ''), signature: 'Applied when the Referrer signs' }] }
  ];
}
