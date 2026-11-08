// The incident card (release 34, section B; migration 0813): what the page prints for one car. Pure, so the unit tests and the
// page use the same words. No amount of money ever appears on a card (no premium, no deductible).
export interface CardCar { vehicle_id: string; year: number | null; make: string | null; model: string | null; plate: string | null; vin: string | null }
export interface CardPolicy { insurer_name: string; policy_number: string; effective_on: string; expires_on: string; named_insured: string; claims_phone: string | null; expired: boolean; slip_document_id: string | null; slip_mime: string | null }
export interface CardData {
  company: { trade_name: string; support_phone: string | null; roadside_phone: string | null; incident_line: string | null };
  policy: CardPolicy | null;
  cars: CardCar[];
}

export const carTitle = (c: CardCar) => [c.year, c.make, c.model].filter(Boolean).join(' ') || 'Car';

/** The steps, in order. Support and roadside numbers are the ones in settings; a step that needs a number we do not have is left out. */
export function steps(d: CardData): string[] {
  const phone = d.company.support_phone;
  const road = d.company.roadside_phone;
  return [
    'Safety first: stop in a safe place, turn on your hazard lights, and get everyone out of danger.',
    'If anyone is hurt, call 911.',
    'Take photos of all the cars, the plates, the damage and the scene.',
    'Exchange name, phone, licence, plate and insurance details with the other driver. Do not admit fault.',
    phone ? `Call or text ${d.company.trade_name} support: ${phone}.` : `Call or text ${d.company.trade_name} support.`,
    ...(road && road !== phone ? [`Roadside help for a breakdown: ${road}.`] : []),
    'Report it in the app with the QR code. Do not leave the car unlocked or unattended.'
  ];
}

/** The page the QR code opens: the renter's bookings (the booking in progress has Report a problem). */
export const reportPath = '/account/bookings';

export const slipKind = (mime: string | null): 'image' | 'pdf' | null => (mime?.startsWith('image/') ? 'image' : mime === 'application/pdf' ? 'pdf' : null);
