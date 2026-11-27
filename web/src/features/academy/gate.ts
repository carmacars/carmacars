// The academy gate (0207, 0731, 0802) on the web side: the staff pages a held person still opens, and the Welcome steps of a
// new hire (app.staff_welcome). No imports, so the unit tests run it as is (gate.test.ts).

/** Held by the gate: the academy, the guide, the profile, Welcome (the onboarding checklist) and the no-access page only; for field
 *  staff also Training, the field guide and My pay (the pay details step), r35 part X. */
export const ACADEMY_OPEN = /^\/staff\/(academy|guide|profile|bug-reports|field\/profile|field\/training|field\/guide|field\/pay|no-access|welcome)(\/|\?|$)/;
export const opensWhileHeld = (path: string) => ACADEMY_OPEN.test(path);
/** Held by the agreement (1060: the academy first, then the agreement, then access): the academy's pages and the documents to sign. */
export const AGREEMENT_OPEN = /^\/staff\/(academy|guide|profile|bug-reports|field\/profile|field\/training|field\/guide|field\/pay|field\/sign|sign|documents|no-access|welcome)(\/|\?|$)/;
export const opensWhileUnsigned = (path: string) => AGREEMENT_OPEN.test(path);
/** r48 FE (3198): the agreement comes first (agreement, academy, WhatsApp, approval): before it is signed, the documents to sign,
 *  Welcome, the profile and the guide only (not the academy yet). */
export const SIGN_FIRST_OPEN = /^\/staff\/(guide|profile|bug-reports|field\/profile|field\/guide|field\/pay|field\/sign|sign|documents|no-access|welcome)(\/|\?|$)/;
export const opensBeforeSigning = (path: string) => SIGN_FIRST_OPEN.test(path);
/** Not fully onboarded (1151: the academy, the agreement, then the WhatsApp groups confirmed): the same onboarding pages only. */
export const ONBOARDING_OPEN = AGREEMENT_OPEN;
export const opensWhileOnboarding = (path: string) => ONBOARDING_OPEN.test(path);

/** 5171: the section a page waits for: the first one required for the page's area (the area and the pages under it; a portal
 *  home, /staff or /staff/field, is that page only). The onboarding pages (AGREEMENT_OPEN: the academy, the guide, the profile,
 *  the documents to sign, Welcome) always open, so a person signing their agreement is never sent round in a loop. */
export function requiredFor<T extends { area: string; href: string }>(required: T[] | undefined, path: string): T | null {
  if (!required?.length || AGREEMENT_OPEN.test(path)) return null;
  const p = path.split('?')[0]!.replace(/\/+$/, '') || '/staff';
  return required.find((r) => (r.area === '/staff' || r.area === '/staff/field') ? p === r.area : p === r.area || p.startsWith(`${r.area}/`)) ?? null;
}

/** 5171: the area of a page for an academy assignment: its route pattern up to the first id. */
export function areaOf(pattern: string): string {
  const segs = pattern.split('?')[0]!.split('/').filter(Boolean);
  const i = segs.findIndex((x) => x.startsWith('['));
  return '/' + (i < 0 ? segs : segs.slice(0, i)).join('/');
}

export type StepKey = 'welcome' | 'profile' | 'availability' | 'academy' | 'agreement' | 'team' | 'approval' | 'pay' | 'tasks';
export interface WelcomeTask { id: string; title: string; detail: string | null; done: boolean }
export interface WelcomeStep { key: StepKey; done: boolean; phone?: boolean; phone_verified?: boolean; address?: boolean; passed?: number; sections?: number; /** 5170: the whole academy */ full_passed?: number; full_sections?: number; waived?: boolean; tasks?: WelcomeTask[];
  /** 1060 */ preferred_name?: string | null; /** 1067 */ location?: string | null; state?: 'signed' | 'waived' | 'sent' | 'none'; request_id?: string | null; waiting_for_academy?: boolean; /** 3198: the academy opens once the agreement is signed */ waiting_for_agreement?: boolean; missing?: string[]; open?: boolean; groups?: Array<{ key: string; name: string; url: string; /** 1151 */ joined?: boolean; /** 3191 */ required?: boolean; member_tag?: string; tag_set?: boolean }>; /** 1151: one checkbox a group */ confirm?: boolean;
  /** 1154: step 4, approved by an Admin or a Fleet team member */ asked_at?: string | null; rejected_at?: string | null; reject_reason?: string | null; approved_by?: string | null;
  /** 1770: field staff, when they can usually work (open from the start; required for the portal) */ slots?: string[]; note?: string | null; required?: boolean;
  /** 2373: the Field Staff Agreement waits for the driver's licence number the person gives here */ needs_licence?: boolean }
