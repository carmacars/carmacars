import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { CallRoom } from '@/features/calls/CallRoom';
import { guestSession, mediaConfig } from '@/server/calls';

// r50 (5010): a candidate's interview call, from the link in their booking email; no account. Opening the page uses
// nothing (an email scanner may open it); Join uses the link (POST /api/calls/guest), which then works in this browser only.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your interview call | CarmaCars', path: '/call/i', noindex: true,
  description: 'Your interview call with CarmaCars, in your browser. Allow your camera and microphone when asked.' });
const SR = { role: 'service_role' as const };
const at = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', weekday: 'long', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZoneName: 'short' }).format(new Date(iso));
interface Peek { state: 'open' | 'early' | 'over' | 'replaced' | 'not_booked' | 'not_found'; used: boolean; first_name?: string; role_title?: string; starts_at?: string; opens_at?: string; booking_url?: string }
const WORDS: Record<string, string> = {
  used: 'This link was already opened in another browser. Open it on the device you first used, or reply to your booking email and we will send a new one.',
  replaced: 'This link was replaced: your call was moved or cancelled. Use the link in your newest email.',
  not_booked: 'This call is no longer booked. Book another time from your booking link.',
  over: 'This call has ended. If you missed it, reply to your booking email.',
  early: 'It is too early: the call opens 15 minutes before it starts.',
  not_found: 'This link is not valid. Open the link in our email again.',
  bad_session: 'Your browser blocked the call\'s cookie. Allow cookies for carmacars.ca and try again.',
};

export default async function GuestCall({ params, searchParams }: { params: Promise<{ token: string }>; searchParams: Promise<Record<string, string | undefined>> }) {
  const [{ token }, sp] = await Promise.all([params, searchParams]);
  const ok = /^[0-9a-f]{64}$/.test(token);
  const peek = ok ? ((await rpc('server_call_guest_peek', { p_token: token }, SR)) as unknown as Peek) : null;
  const session = ok ? await guestSession() : null;
  const media = mediaConfig().provider !== 'off';
  return (
    <div className="p-careers">
      <section className="section">
        <div className="wrap stack-lg">
          {session && media
            ? <><h1 className="d2">Your interview call, {session.first_name}</h1>
                <CallRoom join={{ guest: true }} title={`${session.role_title}: ${at(session.starts_at)}`} leaveHref={session.booking_url} /></>
            : <div className="cr-narrow stack">
                <h1 className="d2">{peek?.first_name ? `Your interview call, ${peek.first_name}` : 'Your interview call'}</h1>
                {peek?.starts_at && <p data-testid="guest-when">{peek.role_title}: {at(peek.starts_at)}.</p>}
                {sp.e && <p className="alert alert--error" role="alert" data-testid="guest-error"><span>{WORDS[sp.e] ?? WORDS.not_found}</span></p>}
                {!sp.e && peek && peek.state !== 'open' && <p className="alert alert--warn" role="status" data-testid="guest-state"><span>{WORDS[peek.state]}{peek.state === 'early' && peek.opens_at ? ` It opens at ${at(peek.opens_at)}.` : ''}</span></p>}
                {!media && <p className="alert alert--warn" role="status"><span>The call in the site is not available right now: we will call you or email you a link.</span></p>}
                {peek?.state === 'open' && media && <form method="post" action="/api/calls/guest" className="stack">
                  <input type="hidden" name="token" value={token} />
                  <p className="small">Use a phone or a computer with a camera, in a quiet place. Your browser asks for the camera and the microphone: allow both. This link works in one browser only.</p>
                  <div><button type="submit" className="btn btn--primary" data-testid="guest-join">Join the call</button></div>
                </form>}
                {peek?.booking_url && <p className="small"><Link prefetch={false} className="link" href={peek.booking_url}>Move or cancel the call</Link></p>}
              </div>}
        </div>
      </section>
    </div>
  );
}
