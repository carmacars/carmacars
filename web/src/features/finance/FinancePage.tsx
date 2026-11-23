import { Tabs, PageHead } from '@/features/admin/ui';
import { FinanceOverview } from './FinanceOverview';
import { BankImport } from './BankImport';
import { BankLines } from './BankLines';
import { FeedSync } from './FeedSync';
import type { BankLinesView, Dashboard } from './model';
import type { StripeCash } from './stripe-cash';

// Release 49 (3480): the one Finance page for Admin (Company > Finance) and the Finance role (Money > Finance): the same
// screens, the same database checks (the owner: every Admin upgrade reaches the matching staff portal).
export function FinancePage({ tab, dash, stripe, lines, base, bookingBase }: {
  tab: 'overview' | 'bank'; dash: Dashboard | null; stripe: StripeCash | { error: string } | null; lines: BankLinesView | null; base: '/admin' | '/staff'; bookingBase: string;
}) {
  const page = `${base}/finance`;
  const open = lines?.counts.unmatched ?? 0;
  return (<>
    <PageHead title="Finance" purpose="Cash in the bank and at Stripe, money in and out, HST, what renters and insurers owe, and the bank lines matched to their records.">
      {lines && lines.provider !== 'file' ? <FeedSync provider={lines.provider} /> : null}
    </PageHead>
    <Tabs label="Finance" current={tab === 'bank' ? `${page}?tab=bank` : page} items={[[page, 'Overview'], [`${page}?tab=bank`, 'Bank lines', open]]} />
    {tab === 'bank' && lines ? (<>
      <BankImport accounts={lines.accounts} refresh={page} />
      <BankLines v={lines} page={page} />
    </>) : dash ? <FinanceOverview d={dash} stripe={stripe} base={base} bookingBase={bookingBase} /> : null}
  </>);
}
