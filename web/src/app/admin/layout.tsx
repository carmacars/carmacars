import '@/styles/portal.css';
import '@/styles/owner.css';
import Link from 'next/link';
import { currentUser } from '@/server/portal/data';
import { signOut } from '@/server/actions/auth';

// The admin portal's frame (docs/blueprint/03-admin.md). Only the owner billing screens exist so far;
// every page checks the Admin role and two-step sign-in itself (requireAdmin).
export default async function AdminLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  return (
    <div className="pt">
      <div className="wrap pt__top">
        <div className="pt__hello">
          <p className="small muted">Admin{user ? <> · <b>{user.email}</b></> : null}</p>
          {user && <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form>}
        </div>
        <nav className="pt__nav" aria-label="Admin">
          <Link href="/admin/owners">Owner applications</Link>
          <Link href="/admin/invoices">Owner invoices</Link>
        </nav>
      </div>
      <div className="wrap pt__body">{children}</div>
    </div>
  );
}
