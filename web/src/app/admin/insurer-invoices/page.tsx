import { redirect } from 'next/navigation';
import { movedTo } from '@/features/admin/hubs';

// r27: Insurer invoices is the Invoices tab of Money > Insurers (a status filter is kept).
export default async function Moved({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  redirect(movedTo('/admin/insurers', 'invoices', await searchParams));
}
