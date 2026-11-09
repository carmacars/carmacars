// The one Onboarding checklist (r34, migration 0823): the owner portal, the owner page of staff and Admin, and the staff
// portals read the same facts (app.onboarding_overview) and show them through these rules. Each step has one state
// (done, waiting on someone, blocked with the reason, not needed), says in plain words who it waits on, and has at most
// one next action, the one for the person looking. Pure: unit-tested in steps.test.ts.

export type Viewer = 'owner' | 'staff' | 'admin';
export type StepState = 'done' | 'waiting' | 'blocked' | 'not_needed';
export type Who = 'owner' | 'carmacars' | 'admin' | 'third_party';

export interface ChecklistRow { code: string; label: string; status: 'done' | 'open' | 'not_applicable'; waits_on: 'owner' | 'carmacars' | 'third_party' | null; owner_action: string | null; staff_action: string | null }
export interface OverviewCar {
  vehicle_id: string; name: string; plate: string | null; status: string; onboarding_status: string; mode: string | null;
  application_id: string | null; application_number: string | null; terms_pending: boolean;
  schedule: { number: string; signed: boolean } | null;
  checklist: ChecklistRow[];
  photos: { permit: number; waiting: number; rejected: number; approved: number; total: number; note: string | null };
  /** to_sign: forms waiting for the owner's signature on screen; changed: of them, signed once and changed since (r35, 1000) */
  forms: { due: boolean; needed: number; made: number; drafts: number; signed: number; missing: string[]; to_sign?: number; changed?: number };
  upfront: { number: string; status: string } | null;
}
export interface Overview {
  viewer: Viewer;
  owner: { id: string; name: string; type: string; fleet_supplier: boolean; missing: string[]; has_account: boolean; email?: string | null; phone?: string | null };
  trackers: boolean;
  cars: OverviewCar[];
}
export interface Action { label: string; href?: string }
export interface Step { code: string; label: string; state: StepState; who: Who | null; waiting: string | null; why: string | null; action: Action | null }
export interface CarSteps { vehicle_id: string; name: string; plate: string | null; steps: Step[]; next: Step | null; done: number; total: number }

/** Where the links of a view go: the owner portal, or the owner page of Admin or staff. */
export interface Base { viewer: Viewer; ownerHref: string; carHref: (vehicleId: string) => string; portal: '/owner' | '/admin' | '/staff' }

export function baseFor(viewer: Viewer, ownerId: string): Base {
  if (viewer === 'owner') return { viewer, ownerHref: '/owner', carHref: (v) => `/owner/vehicles/${v}`, portal: '/owner' };
  const portal = viewer === 'admin' ? '/admin' : '/staff';
  return { viewer, ownerHref: `${portal}/owners/${ownerId}`, carHref: (v) => `${portal}/vehicles/${v}`, portal };
}

const LABEL: Record<string, string> = {
  terms: 'Terms approved', documents: 'Ownership permit and photos', government_forms: 'Government forms (ServiceOntario)', signatures: 'Agreements signed',
  witnessed_forms: 'Form D (and Form C) signed with witnesses', upfront_payment: 'Upfront payment', registry_visit: 'Registry visit', tracker_install: 'Tracker installed',
  insurer_confirmation: 'Fleet insurance confirmed', photos: 'Listing photos', listing: 'Listed on the website'
};

/** Who a step waits on, in the viewer's words. */
export function whoText(who: Who | null, viewer: Viewer): string | null {
  if (!who) return null;
  if (viewer === 'owner') return { owner: 'Waiting on you', carmacars: 'Waiting on CarmaCars', admin: 'Waiting on CarmaCars', third_party: 'Waiting on another office (the registry or the insurer)' }[who];
  return { owner: 'Waiting on the owner', carmacars: 'Waiting on us (CarmaCars staff)', admin: 'Waiting on an Admin', third_party: 'Waiting on the registry or the insurer' }[who];
}

