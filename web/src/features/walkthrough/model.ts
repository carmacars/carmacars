// The rental walkthrough (migration 0291): what the renter reads at each step of their rental, worked out from what the
// database says is done (app.rental_walkthrough) and the booking's own facts. No rule and no amount is made here: every
// figure is one the booking already stores. Pure, so model.test.ts covers it.

export type Stage = 'before' | 'pickup' | 'road' | 'return';
export type StepKey = 'licence' | 'sign' | 'pay' | 'deposit' | 'bring' | 'meet' | 'inspect' | 'own_photos' | 'rules' | 'help' | 'return_prep' | 'checkin' | 'deposit_back';
export interface DbStep { key: StepKey; stage: Stage; kind: 'task' | 'read'; done: boolean; at?: string | null; needed?: boolean }
export interface Walk { enabled: boolean; booking_id: string; stage?: Stage; status?: string; steps?: DbStep[]; done?: number; total?: number; read?: number; of?: number }

export const STAGES: Array<{ key: Stage; title: string; short: string }> = [
  { key: 'before', title: 'Before pickup', short: 'Before' },
  { key: 'pickup', title: 'At pickup', short: 'Pickup' },
  { key: 'road', title: 'On the road', short: 'Driving' },
  { key: 'return', title: 'The return', short: 'Return' }
];

export interface Facts {
  number: string; status: string; pickupWhen: string; returnWhen: string; pickupPlace: string | null; returnPlace: string | null;
  delivery: boolean; depositText: string | null; cardLast4: string | null; kmTotal: number | null; overageText: string | null;
  prepaidFuel: boolean; phone: string | null; roadside: string | null; mapsPickup: string | null; mapsReturn: string | null; handedOver: boolean; checkedIn: boolean;
}
export interface View {
  key: StepKey; stage: Stage; title: string; body: string; points: string[]; state: 'done' | 'now' | 'todo';
  /** a task's own page; a step to read has "Got it" instead */
  cta?: { href: string; label: string }; read: boolean; icon: string;
}

const path = (n: string, sub = '') => `/account/bookings/${encodeURIComponent(n)}${sub ? `/${sub}` : ''}`;

