// r50 hotfix 2: the demo portals for staff. Every staff member (and the Admins) open a renter portal and an owner portal
// with made-up data to see each process as the customer sees it, stage by stage. Nothing here reads or writes the
// database: the data is below, the buttons only say what would happen. Pure: the pages and the unit test share it.
import type { Milestone } from '@/components/portal-ui/Milestones';

export interface DemoStage { key: string; label: string; status: string; badge: string; next: { title: string; note: string; cta: string };
  /** what the renter or owner gets at this stage (emails, texts, alerts) */ notices: string[] }

export const DEMO_BOOKING = { number: 'DEMO-1042', car: '2024 Mercedes-Benz C 300', colour: 'Polar White', renter: 'Jordan Sample', days: 4,
  rentalCents: 52000, feesCents: 7500, hstCents: 7735, depositCents: 50000, place: '1940 Eglinton Ave E, Toronto' };

export const RENTER_STAGES: DemoStage[] = [
  { key: 'requested', label: 'Request sent', status: 'requested', badge: 'Requested', next: { title: 'We are checking the car and the dates', note: 'You hear from us within the hour, by email and text.', cta: 'Message us' },
    notices: ['Email: Your request is in', 'Text: We got your request'] },
  { key: 'offered', label: 'Offer', status: 'offered', badge: 'Offer ready', next: { title: 'Approve your offer', note: 'The price, the deposit and the coverage. The offer holds for 24 hours.', cta: 'See the offer' },
    notices: ['Email: Your offer is ready', 'Text: Your offer, with its link'] },
  { key: 'sign', label: 'Sign and pay', status: 'pending_payment', badge: 'Sign and pay', next: { title: 'Sign and pay to reserve the car', note: 'The agreement first, then the card payment. The deposit is a hold, not a charge.', cta: 'Sign and pay' },
    notices: ['Email: Sign and pay to reserve your car', 'Reminder text after 6 hours'] },
  { key: 'confirmed', label: 'Confirmed', status: 'confirmed', badge: 'Confirmed', next: { title: 'Add your licence and insurance', note: 'Licence photos, a selfie and your proof of insurance, before pickup day.', cta: 'Upload now' },
    notices: ['Email: Booking confirmed, with the receipt and the agreement', 'Push: Get your pickup reminders'] },
  { key: 'pickup', label: 'Pickup day', status: 'confirmed', badge: 'Pickup today', next: { title: 'Pick up your car today', note: 'Bring your original licence and the card you paid with. The walk-around takes about 10 minutes.', cta: 'Directions' },
    notices: ['Text: Pickup reminder in the morning', 'Email: Pickup details and the walkthrough'] },
  { key: 'on_rent', label: 'On the road', status: 'on_rent', badge: 'On rent', next: { title: 'Enjoy the drive', note: 'Return it on time with the same fuel. Extend or report a problem from here.', cta: 'Extend' },
    notices: ['Text: Return reminder the day before', 'Email: Your accident card'] },
  { key: 'returned', label: 'Returned', status: 'returned', badge: 'Returned', next: { title: 'Thanks for bringing it back', note: 'We check the car and release your deposit, usually within 3 business days.', cta: 'See the photos' },
    notices: ['Email: Car returned, with the photo report', 'Email: Deposit released'] },
  { key: 'closed', label: 'Closed', status: 'closed', badge: 'Closed', next: { title: 'Review your rental', note: 'Your final statement is ready. A review earns 100 Rewards points.', cta: 'Write a review' },
    notices: ['Email: Your final statement', 'Email: How did it go? (review request)'] }
];

const TRACK: Array<{ key: string; label: string; hint: string; from: number }> = [
  { key: 'offer', label: 'Approve the offer', hint: 'We check the car and send an offer with the price.', from: 2 },
  { key: 'sign-pay', label: 'Sign and pay', hint: 'The agreement and the payment reserve the car.', from: 3 },
  { key: 'verify', label: 'Licence and insurance', hint: 'Licence photos, a selfie and the proof of insurance.', from: 4 },
  { key: 'pickup', label: 'Pick up the car', hint: 'The walk-around with our team, about 10 minutes.', from: 5 },
  { key: 'return', label: 'Return the car', hint: 'Same fuel, on time. Photos in one minute.', from: 6 },
  { key: 'statement', label: 'Final statement', hint: 'The deposit released and every charge explained.', from: 7 }
];

/** The renter's step tracker at a demo stage (the index of RENTER_STAGES). */
export function renterTrack(stage: number): Milestone[] {
  let seen = false;
  return TRACK.map((t) => {
    const done = stage >= t.from;
    const state = done ? 'done' : seen ? 'later' : 'now';
    if (state === 'now') seen = true;
    return { key: t.key, label: t.label, state, hint: t.hint, yours: state === 'now' && ['offer', 'sign-pay', 'verify', 'pickup', 'return'].includes(t.key) && stage !== 0 } as Milestone;
  });
}

export const OWNER_STAGES: Array<{ key: string; label: string; owner: string; staff: string; expected: string }> = [
  { key: 'application', label: 'Application', owner: 'Tell us about your car: about 5 minutes.', staff: 'Sales reviews the application and calls the owner.', expected: 'Same day' },
  { key: 'terms', label: 'Terms', owner: 'Choose your plan: managed, or co-host.', staff: 'Sales explains the plans and the earnings estimate.', expected: '1 day' },
  { key: 'agreements', label: 'Agreements', owner: 'Read and sign the owner agreement in your portal.', staff: 'Nudge the owner to sign; an Admin countersigns.', expected: '1 to 2 days' },
  { key: 'documents', label: 'Documents', owner: 'Upload the ownership, the insurance and your ID.', staff: 'Check each document: accept, or reject with the reason.', expected: '1 day' },
  { key: 'transfer', label: 'Ownership transfer', owner: 'Book a ServiceOntario visit; bring the ownership and your ID.', staff: 'Help book the visit; record it once it is done.', expected: '2 to 5 days' },
  { key: 'registration', label: 'New registration', owner: 'Nothing to do: we register the car.', staff: 'Fleet records the new plate and permit.', expected: '1 day' },
  { key: 'fleet_policy', label: 'Fleet policy', owner: 'Nothing to do: we add the car to our insurance.', staff: 'Finance confirms the insurer added the car.', expected: '1 to 2 days' },
  { key: 'inspection', label: 'Inspection', owner: 'Bring the car to us, or we pick it up.', staff: 'Fleet inspects: damage, tires, warning lights, photos.', expected: '1 day' },
  { key: 'listed', label: 'Listed', owner: 'Your car is live: bookings and statements show here.', staff: 'Publish the car with its rates.', expected: 'Same day' }
];

/** The owner's onboarding tracker at a demo step (0 to 9: 9 is listed and earning). */
export function ownerTrack(step: number): Milestone[] {
  return OWNER_STAGES.map((s, i) => ({ key: s.key, label: s.label, state: i < step ? 'done' : i === step ? 'now' : 'later',
    hint: `${s.owner} Expected: ${s.expected}.`, yours: i === step && ['application', 'terms', 'agreements', 'documents', 'transfer', 'inspection'].includes(s.key) }));
}

export const DEMO_STATEMENT = { month: 'October', grossCents: 248000, shareCents: 74400, insuranceCents: 45000, trackerCents: 2500, payoutCents: 126100, days: 22, occupancy: 71 };
