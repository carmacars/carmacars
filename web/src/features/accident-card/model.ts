// The accident card of one booking (release 35, migration 0910: app.accident_card): the steps after an accident (the r34
// card's) and the coverage this booking uses, from the renter's own proof or the Protection Plan settings. Never the fleet
// policy. Pure: the card, the pages and the unit tests share the words.
import { steps as cardSteps, type CardData } from '../incident-cards/model.ts';

export type CoverageKind = 'own_policy' | 'card' | 'plan' | 'none';
export interface AccidentCoverage {
  kind: CoverageKind; option: number | null; confirmed: boolean;
  insurer_name: string | null; policy_number: string | null; policy_expiry: string | null;
  card_issuer: string | null; card_brand: string | null; card_last4: string | null; card_coverage_provider: string | null; cardholder_name: string | null;
  plan_provider: string | null; plan_policy_number: string | null; plan_claims_phone: string | null; plan_reference: string | null;
  /** 1010: the provider's claim page, and whether staff entered the renter's own policy number */ plan_claim_url?: string | null; plan_policy_entered?: boolean | null;
  proof_document_id: string | null;
}
export interface AccidentCardData {
  booking_id: string; booking_number: string; pickup_at: string; return_at: string; renter: string | null;
  company: CardData['company'];
  car: { vehicle_id: string; year: number | null; make: string | null; model: string | null; plate: string | null; vin: string | null };
  coverage: AccidentCoverage;
}

/** The steps, the same as the car's card. */
export const accidentSteps = (d: AccidentCardData): string[] => cardSteps({ company: d.company, policy: null, cars: [] });

/** The coverage block: its title, what to tell the insurer, and the lines to show. */
export function coverageBlock(c: AccidentCoverage): { title: string; lead: string; rows: Array<[string, string]> } {
  const rows = (xs: Array<[string, string | null | undefined]>): Array<[string, string]> => xs.filter((x): x is [string, string] => !!x[1]);
  if (c.kind === 'own_policy') return { title: 'Your own auto policy (OPCF 27)',
    lead: 'This rental is covered by your own auto insurance. Call your insurer to report the accident.',
    rows: rows([['Insurer', c.insurer_name], ['Policy number', c.policy_number], ['Policy expires', c.policy_expiry]]) };
  if (c.kind === 'card') return { title: 'Your credit card coverage',
    lead: 'This rental is covered by the rental coverage of the card you paid with. Call the number on the back of the card to open a claim.',
    rows: rows([['Card', [c.card_brand ?? c.card_issuer, c.card_last4 ? `ending ${c.card_last4}` : null].filter(Boolean).join(' ') || null],
      ['Issuer', c.card_issuer && c.card_issuer !== c.card_brand ? c.card_issuer : null], ['Coverage provider', c.card_coverage_provider], ['Cardholder', c.cardholder_name]]) };
  // 1010: the renter's own policy of the plan bought with the rental and the provider's claim page, never a CarmaCars policy
  if (c.kind === 'plan') return { title: 'Protection Plan',
    lead: `You bought the Protection Plan with this rental. Open a claim ${c.plan_claim_url ? 'on the claim page below' : 'with the provider'} with your policy number.`,
    rows: rows([['Provider', c.plan_provider], ['Your policy number', c.plan_policy_number ?? c.plan_reference], ['Claim page', c.plan_claim_url], ['Claims phone', c.plan_claims_phone]]) };
  return { title: 'Coverage', lead: 'No coverage is on this booking yet. Call us before you drive.', rows: [] };
}