export interface Welcome { name: string; portal: 'va' | 'field'; locked: boolean; steps: WelcomeStep[]; /** 1151 */ onboarding_step?: 'academy' | 'agreement' | 'whatsapp' | 'approval' | 'availability' | 'done';
  /** 5304 (REQ-135): the first step left the person can do now */ next?: StepKey | null }

export const STEP_TITLE: Record<StepKey, string> = { welcome: 'Welcome', profile: 'Your profile and phone', availability: 'When you can work', academy: 'The academy', agreement: 'Your staff agreement', team: 'Join the WhatsApp groups', approval: 'Approval', pay: 'Your pay details', tasks: 'Your first tasks' };

/** How often the agreements job runs: the Worker's five-minute tick (custom-worker.ts), when the database says an agreement is due. */
export const AGREEMENT_JOB_WORDS = 'within about 5 minutes';
export interface AgreementWaiting { mine: Array<{ label: string; to: 'profile' | 'licence' }>; theirs: string[]; headline: string | null; theirsLine: string | null; timing: string }
/**
 * What the staff agreement waits for (r40-forms), from the agreement step and the profile step: the values the person gives
 * themselves (home address on the profile, the driver's licence number in the box of this page) and the values only an Admin
 * can set (start date, pay, the vehicle types). Null when it is signed, waived, already sent, or nothing is known to be missing.
 * Labels only; a licence number is never read here.
 */
export function agreementWaiting(ag: WelcomeStep, profile?: WelcomeStep): AgreementWaiting | null {
  if (ag.state === 'signed' || ag.state === 'waived' || ag.state === 'sent') return null;
  const missing = ag.missing ?? [];
  const noAddress = profile?.address === false;
  const mine: AgreementWaiting['mine'] = [];
  if (noAddress && (ag.needs_licence || missing.some((m) => /home address/i.test(m)))) mine.push({ label: 'Home address', to: 'profile' });
  if (ag.needs_licence) mine.push({ label: 'Driver\'s licence number', to: 'licence' });
  const theirs = missing.filter((m) => !/home address|licence number/i.test(m)).map((m) => m.replace(/\s*\([^)]*\)/g, '').trim().toLowerCase());
  if (!mine.length && !theirs.length) return null;
  const list = (xs: string[]) => (xs.length > 1 ? `${xs.slice(0, -1).join(', ')} and ${xs[xs.length - 1]}` : (xs[0] ?? ''));
  return {
    mine, theirs,
    headline: mine.length ? `Complete your profile to get your agreement: missing ${list(mine.map((m) => m.label.toLowerCase()))}` : null,
    theirsLine: theirs.length ? `Waiting for CarmaCars to set your ${list(theirs)}` : null,
    timing: mine.length ? `Your agreement arrives here ${AGREEMENT_JOB_WORDS} after your profile is complete.` : `Your agreement arrives here ${AGREEMENT_JOB_WORDS} after CarmaCars sets ${theirs.length > 1 ? 'them' : 'it'}.`
  };
}

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
    case 'welcome': return 'Your portal opens step by step: your agreement first, then the academy, then the WhatsApp groups, then an approval, then everything else. This page keeps your place.';
    case 'profile': return s.done ? 'Your home address, phone, preferred name and where you live are in.' : `Add ${[!s.preferred_name && 'the name you go by', s.location === null && 'where you live (city and country)', !s.address && 'your home address', !s.phone && 'your mobile number'].filter(Boolean).join(', ') || 'your details'}.`;
    case 'availability': return s.done ? 'Given. Change it any time on your profile.' : `Tick the mornings, afternoons and evenings you can usually work. Fleet plans the shifts from it${s.required === false ? '' : ', and your portal opens once it is in'}.`;
    case 'agreement': return s.state === 'signed' ? 'Signed.' : s.state === 'waived' ? 'An Admin waived the agreement for you.'
      : s.waiting_for_academy ? 'It opens for signing once the academy is passed.' : s.state === 'sent' ? 'Ready to sign: read it and sign on screen. The rest of your portal opens once it is signed.'
      : agreementWaiting(s) ? 'Your agreement is made as soon as everything it needs is in. What is missing is listed below.'
      : s.needs_licence ? 'Add your driver\'s licence number below. Your agreement is made from it within minutes and appears here to sign.'
      : 'It is being prepared from your record. An Admin has been told if anything is missing.';
    case 'team': return !s.open ? 'Opens once the agreement is signed and the academy is passed.' : !s.groups?.length ? 'No group to join.' : s.done ? 'Joined.'
      : `Join ${s.groups.map((g) => g.name).join(' and ')} on WhatsApp, then tick each group you joined. Your portal opens once every group is ticked.`;
    case 'academy': return s.waived ? 'An Admin waived the academy for you.' : s.waiting_for_agreement && !s.done ? 'Opens once your staff agreement is signed.'
      : s.done ? `Basics passed. The rest of your portal is open. Finish the other sections (${s.full_passed ?? 0} of ${s.full_sections ?? 0} passed) before held pay is paid out (commission, bonuses, referral fees, and pay for hours for Field, customer service, Fleet and Finance).`
      : `The basics: ${s.passed ?? 0} of ${s.sections ?? 0} sections passed. Passing them opens your portal and work. If a quiz is below the pass mark, fix the wrong answers once; after a failed try, wait 2 minutes.`;
    case 'approval': return s.done ? `Approved${s.approved_by ? ` by ${s.approved_by}` : ''}.` : !s.open ? 'Opens once you confirm the WhatsApp groups.'
      : s.reject_reason ? `Not approved yet: ${s.reject_reason}. Fix it, then ask again.` : 'Waiting for approval: an Admin or a Fleet team member checks your onboarding and opens your portal.';
    case 'pay': return s.done ? 'On file.' : 'Add the account your pay goes to. Your portal does not wait for it; your first pay does.';
    case 'tasks': return !s.tasks?.length ? 'No first-day tasks for you.' : s.done ? 'All done.' : `${s.tasks.filter((t) => !t.done).length} left.`;
  }
}

