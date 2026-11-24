// Sign first, then cars (r50, migration 3800): the owner portal's one guided path. Six steps, in order: Profile, Sign
// the agreement, Add cars (each on Schedule A, confirmed by signature), Photos and inspection, Approved, Delivered. The
// facts come from the database (app.owner_sign_status); this only words them for the owner and picks the one next
// action. Pure: unit-tested in path.test.ts.

export interface SignMissing { code: 'profile' | 'master' | 'title_holding' | 'schedule'; who: 'owner' | 'carmacars'; label: string; vehicle_id?: string; number?: string }
export interface SignCar {
  vehicle_id: string; name: string; plate: string | null; status: string; onboarding_status: string | null; tier: string | null;
  schedule_number: string | null; vehicle_number: number | null; schedule_signed: boolean; scheduled: boolean; photos_done: boolean;
  approved: boolean; waiting_approval: boolean; delivered_on: string | null; delivered: boolean; gate: string | null;
}
export interface SignStatus {
  viewer: 'owner' | 'staff' | 'admin'; owner_id: string; name: string; email: string | null; has_login: boolean; fleet_supplier: boolean; sign_first: boolean;
  profile_missing: string[];
  master: { id: string; title: string; number: string; variant: string; status: 'draft' | 'sent' | 'signed'; signed_on: string | null } | null;
  title_holding: { number: string; status: string } | null;
  cars: SignCar[]; missing: SignMissing[]; owner_missing: SignMissing[]; last_reminder_at: string | null; can_remind: boolean;
}

export type PathCode = 'profile' | 'sign' | 'cars' | 'photos' | 'approved' | 'delivered';
export type PathState = 'done' | 'current' | 'todo';
export interface PathStep { code: PathCode; label: string; state: PathState; note: string; action: { label: string; href: string } | null }
export interface OwnerPath { steps: PathStep[]; current: PathStep | null; done: number }

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** The six steps for the owner, the current one first not done. null when sign first is off. */
export function ownerPath(s: SignStatus): OwnerPath | null {
  if (!s.sign_first) return null;
  const cars = s.cars;
  const unconfirmed = cars.filter((c) => c.scheduled && !c.schedule_signed);
  const masterSigned = s.master?.status === 'signed' && !s.owner_missing.some((m) => m.code === 'title_holding');
  const needPhotos = cars.filter((c) => !c.photos_done);
  const notApproved = cars.filter((c) => !c.approved);
  const notDelivered = cars.filter((c) => !c.delivered);
  const steps: Array<Omit<PathStep, 'state'> & { done: boolean }> = [
    { code: 'profile', label: 'Your profile', done: s.profile_missing.length === 0,
      note: s.profile_missing.length ? `Missing: ${s.profile_missing.join(', ')}.` : 'Your legal name, address and signing details: done.',
      action: { label: 'Complete my profile', href: '/owner/profile' } },
    { code: 'sign', label: s.master ? `Sign the ${s.master.title}` : 'Sign the agreement', done: masterSigned,
      note: masterSigned ? `Signed${s.master?.signed_on ? ` on ${s.master.signed_on}` : ''}. CarmaCars countersigned.`
        : s.master ? `${s.master.number}${s.title_holding && s.title_holding.status !== 'signed' ? ` with the Title-Holding and Lease Agreement ${s.title_holding.number}` : ''}: filled in from your profile. One signature, before any car comes over.`
        : 'Made from your profile as soon as it is complete.',
      action: { label: 'Read and sign', href: '/owner/sign' } },
    { code: 'cars', label: 'Add your cars', done: cars.length > 0 && unconfirmed.length === 0,
      note: !cars.length ? 'One at a time, or a list of VINs. Each car goes on Schedule A of your agreement.'
        : unconfirmed.length ? `${plural(unconfirmed.length, 'car')} on Schedule A to confirm with your signature: ${unconfirmed.map((c) => c.name).join(', ')}.`
        : `${plural(cars.length, 'car')} on Schedule A, confirmed. You can add more any time.`,
      action: !cars.length ? { label: 'Add my first car', href: '/list-your-car/apply' } : { label: 'Confirm my cars', href: '/owner/sign' } },
    { code: 'photos', label: 'Photos and inspection', done: cars.length > 0 && needPhotos.length === 0,
      note: needPhotos.length ? `Upload the ownership permit and photos of ${needPhotos.map((c) => c.name).join(', ')}.` : 'Received and checked.',
      action: needPhotos[0] ? { label: 'Upload photos', href: `/owner/vehicles/${needPhotos[0].vehicle_id}#photos` } : null },
    { code: 'approved', label: 'Approved', done: cars.length > 0 && notApproved.length === 0,
      note: notApproved.length ? 'CarmaCars checks each car and approves it, usually within 1 business day. Nothing to do on your side.' : 'Every car is approved.',
      action: null },
    { code: 'delivered', label: s.fleet_supplier ? 'Delivered' : 'On the road', done: cars.length > 0 && notDelivered.length === 0,
      note: notDelivered.length ? (s.fleet_supplier ? 'Hand each car over as agreed; its lease starts on the delivery date.' : 'The registry visit, the tracker and the fleet policy; then your car is live.')
        : s.fleet_supplier ? 'Every car is on the lease.' : 'Every car is live.',
      action: null }
  ];
  // the steps before the first one not done are done; that one is current
  const first = steps.findIndex((x) => !x.done);
  const out: PathStep[] = steps.map((x, i) => ({ code: x.code, label: x.label, note: x.note, action: i === first ? x.action : null,
    state: first === -1 || i < first ? 'done' : i === first ? 'current' : 'todo' }));
  return { steps: out, current: first === -1 ? null : out[first]!, done: first === -1 ? out.length : first };
}

/** What the Admin and staff pages say is missing, in their words: who it waits on. */
export function whoWaits(m: SignMissing): string {
  return m.who === 'owner' ? 'Waiting on the owner' : 'Waiting on CarmaCars';
}
