import { redirect } from 'next/navigation';
import { vaPage } from '@/server/va';
import { movedTo } from '@/features/admin/hubs';

export const dynamic = 'force-dynamic';

// Payout reconciliation (05-va.md section 2) is Finance > Money > Reconciliation since the r27 consolidation: old links keep their month.
export default async function VaReconciliation({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [, sp] = await Promise.all([vaPage('/staff/money?tab=reconciliation', ['finance']), searchParams]);
  redirect(movedTo('/staff/money', 'reconciliation', sp));
}
