import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { academyUser } from '@/server/academy';
import { door } from '@/server/door';
import { STEP_TITLE, currentStep, profileHref, signHref, stepWords, type Welcome } from '@/features/academy/gate';
import { Act } from '@/features/admin/Act';
import { TaskDone } from './TaskDone';
import { WhatsAppConfirm } from '@/features/staff-onboarding/WhatsAppConfirm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Welcome', path: '/staff/welcome', noindex: true, description: 'Your first steps: profile, the academy and your first tasks.' });

// Welcome (0802, 1060): the first-login flow of a new hire, and the onboarding checklist the gates keep open. In order:
// welcome, profile (with the preferred name), the academy (every section of the path, each quiz at 80%), the staff
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
  if (ag && ag.state === 'sent' && !ag.waiting_for_academy) href.agreement = signHref(w.portal);
  const label: Record<string, string> = { profile: 'Open your profile', academy: 'Open the academy', agreement: 'Read and sign' };
  return (
    <section className="stack" data-testid="staff-welcome">
      <h1 className="d3">Welcome, {w.name}</h1>
      {w.locked && <p className="alert alert--warn" role="status" data-testid="welcome-locked"><span className="alert__title">{w.onboarding_step === 'whatsapp' ? 'The WhatsApp groups next' : w.steps.find((s) => s.key === 'academy')?.done ? 'Your agreement next' : 'Training first'}</span><span>The rest of your portal opens once you pass the academy, sign your staff agreement and confirm you joined the WhatsApp groups, in that order.</span></p>}
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
            {/* 1151: step 3, one checkbox a group (Sales: the Sales group and the Team group) */}
            {s.key === 'team' && s.open && !!s.groups?.length && !s.done && <WhatsAppConfirm groups={s.groups} primary={s.key === now} refresh="/staff/welcome" />}
            {s.key === 'academy' && s.done && <p><Link prefetch={false} className="link" href="/staff/academy">Your academy</Link></p>}
            {s.key === 'tasks' && !!tasks?.tasks?.length && (
              <ul className="stack" data-testid="welcome-tasks">{tasks.tasks.map((t) => (
                <li key={t.id}><b>{t.title}</b>{t.detail ? <span className="small muted"> {t.detail}</span> : null} {t.done ? <span className="ad-b ad-b--light">Done</span> : <TaskDone id={t.id} title={t.title} />}</li>))}</ul>)}
          </li>))}
      </ol>
      {!w.locked && <p><Link prefetch={false} className="btn btn--primary" href={w.portal === 'field' ? '/staff/field' : '/staff'} data-testid="welcome-start">Go to your portal</Link></p>}
    </section>
  );
}
