import Link from '@/components/Link';
import { notFound } from 'next/navigation';
import '@/features/academy/academy.css';
import { PageHead } from '@/features/admin/ui';
import { academyHome, academySection } from '@/server/academy';
import { Paths } from './Paths';
import { Study } from './Study';
import { dueWords, pct } from './model';

// The two pages of the academy, for staff (/staff/academy) and for an Admin taking the Admin path (/admin/academy/learn).
export async function AcademyHomePage({ userId, base, locked }: { userId: string; base: string; locked?: boolean }) {
  const h = await academyHome(userId);
  return (
    <>
      <PageHead title="Academy" kicker="Training" purpose="Your training path: watch each lesson (narrated by your browser, with captions), then pass the section's quiz to open the next one." />
      {(locked || h.locked) && <p className="alert alert--warn" role="status" data-testid="academy-locked"><span className="alert__title">Training first</span><span>The rest of the portal opens once you pass the basics of your path{h.paths.length > 1 ? 's' : ''}.{base === '/staff/academy' ? <> <Link prefetch={false} className="link" href="/staff/welcome">Your first steps</Link></> : null}</span></p>}
      {!(locked || h.locked) && dueWords(h.lock_from, h.paths.every((p) => p.passed)) && <p className="alert alert--warn" role="status" data-testid="academy-due" data-guide="academy-due"><span>{dueWords(h.lock_from, h.paths.every((p) => p.passed))}</span></p>}
      {h.required && h.required.length > 0 && <section className="alert alert--warn stack" role="status" data-testid="academy-required" aria-labelledby="ac-req">
        <span className="alert__title" id="ac-req">Pass these to continue</span>
        <span>You were stuck on a page, so its section comes first. That part of the portal opens again once you pass it.</span>
        <ul className="ac-required">{h.required.map((r) => <li key={r.id}><Link prefetch={false} className="link" href={r.href}>{r.title}</Link><span className="small muted"> · for {r.area}</span></li>)}</ul>
      </section>}
      {h.counts && !h.all_paths && <p className="small" data-testid="academy-counts">{h.basics_done ? 'Basics passed: your portal and work are open.' : `Basics: ${h.counts.core_passed} of ${h.counts.core_total} sections passed. Passing them opens your portal and work.`} Whole academy: {h.counts.passed} of {h.counts.total} sections.{h.pay_hold ? ' Held pay (commission, bonuses, referral fees and, for Field, customer service, Fleet and Finance, pay for hours) is paid in full on the first pay run after the whole academy is passed.' : ''}</p>}
      {h.all_paths && <p className="small muted" data-testid="academy-admin-all">As an Admin you can open any section, its lessons and its quiz, without passing the one before.</p>}
      <p className="small muted">Pass mark {pct(h.pass_bps)} on each quiz. Each quiz opens once you have had time to read its section; after a failed try, wait before the next one (a few tries a day).</p>
      <Paths paths={h.paths} base={base} />
    </>
  );
}

export async function AcademySectionPage({ userId, base, path, section }: { userId: string; base: string; path: string; section: string }) {
  if (!/^[a-z_]{2,20}$/.test(path) || !/^[a-z0-9-]{2,60}$/.test(section)) notFound();
  const s = await academySection(userId, path, section);
  if ('closed' in s) {
    return (<><PageHead title="Not open yet" kicker="Academy" /><p className="alert alert--warn" role="status"><span>{s.closed}.</span></p><p><Link prefetch={false} className="link" href={base}>Back to my paths</Link></p></>);
  }
  return (
    <>
      <PageHead title={s.title} kicker={`Academy · ${s.path_title}`} purpose={s.blurb}><Link prefetch={false} className="btn btn--quiet btn--sm" href={base}>All sections</Link></PageHead>
      <Study s={s} base={base} />
    </>
  );
}
