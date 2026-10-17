import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import { realUser as currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';
import { AdminNav, AdminSearch } from '@/features/admin/AdminNav';
import { adminGate } from '@/server/admin/data';
import { rpc } from '@/lib/db/repo';
import { PortalSwitch } from '@/features/access/Access';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';

// The admin portal's frame (docs/blueprint/03-admin.md; simpler since October 16, 2026): who is signed in, one search
// box, seven groups of pages with the counts that need someone. Every page checks the Admin role and two-step sign-in itself (requireAdmin);
// the frame shows the rail only to an Admin.
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const gate = user ? await adminGate(user).catch(() => null) : null;
  let counts: Record<string, number> = {};
  if (user && gate?.admin) {
    // five numbers for the rail (public.admin_rail_counts, 0036), not the whole dashboard on every admin page
    try {
      const c = (await rpc('admin_rail_counts', { p_admin: user.id }, { role: 'service_role' })) as unknown as Record<'requests' | 'listings' | 'statements' | 'tolls' | 'refunds' | 'applications', number>;
      counts = { '/admin/requests': c.requests, '/admin/listings': c.listings, '/admin/statements': c.statements, '/admin/tolls': c.tolls, '/admin/money': c.refunds, '/admin/applications': c.applications ?? 0 };
    } catch { counts = {}; }
  }
  return (
    <div className="ad">
      <div className="ad__frame">
        {gate?.admin ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted">Admin · <b data-testid="account-email">{gate.name ?? user?.email}</b></span>
              <span className="gd-frame-links"><GuideLink portal="admin" /><form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form></span></div>
            <PortalSwitch current="admin" />
            <AdminSearch />
            <AdminNav counts={counts} />
          </aside>
        ) : <div />}
        <div className="ad__main">{gate?.admin && user ? <GuideBanner portal="admin" userId={user.id} /> : null}{children}</div>
      </div>
    </div>
  );
}
