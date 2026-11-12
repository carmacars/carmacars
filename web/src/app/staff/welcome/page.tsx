import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { academyUser } from '@/server/academy';
import { door } from '@/server/door';
import { STEP_TITLE, agreementWaiting, currentStep, profileHref, signHref, stepWords, type Welcome } from '@/features/academy/gate';
import { Act } from '@/features/admin/Act';
import { TaskDone } from './TaskDone';
import { WhatsAppConfirm } from '@/features/staff-onboarding/WhatsAppConfirm';
import { AvailabilityGrid } from '@/features/field-portal/AvailabilityGrid';

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
  const now = currentStep(w.steps.slice(1));
  const tasks = w.steps.find((s) => s.key === 'tasks');
  const href: Record<string, string> = { profile: profileHref(w.portal), academy: '/staff/academy' };
  const ag = w.steps.find((s) => s.key === 'agreement');
  // r40-forms: what the agreement waits for, who can give it, and how soon it arrives once it is in
  const wait = ag ? agreementWaiting(ag, w.steps.find((s) => s.key === 'profile')) : null;
  if (ag && ag.state === 'sent' && !ag.waiting_for_academy) href.agreement = signHref(w.portal);
  const label: Record<string, string> = { profile: 'Open your profile', academy: 'Open the academy', agreement: 'Read and sign' };
  return (
    <section className="stack" data-testid="staff-welcome">
      <h1 className="d3">Welcome, {w.name}</h1>
      {w.locked && <p className="alert alert--warn" role="status" data-testid="welcome-locked"><span className="alert__title">{w.onboarding_step === 'availability' ? 'When you can work, last' : w.onboarding_step === 'approval' ? 'Waiting for approval' : w.onboarding_step === 'whatsapp' ? 'The WhatsApp groups next' : w.steps.find((s) => s.key === 'academy')?.done ? 'Your agreement next' : 'Training first'}</span><span>The rest of your portal opens once you pass the academy, sign your staff agreement, confirm you joined the WhatsApp groups and an Admin or a Fleet VA approves, in that order. Field staff also tick when they can usually work.</span></p>}
      {/* 1154: the academy is always one press away */}
      <p><Link prefetch={false} className="link" href="/staff/academy" data-testid="welcome-academy-link">Open the academy</Link></p>
      <ol className="stack" aria-label="Your first steps">
        {w.steps.map((s, i) => (
          <li key={s.key} className={`pt-card ad-card${s.key === now ? ' pt-card--next' : ''}`} data-testid={`welcome-step-${s.key}`} data-done={s.done ? 'true' : 'false'}>
            <h2 className="d4">{i + 1}. {STEP_TITLE[s.key]} {s.done && s.key !== 'welcome' ? <span className="ad-b ad-b--light">Done</span> : null}</h2>
            <p className="small">{stepWords(s)}</p>
            {href[s.key] && !s.done && <p><Link prefetch={false} className={`btn btn--sm ${s.key === now ? 'btn--primary' : 'btn--ghost'}`} href={href[s.key]!}>{label[s.key]}</Link></p>}
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
              <ul className="stack" data-testid="welcome-tasks">{tasks.tasks.map((t) => (
                <li key={t.id}><b>{t.title}</b>{t.detail ? <span className="small muted"> {t.detail}</span> : null} {t.done ? <span className="ad-b ad-b--light">Done</span> : <TaskDone id={t.id} title={t.title} />}</li>))}</ul>)}
          </li>))}
      </ol>
      {!w.locked && <p><Link prefetch={false} className="btn btn--primary" href={w.portal === 'field' ? '/staff/field' : '/staff'} data-testid="welcome-start">Go to your portal</Link></p>}
    </section>
  );
}
