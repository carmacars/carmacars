import Link from '@/components/Link';
import { pageMeta } from '@/features/seo/meta';
import { getSettings } from '@/lib/site';
import { readClaim } from '@/features/returns/server';
import { ReturnedForm } from '@/features/returns/ReturnedForm';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: "I've returned the car", path: '/returned', noindex: true, description: 'Tell us the car is back: the late notices stop while we check.' });

const when = (iso: string) => new Date(iso).toLocaleString('en-CA', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });

// The one-tap link of every overdue notice (migration 0532): the renter's "I've returned the car" form, without sign-in
// (the booking's return_link_token is the key). Opening it changes nothing (mail scanners open links); the button sends it.
export default async function Returned({ params }: { params: Promise<{ token: string }> }) {
  const [{ token }, s] = await Promise.all([params, getSettings()]);
  const c = await readClaim(token);
  const phone = s.phone_display ? <a className="link" href={`tel:${String(s.phone_display).replace(/[^\d+]/g, '')}`}>{s.phone_display}</a> : null;
  return (
    <section className="section">
      <div className="wrap stack" style={{ maxWidth: '40rem' }} data-testid="returned-page">
        {!c ? (<>
          <h1 className="d2">This link does not work</h1>
          <p className="lead">It may be incomplete. Use the link in the email or text again{phone ? <>, or call us at {phone}</> : null}.</p>
        </>) : c.done ? (<>
          <h1 className="d2">Your return is recorded</h1>
          <p className="lead">Booking {c.number} is checked out. Thank you.</p>
        </>) : c.return_state === 'returned_pending_confirmation' ? (<>
          <h1 className="d2">We have your report</h1>
          <p className="lead">You told us the {c.car ?? 'car'} is back{c.claim ? ` (${when(c.claim.claimed_at)})` : ''}. The late notices are stopped while we check the car and confirm the return.</p>
        </>) : !c.can_report ? (<>
          <h1 className="d2">Nothing to report on this booking</h1>
          <p className="lead">Booking {c.number} is not out with you right now{phone ? <>. Questions: call us at {phone}</> : null}.</p>
        </>) : (<>
          <h1 className="d2">I&apos;ve returned the car</h1>
          <p className="lead">Booking {c.number}, the {c.car ?? 'car'}, was due back {when(c.return_at)}{c.return_place ? ` at ${c.return_place}` : ''}. Tell us it is back: the late notices stop at once while we check.</p>
          {c.claim?.status === 'denied' && <p className="alert alert--warn" role="status"><span>We could not confirm your last report{c.claim.decision_note ? `: ${c.claim.decision_note}` : ''}. Send it again once the car is back.</span></p>}
          <ReturnedForm token={token} />
          <p className="small muted">Not back yet? Return it now or extend in your booking. The late notices go on until the car is back.</p>
        </>)}
        <p><Link className="link" href="/account">Your bookings</Link></p>
      </div>
    </section>
  );
}
