// The owner agreements as lists of blocks, filled from the owner's records
// (public.server_owner_agreement_facts): the Vehicle Enrollment Agreement with Schedule A (the
// Vehicle Schedule) and Schedule B, the Title-Holding and Lease Agreement with Schedule 1, and the
// Additional Vehicle Schedule. The screen (AgreementView) and the PDF (agreementPdf) both render
// these blocks, so what the owner reads is what the PDF holds. The articles come word for word from
// docs/source (scripts/gen-owner-agreements.mjs).
// Relative imports with their extension: the unit tests render these documents in Node directly (render.test.ts).
import { companyParty, money, pct, phone } from '../../lib/format.ts';
import { markdown, when, type Block, type SignatureRow } from '../agreement/model.ts';
import { ENROLLMENT_ARTICLES, ENROLLMENT_SCHEDULE_B, OWNER_TEMPLATE_VERSION, TITLE_ARTICLES } from './source.generated.ts';

export type PacketKey = 'enrollment' | 'title_holding' | 'additional';

export interface OwnerSchedule {
  id: string; vehicle_id: string; schedule_number: string; vehicle_number: number; is_additional: boolean; year: number; make: string; model: string;
  trim: string | null; colour: string | null; vin: string; plate: string | null; odometer_km: number | null; held_by: string; title_status: string;
  finance_party_name: string | null; finance_permission: string; management_mode: string; onboarding_method: string; insurance_fee_cents: number;
  tracker_fee_cents: number; install_fee_cents: number; revenue_share_bps: number; enrollment_date: string | null; special_terms: string | null;
  owners_lien: string; signed_at: string | null; signature_request_id: string | null; title_agreement_id: string | null; onboarding_status: string;
}
export interface OwnerAgreementFacts {
  owner: { id: string; owner_type: 'individual' | 'corporation'; legal_name: string; corporation_name: string | null; corporation_number: string | null;
    email: string | null; phone: string | null; hst_number: string | null; address: string | null; signing_officer_name: string | null;
    signing_officer_title: string | null; signer_name: string; signer_role: string; payout: string | null };
  company: { trade_name: string; legal_name?: string | null; address: string | null; email: string | null; phone: string | null; signing_officer_name: string; signing_officer_title: string | null; install_fee_cents: number; hst_bps: number };
  agreements: Array<{ id: string; kind: 'enrollment' | 'title_holding'; agreement_number: string; status: string; agreement_date: string | null; signature_request_id: string | null; document_sha256: string | null }>;
  schedules: OwnerSchedule[];
  /** The other Owners named in the Title Schedule (0053): each signs with their own link. */
  cosigners?: Array<{ id: string; name: string; email: string; status: 'pending' | 'signed'; signed_at: string | null }>;
  /** The portal owner has signed; the documents wait for the other Owners. */
  waiting_for_owners?: boolean;
}

export const TITLES: Record<PacketKey, string> = {
  enrollment: 'Vehicle Enrollment Agreement',
  title_holding: 'Title-Holding and Lease Agreement',
  additional: 'Additional Vehicle Schedule'
};
export const OWNER_SIGN_STATEMENT = 'I have read these documents and I sign them electronically.';
export const CONFIRMATIONS = [
  { code: 'own_insurance', text: 'I keep my own insurance until CarmaCars confirms in writing (3.3).' },
  { code: 'fees_no_income', text: 'Fees are due every month, rented or not. No income is promised (2.3, 4.3).' },
  { code: 'tracker_downtime', text: 'The Tracker records location, including when I drive. No pay for downtime (5, 10, 15).' }
] as const;
export { OWNER_TEMPLATE_VERSION };

const agreement = (f: OwnerAgreementFacts, k: 'enrollment' | 'title_holding') => f.agreements.find((a) => a.kind === k) ?? null;
const unsigned = (f: OwnerAgreementFacts) => f.schedules.filter((s) => !s.signed_at);

