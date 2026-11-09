// The digital incident card (1150: app.incident_digital, the page /incident the printed card's QR code opens). The signed-in
// renter or a driver named on the booking sees their booking in progress: the car and plate, the dates, the booking number,
// the drivers, the coverage option of the booking with its proof, the rental agreement, the steps and the numbers, and Report
// a problem. Several bookings in progress: a picker. None: the steps and the numbers only. Pure, for the page and the tests.
import { steps } from './model.ts';
import type { AccidentCardData } from '../accident-card/model.ts';

export interface DigitalBookingRow { booking_number: string; pickup_at: string; return_at: string; status: string; car: string | null; plate: string | null; role: 'renter' | 'driver' }
export type DigitalCard = AccidentCardData & {
  status: string; role: 'renter' | 'driver';
  drivers: Array<{ name: string; role: 'renter' | 'additional' }>;
  contract: { document_id: string; title: string; created_at: string } | null;
  proof: { document_id: string; mime: string | null } | null;
};
export interface IncidentDigital { company: AccidentCardData['company']; bookings: DigitalBookingRow[]; card: DigitalCard | null }

export type DigitalView =
  | { mode: 'none'; steps: string[] }
  | { mode: 'pick'; steps: string[]; bookings: DigitalBookingRow[] }
  | { mode: 'card'; steps: string[]; card: DigitalCard; others: DigitalBookingRow[] };

/** What the page shows: the card, a picker, or the generic steps and numbers only (never a booking that is not theirs: the
 *  database returns only the person's own). */
export function digitalView(d: IncidentDigital): DigitalView {
  const s = steps({ company: d.company });
  if (d.card) return { mode: 'card', steps: s, card: d.card, others: d.bookings.filter((b) => b.booking_number !== d.card!.booking_number) };
  if (d.bookings.length > 1) return { mode: 'pick', steps: s, bookings: d.bookings };
  return { mode: 'none', steps: s };
}

/** The proof the renter shows for their option, in words. */
export function proofWords(c: DigitalCard): string {
  switch (c.coverage.kind) {
    case 'own_policy': return c.proof ? 'Show your own insurance pink slip (below) and the insurance slip on the card in the car.' : 'Show your own insurance pink slip and the insurance slip on the card in the car.';
    case 'card': return 'Show the insurance slip on the card in the car. Damage to this car is claimed on the card you paid with.';
    case 'plan': return 'Show the insurance slip on the card in the car. Damage to this car is claimed with the Protection Plan provider.';
    default: return 'No coverage is confirmed on this booking: call us before you drive.';
  }
}

/** The digital card in the renter portal (the printed QR's /incident redirects here, through sign-in), for one booking. */
export const incidentHref = (booking?: string) => (booking ? `/account/incident?b=${encodeURIComponent(booking)}` : '/account/incident');
/** A document of the card (the agreement or the coverage proof), served after the database checks the person. */
export const incidentDocHref = (id: string) => `/account/incident/doc/${id}`;
/** Where /incident sends the browser: the portal page, keeping a valid booking number only. */
export function incidentRedirect(b: string | null | undefined): string {
  const n = (b ?? '').trim().toUpperCase();
  return /^[A-Z]{1,4}-[0-9A-Z]{1,12}$/.test(n) ? incidentHref(n) : incidentHref();
}
