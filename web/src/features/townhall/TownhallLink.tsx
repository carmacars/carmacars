import Link from '@/components/Link';
import { door } from '@/server/door';

// 1505: the weekly townhall's call link on the frame of every staff portal (office and field): the next call, and Join
// (through the site, which counts the join) from 15 minutes before; the deck is one tap away.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'short', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

export async function TownhallLink({ userId }: { userId: string }) {
  const v = await door<{ has_link: boolean; next_at: string | null; minutes: number; live: boolean }>(userId, 'ops_read', 'townhall_link').catch(() => null);
  if (!v?.next_at) return null;
  return (
    <p className="small th-link" data-testid="townhall-link">
      <Link prefetch={false} className="link" href="/staff/townhall">Townhall {when(v.next_at)}</Link>
      {v.has_link ? <>{' · '}<a className={v.live ? 'btn btn--sm btn--primary' : 'link'} href="/api/townhall-join" target="_blank" rel="noopener noreferrer" data-testid="townhall-link-join">{v.live ? 'Join now' : 'Call link'}</a></> : null}
    </p>
  );
}
