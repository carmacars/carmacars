import '@/styles/portal.css';
import '@/styles/owner.css';
import '@/styles/admin.css';
import { currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';
import { AdminNav } from '@/features/admin/AdminNav';
import { adminGate } from '@/server/admin/data';
import { adminRead } from '@/server/admin/api';

// The admin portal's frame (docs/blueprint/03-admin.md): the rail of sections, who is signed in, the
// counts that need someone. Every page checks the Admin role and two-step sign-in itself (requireAdmin);
// the frame shows the rail only to an Admin.
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const gate = user ? await adminGate(user).catch(() => null) : null;
  let counts: Record<string, number> = {};
  if (user && gate?.admin) {
    try {
      const d = await adminRead<{ requests: unknown[]; approvals: { listings: number; statements: number; tolls: number; refunds: number } }>(user.id, 'dashboard');
      counts = { '/admin/requests': d.requests.length, '/admin/listings': d.approvals.listings, '/admin/statements': d.approvals.statements, '/admin/tolls': d.approvals.tolls, '/admin/money': d.approvals.refunds };
    } catch { counts = {}; }
  }
  return (
    <div className="ad">
      <div className="ad__frame">
        {gate?.admin ? (
          <aside className="ad__rail">
            <div className="ad__who"><span className="muted">Admin · <b>{gate.name ?? user?.email}</b></span>
              <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form></div>
            <AdminNav counts={counts} />
          </aside>
        ) : <div />}
        <div className="ad__main">{children}</div>
      </div>
    </div>
  );
}
