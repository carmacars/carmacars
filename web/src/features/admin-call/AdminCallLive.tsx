import Link from '@/components/Link';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { mediaConfig, type Joined } from '@/server/calls';
import { CallRoom } from '@/features/calls/CallRoom';
import { callSlides, type AdminCall } from './model';

// r50 hotfix 2 (5150): the Admin call in the site: the call beside this week's deck (either Admin presents), in its own
// room that only Admins may join. When the call in the site is off, the page says so.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

export async function AdminCallLive({ userId }: { userId: string }) {
  const v = await door<AdminCall>(userId, 'admin_read', 'admin_call', {});
  const back = '/admin/admin-call';
  if (!v.in_site || mediaConfig().provider === 'off') {
    return (<Card title="The Admin call" testId="ac-live-off"><p className="small">The call in the site is not available here right now.</p>
      <p className="small"><Link prefetch={false} className="link" href={back}>The deck</Link></p></Card>);
  }
  let joined: Joined | null = null;
  let why: string | null = null;
  try { joined = await door<Joined>(userId, 'admin_read', 'call_join', { room: 'admin_call' }); } catch (e) { why = (e as Error).message; }
  if (!joined) {
    return (<Card title={v.next_at ? `Admin call: ${when(v.next_at)}` : 'Weekly Admin call'} testId="ac-live-wait">
      <p className="small" data-testid="ac-live-why">{why}</p><p className="small"><Link prefetch={false} className="link" href={back}>The deck</Link></p></Card>);
  }
  return (<div className="call-layout" data-testid="ac-live">
    <p className="small muted">Approve and Deny are on <Link prefetch={false} className="link" href={back}>the deck page</Link>: open it beside the call.</p>
    <CallRoom join={{ as: { room: 'admin_call' } }} title={joined.title} slides={v.deck ? callSlides(v.deck.slides) : []} live fallbackUrl={null} leaveHref={back} />
  </div>);
}
