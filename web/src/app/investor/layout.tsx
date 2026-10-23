import '@/styles/portal.css';
import { InvestorNav } from '@/features/investor/InvestorNav';
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
  // the investor deck (0083): for investors while the Admin shows it, for Admins always
  const deck = investor ? await door<{ visible: boolean }>(user!.id, 'investor_read', 'deck_visible').then((r) => r.visible).catch(() => false) : roles?.admin ?? false;
  return (
    <div className="pt">
      <div className="container iv-frame" style={{ maxWidth: '45rem', paddingBlock: 'var(--s-4) var(--s-6)' }}>
        {user && (
          <div className="pt__top iv-top">
            <div className="pt__hello"><p className="small muted">Investor portal · <b data-testid="account-email">{user.email}</b></p>
              <span className="gd-frame-links">{investor && <GuideLink portal="investor" />}<SignOutOrExit /></span></div>
            <PortalSwitch current="investor" />
            <InvestorNav deck={deck} investor={investor} />
            {investor && <GuideBanner portal="investor" userId={user.id} />}
          </div>
        )}
        <div className="iv-body">{children}</div>
      </div>
    </div>
  );
}
