import '@/styles/alerts.css';
import Link from '@/components/Link';
import { redirect } from 'next/navigation';
import { pageMeta } from '@/features/seo/meta';
import { realUser } from '@/server/portal/data';
import { callNumber } from '@/features/alerts/types';
import { CallNow } from './CallNow';
import { rolesOf } from '@/server/door';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Call', path: '/alerts/call', noindex: true, description: 'Call from a staff alert.' });

// The Call button of a staff phone alert (migration 0466): an alert can only open a page of the site, so it opens this
// one, which hands the number to the phone's dialer (the Quo app when it handles calls on that phone). Signed in only.
export default async function Call({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const to = callNumber((await searchParams).to);
  const user = await realUser();
  if (!user) redirect(`/sign-in?next=${encodeURIComponent(`/alerts/call${to ? `?to=${encodeURIComponent(to)}` : ''}`)}`);
  const back = (await rolesOf(user.id).catch(() => null))?.admin ? '/admin/alerts' : '/staff/alerts';
  return (
    <main className="al-call" id="main" data-testid="alert-call">
      <h1 className="d3">Call</h1>
      {to ? <CallNow to={to} /> : <p>This alert has no number to call.</p>}
      <p className="small muted"><Link prefetch={false} className="link" href={back}>Back to Alerts</Link></p>
    </main>
  );
}
