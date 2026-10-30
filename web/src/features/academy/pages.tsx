import Link from 'next/link';
import { notFound } from 'next/navigation';
import '@/features/academy/academy.css';
import { PageHead } from '@/features/admin/ui';
import { academyHome, academySection } from '@/server/academy';
import { Paths } from './Paths';
import { Study } from './Study';
import { pct } from './model';

// The two pages of the academy, for staff (/staff/academy) and for an Admin taking the Admin path (/admin/academy/learn).
export async function AcademyHomePage({ userId, base, locked }: { userId: string; base: string; locked?: boolean }) {
  const h = await academyHome(userId);
  return (
    <>
      <PageHead title="Academy" kicker="Training" purpose="Your training path: watch each lesson (narrated by your browser, with captions), then pass the section's quiz to open the next one." />
      {(locked || h.locked) && <p className="alert alert--warn" role="status" data-testid="academy-locked"><span className="alert__title">Training first</span><span>The rest of the portal opens once you pass your path{h.paths.length > 1 ? 's' : ''}.</span></p>}
      <p className="small muted">Pass mark {pct(h.pass_bps)} on each quiz. Retries are allowed.</p>
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