// a step that cannot start until another one is done
const NEEDS: Record<string, string[]> = {
  signatures: ['terms'], witnessed_forms: ['terms'], government_forms: ['terms'], upfront_payment: ['terms'],
  registry_visit: ['signatures', 'government_forms'], insurer_confirmation: ['registry_visit'], listing: ['insurer_confirmation', 'photos']
};

function act(code: string, car: OverviewCar, b: Base, ownerMissing: string[]): Action | null {
  const v = car.vehicle_id;
  if (b.viewer === 'owner') {
    switch (code) {
      case 'documents': return { label: car.photos.rejected > 0 ? 'Upload a new photo' : 'Upload the ownership permit', href: `/owner/vehicles/${v}#photos` };
      case 'signatures': return { label: 'Check and sign', href: '/owner/sign' };
      case 'witnessed_forms': return { label: 'Sign with your witnesses', href: '/owner/documents#ow-wit' };
      case 'government_forms':
        if (car.forms.drafts > 0) return ownerMissing.length ? { label: 'Complete your details', href: '/owner/profile' } : null;
        // r35 (1000): each government form is signed on screen first
        return (car.forms.to_sign ?? 0) > 0 ? { label: (car.forms.changed ?? 0) > 0 ? 'Sign the forms again' : 'Sign your government forms', href: `/owner/sign/forms/${v}` } : { label: 'Open your government forms', href: '/owner/documents#ow-forms' };
      case 'upfront_payment': return { label: 'Pay the upfront invoice', href: '/owner/invoices' };
      default: return null;
    }
  }
  const admin = b.viewer === 'admin';
  switch (code) {
    case 'terms': return admin ? { label: 'Review and approve the terms', href: car.application_id ? `/admin/applications/${car.application_id}` : `${b.ownerHref}?tab=terms` } : null;
    case 'documents': return car.photos.waiting > 0 ? { label: 'Check the photos', href: `${b.ownerHref}#photos` } : { label: 'Upload the ownership permit for the owner', href: `${b.ownerHref}#photos` };
    case 'signatures': return { label: 'Send the owner the signing link', href: `${b.ownerHref}#send-link` };
    case 'witnessed_forms': return { label: 'See Forms C and D', href: `${b.portal}/owner-forms` };
    case 'government_forms': return { label: car.forms.drafts > 0 ? 'See what the forms miss' : 'Open the government forms', href: `${b.ownerHref}#gov-forms` };
    case 'upfront_payment': return admin ? { label: 'Issue or record the upfront invoice', href: `${b.ownerHref}#ad-up` } : null;
    default: return { label: 'Open the car', href: b.carHref(v) };
  }
}

