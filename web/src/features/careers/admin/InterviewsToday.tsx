import Link from '@/components/Link';
import { door } from '@/server/door';
import { Card } from '@/features/admin/ui';
import { callLinkLabel, type InterviewCall } from '@/features/careers/model';

// 2590: Admin Today: the day's interview calls (booked, and the ones already held), with the call link of each.
export async function InterviewsToday({ userId }: { userId: string }) {
  const calls = await door<InterviewCall[]>(userId, 'admin_read', 'interviews_today').catch(() => null);
  if (!calls?.length) return null;
  const time = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));
  const booked = calls.filter((c) => c.status === 'booked').length;
  return (
    <Card title={`Interviews today (${calls.length})`} testId="interviews-today" tone={booked ? 'next' : undefined} aside={<Link prefetch={false} className="link small" href="/admin/hiring?tab=calls">Calls</Link>}>
      <ul className="ad-sched">{calls.map((c) => (
        <li key={c.id} data-testid={`interview-${c.id}`}><time className="ad-sched__time">{time(c.starts_at)}</time>
          <span className="ad-sched__body"><span><Link prefetch={false} className="link" href={`/admin/hiring/${c.id}`}>{c.name}</Link></span><span className="ad-sub">{c.role}</span></span>
          {c.status === 'booked' && c.link
            ? <a className="btn btn--primary btn--sm" href={c.link} target={c.link.startsWith('tel:') ? undefined : '_blank'} rel="noopener noreferrer">{callLinkLabel(c)}</a>
            : <span className={c.status === 'booked' ? 'ad-pill ad-pill--red' : 'ad-pill'}>{c.status === 'booked' ? 'no link' : c.status === 'no_show' ? 'no show' : 'done'}</span>}
        </li>))}</ul>
    </Card>
  );
}
