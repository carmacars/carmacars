import Link from 'next/link';
import { pageMeta } from '@/features/seo/meta';
import { rpc } from '@/lib/db/repo';
import { getSettings } from '@/lib/site';
import { unsubscribe } from '@/server/actions/unsubscribe';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Unsubscribe', path: '/unsubscribe', noindex: true, description: 'Stop offers and review requests by email.' });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Info = { valid: boolean; masked_email: string | null; already_unsubscribed: boolean };

// The unsubscribe link of every marketing email (come-back offers, review requests). Opening the link changes
// nothing (mail scanners open links); the button does. Booking and account emails continue.
export default async function Unsubscribe({ searchParams }: { searchParams: Promise<{ token?: string; done?: string }> }) {
  const { token = '', done } = await searchParams;
  const s = await getSettings();
  const info: Info = UUID.test(token) ? ((await rpc('server_unsubscribe_info', { p_token: token }, { role: 'service_role' })) as unknown as Info) : { valid: false, masked_email: null, already_unsubscribed: false };
  return (
    <section className="section">
      <div className="wrap stack" style={{ maxWidth: '40rem' }}>
        {!info.valid ? (<>
          <h1 className="d2">This link does not work</h1>
          <p className="lead">It may be incomplete. Use the link at the bottom of the email again{s.public_email ? <>, or write to <a className="link" href={`mailto:${s.public_email}`}>{s.public_email}</a> and we will take you off the list</> : null}.</p>
        </>) : info.already_unsubscribed || done ? (<>
          <h1 className="d2">You are unsubscribed</h1>
          <p className="lead" role="status">{info.masked_email} will get no more offers or review requests from {s.brand_name}. Emails about your bookings and your account still arrive.</p>
          <p className="small muted">Changed your mind? Turn offers back on in your account under Notifications.</p>
        </>) : (<>
          <h1 className="d2">Unsubscribe from offers</h1>
          <p className="lead">Stop offers and review requests to {info.masked_email}. Emails about your bookings and your account still arrive.</p>
          <form action={unsubscribe}><input type="hidden" name="token" value={token} /><button className="btn btn--primary btn--lg" type="submit">Unsubscribe</button></form>
        </>)}
        <p><Link className="link" href="/">Back to {s.brand_name}</Link></p>
      </div>
    </section>
  );
}
