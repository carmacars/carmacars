// The owner pipeline (r50, migration 4511): one stage tracker per owner and car. The database decides every stage
// (app.owner_stage_track); this words it for the viewer and picks the one action they may take. Pure: unit-tested in
// model.test.ts.

export type StageCode = 'application' | 'terms' | 'incorporate' | 'agreements' | 'documents' | 'transfer' | 'registration' | 'fleet_policy' | 'inspection' | 'listed';
export type StageState = 'done' | 'current' | 'todo' | 'not_needed';
export type Actor = 'owner' | 'sales' | 'admin' | 'fleet';
export type Viewer = 'owner' | 'sales' | 'staff' | 'admin';
export type Route = 'transfer' | 'co_registrant' | 'lease' | 'lease_new_corporation';

export interface StageAction { label: string; href?: string | null; op?: 'appointment' | 'visited' | 'inspected' | 'nudge' | 'insure'; external?: boolean; provider?: string }
export interface StageItem { label: string; done: boolean; kind?: string; state?: string; who?: string; href?: string }
export interface Stage {
  code: StageCode; label: string; state: StageState; actor: Actor; items: StageItem[];
  override: { status: string; note: string; at: string } | null;
  action: Partial<Record<'owner' | 'staff' | 'admin' | 'fleet', StageAction>> | null;
  blockers: string[]; bring: string | null; where: string | null; where_url: string | null; expected: string; call_script: string;
  owner_text: string; staff_text: string;
}
export interface Track {
  vehicle_id: string; name: string; plate: string | null; owner_id: string; owner_name: string; route: Route; route_label: string; method: string;
  stages: Stage[]; current: Stage | null; stage: StageCode | null; actor: Actor | null; done: number; total: number;
  stage_since: string | null; days_in_stage: number | null; last_nudge_at: string | null; nudges: number; fees_payer: string;
  uvip_needed: boolean; ssc_needed: boolean; appointment_at: string | null; appointment_place: string | null;
}
export interface Stages {
  viewer: Viewer; owner_id: string; agent?: string; can_override: boolean; can_nudge: boolean; can_record: boolean; stall_days: number; finder_url: string;
  incorporation: { usable: boolean; provider: string }; cars: Track[];
}
export interface BoardCar {
  vehicle_id: string; owner_id: string; owner_name: string; first_name: string; phone: string | null; email: string | null; car: string; plate: string | null;
  route: Route; route_label: string; stage: StageCode; stage_label: string; actor: Actor | null; days_in_stage: number; stage_since: string; stalled: boolean;
  next_action: string; salesperson: string | null; last_nudge_at: string | null; nudges: number; has_login: boolean;
}
export interface Board { viewer: 'admin' | 'staff' | 'sales'; stall_days: number; agent: string; stages: Array<{ code: StageCode; label: string; call_script: string; expected: string }>; cars: BoardCar[] }

export const ACTOR_WORDS: Record<Actor, string> = { owner: 'the owner', sales: 'Sales', admin: 'an Admin', fleet: 'Fleet' };
export const STATE_WORDS: Record<StageState, string> = { done: 'Done', current: 'Now', todo: 'Later', not_needed: 'Not needed' };

/** Who acts on the current stage, in the viewer's words: "You" for the one whose turn it is. */
export function waitsOn(actor: Actor | null, viewer: Viewer): string {
  if (!actor) return 'Nothing waiting';
  if (viewer === 'owner') return actor === 'owner' ? 'Your turn' : 'With CarmaCars';
  if (viewer === 'admin' && (actor === 'admin' || actor === 'fleet')) return actor === 'admin' ? 'Your turn (Admin)' : 'Fleet';
  if (viewer === 'staff' && actor === 'fleet') return 'Your turn (Fleet)';
  return `Waiting on ${ACTOR_WORDS[actor]}`;
}

/** The one action of a stage for this viewer: the owner's when it is theirs; staff's (nudge, record) otherwise. Admins may
 *  take Fleet's action too. null when the viewer has nothing to press. */
