import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { academyUser } from '@/server/academy';
import { door } from '@/server/door';
import { STEP_TITLE, agreementWaiting, currentStep, profileHref, stepAction, stepWords, type StepAction, type Welcome } from '@/features/academy/gate';
import { SignNow } from '@/features/staff-onboarding/SignNow';
import { Act } from '@/features/admin/Act';
import { TaskDone } from './TaskDone';
import { WhatsAppConfirm } from '@/features/staff-onboarding/WhatsAppConfirm';
import { AvailabilityGrid } from '@/features/field-portal/AvailabilityGrid';
import { ResignSection } from '@/features/staff/Resign';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Welcome', path: '/staff/welcome', noindex: true, description: 'Your first steps: profile, the academy and your first tasks.' });

// Welcome (0802, 1060): the first-login flow of a new hire, and the onboarding checklist the gates keep open. In order:
// welcome, profile (with the preferred name), the academy (every section of the path, each quiz at 90%), the staff
// agreement (opens once the academy is passed), the team's WhatsApp group, then the first-day To do's of their Hire. The
// rest of the portal opens once the academy is passed and the agreement signed (or an Admin waived either).
// An <Act> holds a dialog and a form, so it sits in a <div>, never a <p> (a <p> around it breaks hydration, React #418).
export default async function StaffWelcome() {
  const { user, aal } = await academyUser('/staff/welcome');
  const w = await door<Welcome>(user.id, 'ops_read', 'staff_welcome', {}, aal);
  // 5304 (REQ-135): the step to do now, from the database (the first one left that can be done), else the first not done
  const now = w.next ?? currentStep(w.steps.slice(1));
  const tasks = w.steps.find((s) => s.key === 'tasks');
  const ag = w.steps.find((s) => s.key === 'agreement');
  // r40-forms: what the agreement waits for, who can give it, and how soon it arrives once it is in
  const wait = ag ? agreementWaiting(ag, w.steps.find((s) => s.key === 'profile')) : null;
  const nextStep = w.steps.find((s) => s.key === now);
  const nextAction = nextStep ? stepAction(nextStep, w.portal) : null;
  return (
    <section className="stack" data-testid="staff-welcome" data-guide="staff-welcome">
      <h1 className="d3">Welcome, {w.name}</h1>
      {w.locked && <div className="alert alert--warn stack" role="status" data-testid="welcome-locked"><span className="alert__title">{nextStep ? `Next: ${STEP_TITLE[nextStep.key]}` : 'Almost there'}</span><span>Do the steps below, one button each. Your portal opens when the list is done. Done steps are ticked.</span>
        {nextStep && nextAction && <StepButton a={nextAction} step={nextStep.key} primary testId="welcome-next" />}</div>}
      {/* 1154: the academy is always one press away */}
      {/* r48 FE (3198): once the agreement is signed */}
      {!w.steps.find((s) => s.key === 'academy')?.waiting_for_agreement && <p><Link prefetch={false} className="link" href="/staff/academy" data-testid="welcome-academy-link">Open the academy</Link></p>}
      <ol className="stack" aria-label="Your first steps">
        {w.steps.map((s, i) => (
          <li key={s.key} id={`step-${s.key}`} className={`pt-card ad-card${s.key === now ? ' pt-card--next' : ''}`} data-testid={`welcome-step-${s.key}`} data-done={s.done ? 'true' : 'false'}>
            <h2 className="d4">{s.done && s.key !== 'welcome' ? <span aria-hidden="true">✓ </span> : null}{i + 1}. {STEP_TITLE[s.key]} {s.done && s.key !== 'welcome' ? <span className="ad-b ad-b--light">Done</span> : null}</h2>
            <p className="small">{stepWords(s)}</p>
            {!s.done && <StepButton a={stepAction(s, w.portal)} step={s.key} primary={s.key === now} testId={`welcome-do-${s.key}`} />}
            {s.key === 'profile' && !s.preferred_name && <div><Act ops action="staff_preferred_name_save" label="Add the name you go by" variant={s.key === now ? 'primary' : 'ghost'} title="Your preferred name" submitLabel="Save"
              testId="welcome-preferred-name" refresh={['/staff/welcome']} done="Saved." fields={[{ name: 'preferred_name', label: 'The name you go by', type: 'text', required: true, placeholder: 'For example: Sam', hint: 'Shown across the portals and on the staff list.' }]} /></div>}
            {s.key === 'profile' && s.location === null && <div><Act ops action="staff_location_save" label="Add where you live" variant={s.key === now ? 'primary' : 'ghost'} title="Where you live" submitLabel="Save"
              testId="welcome-location" refresh={['/staff/welcome']} done="Saved." fields={[{ name: 'city', label: 'City or town', type: 'text', required: true },
                { name: 'country', label: 'Country', type: 'select', required: true, value: 'CA', options: [['CA', 'Canada'], ['US', 'United States'], ['PH', 'Philippines'], ['IN', 'India'], ['PK', 'Pakistan'], ['MX', 'Mexico'], ['GB', 'United Kingdom'], ['ZZ', 'Another country']],
                  hint: 'Sales in person is for the Toronto area; elsewhere your Sales work is remote.' }]} /></div>}
            {s.key === 'agreement' && wait && (
              <div className="alert alert--warn" role="status" data-testid="welcome-agreement-waiting">
                <span className="alert__title">{wait.headline ?? wait.theirsLine}</span>
                <span>
                  {wait.mine.length > 0 && <span className="stack" data-testid="welcome-agreement-mine">{wait.mine.map((m) => (
                    <span key={m.to}>{m.label}: <Link prefetch={false} className="link" href={m.to === 'profile' ? profileHref(w.portal) : '#agreement-licence'} data-testid={`welcome-agreement-fix-${m.to}`}>{m.to === 'profile' ? 'Add it on your profile' : 'Add it below'}</Link></span>))}</span>}
                  {wait.headline && wait.theirsLine && <span data-testid="welcome-agreement-theirs">{wait.theirsLine}.</span>}
                  <span className="small"> {wait.timing}</span>
                </span>
              </div>)}
            {/* 2373: the Field Staff Agreement is made once the person gives their licence number */}
            {s.key === 'agreement' && s.needs_licence && <div id="agreement-licence"><Act ops action="staff_licence_number_save" label="Add my driver's licence number" variant="primary" title="Your driver's licence number" submitLabel="Save"
              testId="welcome-licence" refresh={['/staff/welcome']} done="Saved. Your agreement is being made." fields={[{ name: 'licence_number', label: 'Driver\'s licence number', type: 'text', required: true, placeholder: 'A1234-12345-12345', hint: 'As it is on your licence card. It goes in your Field Staff Agreement.' }]} /></div>}
            {/* 1151: step 3, one checkbox a group (Sales: the Sales group and the Team group) */}
            {s.key === 'team' && s.open && !!s.groups?.length && !s.done && <WhatsAppConfirm groups={s.groups} primary={s.key === now} refresh="/staff/welcome" />}
            {/* 1770: field staff tick when they can usually work (open from the start, required for the portal) */}
            {s.key === 'availability' && !s.done && <AvailabilityGrid value={{ slots: s.slots ?? [], note: s.note ?? null }} testId="welcome-availability" submit="Save when I can work" onboarding />}
            {s.key === 'academy' && s.done && <p><Link prefetch={false} className="link" href="/staff/academy">Your academy</Link></p>}
            {/* 1154: step 4; after a rejection the person asks again once fixed */}
            {s.key === 'approval' && s.open && !s.done && (s.reject_reason
              ? <div><Act ops action="staff_onboarding_ask_again" label="Ask again" variant="primary" refresh={['/staff/welcome']} done="Asked." testId="welcome-ask-again" /></div>
              : <p className="ad-b" data-testid="welcome-waiting-approval">Waiting for approval</p>)}
            {s.key === 'tasks' && !!tasks?.tasks?.length && (
              <ul className="stack" data-testid="welcome-tasks" data-guide="welcome-tasks">{tasks.tasks.map((t) => (
                <li key={t.id}><b>{t.title}</b>{t.detail ? <span className="small muted"> {t.detail}</span> : null} {t.done ? <span className="ad-b ad-b--light">Done</span> : <TaskDone id={t.id} title={t.title} />}</li>))}</ul>)}
          </li>))}
      </ol>
      {!w.locked && <p><Link prefetch={false} className="btn btn--primary" href={w.portal === 'field' ? '/staff/field' : '/staff'} data-testid="welcome-start" data-guide="welcome-start">Go to your portal</Link></p>}
      {/* r50 (5020): while still in onboarding, Resign is here too (the profile may not be open yet) */}
      {w.locked && <ResignSection userId={user.id} portal={w.portal === 'field' ? 'field' : 'va'} className="pt-card stack" refresh={['/staff/welcome']} />}
    </section>
  );
}

// 5304 (REQ-135): the one button of a step. A form in the step ('here') gets a button to it from the top of the page.
function StepButton({ a, step, primary, testId }: { a: StepAction; step: string; primary?: boolean; testId: string }) {
  const cls = `btn btn--lg btn--block ${primary ? 'btn--primary' : 'btn--ghost'}`;
  if (a.kind === 'link') return <p><Link prefetch={false} className={cls} href={a.href} data-testid={testId}>{a.label}</Link></p>;
  if (a.kind === 'sign_now') return <SignNow label={a.label} primary={primary} testId={testId} />;
  if (a.kind === 'here') return testId === 'welcome-next' ? <p><a className={cls} href={`#step-${step}`} data-testid={testId}>{a.label}</a></p> : null;
  if (a.kind === 'wait') return testId === 'welcome-next' ? <p className="ad-b" data-testid={testId}>{a.label}</p> : null;
  return null;
}
