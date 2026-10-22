import Link from 'next/link';
import { redirect } from 'next/navigation';
import { PageHead } from '@/components/Blocks';
import { pageMeta } from '@/features/seo/meta';
import { pendingView } from '@/server/capture';
import { realUser } from '@/server/portal/data';
import { leavePending } from '@/server/actions/capture';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your request', path: '/my-request', noindex: true, description: 'Continue the request you started on this device.' });

const day = (iso: string | null) => (iso ? new Date(iso + (iso.length === 10 ? 'T12:00:00' : '')).toLocaleDateString('en-CA', { month: 'short', day: 'numeric', timeZone: 'America/Toronto' }) : '');
const STATUS: Record<string, string> = { requested: 'Sent: we are checking the car and the price', offered: 'Offer ready: confirm your email to see it', declined: 'Declined', expired: 'Expired', pending_payment: 'Approved: waiting for payment' };

// Contact capture (migration 0090): what this browser started, without a sign-in. The unverified session sees only
// what was made on this device during it; accepting an offer, signing, paying and uploads need the emailed link,
// which signs in and confirms the email.
export default async function MyRequest() {
  if (await realUser().catch(() => null)) redirect('/account');
  const v = await pendingView();
  const trail: [string, string?][] = [['Home', '/'], ['Your request']];
  if (!v) {
    return (
      <div className="p-contact">
        <PageHead trail={trail} h1="Nothing started on this device." lead="Sign in to see your trips, or pick a car to start a request." />
        <section className="section"><div className="wrap stack"><p><Link className="btn btn--primary" href="/cars">Find a car</Link> <Link className="btn" href="/sign-in">Sign in</Link></p></div></section>
      </div>
    );
  }
  const first = (v.name || '').split(' ')[0] || 'there';
  return (
    <div className="p-contact">
      <PageHead trail={trail} h1={`Hi ${first}, here is what you started.`} lead="Saved on this device. You do not need a password to carry on here." />
      <section className="section">
        <div className="wrap stack-lg" data-testid="my-request">
          <div className="alert" role="note"><span className="alert__title">Email not confirmed yet</span>
            <span>We opened an account for {v.email}. To accept an offer, sign or pay, open the link in the email &quot;Continue your request&quot; we send to that address: one tap signs you in and confirms it.</span></div>
          {v.drafts.length > 0 && (
            <div className="stack"><h2 className="d3">Not sent yet</h2>
              <ul className="stack">{v.drafts.map((d) => (
                <li key={d.id}>{d.form_code === 'booking_request'
                  ? <><b>{d.car_name ?? 'A booking request'}</b>{d.from ? `, ${day(d.from)} to ${day(d.to)}` : ''}. <Link className="link" href={d.car ? `/book/${d.car}` : '/cars'}>Continue the request</Link></>
                  : <><b>Owner application</b>. <Link className="link" href="/list-your-car/apply">Continue the application</Link></>}</li>))}</ul></div>)}
          {v.bookings.length > 0 && (
            <div className="stack"><h2 className="d3">Sent</h2>
              <ul className="stack">{v.bookings.map((b) => <li key={b.number} data-testid="my-request-booking"><b>{b.number}</b>, {b.car}, {day(b.pickup_at.slice(0, 10))} to {day(b.return_at.slice(0, 10))}: {STATUS[b.status] ?? b.status.replace(/_/g, ' ')}</li>)}</ul></div>)}
          {v.chats.length > 0 && <p className="small muted">Your chat with us ({v.chats.map((c) => c.number).join(', ')}) stays open in the chat button.</p>}
          {!v.drafts.length && !v.bookings.length && <p><Link className="btn btn--primary" href="/cars">Find a car</Link></p>}
          <form action={leavePending}><button className="btn btn--ghost btn--sm" type="submit">Not you? Forget this device</button></form>
        </div>
      </section>
    </div>
  );
}
