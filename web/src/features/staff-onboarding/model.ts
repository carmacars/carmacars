// The staff onboarding gate (1151): the academy, the agreement, then the WhatsApp groups confirmed, in that order; nothing
// else opens until all three are done. Pure, for the pages and the tests.
export type OnboardingStep = 'academy' | 'agreement' | 'whatsapp' | 'done';
export interface Group { key: string; name: string; url: string; joined?: boolean }
export interface OnboardingState { member: boolean; academy?: boolean; agreement?: boolean; whatsapp?: boolean; required?: string[]; joined?: string[];
  whatsapp_joined_at?: string | null; exempt?: boolean; step: OnboardingStep; done: boolean }
export interface OnboardingRow { user_id: string; name: string; functions: string[]; onboarded: boolean; state: OnboardingState; groups: Group[]; marked_by: string | null }

export const STEP_LABEL: Record<OnboardingStep, string> = { academy: 'Academy', agreement: 'Staff agreement', whatsapp: 'WhatsApp groups', done: 'Onboarded' };

/** The groups still to tick. */
export const groupsLeft = (groups: Group[]): Group[] => groups.filter((g) => !g.joined);

/** One person's line for the Admin. */
export function rowWords(r: OnboardingRow): string {
  if (r.state.exempt) return 'Exempt (a test or verify account): never held.';
  if (r.onboarded) return `Onboarded${r.marked_by ? `: WhatsApp marked by ${r.marked_by}` : ''}.`;
  const g = r.groups.map((x) => `${x.name} ${x.joined ? 'joined' : 'not confirmed'}`).join(', ');
  switch (r.state.step) {
    case 'academy': return 'Held at step 1: the academy is not passed yet.';
    case 'agreement': return 'Held at step 2: the staff agreement is not signed yet.';
    case 'whatsapp': return `Held at step 3: ${g || 'the WhatsApp groups are not confirmed'}.`;
    default: return 'Onboarded.';
  }
}

/** Signed but not confirmed: who the bulk Mark joined would mark. */
export const markable = (rows: OnboardingRow[]): OnboardingRow[] => rows.filter((r) => !r.onboarded && !r.state.exempt && r.state.agreement && !r.state.whatsapp);
