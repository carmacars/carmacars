import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { Filters, PageHead, t } from '@/features/admin/ui';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Renter messages', path: '/staff/messages', noindex: true, description: 'Messages with renters.' });

type M = { id: string; direction: string; channel: string; body: string | null; subject: string | null; occurred_at: string; booking_number: string; renter_first_name: string | null; sent_by: string | null };
const CHANNEL: Record<string, string> = { sms: 'text', email: 'email', portal: 'portal', whatsapp: 'WhatsApp', phone: 'call', chat: 'chat' };

// Renter messages (05-va.md section 4; a conversation list since October 25, 2026): newest first, the renter's own
// messages marked; each opens its booking's messages, where a quick reply is sent.
export default async function Messages({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ read }, sp] = await Promise.all([vaPage('/staff/messages', ['cs']), searchParams]);
  const all = await read<M[]>('messages');
  const dir = sp.dir === 'inbound' ? 'inbound' : '';
  const rows = all.filter((r) => !dir || r.direction === 'inbound');
  const inbound = all.filter((r) => r.direction === 'inbound').length;
  return (
    <>
      <PageHead title="Renter messages" purpose="Every message with a renter, newest first. Open one to read the whole conversation and reply." />
      <Filters base="/staff/messages" name="dir" value={dir} sp={sp} options={[['', `All (${all.length})`], ['inbound', `From renters (${inbound})`]]} />
      {rows.length ? (
        <ul className="va-msgs" data-testid="messages-inbox" aria-label="Messages">
          {rows.map((r) => {
            const inb = r.direction === 'inbound';
            const who = inb ? r.renter_first_name ?? 'Renter' : r.sent_by ?? 'CarmaCars';
            return (
              <li key={r.id} className={`va-msg${inb ? ' va-msg--in' : ''}`}>
                <span className="va-msg__avatar" aria-hidden="true">{who.trim().charAt(0).toUpperCase() || 'C'}</span>
                <span className="va-msg__text">
                  <span className="va-msg__who"><Link prefetch={false} className="link" href={`/staff/bookings/${encodeURIComponent(r.booking_number)}?tab=messages`}>{who}</Link>
                    <span className="va-msg__dir">{inb ? 'to CarmaCars' : 'to the renter'}{CHANNEL[r.channel] ? ` by ${CHANNEL[r.channel]}` : ''} · {r.booking_number}</span></span>
                  <span className="va-msg__body">{r.body ?? r.subject ?? ''}</span>
                </span>
                <span className="va-msg__when">{t(r.occurred_at)}</span>
              </li>);
          })}
        </ul>
      ) : <p className="ad-empty" data-testid="messages-inbox-empty">{all.length ? 'No message from a renter yet. Choose All to see every message.' : 'No messages yet. Messages with renters appear here as they come in.'}</p>}
    </>
  );
}
