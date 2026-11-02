import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Owner invoices is the Invoices tab of Money > Owner money (a status filter or search is kept). An invoice keeps its own page.
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/owner-money', 'invoices', await searchParams));
}
