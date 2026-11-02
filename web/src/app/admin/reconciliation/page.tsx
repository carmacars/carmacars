import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Reconciliation is a tab of Money > Payments.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/money', 'reconciliation', await searchParams));
}
