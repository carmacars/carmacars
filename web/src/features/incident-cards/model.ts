// The incident card (release 34, section B; migration 0813; one generic card since 1150): what the page prints. Pure, so the
// unit tests and the pages use the same words. No amount of money ever appears on a card (no premium, no deductible), and
// no car, plate, VIN, renter or booking: the same card goes in every car.
export interface CardCar { vehicle_id: string; year: number | null; make: string | null; model: string | null; plate: string | null; vin: string | null }
export interface CardPolicy { insurer_name: string; policy_number: string; effective_on: string; expires_on: string; named_insured: string; claims_phone: string | null; expired: boolean; slip_document_id: string | null; slip_mime: string | null }
export interface CardData {
  company: { trade_name: string; support_phone: string | null; roadside_phone: string | null; incident_line: string | null };
  policy: CardPolicy | null;
  /** the fleet (0813 still returns it; the generic card does not print it) */ cars?: CardCar[];
}

export const carTitle = (c: Pick<CardCar, 'year' | 'make' | 'model'>) => [c.year, c.make, c.model].filter(Boolean).join(' ') || 'Car';

/** The page the QR code opens (1150): sign in, then the digital incident card of the renter's booking in progress. */
export const reportPath = '/incident';

/** The steps, in order. Support and roadside numbers are the ones in settings; a step that needs a number we do not have is left out. */
export function steps(d: Pick<CardData, 'company'>): string[] {
  const phone = d.company.support_phone;
  const road = d.company.roadside_phone;
  return [
    'Safety first: stop in a safe place, turn on your hazard lights, and get everyone out of danger.',
    'If anyone is hurt, call 911.',
    'Take photos of all the cars, the plates, the damage and the scene.',
    'Exchange name, phone, licence, plate and insurance details with the other driver. Do not admit fault.',
    phone ? `Call or text ${d.company.trade_name} support: ${phone}.` : `Call or text ${d.company.trade_name} support.`,
    ...(road && road !== phone ? [`Roadside help for a breakdown: ${road}.`] : []),
    'Report it in the app with the QR code: it opens your digital incident card. Do not leave the car unlocked or unattended.'
  ];
}

/** The three coverage options a renter can have (bookings.coverage_option 1 to 3; option 4, insurance included with the car,
 *  is for insurer-paid replacement rentals and is not on the card), each with what to show the other driver and the police. */
export interface CoverageOption { option: 1 | 2 | 3; title: string; show: string }
export const COVERAGE_OPTIONS: CoverageOption[] = [
  { option: 1, title: 'Option 1: your own auto insurance (OPCF 27)',
    show: 'Show the insurance slip on this card and your own insurance pink slip. Your insurer and policy number are on your digital card. Call your insurer to report it.' },
  { option: 2, title: 'Option 2: credit card rental coverage',
    show: 'Show the insurance slip on this card. The card you paid with covers damage to this car: the card is named on your digital card. Call the number on the back of the card to open a claim.' },
  { option: 3, title: 'Option 3: the CarmaCars Protection Plan',
    show: 'Show the insurance slip on this card. The Protection Plan provider and your policy number are on your digital card. Open a claim with the provider.' }
];
export const coverageLead = 'Your option is on your booking. Scan the QR code to see it, with your proof.';

export const slipKind = (mime: string | null): 'image' | 'pdf' | null => (mime?.startsWith('image/') ? 'image' : mime === 'application/pdf' ? 'pdf' : null);

/** Cards a Letter sheet: two, one above the other, each 7.5 x 4.75 in with crop marks. */
export const CARDS_PER_SHEET = 2;
