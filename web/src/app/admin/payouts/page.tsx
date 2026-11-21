import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: Payouts is a tab of Money > Owner money.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/payouts']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
