import { pageMeta } from '@/features/seo/meta';
import { page } from '@/server/admin/api';
import { tabOf } from '@/features/admin/hubs';
import { Invoices } from './Invoices';
import { Debits } from './Debits';
import { Statements } from './Statements';
import { Payouts } from './Payouts';

export const dynamic = 'force-dynamic';
export const metadata = pageMeta({ title: 'Owner money', path: '/admin/owner-money', noindex: true, description: 'Owner invoices, the monthly debit, owner statements and payouts.' });

const TABS = ['invoices', 'debits', 'statements', 'payouts'] as const;

// Money > Owner money (r27, the owner on November 1, 2026: "We need less pages not more"): the money between CarmaCars
// and its owners on one page. Invoices (what owners owe), Debits (how it is collected), Statements (what they earned) and
// Payouts (how it is paid). /admin/invoices, /admin/debits, /admin/statements and /admin/payouts redirect to their tabs;
// an invoice's and a statement's own pages keep their addresses.
export default async function OwnerMoney({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const [ctx, sp] = await Promise.all([page('/admin/owner-money'), searchParams]);
  const tab = tabOf(TABS, sp.tab);
  if (tab === 'debits') return <Debits ctx={ctx} />;
  if (tab === 'statements') return <Statements ctx={ctx} sp={sp} />;
  if (tab === 'payouts') return <Payouts ctx={ctx} sp={sp} />;
  return <Invoices ctx={ctx} sp={sp} />;
}
