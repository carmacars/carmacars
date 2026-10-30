import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Card, PageHead, Table, t } from '@/features/admin/ui';
import type { Task } from '@/features/va/tasks';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Photo reviews', path: '/staff/reviews', noindex: true, description: 'Handover and return photos to review.' });

// The photo reviews waiting (procedures 3 and 4, within 1 hour): each opens the side-by-side viewer.
export default async function Reviews() {
  const { read } = await vaPage('/staff/reviews', ['fleet']);
  const q = (await read<Task[]>('queue')).filter((x) => x.task_type === 'review_photos');
  return (<>
    <PageHead title="Photo reviews" kicker={`${q.length} waiting`} />
    <Card title="To review" testId="reviews"><Table rows={q as unknown as Array<Record<string, unknown>>} empty="No photo sets waiting." cols={[
      { key: 'due_at', label: 'Due', render: (r) => <span className={r.overdue ? 'ad-late' : undefined}>{t(r.due_at)}</span> }, { key: 'title', label: 'Task', className: 'wrap' },
      { key: 'booking_number', label: 'Booking', render: (r) => r.booking_number ? <Link prefetch={false} className="link" href={`/staff/review/${encodeURIComponent(String(r.booking_number))}?task=${String(r.id)}`}>{String(r.booking_number)}</Link> : null }]} /></Card>
  </>);
}
