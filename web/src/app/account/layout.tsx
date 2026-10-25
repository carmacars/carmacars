import '@/styles/portal.css';
import '@/components/portal-ui/portal-ui.css';
import { rpc } from '@/lib/db/repo';
import { PortalNav } from '@/features/portal/PortalNav';
import { currentUser } from '@/server/portal/data';
import { viewAs } from '@/server/view-as';
import { PortalSwitch, SignOutOrExit } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';

// The renter portal shell (02-booking-and-renter.md section 7): phone-first tabs, then the page.
// Each page checks the session itself (a page without one redirects to sign in).
export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  if (!user) return <>{children}</>;
  const [unread, v] = await Promise.all([
    rpc('my_unread_count', {}, { role: 'authenticated', userId: user.id }).then(Number).catch(() => 0),
    viewAs()
  ]);
  return (
    <div className="pt pt--lux pt--renter">
      <div className="wrap pt__top">
        <div className="pt__hello">
          <p className="small muted">{v ? 'Viewing as' : 'Signed in as'} <b data-testid="account-email">{user.email}</b></p>
          <span className="gd-frame-links"><GuideLink portal="renter" /><SignOutOrExit /></span>
        </div>
        <PortalSwitch current="account" />
        <PortalNav unread={unread || 0} />
        <GuideBanner portal="renter" userId={user.id} />
      </div>
      <div className="wrap pt__body">{children}</div>
    </div>
  );
}
