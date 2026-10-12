import '@/styles/portal.css';
import '@/styles/owner.css';
import { rpc } from '@/lib/db/repo';
import { OwnerNav } from '@/features/owner/OwnerNav';
import { currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';

// The owner portal shell (04-owner.md): the same phone-first frame as the renter portal. Each page
// checks the session and the owner role itself (requireOwner).
export default async function OwnerLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  if (!user) return <>{children}</>;
  const unread = ((await rpc('my_notifications', { p_limit: 100, p_unread_only: true }, { role: 'authenticated', userId: user.id }).catch(() => [])) ?? []) as unknown[];
  return (
    <div className="pt">
      <div className="wrap pt__top">
        <div className="pt__hello">
          <p className="small muted">Owner portal · <b data-testid="account-email">{user.email}</b></p>
          <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form>
        </div>
        <OwnerNav unread={unread.length} />
      </div>
      <div className="wrap pt__body">{children}</div>
    </div>
  );
}
