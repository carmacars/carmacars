import '@/styles/portal.css';
import '@/components/portal-ui/portal-ui.css';
import '@/styles/portal-revamp.css';
import '@/styles/ui-kit.css';
import { redirect } from 'next/navigation';
import { rpc } from '@/lib/db/repo';
import { rolesOf } from '@/server/door';
import { PortalNav } from '@/features/portal/PortalNav';
import { currentUser } from '@/server/portal/data';
import { viewAs } from '@/server/view-as';
import { PortalSwitch, SignOutOrExit } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';
import { StuckHelp } from '@/features/help/StuckHelp';
import { TermsGate } from '@/features/terms/TermsGate';
import { PushInvite } from '@/features/push/PushAlerts';

// The renter portal shell (02-booking-and-renter.md section 7): phone-first tabs, then the page.
// Each page checks the session itself (a page without one redirects to sign in).
export default async function AccountLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  if (!user) return <>{children}</>;
  const [unread, v, roles] = await Promise.all([
    rpc('my_unread_count', {}, { role: 'authenticated', userId: user.id }).then(Number).catch(() => 0),
    viewAs(),
    rolesOf(user.id).catch(() => null)
  ]);
  // an Admin account has no renter portal (the owner, November 7): its renter profile and bookings stay on file
  if (roles?.admin && !v) redirect('/admin');
  return (
    <div className="pt pt--lux pt--rv pt--renter">
      <div className="wrap pt__top">
        <div className="pt__hello">
          <p className="small muted">{v ? 'Viewing as' : 'Signed in as'} <b data-testid="account-email">{user.email}</b></p>
          <span className="gd-frame-links"><GuideLink portal="renter" /><SignOutOrExit /></span>
        </div>
        <PortalSwitch current="account" />
        <PortalNav unread={unread || 0} />
        <GuideBanner portal="renter" userId={user.id} /><StuckHelp portal="renter" />
        <PushInvite portal="renter" home="/account" />
      </div>
      <div className="wrap pt__body"><TermsGate userId={user.id} portal="renter">{children}</TermsGate></div>
    </div>
  );
}
