import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import { realUser as currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';
import { AdminNav } from '@/features/admin/AdminNav';
import { adminGate } from '@/server/admin/data';
import { rpc } from '@/lib/db/repo';
import { PortalSwitch } from '@/features/access/Access';

// The admin portal's frame (docs/blueprint/03-admin.md): the rail of sections, who is signed in, the
// counts that need someone. Every page checks the Admin role and two-step sign-in itself (requireAdmin);
// the frame shows the rail only to an Admin.
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const gate = user ? await adminGate(user).catch(() => null) : null;
  let counts: Record<string, number> = {};
  if (user && gate?.admin) {
    // five numbers for the rail (public.admin_rail_counts, 0036), not the whole dashboard on every admin page
    try {
      const c = (await rpc('admin_rail_counts', { p_admin: user.id }, { role: 'service_role' })) as unknown as Record<'requests' | 'listings' | 'statements' | 'tolls' | 'refunds', number>;
      counts = { '/admin/requests': c.requests, '/admin/listings': c.listings, '/admin/statements': c.statements, '/admin/tolls': c.tolls, '/admin/money': c.refunds };
    } catch { counts = {}; }
  }
  return (
    <div className="ad">
      <div className="ad__frame">
        {gate?.admin ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted">Admin · <b data-testid="account-email">{gate.name ?? user?.email}</b></span>
              <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form></div>
            <PortalSwitch current="admin" />
            <AdminNav counts={counts} />
          </aside>
        ) : <div />}
        <div className="ad__main">{children}</div>
      </div>
    </div>
  );
}
