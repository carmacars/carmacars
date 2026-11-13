// r43: the hiring and onboarding pipeline, one stage per person, in the order the owner reads it:
//   Applied > AI interview > Interview booked > Decision > (hired) Agreement to sign > Academy > WhatsApp groups > Waiting for approval > Onboarded.
// Pure: the Admin's Hiring pipeline, the Fleet portal and the unit tests share it.
import type { OnboardingRow } from './model.ts';

export type AppStage = 'applied' | 'ai' | 'booked' | 'decision';
export type StaffStage = 'agreement' | 'academy' | 'whatsapp' | 'approval' | 'onboarded';
export type Stage = AppStage | StaffStage;

export const STAGES: ReadonlyArray<{ key: Stage; label: string; hint: string }> = [
  { key: 'applied', label: 'Applied', hint: 'Scored on the server; below the bar waits for your review.' },
  { key: 'ai', label: 'AI interview', hint: 'Sent the interview link; waiting for them to take it or for the scoring.' },
  { key: 'booked', label: 'Interview booked', hint: 'Invited to book, or a call is booked.' },
  { key: 'decision', label: 'Decision', hint: 'Interviewed: hire, maybe or no.' },
  { key: 'agreement', label: 'Hired: agreement to sign', hint: 'Hired. Send the staff agreement; they sign in their portal.' },
  { key: 'academy', label: 'Academy', hint: 'Agreement signed; the academy is not passed yet.' },
  { key: 'whatsapp', label: 'WhatsApp groups to confirm', hint: 'Academy passed and agreement signed; the WhatsApp groups are not confirmed.' },
  { key: 'approval', label: 'Waiting for approval', hint: 'Everything is done. Approve to open their portal, or reject with a reason.' },
  { key: 'onboarded', label: 'Onboarded', hint: 'Their portal is open.' }
];

export interface PipeApp {
  id: string; full_name: string; role: string; status: string; score: number | null; pass_mark?: number; created_at: string; slot_starts_at: string | null;
  ai?: { state: 'sent' | 'started' | 'submitted' | 'scored' | 'expired'; live_call?: boolean } | null;
}

/** Which application stage a candidate is in (null: out of the pipeline: declined, not hired, withdrawn, referred, or already hired and now staff). */
export function appStage(a: PipeApp): AppStage | null {
  const ai = a.ai && !a.ai.live_call ? a.ai : null;
  if (['declined', 'rejected', 'withdrawn', 'referred', 'hired', 'no_show'].includes(a.status)) return null;
  if (a.status === 'interviewed') return 'decision';
  if (a.status === 'booked') return 'booked';
  if (ai && ['new', 'invited', 'below_bar'].includes(a.status)) return ai.state === 'scored' ? 'decision' : 'ai';
  if (a.status === 'invited') return 'booked';
  if (a.status === 'new' || a.status === 'below_bar') return 'applied';
  return null;
}

/** Which onboarding stage a staff member is in: the first thing still missing, in the owner's order (null: exempt test accounts). */
export function staffStage(r: OnboardingRow): StaffStage | null {
  if (r.state.exempt) return null;
  if (r.onboarded) return 'onboarded';
  if (!r.state.agreement) return 'agreement';
  if (!r.state.academy) return 'academy';
  if (!r.state.whatsapp) return 'whatsapp';
  return 'approval';
}

/** Every person in exactly one stage; the counts per stage in order. */
export function groupPipeline(apps: PipeApp[], staff: OnboardingRow[]): { apps: Record<AppStage, PipeApp[]>; staff: Record<StaffStage, OnboardingRow[]>; counts: Record<Stage, number> } {
  const a: Record<AppStage, PipeApp[]> = { applied: [], ai: [], booked: [], decision: [] };
  const s: Record<StaffStage, OnboardingRow[]> = { agreement: [], academy: [], whatsapp: [], approval: [], onboarded: [] };
  for (const x of apps) { const k = appStage(x); if (k) a[k].push(x); }
  for (const x of staff) { const k = staffStage(x); if (k) s[k].push(x); }
  const counts = Object.fromEntries(STAGES.map(({ key }) => [key, (a as Record<string, unknown[]>)[key]?.length ?? (s as Record<string, unknown[]>)[key]?.length ?? 0])) as Record<Stage, number>;
  return { apps: a, staff: s, counts };
}
