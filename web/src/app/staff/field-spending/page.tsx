import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { PageHead } from '@/features/admin/ui';
import { fieldFinance } from '@/server/field-finance';
import { PayIdentityPanel, SpendingPanel } from '@/features/field-portal/FinancePanels';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Field spending', path: '/staff/field-spending', noindex: true, description: 'Money field staff spent, and their pay details.' });

// Finance > Field spending (r35 part X; 0930, 0931): approve or refuse what field staff spent, pay it back, and who is missing pay details.
export default async function FieldSpending() {
  const { user, aal } = await vaPage('/staff/field-spending', ['finance']);
  const f = await fieldFinance(user.id, aal, 'finance');
  return (<><PageHead title="Field spending" purpose="Money field staff spent for the company: check the receipt, approve or refuse, then mark it paid back. Below, who has not entered their pay details." />
    <SpendingPanel rows={f.spends} /><PayIdentityPanel rows={f.ids} /></>);
}
