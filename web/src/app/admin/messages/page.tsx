import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { Act } from '@/features/admin/Act';
import { Badge, BookingLink, Filters, PageHead, Search, Table, Tabs, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Email', path: '/admin/messages', noindex: true, description: 'Notification outbox and suppressions.' });
type R = Record<string, unknown>;

export default async function Messages({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ list }, sp] = await Promise.all([page('/admin/messages'), searchParams]);
  const tab = sp.tab ?? 'outbox';
  const tabs = <Tabs current={`/admin/messages?tab=${tab}`} items={[['/admin/messages?tab=outbox', 'Outbox'], ['/admin/messages?tab=suppressions', 'Suppressions']]} />;
  if (tab === 'suppressions') {
    const { rows } = await list('email_suppressions', { limit: 300 });
    return (<><PageHead title="Email"><Act action="suppression_add" label="Suppress an address" fields={[{ name: 'email', label: 'Email', type: 'email', required: true }, { name: 'scope', label: 'Scope', type: 'select', required: true, value: 'all', options: [['all', 'All email'], ['marketing', 'Marketing only']] }, { name: 'detail', label: 'Why' }]} refresh={['/admin/messages']} /></PageHead>{tabs}
      <Table<R> testId="suppressions" rows={rows} empty="No suppressed addresses." cols={[{ key: 'email', label: 'Email' }, { key: 'scope', label: 'Scope' }, { key: 'reason', label: 'Reason' }, { key: 'detail', label: 'Detail', className: 'wrap' }, { key: 'created_at', label: 'Since', render: (r) => t(r.created_at) },
        { key: 'act', label: '', render: (r) => r.lifted_at ? `lifted ${t(r.lifted_at)}` : <Act action="suppression_lift" payload={{ id: r.id }} label="Lift" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={['/admin/messages']} /> }]} /></>);
  }
  const { rows, count } = await list('notification_outbox', { eq: sp.status ? { status: sp.status } : {}, q: sp.q, limit: 200 });
  return (<><PageHead title="Email" kicker={`${count} messages`}><Search action="/admin/messages" value={sp.q} placeholder="Address or email code" /></PageHead>{tabs}
    <Filters base="/admin/messages" name="status" value={sp.status ?? ''} sp={sp} options={[['', 'All'], ['queued', 'Queued'], ['sent', 'Sent'], ['failed', 'Failed'], ['suppressed', 'Suppressed'], ['skipped', 'Skipped']]} />
    <Table<R> testId="outbox" rows={rows} empty="No messages." cols={[{ key: 'created_at', label: 'Created', render: (r) => t(r.created_at) }, { key: 'code', label: 'Email' }, { key: 'to_address', label: 'To' }, { key: 'booking_number', label: 'Booking', render: (r) => r.booking_number ? <BookingLink n={r.booking_number} /> : null },
      { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'attempts', label: 'Tries', num: true }, { key: 'sent_at', label: 'Sent', render: (r) => t(r.sent_at) }, { key: 'last_error', label: 'Error', className: 'wrap' },
      { key: 'act', label: '', render: (r) => <span className="ad-actions"><Act action="outbox_resend" payload={{ id: r.id }} label="Resend" refresh={['/admin/messages']} />{['queued', 'delayed'].includes(String(r.status)) && <Act action="outbox_cancel" payload={{ id: r.id }} label="Cancel" refresh={['/admin/messages']} />}</span> }]} /></>);
}
