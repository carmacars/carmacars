import { pageMeta } from '@/features/seo/meta';
import { vaPage } from '@/server/va';
import { door } from '@/server/door';
import { Card, PageHead } from '@/features/admin/ui';
import { ExpenseCapture } from '@/features/expenses/ExpenseCapture';
import { ExpenseEntries, type ExpenseEntry } from '@/features/expenses/ExpenseEntries';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Expenses', path: '/staff/expenses', noindex: true, description: 'Log an expense from its receipt photos.' });

// R50 hotfix 2 (5143): Admin > Expenses' receipt capture for Finance and Fleet: take or upload the receipt photos, check what
// was read, save. The car's owner pays by default (the owner's next statement), or CarmaCars.
export default async function StaffExpenses() {
  const { user, aal } = await vaPage('/staff/expenses', ['finance', 'fleet']);
  const logged = await door<ExpenseEntry[]>(user.id, 'ops_read', 'expense_entries', { limit: 30 }, aal).catch(() => [] as ExpenseEntry[]);
  return (<><PageHead title="Expenses" purpose="Log what you paid for a car or the company from the receipt: a photo is enough. Check what was read, then save." />
    <ExpenseCapture />
    <Card title="Logged from receipts"><ExpenseEntries rows={logged ?? []} base="/staff" /></Card></>);
}