/** The gate of one person for Admin (app.academy_gate_state). */
export interface GateState { user_id: string; locked: boolean; done: boolean; passed: number; sections: number; lock_from: string | null; waiver: { reason: string; at: string; by: string | null } | null;
  /** 5170: the whole academy, and why payouts are held */ full_passed?: number; full_sections?: number; pay_hold?: string | null;
  /** 5171: sections to pass before continuing an area */ required?: Array<{ id: string; area: string; title: string; href: string; reason: string; at: string }> }

export function gateWords(g: GateState): string {
  if (g.waiver) return `Waived by ${g.waiver.by ?? 'an Admin'}: ${g.waiver.reason}. Their portal is open (${g.passed} of ${g.sections} sections passed).`;
  const full = g.full_sections !== undefined ? ` Whole academy: ${g.full_passed ?? 0} of ${g.full_sections}${g.pay_hold ? ', so their pay is held' : ''}.` : '';
  if (g.done) return `Basics passed: ${g.passed} of ${g.sections} sections. Their portal is open.${full}`;
  if (g.locked) return `Held: ${g.passed} of ${g.sections} basics sections passed. Until they pass the basics, they open only the academy, the guide, their profile and Welcome.${full}`;
  return `${g.passed} of ${g.sections} sections passed. ${g.lock_from ? `Not held yet (the hold starts ${new Date(g.lock_from).toLocaleDateString('en-CA', { timeZone: 'America/Toronto', month: 'short', day: 'numeric' })}).` : 'Not held: only a hire from one-step Hire or a person an Admin enrolled is held.'}`;
}

/** 5304 (REQ-135): what the one button of a step does. Every step left has a button or the form itself on the page, so
 *  onboarding has no dead end: 'link' opens a page, 'sign_now' makes the agreement if needed and opens it, 'here' is a form
 *  in the step (the WhatsApp groups, when you can work, the licence number), 'wait' is someone else's step (approval). */
export type StepAction = { kind: 'link'; label: string; href: string } | { kind: 'sign_now'; label: string } | { kind: 'here'; label: string } | { kind: 'wait'; label: string } | { kind: 'none' };
export function stepAction(s: WelcomeStep, portal: 'va' | 'field'): StepAction {
  if (s.done || s.key === 'welcome' || s.key === 'tasks') return { kind: 'none' };
  switch (s.key) {
    case 'profile': return { kind: 'link', label: 'Finish my profile', href: profileHref(portal) };
    case 'agreement': return s.needs_licence ? { kind: 'here', label: 'Add my driver\'s licence number' }
      : s.state === 'sent' ? { kind: 'link', label: 'Sign my agreement', href: signHref(portal) } : { kind: 'sign_now', label: 'Sign my agreement now' };
    case 'academy': return s.waiting_for_agreement ? { kind: 'sign_now', label: 'Sign my agreement first' } : { kind: 'link', label: 'Open the academy', href: '/staff/academy' };
    case 'availability': return { kind: 'here', label: 'Set when I can work' };
    case 'team': return s.open === false ? { kind: 'wait', label: 'Opens after the agreement and the academy' } : { kind: 'here', label: 'Join the group and confirm' };
    case 'pay': return { kind: 'link', label: 'Add my pay details', href: `${portal === 'field' ? '/staff/field/pay' : '/staff/profile'}#pay` };
    case 'approval': return s.reject_reason ? { kind: 'here', label: 'Ask again' } : { kind: 'wait', label: 'Waiting for an Admin or Fleet to approve' };
  }
}
