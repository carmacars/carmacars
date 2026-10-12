import Link from 'next/link';
import { redirect } from 'next/navigation';
import { auth } from '@/lib/auth';
import { signOut } from '@/server/actions/auth';
import { pageMeta } from '@/features/seo/meta';

// The renter portal's front door. The portal itself (bookings, offers, signing, payment) is the next
// stage of the build; this page proves the session and offers sign out.
export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Your account', path: '/account', noindex: true, description: 'Your CarmaCars account.' });

export default async function Account({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const user = await (await auth()).currentUser();
  if (!user) redirect('/sign-in?next=/account');
  const sp = await searchParams;
  return (
    <section className="section">
      <div className="wrap stack-lg" style={{ maxWidth: '40rem' }}>
        {sp.welcome && <p className="alert alert--ok" role="status"><span className="alert__title">Account created</span><span>You are signed in.</span></p>}
        {sp.password && <p className="alert alert--ok" role="status"><span className="alert__title">Password saved</span><span>You are signed in with your new password.</span></p>}
        <h1 className="d2">Your account</h1>
        <p>Signed in as <b data-testid="account-email">{user.email}</b>.</p>
        <p className="muted">Your requests, offers, agreements and statements will appear here. For now, we send everything about a request by email.</p>
        <div className="row">
          <Link className="btn btn--primary" href="/cars">Find a car</Link>
          <form action={signOut}><button className="btn btn--ghost" type="submit">Sign out</button></form>
        </div>
      </div>
    </section>
  );
}
