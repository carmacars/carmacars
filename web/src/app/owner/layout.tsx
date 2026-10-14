import '@/styles/portal.css';
import '@/styles/owner.css';
import { rpc } from '@/lib/db/repo';
import { OwnerNav } from '@/features/owner/OwnerNav';
import { currentUser } from '@/server/portal/data';
import { PortalSwitch, SignOutOrExit } from '@/features/access/Access';

// The owner portal shell (04-owner.md): the same phone-first frame as the renter portal. Each page
// checks the session and the owner role itself (requireOwner).
export default async function OwnerLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  if (!user) return <>{children}</>;
  const unread = await rpc('my_unread_count', {}, { role: 'authenticated', userId: user.id }).then(Number).catch(() => 0);
  return (
    <div className="pt">
      <div className="wrap pt__top">
        <div className="pt__hello">
          <p className="small muted">Owner portal · <b data-testid="account-email">{user.email}</b></p>
          <SignOutOrExit />
        </div>
        <PortalSwitch current="owner" />
        <OwnerNav unread={unread || 0} />
      </div>
      <div className="wrap pt__body">{children}</div>
    </div>
  );
}
