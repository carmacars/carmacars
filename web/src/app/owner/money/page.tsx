import { pageMeta } from '@/features/seo/meta';
import { PageHeader } from '@/features/portal/Chrome';
import { requireOwner } from '@/server/owner/data';
import { PortalTabs } from '@/features/portal-nav/PortalTabs';
import { tabOf, tabsFor } from '@/features/portal-nav/tabs';
import { OWNER_MONEY_TABS } from '@/features/owner/menu';
import { StatementsTab } from './StatementsTab';
import { PayoutsTab } from './PayoutsTab';
import { InvoicesTab } from './InvoicesTab';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Money', path: '/owner/money', noindex: true, description: 'Your statements, payouts and invoices.' });

// Money (r27 portals: three pages behind chips became one page with tabs). Statements (what you earned, this month so far
// first), Payouts (what we sent), Invoices (what you owe; a partner rental company pays no fees, so it has no Invoices).
// /owner/statements, /owner/payouts and /owner/invoices redirect to their tabs; a statement and an invoice keep their pages.
export default async function OwnerMoney({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([requireOwner('/owner/money'), searchParams]);
  const tabs = tabsFor(OWNER_MONEY_TABS, { partner: ctx.home.kind === 'partner' });
  const tab = tabOf(tabs, sp.tab);
  const due = ctx.home.invoices.filter((i) => i.payable).length;
  return (
    <>
      <PageHeader title="Money" />
      <PortalTabs label="Money" tabs={tabs} current={tab.key} counts={{ invoices: due }} />
      {tab.key === 'payouts' ? <PayoutsTab {...ctx} /> : tab.key === 'invoices' ? <InvoicesTab {...ctx} /> : <StatementsTab {...ctx} />}
    </>
  );
}
