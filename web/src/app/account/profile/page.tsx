import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { requireUser } from '@/server/portal/data';
import { PortalTabs } from '@/features/portal-nav/PortalTabs';
import { tabOf } from '@/features/portal-nav/tabs';
import { RENTER_ACCOUNT_TABS } from '@/features/portal/menu';
import { ProfileTab } from './ProfileTab';
import { NotificationsTab } from './NotificationsTab';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Account', path: '/account/profile', noindex: true, description: 'Your details, sign-in, card on file, drivers, messages and email preferences.' });

// Account (r27 portals): Profile and Notifications on one page with tabs (two menu links before). /account/notifications
// redirects to its tab with its query.
export default async function AccountPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [user, sp] = await Promise.all([requireUser('/account/profile'), searchParams]);
  const tab = tabOf(RENTER_ACCOUNT_TABS, sp.tab);
  return (
    <>
      <PageHeader title="Account" purpose={tab.key === 'notifications' ? 'Messages from CarmaCars, and which optional emails you get.' : 'Your details, sign-in, card on file and drivers.'} />
      <PortalTabs label="Account" tabs={RENTER_ACCOUNT_TABS} current={tab.key} />
      {tab.key === 'notifications' ? <NotificationsTab user={user} /> : <ProfileTab user={user} />}
    </>
  );
}
