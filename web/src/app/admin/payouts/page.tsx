import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Payouts is a tab of Money > Owner money.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/owner-money', 'payouts', await searchParams));
}
