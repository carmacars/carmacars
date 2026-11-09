// The academy gate (0207, 0731, 0802) on the web side: the staff pages a held person still opens, and the Welcome steps of a
// new hire (app.staff_welcome). No imports, so the unit tests run it as is (gate.test.ts).

/** Held by the gate: the academy, the guide, the profile, Welcome (the onboarding checklist) and the no-access page only; for field
 *  staff also Training, the field guide and My pay (the pay details step), r35 part X. */
export const ACADEMY_OPEN = /^\/staff\/(academy|guide|profile|field\/profile|field\/training|field\/guide|field\/pay|no-access|welcome)(\/|\?|$)/;
export const opensWhileHeld = (path: string) => ACADEMY_OPEN.test(path);
/** Held by the agreement (1060: the academy first, then the agreement, then access): the academy's pages and the documents to sign. */
export const AGREEMENT_OPEN = /^\/staff\/(academy|guide|profile|field\/profile|field\/training|field\/guide|field\/pay|field\/sign|sign|documents|no-access|welcome)(\/|\?|$)/;
export const opensWhileUnsigned = (path: string) => AGREEMENT_OPEN.test(path);

export type StepKey = 'welcome' | 'profile' | 'academy' | 'agreement' | 'team' | 'tasks';
export interface WelcomeTask { id: string; title: string; detail: string | null; done: boolean }
export interface WelcomeStep { key: StepKey; done: boolean; phone?: boolean; phone_verified?: boolean; address?: boolean; passed?: number; sections?: number; waived?: boolean; tasks?: WelcomeTask[];
  /** 1060 */ preferred_name?: string | null; state?: 'signed' | 'waived' | 'sent' | 'none'; request_id?: string | null; waiting_for_academy?: boolean; missing?: string[]; open?: boolean; groups?: Array<{ key: string; name: string; url: string }> }
export interface Welcome { name: string; portal: 'va' | 'field'; locked: boolean; steps: WelcomeStep[] }

export const STEP_TITLE: Record<StepKey, string> = { welcome: 'Welcome', profile: 'Your profile and phone', academy: 'The academy', agreement: 'Your staff agreement', team: 'Join the team group', tasks: 'Your first tasks' };

/** The step to do now: the first one not done (null when all are). */
export function currentStep(steps: WelcomeStep[]): StepKey | null {
  return steps.find((s) => !s.done)?.key ?? null;
}

export function profileHref(portal: 'va' | 'field'): string {
  return portal === 'field' ? '/staff/field/profile' : '/staff/profile';
}
export function signHref(portal: 'va' | 'field'): string {
  return portal === 'field' ? '/staff/field/sign' : '/staff/sign';
}

/** The words under a step. */
export function stepWords(s: WelcomeStep): string {
  switch (s.key) {
    case 'welcome': return 'Your portal opens step by step: the academy first, then your agreement, then everything else. This page keeps your place.';
    case 'profile': return s.done ? 'Your home address, phone and preferred name are in.' : `Add ${[!s.preferred_name && 'the name you go by', !s.address && 'your home address', !s.phone && 'your mobile number'].filter(Boolean).join(', ') || 'your details'}.`;
    case 'agreement': return s.state === 'signed' ? 'Signed.' : s.state === 'waived' ? 'An Admin waived the agreement for you.'
      : s.waiting_for_academy ? 'It opens for signing once the academy is passed.' : s.state === 'sent' ? 'Ready to sign: read it and sign on screen. The rest of your portal opens once it is signed.'
      : 'It is being prepared from your record. An Admin has been told if anything is missing.';
    case 'team': return !s.open ? 'Opens once the academy is passed and the agreement is signed.' : !s.groups?.length ? 'No group to join.' : s.done ? 'Joined.' : 'Join the WhatsApp group, then press I joined.';
    case 'academy': return s.waived ? 'An Admin waived the academy for you.' : s.done ? 'Passed. The rest of your portal is open.' : `${s.passed ?? 0} of ${s.sections ?? 0} sections passed. Each quiz passes at 80%, and you can retake it.`;
    case 'tasks': return !s.tasks?.length ? 'No first-day tasks for you.' : s.done ? 'All done.' : `${s.tasks.filter((t) => !t.done).length} left.`;
  }
}

/** The gate of one person for Admin (app.academy_gate_state). */
export interface GateState { user_id: string; locked: boolean; done: boolean; passed: number; sections: number; lock_from: string | null; waiver: { reason: string; at: string; by: string | null } | null }

export function gateWords(g: GateState): string {
  if (g.waiver) return `Waived by ${g.waiver.by ?? 'an Admin'}: ${g.waiver.reason}. Their portal is open (${g.passed} of ${g.sections} sections passed).`;
  if (g.done) return `Passed: ${g.passed} of ${g.sections} sections. Their portal is open.`;
  if (g.locked) return `Held: ${g.passed} of ${g.sections} sections passed. Until they pass, they open only the academy, the guide, their profile and Welcome.`;
  return `${g.passed} of ${g.sections} sections passed. ${g.lock_from ? `Not held yet (the hold starts ${new Date(g.lock_from).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' })}).` : 'Not held: only a hire from one-step Hire or a person an Admin enrolled is held.'}`;
}
