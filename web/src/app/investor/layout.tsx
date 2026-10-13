import '@/styles/portal.css';
import Link from 'next/link';
import { signOut } from '@/server/actions/auth';
import { currentUser } from '@/server/portal/data';

// The investor area (07-investor.md): statements for existing investors only. Not linked from anywhere
// public, not in the sitemap, disallowed in robots.txt and sent with noindex.
export default async function InvestorLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  return (
    <div className="pt">
      <div className="container" style={{ maxWidth: '45rem', paddingBlock: 'var(--s-6)' }}>
        <nav className="row" aria-label="Investor" style={{ justifyContent: 'space-between', marginBottom: 'var(--s-5)', flexWrap: 'wrap', gap: 'var(--s-3)' }}>
          <span className="row" style={{ gap: 'var(--s-4)' }}><Link prefetch={false} className="link" href="/investor">Investments</Link><Link prefetch={false} className="link" href="/investor/statements">Statements</Link><Link prefetch={false} className="link" href="/investor/profile">Profile and notices</Link></span>
          {user && <form action={signOut}><button className="btn btn--quiet btn--sm" type="submit">Sign out</button></form>}
        </nav>
        {children}
      </div>
    </div>
  );
}
