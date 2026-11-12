import Link from '@/components/Link';
import { door } from '@/server/door';
import { Card } from '@/features/admin/ui';
import { requestNow } from '@/features/va/lanes';
import { townhallCard, type TownhallLinkRead } from './model';

// 2590: the weekly townhall on every portal home (office staff of every function, field staff, Admin Today) from the day
// before until the call ends: the time, a countdown, Join (from 15 minutes before; through the site, which counts the
// join), the calendar invite, and the warning for whoever missed the last one.
export async function TownhallCard({ userId, admin = false }: { userId: string; admin?: boolean }) {
  const v = await door<TownhallLinkRead>(userId, admin ? 'admin_read' : 'ops_read', 'townhall_link').catch(() => null);
  const c = townhallCard(v, requestNow());
  if (!c || !v) return null;
  const page = admin ? '/admin/townhall' : '/staff/townhall';
  return (
    <Card title={c.headline} testId="townhall-card" tone={c.warn || c.joinOpen ? 'warn' : 'next'}
      aside={<span className="ad-pill" data-testid="townhall-card-countdown">{c.countdown}</span>}>
      <p className="small">{c.when}. {c.checkedIn ? 'You are checked in.' : 'Joining through the button checks you in.'}</p>
      {c.warn && <p className="alert alert--warn" role="status" data-testid="townhall-card-warn"><span>{c.warn}</span></p>}
      <div className="row">
        {c.joinOpen && !c.checkedIn
          ? (v.has_link
            ? <a className="btn btn--primary btn--sm" href="/api/townhall-join" target="_blank" rel="noopener noreferrer" data-testid="townhall-card-join">Join / check in</a>
            : <Link prefetch={false} className="btn btn--primary btn--sm" href={page} data-testid="townhall-card-join">Check in</Link>)
          : <span className="btn btn--sm btn--ghost" aria-disabled="true" data-testid="townhall-card-join-later">{c.checkedIn ? 'Checked in' : 'Join opens 15 minutes before'}</span>}
        <a className="btn btn--ghost btn--sm" href="/api/townhall-ics" download="carmacars-townhall.ics" data-testid="townhall-card-ics">Add to calendar</a>
        <Link prefetch={false} className="link small" href={page}>Townhall page</Link>
      </div>
    </Card>
  );
}
