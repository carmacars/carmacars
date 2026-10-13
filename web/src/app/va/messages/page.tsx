import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead, Table, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter messages', path: '/va/messages', noindex: true, description: 'Messages with renters.' });

type M = { id: string; direction: string; channel: string; body: string | null; subject: string | null; occurred_at: string; booking_number: string; renter_first_name: string | null; sent_by: string | null };

// Renter messages (05-va.md section 4): newest first; each opens its booking's messages, where a quick reply is sent.
export default async function Messages() {
  const { read } = await vaPage('/va/messages', ['cs']);
  const rows = await read<M[]>('messages');
  return (
    <>
      <PageHead title="Renter messages" />
      <Table<M & Record<string, unknown>> testId="messages-inbox" rows={rows as Array<M & Record<string, unknown>>} empty="No messages." cols={[
        { key: 'occurred_at', label: 'When', render: (r) => t(r.occurred_at) },
        { key: 'booking_number', label: 'Booking', render: (r) => <Link prefetch={false} className="link" href={`/va/bookings/${encodeURIComponent(r.booking_number)}?tab=messages`}>{r.booking_number}</Link> },
        { key: 'who', label: 'From', render: (r) => (r.direction === 'inbound' ? r.renter_first_name ?? 'Renter' : r.sent_by ?? 'CarmaCars') },
        { key: 'body', label: 'Message', className: 'wrap', render: (r) => r.body ?? r.subject ?? '' }]} />
    </>
  );
}