/** What the owner still has to sign, in order. */
export function packetKeys(f: OwnerAgreementFacts): PacketKey[] {
  const keys: PacketKey[] = [];
  const ea = agreement(f, 'enrollment');
  const ta = agreement(f, 'title_holding');
  const open = unsigned(f);
  if (!open.length) return keys;
  if (ea && ea.status !== 'signed') keys.push('enrollment');
  if (ta && ta.status !== 'signed' && open.some((s) => s.management_mode !== 'turo_only')) keys.push('title_holding');
  if (ea?.status === 'signed' && open.some((s) => s.is_additional)) keys.push('additional');
  return keys;
}

const LABEL: Record<string, string> = {
  individual: 'Individual', corporation: 'Corporation', owned_outright: 'Owned Outright', financed: 'Financed', leased: 'Leased',
  not_applicable: 'Not applicable', attached: 'Attached', not_obtained: 'Not obtained (Form C)', managed: 'Managed', self_managed: 'Self-Managed',
  turo_only: 'Turo-Only', lease_existing_corporation: 'Lease, existing corporation', lease_new_owner_corporation: 'Lease, new Owner Corporation',
  co_registrant: 'Co-Registrant', transfer: 'Transfer', none: 'None (Turo-Only)', not_available: 'Not available', elected: 'Elected', declined: 'Declined'
};
const l = (v: string | null | undefined) => (v ? LABEL[v] ?? v : '');
const vehicleLine = (s: OwnerSchedule) => [s.year, s.make, s.model, s.trim].filter(Boolean).join(' ') + (s.colour ? `, ${s.colour}` : '');
const ownerLine = (f: OwnerAgreementFacts) => f.owner.owner_type === 'corporation' && f.owner.corporation_name && f.owner.corporation_name !== f.owner.legal_name ? `${f.owner.corporation_name} (${f.owner.legal_name})` : f.owner.legal_name;
const dateOr = (d: string | null | undefined, fallback: string) => (d ? when(`${d.slice(0, 10)}T12:00:00Z`, false) : fallback);

function scheduleA(s: OwnerSchedule): Block {
  return { t: 'table', kv: true, head: ['Item', `Vehicle no. ${s.vehicle_number}`], rows: [
    ['Schedule number', s.schedule_number],
    ['Year, make, model, colour', vehicleLine(s)],
    ['VIN, plate, odometer (km)', `${s.vin}, ${s.plate ?? 'plate to come'}, ${s.odometer_km?.toLocaleString('en-CA') ?? 'to be recorded'}`],
    ['Held by', l(s.held_by)],
    ['Status', l(s.title_status)],
    ['Finance Party (lender or lessor)', s.finance_party_name ?? 'None'],
    ["Finance Party's written permission", l(s.finance_permission)],
    ['Management Mode', l(s.management_mode)],
    ['Onboarding Method', l(s.onboarding_method)],
    ['Insurance Fee and Tracker Fee per month', `${money(s.insurance_fee_cents)} and ${money(s.tracker_fee_cents)}, plus HST`],
    ['Install Fee', `${money(s.install_fee_cents)}, plus HST`],
    ['Revenue Share', pct(s.revenue_share_bps)],
    ['Enrollment Date', dateOr(s.enrollment_date, 'The date CarmaCars confirms in writing')],
    ['Special terms', s.special_terms ?? 'None']
  ] };
}
function schedule1(s: OwnerSchedule): Block {
  return { t: 'table', kv: true, head: ['Item', `Vehicle no. ${s.vehicle_number}`], rows: [
    ['Year, make, model, colour', vehicleLine(s)],
    ['VIN and plate', `${s.vin}, ${s.plate ?? 'plate to come'}`],
    ['Status', l(s.title_status)],
    ['Finance Party (lender or lessor)', s.finance_party_name ?? 'None'],
    ['Finance Party Permission', s.finance_permission === 'not_obtained' ? "Not obtained: Owner proceeds at Owner's sole risk" : l(s.finance_permission)],
    ['Onboarding Method', l(s.onboarding_method)],
    ["Owner's Lien", l(s.owners_lien)],
    ['Special terms', s.special_terms ?? 'None']
  ] };
}

