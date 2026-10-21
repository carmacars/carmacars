import '@/styles/portal.css';
import Link from 'next/link';
import { PortalSwitch, SignOutOrExit } from '@/features/access/Access';
import { currentUser } from '@/server/portal/data';
import { GuideBanner, GuideLink } from '@/features/guides/GuideFrame';
import { door, rolesOf } from '@/server/door';

// The investor area (07-investor.md): statements for existing investors only. Not linked from anywhere
// public, not in the sitemap, disallowed in robots.txt and sent with noindex.
export default async function InvestorLayout({ children }: { children: React.ReactNode }) {
  const user = await currentUser();
  const roles = user ? await rolesOf(user.id).catch(() => null) : null;
  const investor = roles?.investor ?? false;
  // the investor deck (0078): for investors while the Admin shows it, for Admins always
  const deck = investor ? await door<{ visible: boolean }>(user!.id, 'investor_read', 'deck_visible').then((r) => r.visible).catch(() => false) : roles?.admin ?? false;
  return (
    <div className="pt">
      <div className="container" style={{ maxWidth: '45rem', paddingBlock: 'var(--s-6)' }}>
        <nav className="row" aria-label="Investor" style={{ justifyContent: 'space-between', marginBottom: 'var(--s-5)', flexWrap: 'wrap', gap: 'var(--s-3)' }}>
          <span className="row" style={{ gap: 'var(--s-4)' }}><Link prefetch={false} className="link" href="/investor">Investments</Link><Link prefetch={false} className="link" href="/investor/statements">Statements</Link><Link prefetch={false} className="link" href="/investor/profile">Profile and notices</Link>{deck && <Link prefetch={false} className="link" href="/investor/deck" data-testid="nav-deck">Investor deck</Link>}{investor && <Link prefetch={false} className="link" href="/investor/sign">Documents to sign</Link>}</span>
          {user && <span className="gd-frame-links">{investor && <GuideLink portal="investor" />}<SignOutOrExit /></span>}
        </nav>
        {user && <div style={{ marginBottom: 'var(--s-4)' }}><PortalSwitch current="investor" /></div>}
        {user && investor && <div style={{ marginBottom: 'var(--s-4)' }}><GuideBanner portal="investor" userId={user.id} /></div>}
        {children}
      </div>
    </div>
  );
}
