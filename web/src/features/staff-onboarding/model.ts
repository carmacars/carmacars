// The staff onboarding gate (1151): the academy, the agreement, then the WhatsApp groups confirmed, in that order; nothing
// else opens until all three are done. 1154: then step 4, approved by an Admin or a Fleet VA. Pure, for the pages and the tests.
export type OnboardingStep = 'academy' | 'agreement' | 'whatsapp' | 'approval' | 'done';
export interface Group { key: string; name: string; url: string; joined?: boolean }
export interface OnboardingState { member: boolean; academy?: boolean; agreement?: boolean; whatsapp?: boolean; required?: string[]; joined?: string[];
  whatsapp_joined_at?: string | null; exempt?: boolean; step: OnboardingStep; done: boolean;
  /** 1154 */ approved?: boolean; approved_at?: string | null; approved_by?: string | null; asked_at?: string | null; rejected_at?: string | null; reject_reason?: string | null;
  /** 2360: every step still missing, in words */ waiting_on?: string[] }
/** 1154: one person waiting for approval (app.staff_onboarding_approvals). */
export interface ApprovalRow { user_id: string; name: string; functions: string[]; asked_at: string | null; rejected_at: string | null; reject_reason: string | null; self: boolean;
  /** 2360: approval, or held only by the WhatsApp step */ step?: OnboardingStep; waiting_on?: string[] }
export interface OnboardingRow { user_id: string; name: string; functions: string[]; onboarded: boolean; state: OnboardingState; groups: Group[]; marked_by: string | null }

export const STEP_LABEL: Record<OnboardingStep, string> = { academy: 'Academy', agreement: 'Staff agreement', whatsapp: 'WhatsApp groups', approval: 'Waiting for approval', done: 'Onboarded' };

/** The groups still to tick. */
export const groupsLeft = (groups: Group[]): Group[] => groups.filter((g) => !g.joined);

/** One person's line for the Admin. */
export function rowWords(r: OnboardingRow): string {
  if (r.state.exempt) return 'Exempt (a test or verify account): never held.';
  if (r.onboarded) return `Onboarded${r.state.approved_by ? `, approved by ${r.state.approved_by}` : ''}${r.marked_by ? `; WhatsApp marked by ${r.marked_by}` : ''}.`;
  const g = r.groups.map((x) => `${x.name} ${x.joined ? 'joined' : 'not confirmed'}`).join(', ');
  switch (r.state.step) {
    case 'academy': return `Held at step 1: the academy is not passed yet.${r.state.whatsapp ? ' The WhatsApp groups are already confirmed (only that step).' : ''}`;
    case 'agreement': return `Held at step 2: the staff agreement is not signed yet.${r.state.whatsapp ? ' The WhatsApp groups are already confirmed (only that step).' : ''}`;
    case 'whatsapp': return `Held at step 3: ${g || 'the WhatsApp groups are not confirmed'}.`;
    case 'approval': return r.state.reject_reason ? `Held at step 4: rejected (${r.state.reject_reason}); they can ask again.` : 'Held at step 4: waiting for an Admin or a Fleet VA to approve.';
    default: return 'Onboarded.';
  }
}

/** Signed but not confirmed: who the bulk Mark joined would mark. */
export const markable = (rows: OnboardingRow[]): OnboardingRow[] => rows.filter((r) => !r.onboarded && !r.state.exempt && r.state.agreement && !r.state.whatsapp);

/** 1154: who an Admin's Approve all would approve (waiting, not themselves). */
export const approvable = (rows: ApprovalRow[]): ApprovalRow[] => rows.filter((r) => !r.self);

/** 2360: "Waiting on: ..." (every missing step), or nothing when nothing is missing. */
export const waitingWords = (w: string[] | undefined): string => (w && w.length ? `Waiting on: ${w.join(', ')}` : '');
