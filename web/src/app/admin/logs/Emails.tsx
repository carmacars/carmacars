import type { AdminPage } from '@/server/admin/api';
import { ListFilters } from '@/features/list-filters/ListFilters';
import { Act } from '@/features/admin/Act';
import { Badge, BookingLink, PageHead, Search, Table, Tiles, t } from '@/features/admin/ui';
import Link from '@/components/Link';

type R = Record<string, unknown>;
// r41 (2570): which provider sent each email, from its provider id (ses:, cf:, else Resend)
const sentBy = (id: unknown) => { const s = typeof id === 'string' ? id : ''; return !s ? null : s.startsWith('ses:') ? 'Amazon SES' : s.startsWith('cf:') ? 'Cloudflare' : 'Resend'; };

// Settings > Logs > Emails and Blocked addresses (was /admin/messages until r27, which redirects): every email the site
// queued, with resend, cancel and text it instead; and the addresses no email goes to.
export async function Emails({ ctx: { list, read }, sp, tab }: { ctx: AdminPage; sp: Record<string, string | undefined>; tab: 'emails' | 'blocked' }) {
  if (tab === 'blocked') {
    const { rows } = await list('email_suppressions', { limit: 300 });
    return (<><PageHead title="Blocked addresses" purpose="Addresses no email goes to: bounced, complained, unsubscribed, or added by hand."><Act action="suppression_add" label="Suppress an address" fields={[{ name: 'email', label: 'Email', type: 'email', required: true }, { name: 'scope', label: 'Scope', type: 'select', required: true, value: 'all', options: [['all', 'All email'], ['marketing', 'Marketing only']] }, { name: 'detail', label: 'Why' }]} refresh={['/admin/logs']} /></PageHead>
      <Table<R> testId="suppressions" rows={rows} empty="No suppressed addresses: every email can be delivered." cols={[{ key: 'email', label: 'Email' }, { key: 'scope', label: 'Scope' }, { key: 'reason', label: 'Reason' }, { key: 'detail', label: 'Detail', className: 'wrap' }, { key: 'created_at', label: 'Since', render: (r) => t(r.created_at) },
        { key: 'act', label: '', render: (r) => r.lifted_at ? `lifted ${t(r.lifted_at)}` : <Act action="suppression_lift" payload={{ id: r.id }} label="Lift" fields={[{ name: 'reason', label: 'Reason', required: true }]} refresh={['/admin/logs']} /> }]} /></>);
  }
  const [{ rows, count }, u] = await Promise.all([list('notification_outbox', { eq: sp.status ? { status: sp.status } : {}, q: sp.q, limit: 200 }),
    read<{ total: number; outbox: number; auth: number; cap: number; warn_at: number; held: number; failed_today: number }>('email_usage').catch(() => null)]);
  return (<><PageHead title="Emails" kicker={`${count} messages`} purpose="Every email the site sent or is waiting to send. Resend one, cancel one, or text it instead."><Search action="/admin/logs?tab=emails" value={sp.q} placeholder="Address or email code" /></PageHead>
    {u && <Tiles items={[{ k: 'Sent today', v: String(u.total), sub: `${u.auth} sign-in emails`, warn: u.total >= u.warn_at },
      { k: 'Held for the limit', v: String(u.held), href: '/admin/logs?tab=emails&status=delayed', warn: u.held > 0 }, { k: 'Failed today', v: String(u.failed_today), href: '/admin/logs?tab=emails&status=failed', warn: u.failed_today > 0 },
      { k: 'In this list', v: String(count) }]} />}
    {u && <p className={`alert ${u.total >= u.warn_at ? 'alert--warn' : 'alert--info'}`} data-testid="email-usage"><span>Today: {u.total} sent ({u.outbox} from this list, {u.auth} sign-in emails.) On a busy day digests and marketing wait first; booking and sign-in emails go last. The daily capacity is on <Link prefetch={false} className="link" href="/admin/settings/usage">Settings &gt; Usage</Link>. Held for the limit: {u.held}. Failed today: {u.failed_today}.</span></p>}
    <ListFilters id="admin-logs-emails-status" base="/admin/logs?tab=emails" sp={sp} chips={{ name: 'status', label: 'Status', value: sp.status ?? '', options: [['', 'All'], ['queued', 'Queued'], ['delayed', 'Held'], ['sent', 'Sent'], ['merged', 'Sent combined'], ['suppressed', 'Repeats held back'], ['failed', 'Failed']] }} />
    <Table<R> testId="outbox" rows={rows} empty="No emails match. Clear a filter, or search by address or booking." cols={[{ key: 'created_at', label: 'Created', render: (r) => t(r.created_at) }, { key: 'code', label: 'Email' }, { key: 'to_address', label: 'To' }, { key: 'booking_number', label: 'Booking', render: (r) => r.booking_number ? <BookingLink n={r.booking_number} /> : null },
      { key: 'status', label: 'Status', render: (r) => <Badge s={String(r.status)} /> }, { key: 'attempts', label: 'Tries', num: true }, { key: 'sent_at', label: 'Sent', render: (r) => t(r.sent_at) },
      { key: 'provider_id', label: 'Sent by', render: (r) => sentBy(r.provider_id) }, { key: 'last_error', label: 'Error', className: 'wrap' },
      { key: 'status_reason', label: 'Why', className: 'wrap' },
      { key: 'act', label: '', render: (r) => <span className="ad-actions"><Act action="outbox_resend" payload={{ id: r.id }} label="Resend" refresh={['/admin/logs']} />{['queued', 'delayed'].includes(String(r.status)) && <Act action="outbox_cancel" payload={{ id: r.id }} label="Cancel" refresh={['/admin/logs']} />}
        {/* 0212: an email waiting (held for the limit, or queued) goes by text at once; the email still goes later */}
        {['queued', 'delayed'].includes(String(r.status)) && (r.limit_texted_at
          ? <span className="small muted" data-testid={`outbox-texted-${String(r.id)}`}>Texted {t(r.limit_texted_at)}</span>
          : <Act action="outbox_text" payload={{ id: r.id }} label="Text it instead" refresh={['/admin/logs']} done="Text queued: it goes within five minutes. The email still goes when the limit lifts." testId={`outbox-text-${String(r.id)}`} confirm="Send this message by text to the person's mobile now? The email still goes when the limit lifts." />)}</span> }]} /></>);
}
