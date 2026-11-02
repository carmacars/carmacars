import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Renter leads is the Leads tab of People > Renters (a search or filter is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/renters', 'leads', await searchParams));
}