export interface SignedBy { owner?: SignatureRow; carmacars?: SignatureRow; initials?: string; others?: SignatureRow[] }

function signatureRows(f: OwnerAgreementFacts, s?: SignedBy): SignatureRow[] {
  const ownerParty = f.owner.owner_type === 'corporation' ? `Owner (corporation), ${f.owner.signing_officer_title ?? 'signing officer'}` : 'Owner (individual)';
  // every Owner named in the Title Schedule signs, each with their own link (0053)
  const others = (f.cosigners ?? []).map((c) => s?.others?.find((o) => o.name === c.name) ?? { party: 'Owner', name: c.name, signature: '', when: '' });
  return [
    s?.owner ?? { party: ownerParty, name: f.owner.signer_name, signature: '', when: '' },
    ...others,
    s?.carmacars ?? { party: 'CarmaCars', name: [f.company.signing_officer_name, f.company.signing_officer_title].filter(Boolean).join(', '), signature: others.length ? 'Applied when the last Owner signs' : 'Applied when the Owner signs', when: '' }
  ];
}

export function documentBlocks(f: OwnerAgreementFacts, key: PacketKey, signed?: SignedBy): Block[] {
  const ea = agreement(f, 'enrollment');
  const ta = agreement(f, 'title_holding');
  const o = f.owner;
  // as the source text names it: "18122211 Canada Inc., operating as CarmaCars and CarmaCars.ca"
  const company = `${companyParty(f.company.legal_name, f.company.trade_name || 'CarmaCars')} and CarmaCars.ca`;
  const notice = [f.company.address, f.company.email].filter(Boolean).join(', ') || 'The email address on this page';
  const ownerAddress = [o.address, o.email, phone(o.phone), o.hst_number ? `HST ${o.hst_number}` : 'No HST number'].filter(Boolean).join('; ');
  if (key === 'enrollment') {
    const schedules = f.schedules.filter((s) => !s.is_additional);
    return [
      { t: 'title', text: 'CarmaCars Vehicle Enrollment Agreement' },
      { t: 'h2', text: 'Cover summary' },
      { t: 'p', text: 'This page is a summary. The rest governs.' },
      { t: 'table', kv: true, head: ['Party', 'Details'], rows: [
        ['Agreement number', ea?.agreement_number ?? ''],
        ['CarmaCars', company],
        ['CarmaCars notice address', notice],
        ['Owner (legal name)', o.legal_name],
        ["Owner's corporation, if any", o.corporation_name ? `${o.corporation_name}, corporation no. ${o.corporation_number ?? 'to come'}` : 'None'],
        ['Owner address, email, phone, HST number', ownerAddress],
        ['Payout method and details', o.payout ?? 'Given in the owner portal before the first payout'],
        ['Agreement Date', dateOr(ea?.agreement_date, 'The date the Owner signs')]
      ] },
      { t: 'table', kv: true, head: ['Topic', 'Summary'], rows: [
        ['Fees (4)', 'Set per Vehicle. Due every month, rented or not.'],
        ['Earnings (8)', 'Owner Revenue less the Revenue Share, paid monthly.'],
        ['Own use (9)', 'Free when the Vehicle is not booked.'],
        ['Damage (10)', 'Approved shops only. No pay for downtime.'],
        ['Leaving (12)', 'No minimum term. Any Vehicle may exit on notice.']
      ] },
      { t: 'h2', text: 'The Agreement' },
      ...markdown(ENROLLMENT_ARTICLES, {}),
      { t: 'h2', text: 'Signatures' },
      { t: 'signatures', rows: signatureRows(f, signed) },
      { t: 'p', text: 'Each corporate signatory has authority to bind the corporation.' },
      { t: 'table', kv: true, head: ['The Owner confirms', 'Initials'], rows: CONFIRMATIONS.map((c) => [c.text, signed?.initials ?? '']) },
      { t: 'h2', text: 'Schedule A: Vehicle Schedule' },
      { t: 'p', text: `Vehicle Schedule to the Enrollment Agreement ${ea?.agreement_number ?? ''} between CarmaCars and ${ownerLine(f)} (the Owner). It has one entry, as below, for each Vehicle.` },
      ...schedules.map(scheduleA),
      { t: 'h2', text: 'Schedule B: Standard numbers and onboarding costs' },
      ...markdown(ENROLLMENT_SCHEDULE_B, {})
    ];
  }
  if (key === 'title_holding') {
    const schedules = f.schedules.filter((s) => s.management_mode !== 'turo_only');
    return [
      { t: 'title', text: 'CarmaCars Vehicle Title-Holding and Lease Agreement' },
      { t: 'h2', text: 'Cover summary' },
      { t: 'p', text: 'This page is a summary. The rest governs.' },
      { t: 'table', kv: true, head: ['Party', 'Details'], rows: [
        ['Agreement number', ta?.agreement_number ?? ''],
        ['CarmaCars', company],
        ['Owner (legal name)', o.legal_name],
        ['Owner Corporation, if any', o.corporation_name ? `${o.corporation_name}, corporation no. ${o.corporation_number ?? 'to come'}` : 'None'],
        ['Date of this Agreement', dateOr(ta?.agreement_date, 'The date the Owner signs')]
      ] },
      { t: 'table', kv: true, head: ['Topic', 'Summary'], rows: [
        ['Nominee only (4)', 'CarmaCars holds each registration for the Owner, who keeps all equity.'],
        ['Lenders (7)', 'The Owner needs written permission and bears every consequence.'],
        ['Return (11)', "A Vehicle's registration moves back when it exits."]
      ] },
      { t: 'h2', text: 'The Agreement' },
      ...markdown(TITLE_ARTICLES, {}),
      { t: 'h2', text: 'Signatures' },
      { t: 'signatures', rows: signatureRows(f, signed) },
      { t: 'p', text: "An individual and that individual's Owner Corporation both sign." },
      { t: 'h2', text: 'Schedule 1: Title Schedule' },
      { t: 'p', text: `Title Schedule to the Title-Holding and Lease Agreement ${ta?.agreement_number ?? ''} between CarmaCars and ${ownerLine(f)} (the Owner). It has one entry, as below, for each Vehicle, numbered as in the Vehicle Schedule.` },
      ...schedules.map(schedule1)
    ];
  }
  const added = unsigned(f).filter((s) => s.is_additional);
  return [
    { t: 'title', text: 'CarmaCars Additional Vehicle Schedule' },
    { t: 'p', text: `Additional Vehicle Schedule to the Enrollment Agreement ${ea?.agreement_number ?? ''}${ta ? ` and the Title Agreement ${ta.agreement_number}` : ''} between CarmaCars and ${ownerLine(f)} (the Owner). The Vehicles below are added to both agreements, or to the Enrollment Agreement alone if Turo-Only. Schedule 1 and Forms A to D of the Title Agreement apply to each of them, and the Owner repeats the Form C acknowledgments for each one that is Financed or Leased. Nothing else changes.` },
    ...added.flatMap((s) => [{ t: 'h3', text: `Vehicle no. ${s.vehicle_number}: Schedule A entry` } as Block, scheduleA(s),
      ...(s.management_mode !== 'turo_only' ? [{ t: 'h3', text: `Vehicle no. ${s.vehicle_number}: Schedule 1 entry` } as Block, schedule1(s)] : [])]),
    { t: 'h2', text: 'Signatures' },
    { t: 'signatures', rows: signatureRows(f, signed) }
  ];
}
