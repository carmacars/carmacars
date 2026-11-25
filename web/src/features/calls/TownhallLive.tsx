import Link from '@/components/Link';
import { Act } from '@/features/admin/Act';
import { Card } from '@/features/admin/ui';
import { door } from '@/server/door';
import { mediaConfig, type Joined } from '@/server/calls';
import data from '@/features/investor/updates-data.json';
import { releasesOfWeek, withReleases, type Release, type Townhall } from '@/features/townhall/model';
import { CallRoom, type DeckSlide } from './CallRoom';
import '@/features/townhall/townhall.css';

// r50 (5010): the weekly townhall in the site: the call beside this week's deck (the presenter, an Admin, moves the
// slides for everyone), attendance recorded by itself. When an Admin switched to the outside link (the media server is
// down) or the media server is not set up, the page offers that link instead.
const when = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(new Date(iso));

export async function TownhallLive({ userId, base }: { userId: string; base: '/admin' | '/staff' }) {
  const v = await door<Townhall & { in_site?: boolean; calls_mode?: string }>(userId, 'ops_read', 'townhall', {});
  const media = mediaConfig();
  const inSite = v.in_site !== false && media.provider !== 'off';
  const back = `${base}/townhall`;
  const slides: DeckSlide[] = v.deck ? withReleases(v.deck.slides, releasesOfWeek(data as unknown as Release[], v.deck.week_of))
    .map((s) => ({ key: s.key, title: s.title, points: s.points ?? [], lines: [...(s.lines ?? []), ...(s.board ?? []).map((b) => `${b.label}: ${b.value}`), ...(s.people ?? []).map((p) => `${p.name} (${p.role})${p.shoutout ? `: ${p.shoutout}` : ''}`), ...(s.note ? [s.note] : [])] })) : [];
  const toggle = v.admin ? <Act action="calls_mode" payload={{ mode: inSite ? 'link' : 'in_site' }} label={inSite ? 'Switch to the outside link' : 'Back to the call in the site'} refresh={[`${base}/townhall/live`, back]}
    confirm={inSite ? 'Everyone joins through the outside call link (Program settings) until you switch back. Use it when the call in the site is down.' : undefined}
    done={inSite ? 'Switched: Join opens the outside link.' : 'Back: the call is in the site.'} testId="calls-mode" /> : null;
  if (!inSite) {
    return (<Card title="The townhall call" testId="townhall-live-fallback" aside={toggle}>
      <p className="small">{v.calls_mode === 'link' ? 'An Admin switched the townhall to the outside call link for now.' : 'The call in the site is not available here.'}</p>
      {v.call_url ? <a className="btn btn--primary btn--sm" href="/api/townhall-join" target="_blank" rel="noopener noreferrer" data-testid="townhall-live-join-link">Join the call</a>
        : <p className="small muted">No outside link is set (Program settings, Townhall call link).</p>}
      <p className="small"><Link prefetch={false} className="link" href={back}>The townhall page</Link></p>
    </Card>);
  }
  let joined: Joined | null = null;
  let why: string | null = null;
  try { joined = await door<Joined>(userId, 'ops_read', 'call_join', { room: 'townhall' }); } catch (e) { why = (e as Error).message; }
  if (!joined) {
    return (<Card title={v.next_at ? `Townhall: ${when(v.next_at)}` : 'Weekly townhall'} testId="townhall-live-wait" aside={toggle}>
      <p className="small" data-testid="townhall-live-why">{why}</p>
      <p className="small"><Link prefetch={false} className="link" href={back}>The deck and the townhall page</Link></p>
    </Card>);
  }
  return (<div className="call-layout">
    {v.admin && <p className="small muted row" data-testid="townhall-live-admin">You present: Next moves everyone&apos;s slide. People shows who is in and who has not joined. {toggle}</p>}
    <CallRoom join={{ as: { room: 'townhall' } }} title={joined.title} slides={slides} live={v.admin} fallbackUrl={v.call_url} leaveHref={back} />
  </div>);
}
