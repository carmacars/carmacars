// The academy gate (0207, 0731, 0802) on the web side: the staff pages a held person still opens, and the Welcome steps of a
// new hire (app.staff_welcome). No imports, so the unit tests run it as is (gate.test.ts).

/** Held by the gate: the academy, the guide, the profile, Welcome (the onboarding checklist) and the no-access page only. */
export const ACADEMY_OPEN = /^\/staff\/(academy|guide|profile|field\/profile|no-access|welcome)(\/|\?|$)/;
export const opensWhileHeld = (path: string) => ACADEMY_OPEN.test(path);

export type StepKey = 'welcome' | 'profile' | 'academy' | 'tasks';
export interface WelcomeTask { id: string; title: string; detail: string | null; done: boolean }
export interface WelcomeStep { key: StepKey; done: boolean; phone?: boolean; phone_verified?: boolean; address?: boolean; passed?: number; sections?: number; waived?: boolean; tasks?: WelcomeTask[] }
export interface Welcome { name: string; portal: 'va' | 'field'; locked: boolean; steps: WelcomeStep[] }

export const STEP_TITLE: Record<StepKey, string> = { welcome: 'Welcome', profile: 'Your profile and phone', academy: 'The academy', tasks: 'Your first tasks' };

/** The step to do now: the first one not done (null when all are). */
export function currentStep(steps: WelcomeStep[]): StepKey | null {
  return steps.find((s) => !s.done)?.key ?? null;
}

export function profileHref(portal: 'va' | 'field'): string {
  return portal === 'field' ? '/staff/field/profile' : '/staff/profile';
}

/** The words under a step. */
export function stepWords(s: WelcomeStep): string {
  switch (s.key) {
    case 'welcome': return 'Your portal opens in four steps. Do them in order; this page keeps your place.';
    case 'profile': return s.done ? 'Your home address and phone are in.' : `Add ${[!s.address && 'your home address', !s.phone && 'your mobile number'].filter(Boolean).join(' and ') || 'your details'} in your profile.`;
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