/** The steps of one car, for the viewer. */
export function carSteps(car: OverviewCar, o: Overview, b: Base = baseFor(o.viewer, o.owner.id)): CarSteps {
  const steps: Step[] = [];
  const intake = car.onboarding_status === 'intake';
  // the terms: not a checklist row; an Admin approves them (Approve on the application)
  steps.push({ code: 'terms', label: LABEL.terms!, state: intake ? 'waiting' : 'done', who: intake ? 'admin' : null, waiting: null, why: null, action: null });
  for (const r of car.checklist) {
    if (r.code === 'owner_details') continue;   // the owner's own step, once above the cars
    if (r.code === 'tracker_install' && !o.trackers) continue;
    let state: StepState = r.status === 'done' ? 'done' : r.status === 'not_applicable' ? 'not_needed' : 'waiting';
    let who: Who | null = state === 'waiting' ? (r.waits_on ?? 'carmacars') : null;
    let why: string | null = null;
    if (r.code === 'documents' && state !== 'not_needed') {
      if (car.photos.rejected > 0) { state = 'waiting'; who = 'owner'; why = car.photos.note ? `A photo was not accepted: ${car.photos.note}` : 'A photo was not accepted: upload a new one.'; }
      else if (car.photos.permit > 0 && car.photos.waiting > 0) { state = 'waiting'; who = 'carmacars'; why = 'Uploaded: CarmaCars checks it.'; }
      else if (car.photos.permit === 0) { state = 'waiting'; who = 'owner'; why = 'Both sides of the ownership permit, flat and readable.'; }
    }
    if (r.code === 'government_forms' && state !== 'not_needed') {
      if (!car.forms.due) { state = 'blocked'; who = null; why = 'Made by themselves once the terms are approved.'; }
      else if (car.forms.needed === 0) { state = 'not_needed'; who = null; }
      else if (car.forms.drafts > 0) { state = 'blocked'; who = 'owner'; why = car.forms.missing.length ? `Missing: ${car.forms.missing.join(', ')}.` : 'A value is missing on a form.'; }
      else if (car.forms.made >= car.forms.needed && (car.forms.to_sign ?? 0) > 0) {
        // r35 (1000): the step is done when every form is signed; a form changed after it was signed asks again
        state = 'waiting'; who = 'owner';
        why = (car.forms.changed ?? 0) > 0 ? 'A value on a form changed after it was signed: sign it again.'
          : `${car.forms.to_sign} of ${car.forms.needed} government form${car.forms.needed === 1 ? '' : 's'} to sign on screen.`;
      }
      else if (car.forms.made >= car.forms.needed) {
        state = 'done'; who = null;
        why = car.forms.signed >= car.forms.needed ? 'Signed on screen. Print them and sign them in ink at the registry visit.' : `${car.forms.made} filled in by themselves. Print them and sign them in ink for the registry visit.`;
      }
    }
    steps.push({ code: r.code, label: LABEL[r.code] ?? r.label, state, who, waiting: null, why, action: null });
  }
  // a step that waits on one not done yet is blocked, with the reason
  const byCode = new Map(steps.map((s) => [s.code, s]));
  for (const s of steps) {
    if (s.state !== 'waiting') continue;
    const before = (NEEDS[s.code] ?? []).map((c) => byCode.get(c)).filter((x): x is Step => !!x && (x.state === 'waiting' || x.state === 'blocked'));
    if (before.length) { s.state = 'blocked'; s.who = null; s.why = `First: ${before.map((x) => x.label.toLowerCase()).join(' and ')}.`; }
  }
  for (const s of steps) {
    s.waiting = s.state === 'waiting' ? whoText(s.who, b.viewer) : null;
    // one next action, for the person looking, on a step that waits on them (staff act for the owner too) or is blocked by a value they can add
    const mine = s.state === 'waiting' && (b.viewer === 'owner' ? s.who === 'owner' : s.who !== 'admin' || b.viewer === 'admin');
    const fix = s.state === 'blocked' && s.code === 'government_forms' && car.forms.due;
    const find = s.code === 'government_forms' && s.state === 'done';   // where the forms are, once made
    s.action = mine || fix || find ? act(s.code, car, b, o.owner.missing) : null;
  }
  const counted = steps.filter((s) => s.state !== 'not_needed');
  const next = steps.find((s) => s.state === 'waiting' && s.action) ?? steps.find((s) => s.state === 'waiting') ?? null;
  return { vehicle_id: car.vehicle_id, name: car.name, plate: car.plate, steps, next, done: counted.filter((s) => s.state === 'done').length, total: counted.length };
}

/** The owner's own step (their details), once above the cars. */
export function ownerStep(o: Overview, b: Base = baseFor(o.viewer, o.owner.id)): Step {
  const missing = o.owner.missing;
  if (!missing.length) return { code: 'owner_details', label: o.viewer === 'owner' ? 'Your details' : 'The owner\'s details', state: 'done', who: null, waiting: null, why: null, action: null };
  const action: Action = b.viewer === 'owner' ? { label: 'Complete your details', href: '/owner/profile' } : { label: 'Send the owner a link to finish them', href: `${b.ownerHref}#send-link` };
  return { code: 'owner_details', label: o.viewer === 'owner' ? 'Your details' : 'The owner\'s details', state: 'waiting', who: 'owner', waiting: whoText('owner', b.viewer), why: `Missing: ${missing.join(', ')}.`, action };
}

export const STATE_TEXT: Record<StepState, string> = { done: 'Done', waiting: 'To do', blocked: 'Blocked', not_needed: 'Not needed' };
