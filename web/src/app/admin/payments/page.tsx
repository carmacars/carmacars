import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';
import { ADMIN_MOVED } from '@/server/portal-access';

// r27: Payments by day is the By day tab of Money > Payments (the query, a date range or methods, is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const [to, tab, tabs] = ADMIN_MOVED['/admin/payments']!;
  redirect(movedTo(to, tab, await searchParams, tabs));
}
