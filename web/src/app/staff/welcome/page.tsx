import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { academyUser } from '@/server/academy';
import { door } from '@/server/door';
import { STEP_TITLE, currentStep, profileHref, stepWords, type Welcome } from '@/features/academy/gate';
import { TaskDone } from './TaskDone';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Welcome', path: '/staff/welcome', noindex: true, description: 'Your first steps: profile, the academy and your first tasks.' });

// Welcome (0802): the first-login flow of a new hire, and the onboarding checklist the academy gate keeps open. Four steps
// in order: welcome, profile and phone, the academy (every section of the path, each quiz at 80%), then the first-day To
// do's of their Hire. The rest of the portal opens once the academy is passed (or an Admin waived it).
export default async function StaffWelcome() {
  const { user, aal } = await academyUser('/staff/welcome');
  const w = await door<Welcome>(user.id, 'ops_read', 'staff_welcome', {}, aal);
  const now = currentStep(w.steps.slice(1));
  const tasks = w.steps.find((s) => s.key === 'tasks');
  const href: Record<string, string> = { profile: profileHref(w.portal), academy: '/staff/academy' };
  return (
    <section className="stack" data-testid="staff-welcome">
      <h1 className="d3">Welcome, {w.name}</h1>
      {w.locked && <p className="alert alert--warn" role="status" data-testid="welcome-locked"><span className="alert__title">Training first</span><span>The rest of your portal opens once you pass the academy.</span></p>}
      <ol className="stack" aria-label="Your first steps">
        {w.steps.map((s, i) => (
          <li key={s.key} className={`pt-card ad-card${s.key === now ? ' pt-card--next' : ''}`} data-testid={`welcome-step-${s.key}`} data-done={s.done ? 'true' : 'false'}>
            <h2 className="d4">{i + 1}. {STEP_TITLE[s.key]} {s.done && s.key !== 'welcome' ? <span className="ad-b ad-b--light">Done</span> : null}</h2>
            <p className="small">{stepWords(s)}</p>
            {href[s.key] && !s.done && <p><Link prefetch={false} className={`btn btn--sm ${s.key === now ? 'btn--primary' : 'btn--ghost'}`} href={href[s.key]!}>{s.key === 'academy' ? 'Open the academy' : 'Open your profile'}</Link></p>}
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
