import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Payments by day is the By day tab of Money > Payments (the query, a date range or methods, is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/money', 'day', await searchParams));
}