function copy(k: StepKey, f: Facts, s: DbStep): Omit<View, 'key' | 'stage' | 'state' | 'read'> {
  const pending = ['requested', 'offered'].includes(f.status);
  switch (k) {
    case 'licence': return { icon: 'id', title: 'Upload your licence', body: 'A photo of the front and back of each driver\'s licence, and a selfie. We check it before pickup: the car is released only to a verified driver.',
      points: [], cta: s.done ? undefined : { href: path(f.number, 'verify'), label: 'Add your licence' } };
    case 'sign': return { icon: 'doc', title: 'Sign the rental agreement', body: 'Read it on your phone and sign with your finger. Every driver signs their own part.',
      points: [], cta: s.done || pending ? undefined : { href: path(f.number, 'sign'), label: 'Sign the agreement' } };
    case 'pay': return { icon: 'card', title: pending ? 'Pay once we confirm' : 'Pay for the rental', body: pending ? 'We check the car and send you the full price. You pay only after you have seen it and said yes.' : 'Pay the total by card. Your receipt is under Documents.',
      points: [], cta: s.done || pending || f.status !== 'pending_payment' ? undefined : { href: path(f.number, 'pay'), label: 'Pay now' } };
    case 'deposit': return { icon: 'shield', title: s.needed === false ? 'No deposit on this rental' : 'The deposit hold, on the day',
      body: s.needed === false ? 'Nothing is held on your card for this rental.'
        : `On the morning of pickup we place a hold${f.depositText ? ` of ${f.depositText}` : ''} on ${f.cardLast4 ? `the card ending ${f.cardLast4}` : 'your card'}. It is not a charge: it is released after the return.`,
      points: [] };
    case 'bring': return { icon: 'key', title: 'What to bring', body: 'The person collecting the car brings:',
      points: ['Your original driver\'s licence (a photo is not enough)', f.cardLast4 ? `The card ending ${f.cardLast4}` : 'The credit card in your name', 'Your phone, to sign the condition report'] };
    case 'meet': return { icon: 'pin', title: f.delivery ? 'We bring the car to you' : 'Where we meet', body: `${f.pickupWhen}${f.pickupPlace ? `, ${f.pickupPlace}` : ''}. A person from our team meets you with the car: there is no counter and no line. Please be on time; call us if you are running late.`,
      points: [], cta: f.mapsPickup ? { href: f.mapsPickup, label: 'Open in maps' } : undefined };
    case 'inspect': return { icon: 'camera', title: 'Walk around the car with us', body: 'Before you drive off we go around the car together. We photograph every side, the wheels, the inside, the kilometres and the fuel, and mark any scratch or dent on the diagram. You check it and sign the condition report on your phone.',
      points: ['Point out anything we missed: it goes on the report, so it is never charged to you', 'You get the photo report by email right after'], cta: s.done ? { href: path(f.number, 'condition-report'), label: 'See the photo report' } : undefined };
    case 'own_photos': return { icon: 'phone', title: 'Take your own photos too', body: 'A quick walk-around video or a few photos on your phone, at pickup and again at the return, with the time on them. It takes a minute and settles any question later.',
      points: [] };
    case 'rules': return { icon: 'route', title: 'While you have the car', body: 'The short version of your agreement:',
      points: [f.kmTotal ? `${f.kmTotal.toLocaleString('en-CA')} km are included${f.overageText ? `; each km over is ${f.overageText}` : ''}` : 'The kilometres included are on your agreement',
        f.prepaidFuel ? 'Fuel is prepaid: return it at any level' : 'Return it with the same fuel level as at pickup', 'No smoking or vaping in the car',
        'Highway 407 tolls, parking and camera tickets during your rental are charged to you, as your agreement says', 'Only the drivers on the agreement may drive'] };
    case 'help': return { icon: 'alert', title: 'If something goes wrong', body: 'Stay safe first. Then tell us right away, before any repair or tow.',
      points: [f.roadside ? `Roadside help, 24 hours: ${f.roadside}` : 'Roadside help: call us, day and night', 'An accident: call the police if anyone is hurt, take photos, and get the other driver\'s details', f.phone ? `Our team: ${f.phone}, or message us on your booking` : 'Our team: message us on your booking'],
      cta: f.status === 'on_rent' ? { href: `${path(f.number)}?ask=problem#messages`, label: 'Report a problem' } : undefined };
    case 'return_prep': return { icon: 'clock', title: 'Before you bring it back', body: `Return by ${f.returnWhen}${f.returnPlace ? `, ${f.returnPlace}` : ''}. Need more time? Ask to extend before then.`,
      points: [f.prepaidFuel ? 'Fuel is prepaid: no need to fill up' : 'Fill the tank to the level it had at pickup', 'Take your things out: check the glovebox, the trunk and under the seats', 'Remove any garbage, so no cleaning is charged'],
      cta: f.status === 'on_rent' ? { href: path(f.number, 'extend'), label: 'Ask for more time' } : undefined };
    case 'checkin': return { icon: 'camera', title: 'The check-in', body: 'We go around the car with you again: the same photos, the kilometres and the fuel. You see the difference from the pickup on your phone.',
      points: [], cta: s.done ? { href: path(f.number, 'condition-report'), label: 'See the photo report' } : undefined };
    case 'deposit_back': return { icon: 'shield', title: 'Your deposit back', body: 'Once the car is back and checked, the hold is released. Your bank shows it again within a few business days. Any toll or ticket that arrives later is charged with a receipt.',
      points: [] };
  }
}

/** Each step for the page: done, the one to do now, or later. The "now" step is the first one not done in the stages up to the trip's. */
export function walkView(w: Walk, f: Facts): { views: View[]; now: View | null; stage: Stage; done: number; total: number } {
  const stage = w.stage ?? 'before';
  const upTo = STAGES.findIndex((x) => x.key === stage);
  const steps = (w.steps ?? []).filter((s) => !(s.key === 'deposit' && s.needed === false && !s.done));
  let nowSet = false;
  const views: View[] = steps.map((s) => {
    const due = STAGES.findIndex((x) => x.key === s.stage) <= upTo;
    let state: View['state'] = s.done ? 'done' : 'todo';
    if (!s.done && due && !nowSet) { state = 'now'; nowSet = true; }
    return { key: s.key, stage: s.stage, state, read: s.kind === 'read', ...copy(s.key, f, s) };
  });
  // nothing due is open: the next step still to come is the one to read now
  if (!nowSet) { const n = views.find((v) => v.state === 'todo'); if (n) n.state = 'now'; }
  return { views, now: views.find((v) => v.state === 'now') ?? null, stage, done: views.filter((v) => v.state === 'done').length, total: views.length };
}
