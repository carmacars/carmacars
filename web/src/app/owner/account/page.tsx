import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { requireOwner } from '@/server/owner/data';
import { rpc } from '@/lib/db/repo';
import { PortalTabs } from '@/features/portal-nav/PortalTabs';
import { tabOf } from '@/features/portal-nav/tabs';
import { OWNER_ACCOUNT_TABS } from '@/features/owner/menu';
import { ProfileTab } from './ProfileTab';
import { BankingTab } from './BankingTab';
import { NotificationsTab } from './NotificationsTab';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Account', path: '/owner/account', noindex: true, description: 'Your owner details, banking and notifications.' });

// Account (r27 portals: three pages behind chips became one page with tabs). /owner/profile, /owner/banking and
// /owner/notifications redirect to their tabs with their query.
export default async function OwnerAccount({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([requireOwner('/owner/account'), searchParams]);
  const tab = tabOf(OWNER_ACCOUNT_TABS, sp.tab);
  const unread = await rpc('my_unread_count', {}, { role: 'authenticated', userId: ctx.user.id }).then(Number).catch(() => 0);
  // the payout account is the one thing an owner with cars must add (payouts need it): its tab says so
  const banking = ctx.home.vehicles.length > 0 && !ctx.home.payout_accounts.length ? 1 : 0;
  return (
    <>
      <PageHeader title="Account" purpose={tab.key === 'banking' ? 'Where we pay you, and how your fees are paid.' : tab.key === 'notifications' ? undefined : 'Your contact details and the details your agreements and registry forms use.'} />
      <PortalTabs label="Account" tabs={OWNER_ACCOUNT_TABS} current={tab.key} counts={{ notifications: unread || 0, banking }} />
      {tab.key === 'banking' ? <BankingTab {...ctx} /> : tab.key === 'notifications' ? <NotificationsTab {...ctx} /> : <ProfileTab {...ctx} />}
    </>
  );
}
