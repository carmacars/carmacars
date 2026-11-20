// The staff onboarding gate (1151): the academy, the agreement, then the WhatsApp groups confirmed, in that order; nothing
// else opens until all three are done. 1154: then step 4, approved by an Admin or a Fleet VA. Pure, for the pages and the tests.
export type OnboardingStep = 'academy' | 'agreement' | 'whatsapp' | 'approval' | 'done';
export interface Group { key: string; name: string; url: string; joined?: boolean; /** 3191: false for the Sales group shown to who passed the Sales path */ required?: boolean;
  /** 3191: "Name - Position", what the person sets as their member tag in each group */ member_tag?: string; tag_set?: boolean }

/** 3191: the steps to set the member tag in a WhatsApp group (the onboarding step, the home card and the guides say the same). */
export const TAG_STEPS = ['Open the group in WhatsApp and tap its name at the top.', 'Tap your own name in the member list (or Edit member tag).',
  'Paste your member tag and save. Do it in each group you join.'];
export interface OnboardingState { member: boolean; academy?: boolean; agreement?: boolean; whatsapp?: boolean; required?: string[]; joined?: string[];
  whatsapp_joined_at?: string | null; exempt?: boolean; step: OnboardingStep; done: boolean;
  /** 1154 */ approved?: boolean; approved_at?: string | null; approved_by?: string | null; asked_at?: string | null; rejected_at?: string | null; reject_reason?: string | null;
  /** 2360: every step still missing, in words */ waiting_on?: string[] }
/** 1154: one person waiting for approval (app.staff_onboarding_approvals). */
export interface ApprovalRow { user_id: string; name: string; functions: string[]; asked_at: string | null; rejected_at: string | null; reject_reason: string | null; self: boolean;
  /** 2360: approval, or held only by the WhatsApp step */ step?: OnboardingStep; waiting_on?: string[] }
export interface OnboardingRow { user_id: string; name: string; functions: string[]; onboarded: boolean; state: OnboardingState; groups: Group[]; marked_by: string | null;
  /** 3191: the member tag, the academy sections passed of their paths, and for Sales their Sales path */
  member_tag?: string; academy?: { passed: number; total: number }; sales_academy?: { path: string; passed: number; total: number; last_activity: string | null } | null }

/** 3191: "Academy 3 of 19 (Sales), last active 2 days ago" for the Admin's pipeline. */
export function academyWords(r: OnboardingRow, now = Date.now()): string | null {
  const a = r.sales_academy ?? r.academy;
  if (!a || !a.total) return null;
  const last = r.sales_academy?.last_activity ? Math.floor((now - new Date(r.sales_academy.last_activity).getTime()) / 86_400_000) : null;
  return `Academy ${a.passed} of ${a.total}${r.sales_academy ? ' (Sales)' : ''}${last !== null ? `, last active ${last === 0 ? 'today' : `${last} day${last === 1 ? '' : 's'} ago`}` : ''}`;
}

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