export function actionFor(s: Stage, viewer: Viewer): StageAction | null {
  const a = s.action;
  if (!a || s.state !== 'current') return null;
  if (viewer === 'owner') return s.actor === 'owner' ? a.owner ?? null : null;
  if (viewer === 'admin') return a.admin ?? a.fleet ?? a.staff ?? null;
  if (viewer === 'staff') return a.fleet ?? a.staff ?? null;
  // sales: nudge or help, never an Admin's or Fleet's action
  return a.staff && (a.staff.op === 'nudge' || a.staff.op === 'appointment') ? a.staff : null;
}

/** A link of an action for a portal: {base} is /admin or /staff. */
export function hrefFor(href: string | null | undefined, base: '/admin' | '/staff'): string | null {
  return href ? href.replace('{base}', base) : null;
}

/** The call script of a stage with the owner's first name, the car, the agent and what is missing. */
export function fillScript(script: string, v: { first_name: string; car: string; agent: string; missing?: string }): string {
  return script.replace(/\{\{first_name\}\}/g, v.first_name || 'there').replace(/\{\{car\}\}/g, v.car).replace(/\{\{agent\}\}/g, v.agent || 'CarmaCars')
    .replace(/\{\{missing\}\}/g, v.missing || 'a few documents');
}

/** "3 days", "today" */
export function daysWords(n: number | null): string {
  if (n === null || n === undefined) return '';
  return n <= 0 ? 'today' : n === 1 ? '1 day' : `${n} days`;
}

/** The board's columns: the stages in order, each with its cars (most days in stage first, as the database sorts them). */
export function columns(b: Board): Array<{ code: StageCode; label: string; cars: BoardCar[] }> {
  return b.stages.filter((s) => s.code !== 'application' || b.cars.some((c) => c.stage === 'application'))
    .map((s) => ({ code: s.code, label: s.label, cars: b.cars.filter((c) => c.stage === s.code) }));
}

/** The progress line of a track: "4 of 9 done. Now: Ownership transfer, your turn." */
export function progressLine(t: Track, viewer: Viewer): string {
  const c = t.current;
  if (!c) return `All ${t.total} steps done.`;
  return `${t.done} of ${t.total} done. Now: ${c.label}, ${waitsOn(c.actor, viewer).toLowerCase()}.`;
}

/** The documents an owner can upload on a car's page, from the current track (route and stage). */
export function uploadKinds(t: Track | null): string[] {
  if (!t) return [];
  const docs = t.stages.find((s) => s.code === 'documents')?.items.map((i) => i.kind).filter((k): k is string => !!k) ?? [];
  const transfer = t.stages.find((s) => s.code === 'transfer');
  const extra = transfer ? transfer.items.map((i) => i.kind).filter((k): k is string => !!k) : [];
  const reg = t.stages.some((s) => s.code === 'registration') ? ['new_registration'] : [];
  return [...new Set([...docs, ...extra, ...reg])];
}

/** The upload tile of each document kind on the owner's car page. */
export const UPLOAD_TEXT: Record<string, { title: string; hint: string }> = {
  owner_id: { title: 'Driver\'s licence', hint: 'Both sides, readable. The licence of the person (or signing officer) who goes to ServiceOntario.' },
  ownership_permit: { title: 'Ownership permit', hint: 'Both sides, flat and readable. Photos or a PDF.' },
  owner_insurance_proof: { title: 'Your insurance', hint: 'Your current insurance card. Keep your insurance until we confirm in writing.' },
  finance_party_permission: { title: 'Lender or lessor permission', hint: 'If your car is financed or leased: their written permission.' },
  lien_payout_letter: { title: 'Lender\'s payout letter', hint: 'If your car is financed: the letter from your lender with the payout amount.' },
  corporate_documents: { title: 'Corporate documents', hint: 'The certificate or articles of incorporation and proof of who signs for the corporation.' },
  uvip: { title: 'Used Vehicle Information Package', hint: 'From ServiceOntario (online or at the counter). A photo or the PDF.' },
  safety_certificate: { title: 'Safety Standards Certificate', hint: 'From a licensed inspection station. A photo or the PDF.' },
  new_registration: { title: 'New ownership permit', hint: 'After the ServiceOntario visit: both sides of the new permit.' }
};
