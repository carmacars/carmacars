import '@/styles/portal.css';
import { rpc } from '@/lib/db/repo';
import { PortalNav } from '@/features/portal/PortalNav';
import { currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';

// The renter portal shell (02-booking-and-renter.md section 7): phone-first tabs, then the page.
// Each page checks the session itself (a page without one redirects to sign in).
export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  if (!user) return <>{children}</>;
  const unread = ((await rpc('my_notifications', { p_limit: 100, p_unread_only: true }, { role: 'authenticated', userId: user.id }).catch(() => [])) ?? []) as unknown[];
  return (
    <div className="pt">
      <div className="wrap pt__top">
        <div className="pt__hello">
          <p className="small muted">Signed in as <b data-testid="account-email">{user.email}</b></p>
          <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form>
        </div>
        <PortalNav unread={unread.length} />
      </div>
      <div className="wrap pt__body">{children}</div>
    </div>
  );
}
